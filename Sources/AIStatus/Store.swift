import AppKit
import Observation

/// 后台任务（见 startBackgroundWork）每分钟醒一次：
/// 额度按设置的间隔自动查询（默认每 5 分钟），状态栏数字和额度通知靠它；设为「仅在使用时」则只在本机正在用
/// Claude Code / Codex 时查，最多每 10 分钟一次。官方状态页和 Codex 全员重置信号每 5 分钟看一次。
/// 点开面板时距上次查询超过 30 秒会再查一次。被限流（HTTP 429）后按服务器要求暂停。
@MainActor
@Observable
final class Store {
    var claude = ProviderState()
    var codex = ProviderState()
    var claudeTokens = TokenTotals()
    var codexTokens = TokenTotals()
    var spend: [AdminProvider: SpendState] = [:]
    /// DeepSeek 没有订阅额度，余额在 spend 里，这里只放服务状态
    var deepseekHealth: ServiceHealth?
    /// Codex 全员重置的预告和记录（didcodexreset.com）
    var resetSignal: ResetSignal?
    var isFetching = false
    var lastUpdated: Date?

    @ObservationIgnored private let scanner = TokenScanner()
    @ObservationIgnored private var lastFetch = Date.distantPast
    /// 被服务器限流（HTTP 429）后，在这个时间之前不再请求
    @ObservationIgnored private var blockedUntil: [String: Date] = [:]
    /// 查询进行中又要求强制刷新（比如保存设置）时，排队在本次结束后再跑一次
    @ObservationIgnored private var pendingForcedRefresh = false
    @ObservationIgnored private var lastQuotaFetch: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastStatusCheck = Date.distantPast
    @ObservationIgnored private var lastSignalCheck = Date.distantPast
    @ObservationIgnored private var lastGapFetch = Date.distantPast
    /// 「仅在使用时」模式下，上一次后台检查时的今日 token 数，用来判断这段时间本机有没有在用
    @ObservationIgnored private var activityBaseline: (claude: Int, codex: Int)?

    /// 连续点开面板时，距上次联网不足这个间隔就只刷新本地数据
    private static let minFetchInterval: TimeInterval = 30
    private static let tickInterval: TimeInterval = 60
    private static let statusInterval: TimeInterval = 300
    private static let activeQuotaInterval: TimeInterval = 600

    init() {
        reloadConfiguredProviders()
        // 启动时不联网，先用上次查询的结果（状态栏图标也靠它）
        claude.quota = QuotaCache.load("claude")
        codex.quota = QuotaCache.load("codex")
    }

    /// 状态栏图标里两层圆环的长度和旁边的数字：各家最紧张的那个额度（剩余比例最小的窗口）
    var iconLevels: [Double?] {
        [claude, codex].map { $0.quota?.windows.map(\.remainingPercent).min().map { $0 / 100 } }
    }

    /// 状态栏图标旁的数字，如「97 · 18」；不用的那家不显示
    var menuBarText: String {
        let shown = zip([claude, codex], iconLevels).filter { !$0.0.notInUse }.map(\.1)
        guard !shown.isEmpty else { return "–" }
        return shown.map { $0.map { "\(Int(($0 * 100).rounded()))" } ?? "–" }.joined(separator: " · ")
    }

    /// 最严重的服务状态；DeepSeek 只在填了 API Key 时算进去
    var serviceLevel: ServiceLevel {
        let deepseek = spend[.deepseek] == nil ? nil : deepseekHealth?.ifCurrent?.level
        return [claude.currentHealth?.level, codex.currentHealth?.level, deepseek].compactMap { $0 }.max() ?? .ok
    }

    var hasError: Bool {
        [claude, codex].contains { $0.error != nil && !$0.notInUse } || spend.values.contains { $0.error != nil }
    }

    func panelOpened() {
        Task { await refresh(force: false) }
    }

    func refreshNow() {
        Task { await refresh(force: true) }
    }

