import Foundation

/// 服务健康程度，越往后越严重
enum ServiceLevel: Int, Comparable {
    case ok, notice, maintenance, degraded, partial, major

    static func < (a: ServiceLevel, b: ServiceLevel) -> Bool { a.rawValue < b.rawValue }

    /// 真正影响使用时，状态栏图标上才显示圆点
    var alertsMenuBar: Bool { self >= .degraded }

    var title: String {
        switch self {
        case .ok: return L("正常")
        case .notice: return L("有进行中的事件")
        case .maintenance: return L("维护中")
        case .degraded: return L("性能下降")
        case .partial: return L("部分中断")
        case .major: return L("严重中断")
        }
    }
}

struct ServiceHealth: Equatable {
    var level: ServiceLevel
    /// 简短中文说明，如「Claude Code 性能下降」「代码审查、安全审查出错增多」
    var summary: String?
    /// 事件进展，如「已修复，观察中」
    var stage: String?
    /// 状态页上的英文原文，鼠标悬停时显示
    var original: String?
    var checkedAt: Date

    /// 查询失败时保留上次结果，但超过 30 分钟没更新就不再显示
    var ifCurrent: ServiceHealth? { Date().timeIntervalSince(checkedAt) < 30 * 60 ? self : nil }
}

/// 读取官方状态页的 summary.json（Atlassian Statuspage 格式，OpenAI 的 incident.io 状态页也兼容）
enum ServiceStatusClient {
    struct Source {
        let summaryURL: URL
        let pageURL: URL
        /// 事件标题里认不出具体功能时用的主语
        let fallbackSubject: String
        /// 只看和我们相关的组件，比如 OpenAI 的图片、Sora 出问题不算
        let isRelevantComponent: (String) -> Bool
        /// OpenAI 的事件不带受影响组件，只能按标题关键词筛；为空表示不筛
        let incidentKeywords: [String]
    }

    static var claude: Source { Source(
        summaryURL: URL(string: "https://status.claude.com/api/v2/summary.json")!,
        pageURL: URL(string: "https://status.claude.com")!,
        fallbackSubject: L("Claude 服务"),
        isRelevantComponent: { name in ["claude.ai", "Claude API", "Claude Code"].contains { name.hasPrefix($0) } },
        incidentKeywords: []
    ) }

    static var openai: Source { Source(
        summaryURL: URL(string: "https://status.openai.com/api/v2/summary.json")!,
        pageURL: URL(string: "https://status.openai.com")!,
        fallbackSubject: L("OpenAI 服务"),
        isRelevantComponent: { name in
            name.localizedCaseInsensitiveContains("codex") || ["CLI", "VS Code extension", "Login", "Conversations"].contains(name)
        },
        incidentKeywords: ["codex", "chatgpt", "login", "log in", "sign in", "code review"]
    ) }

    static func fetch(_ source: Source) async throws -> ServiceHealth {
        var req = URLRequest(url: source.summaryURL, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.http(status) }
        return try parse(data, source: source)
    }

    static func parse(_ data: Data, source: Source) throws -> ServiceHealth {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse
        }
        var level = ServiceLevel.ok
        var summary: String?
        var stage: String?
        var original: String?

        // 组件状态：取最严重的一个，多个时写「等 N 项」
        var affected: [(name: String, level: ServiceLevel)] = []
        for c in json["components"] as? [[String: Any]] ?? [] where c["group"] as? Bool != true {
            guard let name = c["name"] as? String, source.isRelevantComponent(name),
                  let l = componentLevel(c["status"] as? String), l > .ok else { continue }
            affected.append((name, l))
        }
        if let top = affected.max(by: { $0.level < $1.level }) {
            let name = shortName(top.name)
            level = top.level
            summary = affected.count > 1
                ? L("\(name) 等 \(affected.count) 项\(top.level.title)")
                : L("\(name)\(top.level.title)")
        }

