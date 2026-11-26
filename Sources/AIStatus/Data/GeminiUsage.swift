import Foundation

/// Gemini 订阅额度：运行 Antigravity CLI（`agy`）自带的 `/usage` 命令，解析它打印的额度表。
/// 不读取任何登录令牌，登录和续期都由 agy 自己负责；本机没装 agy 或没登录就不显示。
/// 输出是制表符分隔的几行：
///   Gemini Models\tWeekly Limit Remaining\t100%\t2026-12-03T07:40:32Z
///   Gemini Models\tFive Hour Limit Remaining\t100%\t2026-11-26T12:40:32Z
///   Claude and GPT models\tWeekly Limit Remaining\t100%\t1970-01-01T00:00:00Z   （1970 表示这组额度还没用过）
/// `/credits` 另外给出 Google AI Credits 余额：`Remaining credits\t0`
enum GeminiUsageClient {
    static let timeout: TimeInterval = 40

    static func fetch() async throws -> ProviderQuota {
        guard let agy = locate() else { throw FetchError.noCredentials(L("本机未安装 Antigravity，安装并登录后自动显示")) }
        async let usage = run(agy, "/usage")
        async let credits = run(agy, "/credits")
        let usageOutput = try await usage
        let creditsOutput = try? await credits
        var quota = try parse(usageOutput)
        quota.credits = creditsOutput.flatMap(parseCredits)
        return quota
    }

    /// agy 的安装位置：官方安装脚本放在 ~/.local/bin，也可能被装进 Homebrew 或 PATH 里
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/agy", "\(home)/.antigravity-cli/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/agy" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static func run(_ agy: URL, _ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = agy
                // 日志丢掉，不然每次查询都在 ~/.gemini 里多一个日志文件
                process.arguments = ["--log-file", "/dev/null", "-p", command]
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(throwing: FetchError.noCredentials(L("本机未安装 Antigravity，安装并登录后自动显示")))
                    return
                }
                // 超时就结束它，不能让后台查询一直挂着
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    static func parse(_ output: String) throws -> ProviderQuota {
        struct Row { let group: String; let fiveHour: Bool; let remaining: Double; let resets: Date? }
        var rows: [Row] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, cells[1].localizedCaseInsensitiveContains("limit"),
                  let remaining = Double(cells[2].replacingOccurrences(of: "%", with: ""))
            else { continue }
            let resets = cells.count > 3 ? DateParsing.iso8601(cells[3]) : nil
            rows.append(Row(group: cells[0], fiveHour: cells[1].localizedCaseInsensitiveContains("five hour"),
                            remaining: remaining, resets: resets))
        }
        guard !rows.isEmpty else {
            // 没登录时 agy 打印的是提示文字
            if output.localizedCaseInsensitiveContains("log") && output.localizedCaseInsensitiveContains("in") {
                throw FetchError.noCredentials(L("本机未登录 Antigravity，登录后自动显示"))
            }
            throw FetchError.badResponse
        }
        var windows: [QuotaWindow] = []
        for row in rows {
            // 1970 的重置时间表示这组额度还没动过：满额时不显示，免得多出两行永远是 100% 的
            let untouched = (row.resets ?? .distantPast) < Date(timeIntervalSince1970: 86_400 * 365)
            let isGemini = row.group.localizedCaseInsensitiveContains("gemini")
            if untouched && row.remaining >= 100 && !isGemini { continue }
            let group = isGemini ? "Gemini" : L("Claude 和 GPT")
            windows.append(QuotaWindow(
                id: (isGemini ? "gemini" : "partner") + (row.fiveHour ? "_5h" : "_weekly"),
                name: row.fiveHour ? .fiveHourOf(group) : .weeklyModel(group),
                usedPercent: 100 - row.remaining,
                resetsAt: untouched ? nil : row.resets,
                weekly: isGemini && !row.fiveHour))
        }
        // 先 Gemini 后其他；同一组里周额度在前
        windows.sort { rank($0) < rank($1) }
        return ProviderQuota(plan: nil, windows: windows, credits: nil, source: .live, asOf: Date())
    }

    private static func rank(_ w: QuotaWindow) -> Int {
        (w.id.hasPrefix("gemini") ? 0 : 2) + (w.id.hasSuffix("_5h") ? 1 : 0)
    }

    /// 「Remaining credits\t0」；0 不显示
    static func parseCredits(_ output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline) where line.localizedCaseInsensitiveContains("credits") {
            let cells = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count >= 2, let value = Double(cells[1].replacingOccurrences(of: ",", with: "")), value > 0 { return value }
        }
        return nil
    }
}
