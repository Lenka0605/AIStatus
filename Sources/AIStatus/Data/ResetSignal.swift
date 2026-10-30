import Foundation

/// Codex「全员额度重置」信号。OpenAI 偶尔会把所有人的 5 小时和每周额度一次清空，
/// 由 Codex 负责人 Tibo（@thsottiaux）在 X 上预告或宣布；这和额度本身的周期重置是两回事
struct ResetSignal: Equatable {
    struct Post: Equatable {
        var id: String
        var at: Date
        /// 推文内容，有中文翻译时用翻译
        var text: String?
        var url: URL?
    }

    /// Tibo 预告、还没兑现的下一次重置。时间段是 UTC，显示时换成本机时区
    struct Schedule: Equatable {
        var post: Post
        var start: Date
        var end: Date
        /// 「今天之内」这类只给了截止时间的预告
        var deadline: Bool
    }

    /// 最近一次已完成的全员重置
    var latest: Post?
    var next: Schedule?
    /// 最近几次重置间隔的中位数，用来在没有预告时估计下一次
    var typicalGap: TimeInterval?
    var checkedAt: Date

    /// 没有预告时按近期间隔估算
    var estimate: Date? {
        guard next == nil, let latest, let typicalGap else { return nil }
        return latest.at.addingTimeInterval(typicalGap)
    }

    /// 「上次」，从详细到简略排好，面板挑第一个一行放得下的：
    /// 「今天 12:18 · 6 分钟前」「12:18 · 6 分钟前」「6 分钟前」；超过一天只写日期时间
    func latestTexts(now: Date = Date()) -> [String] {
        guard let latest else { return [] }
        guard now.timeIntervalSince(latest.at) < 86_400 else {
            return [Fmt.dayTime(latest.at, now: now), Fmt.dayTime(latest.at, now: now, weekday: false)].uniqued()
        }
        let ago = Fmt.ago(latest.at, now: now)
        return [Fmt.dayTime(latest.at, now: now) + " · " + ago, Fmt.time(latest.at) + " · " + ago, ago]
    }

    enum NextKind { case scheduled, estimated, unknown }

    /// 「下次」，同样从详细到简略：有预告用预告时间，否则按近期间隔估算（「约明天」「约 10/30 周五」）
    func nextTexts(now: Date = Date()) -> (texts: [String], kind: NextKind) {
        if let next { return (next.whenTexts(now: now), .scheduled) }
        guard let estimate else { return (["暂无预告"], .unknown) }
        if estimate < now { return (["随时可能"], .estimated) }
        let day = Fmt.day(estimate, now: now)
        return (["约" + (day.first?.isASCII == true ? " " : "") + day], .estimated)
    }
}

extension ResetSignal.Schedule {
    /// 从详细到简略：「今天 15:00 – 明天 15:00」→「今天 15:00 起」；「进行中，明天 15:00 前」→「明天 15:00 前」。
    /// 第一个是完整说法，通知里用它
    func whenTexts(now: Date = Date()) -> [String] {
        if end < now { return ["预告时间已过，等待确认", "等待确认"] }
        let endAt = [Fmt.dayTime(end, now: now), Fmt.dayTime(end, now: now, weekday: false)].uniqued()
        if deadline || start == end { return endAt.map { $0 + (deadline ? " 前" : "") } }
        if start <= now { return ["进行中，\(endAt[0]) 前"] + endAt.map { $0 + " 前" } }
        let from = Fmt.dayTime(start, now: now)
        let to = Calendar.current.isDate(start, inSameDayAs: end) ? Fmt.time(end) : endAt[0]
        return [from + " – " + to, from + " 起", Fmt.dayTime(start, now: now, weekday: false) + " 起"].uniqued()
    }
}

/// didcodexreset.com 的公开接口：非官方站点，盯着 Tibo 的推文识别重置预告和完成。
/// 不需要密钥，每个 IP 每小时最多 60 次请求
enum ResetSignalClient {
    static let pageURL = URL(string: "https://didcodexreset.com/zh.html")!
    private static let base = "https://didcodexreset.com/openapi/v1"

    /// 最近一次全员重置和下一次预告。不传 timeZone：「明天重置」这类只到日期的预告按 Tibo 所在的太平洋时间理解，
    /// 接口返回 UTC 时间段，显示时再换成本机时区
    static func fetchStatus() async throws -> (latest: ResetSignal.Post?, next: ResetSignal.Schedule?) {
        let data = try await get("/status?lang=zh-CN")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true, let body = json["data"] as? [String: Any]
        else { throw FetchError.badResponse }
        let latest = (body["latestGlobal"] as? [String: Any]).flatMap(post)
        var next: ResetSignal.Schedule?
        if let record = body["nextScheduled"] as? [String: Any], let p = post(record),
           let window = record["scheduleWindow"] as? [String: Any],
           let start = (window["startAt"] as? String).flatMap(DateParsing.iso8601),
           let end = (window["endAt"] as? String).flatMap(DateParsing.iso8601) {
            next = ResetSignal.Schedule(post: p, start: start, end: end, deadline: record["scheduleConstraint"] as? String == "deadline")
        }
        return (latest, next)
    }

    /// 最近 10 条完成记录的间隔中位数。同一次重置可能有推文和人工确认两条记录，相隔 3 小时内的算一次
    static func fetchTypicalGap() async throws -> TimeInterval? {
        let data = try await get("/records?kind=reset_completed&pageSize=10")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["data"] as? [String: Any])?["items"] as? [[String: Any]]
        else { throw FetchError.badResponse }
        // 「重置卡」是发给个人的，不算全员重置
        let times = items.filter { $0["resetType"] as? String != "banked" }.compactMap(post).map(\.at).sorted()
        var merged: [Date] = []
        for t in times where merged.last.map({ t.timeIntervalSince($0) > 3 * 3600 }) ?? true { merged.append(t) }
        let gaps = zip(merged, merged.dropFirst()).map { $1.timeIntervalSince($0) }.sorted()
        guard gaps.count >= 3 else { return nil }
        let mid = gaps.count / 2
        return gaps.count.isMultiple(of: 2) ? (gaps[mid - 1] + gaps[mid]) / 2 : gaps[mid]
    }

    private static func get(_ path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        if http.statusCode == 429 { throw FetchError.rateLimited(http) }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        return data
    }

    /// 完成记录的时间：确认时间 > 生效时间 > 发推时间
    private static func post(_ r: [String: Any]) -> ResetSignal.Post? {
        guard let id = r["id"] as? String,
              let at = ["completedAt", "effectiveAt", "announcedAt"].lazy.compactMap({ (r[$0] as? String).flatMap(DateParsing.iso8601) }).first
        else { return nil }
        let text = ((r["translatedText"] as? String) ?? (r["text"] as? String)).flatMap(clean)
        let url = ((r["source"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
        return ResetSignal.Post(id: id, at: at, text: text, url: url)
    }

    /// 去掉推文里的 t.co 短链接，还原 &amp; 这类转义
    private static func clean(_ text: String) -> String? {
        var s = text.replacingOccurrences(of: #"https?://t\.co/\S+"#, with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
