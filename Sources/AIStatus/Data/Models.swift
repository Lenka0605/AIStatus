import Foundation

struct QuotaWindow: Identifiable, Equatable, Codable {
    /// 额度的种类。只存种类、显示时再翻译，这样在设置里换语言后卡片立即跟着变
    enum Name: Codable, Equatable {
        case weekly
        case fiveHour
        /// 单个模型的周额度，如 Fable
        case weeklyModel(String)
        /// Codex 按窗口长度命名（本周、5 小时……）
        case span(minutes: Int?)
    }

    let id: String
    let name: Name
    let usedPercent: Double
    let resetsAt: Date?
    /// 周额度：用来计算「今日已用」
    var weekly = false
    /// 最多能用掉周额度的百分之几，显示在名称旁边，代替重置时间
    var allowance: Int?

    var label: String {
        switch name {
        case .weekly: return L("本周")
        case .fiveHour: return L("5 小时")
        case .weeklyModel(let model): return L("本周 \(model)")
        case .span(let minutes): return CodexUsageClient.windowLabel(minutes: minutes)
        }
    }

    /// 「最多用周额度的 50%」
    var note: String? { allowance.map { L("最多用周额度的 \($0)%") } }

    /// 重置时间已过但还没拿到新数据时，视为已重置
    var hasReset: Bool { resetsAt.map { $0 <= Date() } ?? false }

    var remainingPercent: Double {
        hasReset ? 100 : max(0, min(100, 100 - usedPercent))
    }
}

enum QuotaSource: String, Equatable, Codable {
    case live
    case log
}

struct ProviderQuota: Equatable, Codable {
    var plan: String?
    var windows: [QuotaWindow]
    var credits: Double?
    var source: QuotaSource
    var asOf: Date
    /// Grok：几个产品共用一份额度，各自用了多少
    var products: [ProductUsage]? = nil
}

struct ProviderState {
    var quota: ProviderQuota?
    var error: String?
    /// 本机找不到登录凭证（没装或没登录）
    var signedOut = false
    /// 今天用掉的周额度（百分点），来自服务器数据，包含网页、云端、其他设备的使用
    var todayUsed: Double?
    var todayUsedAt: Date?
    /// 官方状态页上的服务状态
    var health: ServiceHealth?

    /// 没登录、也没有可显示的额度：多半是这个人不用这家，不当成错误
    var notInUse: Bool { signedOut && quota == nil }

    var currentHealth: ServiceHealth? { health?.ifCurrent }

    /// 跨天后、新的一次查询之前，不显示昨天算出的值
    var todayUsedIfCurrent: Double? {
        guard let todayUsedAt, Calendar.current.isDateInToday(todayUsedAt) else { return nil }
        return todayUsed
    }

    mutating func setTodayUsed(_ value: Double?) {
        guard let value else { return }
        todayUsed = value
        todayUsedAt = Date()
    }
}

struct TokenTotals: Equatable {
    var input = 0       // 未命中缓存的输入
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var other = 0       // 只知道总数、无法区分类型的部分（Codex 运行日志）

    var cache: Int { cacheWrite + cacheRead }
    var total: Int { input + output + cacheWrite + cacheRead + other }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input, output: a.output + b.output,
                    cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead, other: a.other + b.other)
    }

    static func - (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input - b.input, output: a.output - b.output,
                    cacheWrite: a.cacheWrite - b.cacheWrite, cacheRead: a.cacheRead - b.cacheRead, other: a.other - b.other)
    }

    func fieldwiseMax(_ o: TokenTotals) -> TokenTotals {
        TokenTotals(input: max(input, o.input), output: max(output, o.output),
                    cacheWrite: max(cacheWrite, o.cacheWrite), cacheRead: max(cacheRead, o.cacheRead), other: max(other, o.other))
    }
}

enum AdminProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        }
    }

    var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-admin…"
        case .openai: return "sk-admin-…"
        case .deepseek: return "sk-…"
        }
    }

    /// DeepSeek 能直接查到账户余额，用普通 API Key；另外两家只能查花费，要用 Admin Key 并手填余额
    var reportsBalance: Bool { self == .deepseek }
    var keyName: String { reportsBalance ? "API Key" : "Admin Key" }
}

/// 用户在某天填写的余额；snapshot 是填写当天（UTC）已经产生的花费，避免重复扣减
struct BalanceAnchor: Codable, Equatable {
    var balance: Double
    var day: Date            // 填写当天的 UTC 零点（与计费分桶对齐）
    var snapshot: Double?
    var setAt: Date?         // 实际填写时间，仅用于显示
}

struct ApiSpend: Equatable {
    var today: Double?       // DeepSeek 没有花费接口，只有余额
    var month: Double?
    var remaining: Double?
    /// DeepSeek：按币种分开的余额，一个账户可能同时有美元充值和人民币赠金
    var balances: [CurrencyBalance] = []
    var available = true     // DeepSeek：余额不足时 API 已不能调用
    var usage: BalanceUsage? // DeepSeek：由余额变化推算的花费，见 DeepSeekLedger

    var isLow: Bool {
        guard available else { return true }
        if !balances.isEmpty { return balances.allSatisfy(\.isLow) }
        return (remaining ?? .infinity) < 5
    }
}

struct CurrencyBalance: Equatable, Identifiable {
    var currency: String     // CNY 或 USD
    var total: Double
    var granted: Double      // 赠金，优先扣除
    var toppedUp: Double

    var id: String { currency }
    var isLow: Bool { total < (currency == "CNY" ? 35 : 5) }   // 人民币按约 5 美元算
}

struct SpendState {
    var spend: ApiSpend?
    var error: String?
}

enum FetchError: LocalizedError {
    case noCredentials(String)
    case expired(String)
    case unauthorized(String)
    case http(Int)
    case rateLimited(TimeInterval)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials(let s), .expired(let s), .unauthorized(let s): return s
        case .http(let code): return L("请求失败（HTTP \(code)）")
        case .rateLimited: return L("查询太频繁，请稍后再试")
        case .badResponse: return L("返回数据格式无法识别")
        }
    }
}

extension FetchError {
    /// 429 时按服务器给的 Retry-After 等待（限制在 1～60 分钟），没给就等 5 分钟
    static func rateLimited(_ response: HTTPURLResponse) -> FetchError {
        let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
        return .rateLimited(min(max(seconds, 60), 3600))
    }
}

/// 把 async throws 调用包成 Result，方便和 async let 一起并发
func capture<T>(_ op: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await op()) } catch { return .failure(error) }
}