        // 进行中的事件：比组件状态更严重时才用它的标题
        for incident in json["incidents"] as? [[String: Any]] ?? [] {
            guard let name = incident["name"] as? String,
                  !["resolved", "postmortem", "completed"].contains(incident["status"] as? String ?? "")
            else { continue }
            let names = (incident["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let relevant = names.isEmpty
                ? source.incidentKeywords.isEmpty || source.incidentKeywords.contains { name.localizedCaseInsensitiveContains($0) }
                : names.contains(where: source.isRelevantComponent)
            let l = incidentLevel(incident["impact"] as? String)
            if relevant && l > level {
                level = l
                summary = IncidentSummary.chinese(name, fallbackSubject: source.fallbackSubject)
                stage = IncidentSummary.stage(incident["status"] as? String)
                original = name
            }
        }
        return ServiceHealth(level: level, summary: summary, stage: stage, original: original, checkedAt: Date())
    }

    private static func componentLevel(_ status: String?) -> ServiceLevel? {
        switch status {
        case "operational": return .ok
        case "degraded_performance": return .degraded
        case "partial_outage": return .partial
        case "major_outage", "full_outage": return .major
        case "under_maintenance": return .maintenance
        default: return nil
        }
    }

    private static func incidentLevel(_ impact: String?) -> ServiceLevel {
        switch impact {
        case "critical": return .major
        case "major": return .partial
        case "minor": return .degraded
        case "maintenance": return .maintenance
        default: return .notice
        }
    }

    /// 「Claude API (api.anthropic.com)」→「Claude API」
    private static func shortName(_ name: String) -> String {
        name.components(separatedBy: " (").first ?? name
    }
}

/// DeepSeek 的状态页（Flashcat）没有 summary.json，只能读事件的 RSS：每个事件一条，带当前进展和受影响的组件。
/// 标题是「中文（English）」，如「DeepSeek API 性能下降（DeepSeek API Degraded Performance）」
enum DeepSeekStatusClient {
    static let pageURL = URL(string: "https://status.deepseek.com")!
    private static let feedURL = URL(string: "https://status.deepseek.com/feed.rss")!

    static func fetch() async throws -> ServiceHealth {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: feedURL, timeoutInterval: 15))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.http(status) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ServiceHealth {
        let feed = RSSItems()
        let parser = XMLParser(data: data)
        parser.delegate = feed
        guard parser.parse() else { throw FetchError.badResponse }

        var health = ServiceHealth(level: .ok, checkedAt: Date())
        for item in feed.items {
            let status = match(#"Status:</strong>\s*([a-z_]+)"#, in: item.description) ?? ""
            guard !["resolved", "postmortem", "completed"].contains(status) else { continue }
            // 我们只关心 API；没写组件的事件按标题判断
            let components = match(#"Affected components:</strong>\s*([^<]+)"#, in: item.description) ?? item.title
            guard components.localizedCaseInsensitiveContains("API") else { continue }
            let level = level(item.title)
            guard level > health.level else { continue }
            let chinese = item.title.components(separatedBy: CharacterSet(charactersIn: "（(")).first ?? item.title
            health.level = level
            health.summary = chinese.trimmingCharacters(in: CharacterSet(charactersIn: "- ").union(.whitespaces))
            health.stage = IncidentSummary.stage(status)
            health.original = item.title
        }
        return health
    }

    private static func level(_ title: String) -> ServiceLevel {
        if title.contains("维护") { return .maintenance }
        if title.contains("部分中断") || title.contains("部分不可用") { return .partial }
        if title.contains("中断") || title.contains("不可用") { return .major }
        if title.contains("性能下降") || title.contains("异常") { return .degraded }
        return .notice
    }

    /// 第一个括号分组匹配到的内容
    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return text[range].trimmingCharacters(in: .whitespaces)
    }

    private final class RSSItems: NSObject, XMLParserDelegate {
        struct Item { var title = "", description = "" }
        var items: [Item] = []
        private var current: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "item" { current = Item() }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "title": current?.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "description": current?.description = text
            case "item": if let current { items.append(current) }; current = nil
            default: break
            }
        }
    }
}

/// 把状态页的英文事件标题提炼成一句简短中文：「受影响的功能 + 问题类型」。
/// 标题基本都是固定套路（Elevated errors for…、Degraded performance in…、Delays in…），按关键词对照即可
enum IncidentSummary {
    /// 按顺序匹配，先出现的优先
    private static var problems: [(keys: [String], text: String)] { [
        (["maintenance"], L("维护中")),
        (["limited availability", "partially unavailable"], L("部分不可用")),
        (["outage", "unavailable", "not loading", "unable to", "cannot", "can't", "inaccessible", "not working", "down for"], L("无法使用")),
        (["error", "failing", "failure", "failed", "fail to"], L("出错增多")),
        (["degraded performance", "latency", "slow", "timeout", "timing out"], L("变慢")),
        (["delay"], L("延迟")),
        (["degraded", "degradation"], L("功能异常")),
    ] }

