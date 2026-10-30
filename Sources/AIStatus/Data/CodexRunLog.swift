import Foundation
import SQLite3

/// 新版 Codex（ChatGPT 桌面应用内置）把会话存进数据库，不再写 rollout-*.jsonl。
/// 本机唯一可读的用量痕迹是运行日志 logs_N.sqlite 里每次请求后的
/// "post sampling token usage … total_usage_tokens=N"（该次请求的输入+输出 token，只有总数）。
/// 注意这个日志每个会话只保留最新 1000 行，旧行会被删掉，所以调用方要按 id 增量累加，不能每次重算。
enum CodexRunLog {
    struct Batch {
        var tokensByThread: [String: Int] = [:]
        var lastID: Int64
    }

    /// 读取 id 大于 afterID、时间在 start 之后的新记录
    static func newTokens(in url: URL, afterID: Int64, since start: Date) -> Batch? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.absoluteString + "?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        let sql = """
            SELECT id, thread_id, feedback_log_body FROM logs
            WHERE id > ? AND ts >= ? AND target = 'codex_core::session::turn'
              AND feedback_log_body LIKE '%post sampling token usage%'
            ORDER BY id
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterID)
        sqlite3_bind_int64(stmt, 2, Int64(start.timeIntervalSince1970))

        var batch = Batch(lastID: afterID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            batch.lastID = sqlite3_column_int64(stmt, 0)
            let thread = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let body = sqlite3_column_text(stmt, 2),
                  let tokens = value(of: "total_usage_tokens=", in: String(cString: body)) else { continue }
            batch.tokensByThread[thread, default: 0] += tokens
        }
        return batch
    }

    /// 文件名带版本号（logs_2.sqlite），取版本最大的那个
    static func latestDatabase() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: CodexUsageClient.home, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
            .max { version($0) < version($1) }
    }

    private static func version(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("logs_".count)) ?? 0
    }

    private static func value(of key: String, in text: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        return Int(text[range.upperBound...].prefix(while: \.isNumber))
    }
}
