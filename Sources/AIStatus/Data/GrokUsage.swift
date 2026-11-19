import Foundation

/// Grok 订阅额度：读 Grok CLI（`grok login`）保存在 ~/.grok/auth.json 的登录令牌，请求它 /usage 窗口用的计费接口（只读）。
/// 返回本周期（目前按周）用掉的百分比、各产品（Grok Build 写代码、Grok 聊天）各用了多少、周期的起止时间。
/// 令牌 6 小时过期，由 Grok CLI 自己刷新；这里不去刷新（刷新令牌可能是一次性的，刷了会把 CLI 的登录挤掉），
/// 过期了就提示用一次 Grok
enum GrokUsageClient {
    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok") }

    struct Credentials {
        let token: String
        let expiresAt: Date?
    }

    static func fetch() async throws -> ProviderQuota {
        let creds = try loadCredentials()
        if let expiresAt = creds.expiresAt, expiresAt < Date() {
            throw FetchError.expired(L("Grok 登录已过期，使用一次 Grok 后自动恢复"))
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue(cliVersion, forHTTPHeaderField: "x-grok-client-version")
        req.setValue("interactive", forHTTPHeaderField: "x-grok-client-mode")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200: return try parse(data)
        case 401, 403: throw FetchError.unauthorized(L("Grok 登录已过期，使用一次 Grok 后自动恢复"))
        case 429: throw FetchError.rateLimited(http)
        default: throw FetchError.http(http.statusCode)
        }
    }

    /// auth.json 里每个登录一项（键是「签发方::客户端 ID」），取最近签发的那个
    static func loadCredentials() throws -> Credentials {
        let url = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FetchError.noCredentials(L("本机未登录 Grok，登录后自动显示")) }
        let entries = json.values.compactMap { $0 as? [String: Any] }.filter { ($0["key"] as? String)?.isEmpty == false }
        guard let entry = entries.max(by: { ($0["create_time"] as? String ?? "") < ($1["create_time"] as? String ?? "") }),
              let token = entry["key"] as? String
        else { throw FetchError.noCredentials(L("本机未登录 Grok，登录后自动显示")) }
        return Credentials(token: token, expiresAt: (entry["expires_at"] as? String).flatMap(DateParsing.iso8601))
    }

    /// 和本机 Grok CLI 报一样的版本号；读不到就用写这段代码时的版本
    private static var cliVersion: String {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("version.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String
        else { return "1.0.88" }
        return version
    }

    /// {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":…,"end":…},"creditUsagePercent":14.0,
    ///   "productUsage":[{"product":"GrokBuild","usagePercent":13.0},{"product":"GrokChat","usagePercent":1.0}],…}}
    static func parse(_ data: Data) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["config"] as? [String: Any],
              let used = jsonNumber(config["creditUsagePercent"])
        else { throw FetchError.badResponse }
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let start = (period["start"] as? String ?? config["billingPeriodStart"] as? String).flatMap(DateParsing.iso8601)
        let end = (period["end"] as? String ?? config["billingPeriodEnd"] as? String).flatMap(DateParsing.iso8601)
        let type = period["type"] as? String ?? ""
        let minutes = start.flatMap { start in end.map { Int($0.timeIntervalSince(start) / 60) } }
        let weekly = type.hasSuffix("WEEKLY") || CodexUsageClient.isWeekly(minutes)
        let window = QuotaWindow(id: "grok_period", name: weekly ? .weekly : .span(minutes: minutes),
                                 usedPercent: used, resetsAt: end, weekly: weekly)
        let products = (config["productUsage"] as? [[String: Any]] ?? []).compactMap { item -> ProductUsage? in
            guard let product = item["product"] as? String, let percent = jsonNumber(item["usagePercent"]) else { return nil }
            return ProductUsage(product: product, usedPercent: percent)
        }
        return ProviderQuota(plan: nil, windows: [window], credits: nil, source: .live, asOf: Date(),
                             products: products.sorted { $0.usedPercent > $1.usedPercent })
    }
}

/// Grok 的额度由几个产品共用，这是各自用掉的部分（占整个周期额度的百分比）
struct ProductUsage: Equatable, Codable {
    let product: String
    let usedPercent: Double

    var title: String {
        switch product {
        case "GrokBuild": return "Grok Build"
        case "GrokChat": return L("Grok 聊天")
        default:
            // 不认识的按驼峰拆开：GrokImagine → Grok Imagine
            return product.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
    }
}