    /// 受影响的功能；用正则词边界，避免 api 匹配到 rapid 这类单词
    private static var subjects: [(pattern: String, text: String)] { [
        (#"claude code"#, "Claude Code"),
        (#"claude\.ai"#, "claude.ai"),
        (#"\bcowork\b"#, "Cowork"),
        (#"\bconsole\b|platform\.claude\.com|claude platform"#, L("控制台")),
        (#"(multiple|other) models"#, L("多个模型")),
        (#"code reviews?"#, L("代码审查")),
        (#"security reviews?"#, L("安全审查")),
        (#"cloud tasks?|codex web"#, L("云端任务")),
        (#"\bcodex\b(?! web)"#, "Codex"),
        (#"\bcli\b"#, "CLI"),
        (#"vs ?code|ide extension"#, L("编辑器插件")),
        (#"chatgpt"#, "ChatGPT"),
        (#"\bconversations?\b"#, L("对话")),
        (#"\blog ?in\b|sign[ -]?in|authentication"#, L("登录")),
        (#"file uploads?"#, L("文件上传")),
        (#"file downloads?"#, L("文件下载")),
        (#"\bvoice\b"#, L("语音")),
        (#"gpt-image|image generation|\bimages?\b"#, L("图片生成")),
        (#"deep research"#, L("深度研究")),
        (#"connectors?|connections"#, L("连接器")),
        (#"plugins?"#, L("插件")),
        (#"\bmcp\b"#, "MCP"),
        (#"usage data"#, L("用量数据")),
        (#"spend limits?"#, L("消费限额")),
        (#"credits?"#, "Credits"),
        (#"subscriptions?|billing|payments?|purchases?"#, L("订阅付费")),
        (#"\bapis?\b"#, "API"),
    ] }

    /// 模型名保留原文和版本号，如「Fable 5.1」「GPT-6.1」
    private static let modelPatterns = [
        #"(?i)\bclaude\s+([a-z]+\s+\d+(?:\.\d+)?)"#,
        #"(?i)\b((?:opus|sonnet|haiku|fable|mythos)\s+\d+(?:\.\d+)?)"#,
        #"(?i)\b(gpt-\d[\w.]*)"#,
    ]

    /// 英文界面直接用原标题；中文、越南语界面按关键词提炼
    static func chinese(_ title: String, fallbackSubject: String) -> String {
        if AppLanguage.isEnglish { return title }
        let lower = title.lowercased()
        let problem = problems.first { $0.keys.contains(where: lower.contains) }?.text ?? L("出现问题")
        var found = models(in: title)
        for s in subjects where !found.contains(s.text) && lower.range(of: s.pattern, options: .regularExpression) != nil {
            found.append(s.text)
        }
        let subject = found.isEmpty ? fallbackSubject : found.prefix(3).joined(separator: L("、"))
        guard AppLanguage.isChinese else { return L("\(subject)：\(problem)") }
        // 英文结尾和中文之间留一个空格，和面板其他地方的排版一致
        let gap = subject.last.map { $0.isASCII } == true ? " " : ""
        return subject + gap + problem
    }

    private static func models(in title: String) -> [String] {
        var out: [String] = []
        for pattern in modelPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: title, range: NSRange(title.startIndex..., in: title)) {
                guard let range = Range(match.range(at: 1), in: title) else { continue }
                let raw = String(title[range])
                let name = raw.lowercased().hasPrefix("gpt-") ? "GPT" + raw.dropFirst(3) : raw.prefix(1).uppercased() + raw.dropFirst()
                if !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { out.append(name) }
            }
        }
        return out
    }

    static func stage(_ status: String?) -> String? {
        switch status {
        case "investigating": return L("排查中")
        case "identified": return L("已找到原因")
        case "monitoring": return L("已修复，观察中")
        case "scheduled": return L("计划中")
        case "in_progress": return L("进行中")
        default: return nil
        }
    }
}
