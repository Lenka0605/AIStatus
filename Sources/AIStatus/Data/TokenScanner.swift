import Foundation

/// 统计今天（本地时区）这台电脑上 Claude Code 与 Codex 消耗的 token。
/// 按文件记录读取位置，每次只解析新追加的行；跨天自动清零。
/// 新版 Codex 不再写 rollout-*.jsonl，没有 jsonl 的会话改从运行日志数据库补充（见 CodexRunLog）。
actor TokenScanner {
    private var day = Date.distantPast

    private var claudeOffsets: [String: UInt64] = [:]
    private var claudeSeen: [String: TokenTotals] = [:]
    private var claude = TokenTotals()

    private struct CodexFile {
        var offset: UInt64 = 0
        var last: TokenTotals?
        var countedToday = false
    }
    private var codexFiles: [String: CodexFile] = [:]
    private var codex = TokenTotals()

    // Codex 运行日志：按 id 增量累加（日志会删旧行，不能每次重算）
    private var runLogPath: URL?
    private var runLogLastID: Int64 = 0
    private var runLogByThread: [String: Int] = [:]

    private static let claudeRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
    }()

    func scan(now: Date = Date()) -> (claude: TokenTotals, codex: TokenTotals) {
        let start = Calendar.current.startOfDay(for: now)
        if start != day {
            day = start
            claudeOffsets = [:]; claudeSeen = [:]; claude = TokenTotals()
            codexFiles = [:]; codex = TokenTotals()
            runLogLastID = 0; runLogByThread = [:]
        }

        for file in JSONLFiles.list(under: Self.claudeRoots, modifiedSince: start) {
            let path = file.url.path
            claudeOffsets[path] = JSONLFiles.readLines(file.url, from: claudeOffsets[path] ?? 0) { line in
                processClaude(line)
            }
        }

        for file in JSONLFiles.list(under: CodexUsageClient.sessionRoots, modifiedSince: start) {
            // 用文件名做键：会话被归档（移动目录）后不会重复统计
            let key = file.url.lastPathComponent
            var state = codexFiles[key] ?? CodexFile()
            state.offset = JSONLFiles.readLines(file.url, from: state.offset) { line in
                processCodex(line, state: &state)
            }
            codexFiles[key] = state
        }

        // rollout 文件名末尾 36 位是会话 ID；这些会话已经按 jsonl 精确统计，运行日志里跳过它们
        let jsonlSessions = Set(codexFiles.filter { $0.value.countedToday }.map { String($0.key.dropLast(6).suffix(36)) })
        if let db = CodexRunLog.latestDatabase() {
            if db != runLogPath { runLogPath = db; runLogLastID = 0 }   // 日志库换了版本，id 从头开始
            if let batch = CodexRunLog.newTokens(in: db, afterID: runLogLastID, since: start) {
                runLogLastID = batch.lastID
                runLogByThread.merge(batch.tokensByThread, uniquingKeysWith: +)
            }
        }
        let logged = runLogByThread.filter { !jsonlSessions.contains($0.key) }.values.reduce(0, +)
        return (claude, codex + TokenTotals(other: logged))
    }

    private func processClaude(_ line: Data) {
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(DateParsing.iso8601), ts >= day
        else { return }

        let u = TokenTotals(
            input: jsonInt(usage["input_tokens"]),
            output: jsonInt(usage["output_tokens"]),
            cacheWrite: jsonInt(usage["cache_creation_input_tokens"]),
            cacheRead: jsonInt(usage["cache_read_input_tokens"])
        )
        // 同一条消息会按内容块写多行，用 消息ID+请求ID 去重，取各字段最大值
        guard let id = message["id"] as? String else { claude = claude + u; return }
        let key = id + ":" + (obj["requestId"] as? String ?? "")
        let previous = claudeSeen[key] ?? TokenTotals()
        let merged = previous.fieldwiseMax(u)
        claude = claude + (merged - previous)
        claudeSeen[key] = merged
    }

    private func processCodex(_ line: Data, state: inout CodexFile) {
        guard line.range(of: Data("\"token_count\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any]
        else { return }

        // input_tokens 已包含缓存命中部分
        let input = jsonInt(total["input_tokens"])
        let cached = jsonInt(total["cached_input_tokens"])
        let cacheWrite = jsonInt(total["cache_write_input_tokens"])
        let current = TokenTotals(
            input: max(0, input - cached - cacheWrite),
            output: jsonInt(total["output_tokens"]),
            cacheWrite: cacheWrite,
            cacheRead: cached
        )
        // total_token_usage 是会话累计值，取相邻两次的差；今天之前的事件只用来定基准
        var delta = current
        if let last = state.last {
            let diff = current - last
            if diff.input >= 0, diff.output >= 0, diff.cacheWrite >= 0, diff.cacheRead >= 0 { delta = diff }
        }
        state.last = current
        if let ts = (obj["timestamp"] as? String).flatMap(DateParsing.iso8601), ts >= day {
            codex = codex + delta
            state.countedToday = true
        }
    }
}

enum JSONLFiles {
    struct Entry {
        let url: URL
        let modified: Date
    }

    static func list(under roots: [URL], modifiedSince: Date?) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var out: [Entry] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate
                else { continue }
                if let since = modifiedSince, modified < since { continue }
                out.append(Entry(url: url, modified: modified))
            }
        }
        return out
    }

    /// 从 offset 开始读取完整的行（不含最后一个未写完的行），返回新的 offset
    static func readLines(_ url: URL, from offset: UInt64, _ body: (Data) -> Void) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return offset }
        let start = size < offset ? 0 : offset
        guard size > start else { return start }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return start }
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) where !line.isEmpty {
            body(Data(line))
        }
        return start + UInt64(lastNewline - data.startIndex + 1)
    }

    static func tail(of url: URL, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        return try? handle.readToEnd()
    }
}
