import Foundation

/// API 余额：用 Admin Key 查询按天的花费，余额 = 用户填写的余额 − 填写之后的花费；DeepSeek 直接查余额，花费由余额变化推算
enum SpendService {
    static func fetchAll() async -> [AdminProvider: SpendState] {
        var out: [AdminProvider: SpendState] = [:]
        for provider in AdminProvider.allCases {
            guard let key = Preferences.adminKey(for: provider) else { continue }
            switch await capture({ try await fetch(provider, key: key) }) {
            case .success(let spend): out[provider] = SpendState(spend: spend, error: nil)
            case .failure(let error): out[provider] = SpendState(spend: nil, error: error.localizedDescription)
            }
        }
        return out
    }

    static func fetch(_ provider: AdminProvider, key: String, now: Date = Date()) async throws -> ApiSpend {
        if provider.reportsBalance {
            var spend = try await CostClient.deepSeekBalance(key: key)
            spend.usage = await DeepSeekLedger.record(spend.balances, key: key, now: now)
            // 空账户也显示一个 0（不记进账本，免得接口偶尔返回空列表被当成花光了）
            if spend.balances.isEmpty { spend.balances = [CurrencyBalance(currency: "CNY", total: 0, granted: 0, toppedUp: 0)] }
            return spend
        }
        var anchor = Preferences.anchor(for: provider)
        let monthStart = UTC.monthStart(now)
        let since = min(monthStart, anchor?.day ?? monthStart)
        let costs = try await CostClient.dailyCosts(provider, key: key, since: since)

        func sum(from start: Date) -> Double {
            costs.filter { $0.start >= start }.reduce(0) { $0 + $1.amount }
        }

        if let original = anchor, original.snapshot == nil {
            var a = original
            a.snapshot = costs.filter { UTC.calendar.isDate($0.start, inSameDayAs: a.day) }.reduce(0) { $0 + $1.amount }
            // 查询期间用户又改了余额，就不要用旧值覆盖
            if Preferences.anchor(for: provider) == original { Preferences.setAnchor(a, for: provider) }
            anchor = a
        }
        let remaining = anchor.map { a in a.balance - max(0, sum(from: a.day) - (a.snapshot ?? 0)) }
        return ApiSpend(today: sum(from: UTC.dayStart(now)), month: sum(from: monthStart), remaining: remaining)
    }
}

enum CostClient {
    struct DailyCost {
        let start: Date
        let amount: Double   // 美元
    }

    static func dailyCosts(_ provider: AdminProvider, key: String, since: Date) async throws -> [DailyCost] {
        switch provider {
        case .anthropic: return try await anthropic(key: key, since: since)
        case .openai: return try await openAI(key: key, since: since)
        case .deepseek: return []   // 没有花费接口，见 deepSeekBalance
        }
    }

    /// GET /user/balance，金额是十进制字符串。每个币种一条，比如美元充值和人民币赠金会分成两条
    static func deepSeekBalance(key: String) async throws -> ApiSpend {
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let json = try await send(req, keyName: "API Key")
        guard let infos = json["balance_infos"] as? [[String: Any]] else { throw FetchError.badResponse }
        let balances = infos.compactMap { info -> CurrencyBalance? in
            guard let currency = info["currency"] as? String, let total = jsonNumber(info["total_balance"]) else { return nil }
            return CurrencyBalance(currency: currency, total: total, granted: jsonNumber(info["granted_balance"]) ?? 0,
                                   toppedUp: jsonNumber(info["topped_up_balance"]) ?? 0)
        }
        // 美元在前
        let sorted = balances.sorted { ($0.currency == "USD" ? 0 : 1) < ($1.currency == "USD" ? 0 : 1) }
        return ApiSpend(balances: sorted, available: json["is_available"] as? Bool ?? true)
    }

    /// GET /v1/organizations/cost_report，amount 单位是美分（十进制字符串）
    private static func anthropic(key: String, since: Date) async throws -> [DailyCost] {
        var out: [DailyCost] = []
        var page: String?
        for _ in 0..<24 {
            var comps = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            comps.queryItems = [
                URLQueryItem(name: "starting_at", value: DateParsing.rfc3339(since)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var req = URLRequest(url: comps.url!, timeoutInterval: 20)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let json = try await send(req)
            for bucket in json["data"] as? [[String: Any]] ?? [] {
                guard let start = (bucket["starting_at"] as? String).flatMap(DateParsing.iso8601) else { continue }
                let cents = (bucket["results"] as? [[String: Any]] ?? []).reduce(0.0) { $0 + (jsonNumber($1["amount"]) ?? 0) }
                out.append(DailyCost(start: start, amount: cents / 100))
            }
            guard json["has_more"] as? Bool == true, let next = json["next_page"] as? String else { break }
            page = next
        }
        return out
    }

    /// GET /v1/organization/costs，amount.value 单位是美元
    private static func openAI(key: String, since: Date) async throws -> [DailyCost] {
        var out: [DailyCost] = []
        var page: String?
        for _ in 0..<24 {
            var comps = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            comps.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(since.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "180"),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var req = URLRequest(url: comps.url!, timeoutInterval: 20)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let json = try await send(req)
            for bucket in json["data"] as? [[String: Any]] ?? [] {
                guard let start = jsonNumber(bucket["start_time"]) else { continue }
                let dollars = (bucket["results"] as? [[String: Any]] ?? []).reduce(0.0) {
                    $0 + (jsonNumber(($1["amount"] as? [String: Any])?["value"]) ?? 0)
                }
                out.append(DailyCost(start: Date(timeIntervalSince1970: start), amount: dollars))
            }
            guard json["has_more"] as? Bool == true, let next = json["next_page"] as? String else { break }
            page = next
        }
        return out
    }

    private static func send(_ req: URLRequest, keyName: String = "Admin Key") async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw FetchError.unauthorized(L("\(keyName) 无效或没有权限")) }
        guard status == 200 else { throw FetchError.http(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse
        }
        return json
    }
}
