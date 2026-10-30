import Foundation

/// ChatGPT（Codex）额度：优先联网实时查询，失败时用本地会话日志里最近一次记录
enum CodexUsageClient {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static var home: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var sessionRoots: [URL] {
        [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
    }

    /// 联网失败时用本地日志兜底：返回兜底额度（来源标记为 .log）以及联网的错误
    static func fetch() async -> (quota: ProviderQuota?, liveError: Error?) {
        do {
            return (try parse(try await fetchRaw()), nil)
        } catch {
            return (CodexLogReader.latestQuota(), error)
        }
    }

    static func fetchRaw() async throws -> Data {
        let authURL = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else { throw FetchError.noCredentials("本机未登录 Codex，登录后自动显示") }

        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = tokens["account_id"] as? String {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        let (body, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw FetchError.unauthorized("Codex 凭证已过期，使用一次 Codex 后自动恢复")
        }
        if status == 429, let http = response as? HTTPURLResponse { throw FetchError.rateLimited(http) }
        guard status == 200 else { throw FetchError.http(status) }
        return body
    }

    static func parse(_ data: Data) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse
        }
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        var windows: [QuotaWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rateLimit[key] as? [String: Any], let used = jsonNumber(w["used_percent"]) else { continue }
            let minutes = jsonNumber(w["limit_window_seconds"]).map { Int(($0 / 60).rounded()) }
                ?? jsonNumber(w["window_minutes"]).map { Int($0.rounded()) }
            var resets = jsonNumber(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            if resets == nil, let after = jsonNumber(w["reset_after_seconds"]) {
                resets = Date().addingTimeInterval(after)
            }
            windows.append(QuotaWindow(id: key, label: windowLabel(minutes: minutes), usedPercent: used, resetsAt: resets,
                                       weekly: isWeekly(minutes)))
        }
        guard !windows.isEmpty else { throw FetchError.badResponse }
        return ProviderQuota(
            plan: (json["plan_type"] as? String).map(planName),
            windows: windows,
            credits: credits(json["credits"]),
            source: .live,
            asOf: Date()
        )
    }

    static func credits(_ any: Any?) -> Double? {
        guard let c = any as? [String: Any], c["unlimited"] as? Bool != true,
              c["has_credits"] as? Bool != false else { return nil }
        return jsonNumber(c["balance"])
    }

    /// 允许一小时误差（有的版本给 10079 分钟或 604799 秒）
    static func isWeekly(_ minutes: Int?) -> Bool {
        minutes.map { abs($0 - 10_080) <= 60 } ?? false
    }

    static func windowLabel(minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        if isWeekly(minutes) { return "本周" }
        switch minutes {
        case 1_380...: return "\(Int((Double(minutes) / 1_440).rounded())) 天"
        case 55...: return "\(Int((Double(minutes) / 60).rounded())) 小时"
        default: return "\(minutes) 分钟"
        }
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        case "free": return "Free"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// 个人套餐的月费（美元）；团队、企业版按席位计费，Go 各地区定价不同，都不显示
    static func monthlyPrice(_ plan: String) -> Int? {
        ["Plus": 20, "Pro": 200][plan]
    }
}

/// 从 Codex 会话日志（rollout-*.jsonl）的 token_count 事件里取最近一次额度信息
enum CodexLogReader {
    static func latestQuota() -> ProviderQuota? {
        let files = JSONLFiles.list(under: CodexUsageClient.sessionRoots, modifiedSince: nil)
            .sorted { $0.modified > $1.modified }
            .prefix(5)
        for file in files {
            guard let tail = JSONLFiles.tail(of: file.url, maxBytes: 4 << 20) else { continue }
            for line in tail.split(separator: 0x0A).reversed() {
                guard line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                      let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let limits = payload["rate_limits"] as? [String: Any],
                      let quota = quota(from: limits, timestamp: obj["timestamp"] as? String)
                else { continue }
                return quota
            }
        }
        return nil
    }

    private static func quota(from limits: [String: Any], timestamp: String?) -> ProviderQuota? {
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = jsonNumber(w["used_percent"]) else { continue }
            let minutes = jsonNumber(w["window_minutes"]).map { Int($0.rounded()) }
            windows.append(QuotaWindow(
                id: key,
                label: CodexUsageClient.windowLabel(minutes: minutes),
                usedPercent: used,
                resetsAt: jsonNumber(w["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                weekly: CodexUsageClient.isWeekly(minutes)
            ))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderQuota(
            plan: (limits["plan_type"] as? String).map(CodexUsageClient.planName),
            windows: windows,
            credits: CodexUsageClient.credits(limits["credits"]),
            source: .log,
            asOf: timestamp.flatMap(DateParsing.iso8601) ?? Date()
        )
    }
}