    func reloadConfiguredProviders() {
        for provider in AdminProvider.allCases {
            if Preferences.adminKey(for: provider) == nil {
                spend[provider] = nil
            } else if spend[provider] == nil {
                spend[provider] = SpendState()
            }
        }
    }

    /// 只统计本机 token，不联网
    func refreshLocal() async {
        let tokens = await scanner.scan()
        claudeTokens = tokens.claude
        codexTokens = tokens.codex
    }

    func refresh(force: Bool) async {
        await refreshLocal()
        if isFetching {
            if force { pendingForcedRefresh = true }
            return
        }
        guard force || Date().timeIntervalSince(lastFetch) >= Self.minFetchInterval else { return }
        isFetching = true
        lastFetch = Date()

        // 后台刚查过的就不重复查
        let minAge = force ? 0 : Self.minFetchInterval
        async let claudeDone: Void = fetchClaude(minAge: minAge)
        async let codexDone: Void = fetchCodex(minAge: minAge)
        async let statusDone: Void = refreshServiceStatus(maxAge: 60)
        async let signalDone: Void = refreshResetSignal(maxAge: 120)
        async let spendResult = SpendService.fetchAll()
        _ = await (claudeDone, codexDone, statusDone, signalDone)

        // 逐个合并而不是整体替换：查询期间新加的配置不会被抹掉，期间被清除的再去掉
        for (provider, state) in await spendResult {
            spend[provider] = SpendState(spend: state.spend ?? spend[provider]?.spend, error: state.error)
            if let fresh = state.spend { Notifier.shared.balanceUpdated(provider, spend: fresh) }
        }
        reloadConfiguredProviders()

        isFetching = false
        lastUpdated = Date()
        if pendingForcedRefresh {
            pendingForcedRefresh = false
            await refresh(force: true)
        }
    }

