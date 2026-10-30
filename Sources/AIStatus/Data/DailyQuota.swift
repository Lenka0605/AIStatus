import Foundation

/// 「今日已用周额度」：记住当天开始时的已用百分比，之后用差值得到今天用了多少。
/// 数据来自服务器，所以网页、云端任务、手机、其他电脑上的使用都会算进去。
/// 应用一直在后台运行时（比如开机启动），零点后的第一次刷新就是准确的基准；
/// 如果零点时没运行，就用上一次记录的值做基准，期间未观测到的用量会算到今天。
enum DailyQuota {
    private struct Record: Codable {
        var day: String
        var baseline: Double      // 当前额度周期内，今天开始时的已用百分比
        var accumulated: Double   // 今天内额度重置之前已经用掉的部分
        var lastUsed: Double
        var resetsAt: Date?
    }

    static func todayUsed(key: String, window: QuotaWindow, now: Date = Date()) -> Double {
        let defaultsKey = "dailyQuota.\(key)"
        let day = dayFormatter.string(from: now)
        let used = window.usedPercent

        var record: Record
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Record.self, from: data) {
            record = saved
            // 有重置时间就以它为准；用量下降但重置时间没变，视为服务器修正而不是新周期
            let didReset = saved.resetsAt != nil && window.resetsAt != nil
                ? windowChanged(saved.resetsAt, window.resetsAt)
                : used + 0.5 < saved.lastUsed
            if saved.day != day {
                record = Record(day: day, baseline: didReset ? 0 : saved.lastUsed, accumulated: 0,
                                lastUsed: used, resetsAt: window.resetsAt)
            } else if didReset {
                record.accumulated += max(0, saved.lastUsed - saved.baseline)
                record.baseline = 0
            }
        } else {
            record = Record(day: day, baseline: used, accumulated: 0, lastUsed: used, resetsAt: window.resetsAt)
        }
        record.baseline = min(record.baseline, used)
        record.lastUsed = used
        record.resetsAt = window.resetsAt ?? record.resetsAt

        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        return max(0, record.accumulated + used - record.baseline)
    }

    /// 重置时间变了说明进入了新的额度周期（Claude 每次返回的时间有秒级抖动，留 10 分钟容差）
    private static func windowChanged(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) > 600
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
