import Foundation

enum Fmt {
    /// 1234 -> 1.23K, 12_345_678 -> 12.3M
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return trimmed(v / 1_000) + "K"
        case ..<1_000_000_000: return trimmed(v / 1_000_000) + "M"
        default: return trimmed(v / 1_000_000_000) + "B"
        }
    }

    private static func trimmed(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    /// 4 -> "4%"，0.5 -> "0.5%"
    static func percent(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))%" : String(format: "%.1f%%", v)
    }

    static func usd(_ v: Double) -> String {
        usdFormatter.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    /// DeepSeek 的余额可能是人民币
    static func money(_ v: Double, currency: String) -> String {
        currency == "CNY" ? cnyFormatter.string(from: NSNumber(value: v)) ?? String(format: "¥%.2f", v) : usd(v)
    }

    static func integer(_ v: Double) -> String {
        intFormatter.string(from: NSNumber(value: v.rounded())) ?? String(Int(v))
    }

    /// 额度重置时间：一天内用相对时间，更远用「周四 09:00」
    static func reset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return nil }
        if s < 3600 { return "\(max(1, Int(s / 60))) 分钟后重置" }
        if s < 86_400 {
            let h = Int(s / 3600)
            let m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h) 小时 \(m) 分后重置" : "\(h) 小时后重置"
        }
        return weekdayFormatter.string(from: date) + " 重置"
    }

    /// 10/26
    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// 今天显示 17:42，否则显示 10/20 17:42
    static func clock(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? timeFormatter.string(from: date)
            : dayTimeFormatter.string(from: date)
    }

    /// 昨天 / 今天 / 明天 / 后天，更远显示「10/30 周五」（weekday: false 时只写「10/30」）
    static func day(_ date: Date, now: Date = Date(), weekday: Bool = true) -> String {
        let cal = Calendar.current
        let offset = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 99
        switch offset {
        case -1: return "昨天"
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return (weekday ? dayWeekdayFormatter : dateFormatter).string(from: date)
        }
    }

    /// 「今天 15:00」「10/30 周五 15:00」
    static func dayTime(_ date: Date, now: Date = Date(), weekday: Bool = true) -> String {
        day(date, now: now, weekday: weekday) + " " + time(date)
    }

    /// 周三
    static func weekday(_ date: Date) -> String {
        weekdayOnlyFormatter.string(from: date)
    }

    /// 15:00
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// 「刚刚」「6 分钟前」「3 小时前」「2 天前」
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86_400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86_400)) 天前"
    }

    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static let cnyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let weekdayFormatter = formatter("EEE HH:mm")
    private static let weekdayOnlyFormatter = formatter("EEE")
    private static let timeFormatter = formatter("HH:mm")
    private static let dayTimeFormatter = formatter("M/d HH:mm")
    private static let dateFormatter = formatter("M/d")
    private static let dayWeekdayFormatter = formatter("M/d EEE")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
}

enum DateParsing {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 兼容 "…T10:24:22.852Z"、"…T04:59:59.943648+00:00"、"…T00:00:00Z"
    static func iso8601(_ s: String) -> Date? {
        if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: "."), s[dot...].contains(where: { "Z+-".contains($0) }) else { return nil }
        let tail = s[dot...].drop(while: { $0 == "." || $0.isNumber })
        return plain.date(from: String(s[..<dot]) + tail)
    }

    static func rfc3339(_ d: Date) -> String { plain.string(from: d) }
}

/// API 计费按 UTC 日分桶
enum UTC {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func dayStart(_ d: Date) -> Date { calendar.startOfDay(for: d) }

    static func monthStart(_ d: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? dayStart(d)
    }
}

/// JSONSerialization 出来的数字可能是 NSNumber 也可能是字符串
func jsonNumber(_ any: Any?) -> Double? {
    switch any {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

func jsonInt(_ any: Any?) -> Int { jsonNumber(any).map { Int($0) } ?? 0 }

extension Array where Element: Hashable {
    /// 去重，保持原来的顺序
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
