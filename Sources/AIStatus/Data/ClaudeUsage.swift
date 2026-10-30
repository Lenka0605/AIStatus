import Foundation

/// Claude 订阅额度：读取 Claude Code 的 OAuth 凭证，请求 Anthropic 的用量接口（只读）
enum ClaudeUsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
        let tier: String?
    }

    static func fetch() async throws -> ProviderQuota {
        let creds = try loadCredentials()
        let data = try await fetchRaw(creds)
        let plan = await PlanCache.shared.plan(for: creds) ?? creds.plan.map { planName($0, tier: creds.tier) }
        return try parse(data, plan: plan)
    }

    /// 账户接口返回的当前套餐。凭证里的 subscriptionType 是登录时写下的，升级或降级后要重新登录才会变，
    /// 所以以账户接口为准，拿不到再用凭证里的
    static func fetchPlan(_ creds: Credentials) async -> String? {
        var req = URLRequest(url: profileEndpoint, timeoutInterval: 15)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = json["organization"] as? [String: Any],
              // claude_max / claude_pro / claude_team / claude_enterprise；其他类型（如 API 账户）不认
              let type = (org["organization_type"] as? String)?.lowercased(), type.hasPrefix("claude_")
        else { return nil }
        let raw = String(type.dropFirst("claude_".count))
        guard ["max", "pro", "team", "enterprise"].contains(raw) else { return nil }
        return planName(raw, tier: org["rate_limit_tier"] as? String)
    }

    static func loadCredentials() throws -> Credentials {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let raw = SecurityCLI.read(service: "Claude Code-credentials")
            ?? (try? String(contentsOf: fileURL, encoding: .utf8))
        guard let raw,
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw FetchError.noCredentials("本机未登录 Claude Code，登录后自动显示") }
        return Credentials(
            accessToken: token,
            expiresAt: jsonNumber(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            plan: oauth["subscriptionType"] as? String,
            tier: oauth["rateLimitTier"] as? String
        )
    }

    static func fetchRaw(_ creds: Credentials) async throws -> Data {
        // 不自己刷新令牌：刷新会让 Claude Code 保存的凭证失效。用一下 Claude Code 就会自动续期。
        if let exp = creds.expiresAt, exp < Date() {
            throw FetchError.expired("登录凭证已过期，使用一次 Claude Code 后自动恢复")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw FetchError.unauthorized("凭证无效，使用一次 Claude Code 后自动恢复")
        }
        if status == 429, let http = response as? HTTPURLResponse { throw FetchError.rateLimited(http) }
        guard status == 200 else { throw FetchError.http(status) }
        return data
    }

    static func parse(_ data: Data, plan: String?) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse
        }
        let known: [(key: String, label: String, always: Bool)] = [
            ("five_hour", "5 小时", true),
            ("seven_day", "本周", true),
            ("seven_day_opus", "本周 Opus", false),
            ("seven_day_sonnet", "本周 Sonnet", false),
        ]
        var windows: [QuotaWindow] = []
        for item in known {
            guard let w = json[item.key] as? [String: Any], let used = jsonNumber(w["utilization"]) else { continue }
            let resets = (w["resets_at"] as? String).flatMap(DateParsing.iso8601)
            // 按模型区分的周额度只在实际使用过（有重置时间）时显示
            if !item.always && resets == nil { continue }
            windows.append(QuotaWindow(id: item.key, label: item.label, usedPercent: used, resetsAt: resets,
                                       weekly: item.key == "seven_day"))
        }
        guard !windows.isEmpty else { throw FetchError.badResponse }
        return ProviderQuota(plan: plan, windows: windows, credits: nil, source: .live, asOf: Date())
    }

    /// subscriptionType 只区分 max / pro，Max 的两个档位要看 rateLimitTier（如 default_claude_max_20x）
    static func planName(_ raw: String, tier: String?) -> String {
        switch raw.lowercased() {
        case "max":
            let tier = tier?.lowercased() ?? ""
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// 个人套餐的月费（美元）；团队、企业版按席位计费，不显示
    static func monthlyPrice(_ plan: String) -> Int? {
        ["Pro": 20, "Max 5x": 100, "Max 20x": 200][plan]
    }
}

/// 套餐很少变，同一个登录凭证 6 小时内只问一次账户接口
private actor PlanCache {
    static let shared = PlanCache()
    private var entry: (token: String, plan: String, at: Date)?

    func plan(for creds: ClaudeUsageClient.Credentials) async -> String? {
        let cached = entry?.token == creds.accessToken ? entry : nil
        if let cached, Date().timeIntervalSince(cached.at) < 6 * 3600 { return cached.plan }
        guard let plan = await ClaudeUsageClient.fetchPlan(creds) else { return cached?.plan }
        entry = (creds.accessToken, plan, Date())
        return plan
    }
}