    /// 后台任务，启动时调用一次。见类型说明
    func startBackgroundWork() {
        Task {
            while true {
                await backgroundTick()
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    private func backgroundTick() async {
        // 留 10～15 秒余量，避免每次醒来的时间抖动让查询推迟一整轮
        async let statusDone: Void = refreshServiceStatus(maxAge: Self.statusInterval - 10)
        async let signalDone: Void = refreshResetSignal(maxAge: Self.statusInterval - 10)
        async let deepseekDone: Void = refreshDeepSeek(maxAge: Self.statusInterval - 10)
        let before = (lastQuotaFetch["claude"], lastQuotaFetch["codex"])
        if let interval = Preferences.quotaRefresh.interval {
            activityBaseline = nil
            await fetchClaude(minAge: interval - 15)
            await fetchCodex(minAge: interval - 15)
        } else {
            await refreshLocal()
            let now = (claude: claudeTokens.total, codex: codexTokens.total)
            // 刚切到这个模式时只记基准
            if let base = activityBaseline {
                if now.claude > base.claude { await fetchClaude(minAge: Self.activeQuotaInterval) }
                if now.codex > base.codex { await fetchCodex(minAge: Self.activeQuotaInterval) }
            }
            activityBaseline = now
        }
        if before != (lastQuotaFetch["claude"], lastQuotaFetch["codex"]) { lastUpdated = Date() }
        _ = await (statusDone, signalDone, deepseekDone)
    }

    /// DeepSeek 的花费靠余额变化推算（见 DeepSeekLedger），后台也定时查余额，记得越密，花费分到每天越准
    private func refreshDeepSeek(maxAge: TimeInterval) async {
        guard spend[.deepseek] != nil, begin("deepseek", minAge: maxAge) else { return }
        defer { inFlight.remove("deepseek") }
        guard let key = Preferences.adminKey(for: .deepseek) else { return }
        let result = await capture { try await SpendService.fetch(.deepseek, key: key) }
        guard let old = spend[.deepseek] else { return }   // 查询期间清除了 Key
        switch result {
        case .success(let value):
            spend[.deepseek] = SpendState(spend: value, error: nil)
            Notifier.shared.balanceUpdated(.deepseek, spend: value)
        case .failure(let error): spend[.deepseek] = SpendState(spend: old.spend, error: error.localizedDescription)
        }
    }

    /// 被限流、同一家正在查询、或距上次查询不到 minAge 秒时跳过（保留原来的数据和提示）
    private func begin(_ key: String, minAge: TimeInterval) -> Bool {
        guard !inFlight.contains(key), (blockedUntil[key] ?? .distantPast) <= Date(),
              Date().timeIntervalSince(lastQuotaFetch[key] ?? .distantPast) >= minAge
        else { return false }
        inFlight.insert(key)
        lastQuotaFetch[key] = Date()
        return true
    }

    private func fetchClaude(minAge: TimeInterval = 0) async {
        guard begin("claude", minAge: minAge) else { return }
        defer { inFlight.remove("claude") }
        switch await capture({ try await ClaudeUsageClient.fetch() }) {
        case .success(let quota):
            claude.quota = quota
            claude.error = nil
            claude.signedOut = false
            claude.setTodayUsed(Self.todayUsed("claude", quota))
            QuotaCache.save(quota, as: "claude")
            Notifier.shared.quotaUpdated(key: "claude", name: "Claude", quota: quota)
        case .failure(let error):
            claude.error = describe(error, key: "claude")   // 保留上一次的数据
            claude.signedOut = Self.isSignedOut(error)
        }
    }

    private func fetchCodex(minAge: TimeInterval = 0) async {
        guard begin("codex", minAge: minAge) else { return }
        defer { inFlight.remove("codex") }
        let result = await CodexUsageClient.fetch()
        if let quota = result.quota {
            if quota.source == .live {
                codex.quota = quota
                codex.setTodayUsed(Self.todayUsed("codex", quota))
                QuotaCache.save(quota, as: "codex")
            } else if (codex.quota?.asOf ?? .distantPast) < quota.asOf {
                codex.quota = quota   // 本地日志比缓存的上次结果更新时才用它
            }
            if codex.quota == quota { Notifier.shared.quotaUpdated(key: "codex", name: "Codex", quota: quota) }
        }
        // 联网失败但有数据可显示时，卡片上会标「离线/截至」；只有没数据或被限流时才提示
        let message = result.liveError.map { describe($0, key: "codex") }
        let rateLimited = blockedUntil["codex"].map { $0 > Date() } ?? false
        codex.error = (codex.quota == nil || rateLimited) ? message : nil
        codex.signedOut = result.liveError.map(Self.isSignedOut) ?? false
    }

    private static func isSignedOut(_ error: Error) -> Bool {
        if case FetchError.noCredentials = error { return true }
        return false
    }

    /// 各家状态页一起查；失败时保留上一次的结果
    private func refreshServiceStatus(maxAge: TimeInterval) async {
        guard Date().timeIntervalSince(lastStatusCheck) >= maxAge else { return }
        lastStatusCheck = Date()
        async let claudeResult = capture { try await ServiceStatusClient.fetch(ServiceStatusClient.claude) }
        async let openaiResult = capture { try await ServiceStatusClient.fetch(ServiceStatusClient.openai) }
        async let deepseekResult = capture { try await DeepSeekStatusClient.fetch() }
        if case .success(let health) = await claudeResult { claude.health = health }
        if case .success(let health) = await openaiResult { codex.health = health }
        if case .success(let health) = await deepseekResult { deepseekHealth = health }
    }

    /// 重置信号查询失败时保留上一次的结果。历史间隔变化慢，出现新的重置或隔 6 小时才重算
    private func refreshResetSignal(maxAge: TimeInterval) async {
        guard Date().timeIntervalSince(lastSignalCheck) >= maxAge, (blockedUntil["signal"] ?? .distantPast) <= Date() else { return }
        lastSignalCheck = Date()
        let status: (latest: ResetSignal.Post?, next: ResetSignal.Schedule?)
        switch await capture({ try await ResetSignalClient.fetchStatus() }) {
        case .success(let result): status = result
        case .failure(let error): _ = describe(error, key: "signal"); return
        }
        var signal = ResetSignal(latest: status.latest, next: status.next, typicalGap: resetSignal?.typicalGap, checkedAt: Date())
        if status.latest?.id != resetSignal?.latest?.id || Date().timeIntervalSince(lastGapFetch) > 6 * 3600 {
            lastGapFetch = Date()
            switch await capture({ try await ResetSignalClient.fetchTypicalGap() }) {
            case .success(let gap): signal.typicalGap = gap ?? signal.typicalGap
            case .failure(let error): _ = describe(error, key: "signal")
            }
        }
        resetSignal = signal
        await announce(signal)
    }

    /// 新的预告、新的完成各通知一次；重置完成后马上重查 Codex 额度。
    /// 记的是通知过的一组 id：网站会撤回误判的信号，只记最新一条的话，撤回后旧信号会被当成新的再提醒一遍。
    /// 第一次运行只记下当前信号，不把以前的消息当成新的
    private func announce(_ signal: ResetSignal) async {
        let defaults = UserDefaults.standard
        let firstRun = defaults.object(forKey: "signal.seen") == nil
        var seen = defaults.stringArray(forKey: "signal.seen") ?? []
        func isNew(_ id: String) -> Bool {
            guard !seen.contains(id) else { return false }
            seen.append(id)
            return !firstRun
        }
        defer { defaults.set(Array(seen.suffix(30)), forKey: "signal.seen") }

        if let next = signal.next, isNew(next.post.id), next.end > Date() {
            Notifier.shared.resetSignal(next.post, title: "Codex 即将全员重置", body: "Tibo 预告：\(next.whenTexts()[0])")
        }
        // 电脑睡了很久才醒的话，太早的重置就不提醒了
        if let latest = signal.latest, isNew(latest.id), Date().timeIntervalSince(latest.at) < 6 * 3600 {
            Notifier.shared.resetSignal(latest, title: "Codex 全员额度已重置",
                                        body: "Tibo 在 \(Fmt.clock(latest.at)) 宣布重置了所有人的额度，可以放开用了")
            Notifier.shared.cancelResetReminders(key: "codex")   // 原来排好的「额度已恢复」已经没意义了
            await fetchCodex()
            lastUpdated = Date()
        }
    }

    /// 错误转成提示文字；遇到限流时记下等待时间
    private func describe(_ error: Error, key: String) -> String {
        guard case FetchError.rateLimited(let retryAfter) = error else { return error.localizedDescription }
        let until = Date().addingTimeInterval(retryAfter)
        blockedUntil[key] = until
        return "查询太频繁，\(Fmt.clock(until)) 前暂停查询"
    }

    /// 只用联网拿到的实时数据、且只看周额度；本地日志里的额度可能是几天前的
    private static func todayUsed(_ key: String, _ quota: ProviderQuota) -> Double? {
        guard quota.source == .live, let window = quota.windows.first(where: \.weekly) else { return nil }
        return DailyQuota.todayUsed(key: key, window: window)
    }
}

/// 上一次成功查询到的额度，存在 UserDefaults，启动时和限流期间显示
enum QuotaCache {
    static func load(_ key: String) -> ProviderQuota? {
        guard let data = UserDefaults.standard.data(forKey: "quotaCache.\(key)") else { return nil }
        return try? JSONDecoder().decode(ProviderQuota.self, from: data)
    }

    static func save(_ quota: ProviderQuota, as key: String) {
        guard let data = try? JSONEncoder().encode(quota) else { return }
        UserDefaults.standard.set(data, forKey: "quotaCache.\(key)")
    }
}
