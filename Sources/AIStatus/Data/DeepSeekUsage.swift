import CryptoKit
import Foundation

/// DeepSeek 的花费：币种 → 金额
struct BalanceUsage: Equatable {
    var today: [String: Double]
    var month: [String: Double]
    var since: Date               // 开始记录的时间，之前的花费无从得知
    var recent: [DaySpend] = []   // 近 7 天，最后一天是今天
}

struct DaySpend: Equatable, Identifiable {
    var day: Date
    var amounts: [String: Double]
    var recorded: Bool            // 开始记录之前的日子没有数据，和「花了 0」区分开
    var id: Date { day }
}

/// DeepSeek 用 API Key 只能查余额，查不到用量明细（网页后台的用量页要网页登录）。
/// 所以每次查到余额都和上一次比：赠金或充值余额减少的部分记为花费；增加的部分是充值或新到的赠金，不算。
/// 余额精确到分，逐次相减的舍入误差会互相抵消，累计最多差 1 分。
/// 应用没运行或电脑睡眠期间的花费，在下一次查到余额时算到那一天（和 DailyQuota 一样）。赠金过期也会被当成花费
@MainActor
enum DeepSeekLedger {
    private struct Record: Codable {
        var keyID: String                       // 换了 API Key（可能是另一个账户）就重新记
        var since: Date
        var lastAt: Date
        var last: [String: Part]                // 币种 → 上一次查到的余额
        var days: [String: [String: Double]]    // 本地日期 yyyy-MM-dd → 币种 → 花费
    }

    private struct Part: Codable {
        var granted: Double
        var toppedUp: Double
    }

    private static let defaultsKey = "deepseek.ledger"

    /// now 是发出查询的时间：并发的两次查询晚发出的先回来时，早的那次不再往回记
    static func record(_ balances: [CurrencyBalance], key: String, now: Date = Date()) -> BalanceUsage {
        let keyID = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let today = dayFormatter.string(from: now)
        var record = load().flatMap { $0.keyID == keyID ? $0 : nil }
            ?? Record(keyID: keyID, since: now, lastAt: now, last: [:], days: [:])

        if now >= record.lastAt {
            for balance in balances {
                let current = Part(granted: balance.granted, toppedUp: balance.toppedUp)
                if let previous = record.last[balance.currency] {
                    let spent = max(0, previous.granted - current.granted) + max(0, previous.toppedUp - current.toppedUp)
                    if spent > 0.0001 { record.days[today, default: [:]][balance.currency, default: 0] += spent }
                }
                // 这次没返回的币种保留上一次的值，免得接口偶尔少返回一条就被当成花光了
                record.last[balance.currency] = current
            }
            record.lastAt = now
            for day in record.days.keys.sorted().dropLast(62) { record.days[day] = nil }
            if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        }

        var month: [String: Double] = [:]
        for (day, amounts) in record.days where day.hasPrefix(today.prefix(7)) {
            month.merge(amounts, uniquingKeysWith: +)
        }
        let calendar = Calendar.current
        let recent = (0..<7).reversed().compactMap { offset -> DaySpend? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            return DaySpend(day: day, amounts: record.days[dayFormatter.string(from: day)] ?? [:],
                            recorded: day >= calendar.startOfDay(for: record.since))
        }
        return BalanceUsage(today: record.days[today] ?? [:], month: month, since: record.since, recent: recent)
    }

    private static func load() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
