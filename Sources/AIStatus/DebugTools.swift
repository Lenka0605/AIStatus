import SwiftUI

/// 命令行调试模式：
///   --dump               打印当前获取到的全部数据
///   --snapshot <目录>     把面板渲染成 PNG（浅色/深色）
///   --sample             配合 --snapshot：额度用示例数据，不联网（调界面时用）
///   --sample-estimate    配合 --sample：重置信号显示「按间隔估算」而不是「Tibo 预告」
///   --sample-range       配合 --sample：预告是一个时间段（「明天重置」这类只到日期的预告）
///   --sample-signed-out  配合 --sample：Codex 显示为本机没登录
///   --sample-update      配合 --sample：显示「有新版本」
///   --make-icon <目录>    生成 AppIcon.iconset
///   --check-update       查一次 GitHub 上的最新版本并打印
///   --install-update     有新版本就下载、替换当前 .app 并重新打开（测试自动更新用）
@MainActor
enum DebugTools {
    static func run(_ args: [String]) {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        if let dir = value(after: "--make-icon") {
            makeIconset(at: URL(fileURLWithPath: dir))
            exit(0)
        }

        if args.contains("--check-update") || args.contains("--install-update") {
            _ = NSApplication.shared   // 安装完要调用 NSApp.terminate
            Task { @MainActor in
                let updater = Updater.shared
                await updater.check(manual: true)
                print("当前 \(Updater.currentVersion)，最新 \(updater.latest.map { "\($0.version) \($0.dmg?.absoluteString ?? "没有 dmg")" } ?? "无")，状态 \(updater.phase)")
                if args.contains("--install-update"), updater.available != nil {
                    await updater.install()
                    print("安装失败：\(updater.phase)")
                }
                exit(0)
            }
            RunLoop.main.run()
        }

        // ImageRenderer 需要主 RunLoop 在跑，所以这里手动驱动 RunLoop 等待数据，而不是 dispatchMain()
        final class Flag { var done = false }
        let store = Store()
        let flag = Flag()
        Task { @MainActor in
            // --offline：不联网，只统计本机 token（避免调试时触发限流）
            if args.contains("--offline") || args.contains("--sample") { await store.refreshLocal() } else { await store.refresh(force: true) }
            if args.contains("--sample") { fillSample(store, args: args) }
            if args.contains("--sample-update") {
                Updater.shared.latest = Updater.Release(version: "9.9.0", page: Updater.releasesPage, dmg: nil)
            }
            flag.done = true
        }
        while !flag.done {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if args.contains("--dump") { dump(store) }
        if let dir = value(after: "--snapshot") { snapshot(store, to: URL(fileURLWithPath: dir)) }
        if let dir = value(after: "--switch-test") { switchTest(store, to: URL(fileURLWithPath: dir)) }
        exit(0)
    }

    private static func fillSample(_ store: Store, args: [String]) {
        let now = Date()
        store.claude.quota = ProviderQuota(plan: "Ultra", windows: [
            QuotaWindow(id: "seven_day", name: .weekly, usedPercent: 14, resetsAt: now.addingTimeInterval(2 * 86_400), weekly: true),
            QuotaWindow(id: "seven_day_fable", name: .weeklyModel("Fable"), usedPercent: 0, resetsAt: now.addingTimeInterval(2 * 86_400),
                        allowance: 50),
        ], credits: nil, source: .live, asOf: now)
        store.claude.setTodayUsed(2)
        store.codex.quota = ProviderQuota(plan: "Pro", windows: [
            QuotaWindow(id: "secondary_window", name: .span(minutes: 10_080), usedPercent: 81, resetsAt: now.addingTimeInterval(6 * 86_400), weekly: true),
        ], credits: 37_463, source: .live, asOf: now)
        store.codex.setTodayUsed(50)
        store.claude.health = ServiceHealth(level: .degraded, summary: L("\("Claude Code")\(ServiceLevel.degraded.title)"), checkedAt: now)
        store.codex.health = ServiceHealth(
            level: .notice, summary: IncidentSummary.chinese("Elevated errors on code review and security review", fallbackSubject: ""), stage: IncidentSummary.stage("monitoring"),
            original: "Elevated error rates for most hosted Code Reviews and Security Reviews on private GitHub repositories",
            checkedAt: now)
        let post = ResetSignal.Post(id: "sample", at: now.addingTimeInterval(-6 * 60), text: "已经全部同步完成。明天尽情疯狂 Codex 吧。", url: nil)
        let day = Calendar.current.startOfDay(for: now)
        let range = args.contains("--sample-range")
        store.resetSignal = ResetSignal(
            latest: post,
            next: args.contains("--sample-estimate") ? nil : ResetSignal.Schedule(
                post: ResetSignal.Post(id: "sample-next", at: now, text: "第 24 天：明天是重置日", url: nil),
                start: day.addingTimeInterval(86_400 + (range ? 14 : 15) * 3600),
                end: day.addingTimeInterval(range ? 2 * 86_400 + 13 * 3600 + 59 * 60 : 86_400 + 15 * 3600), deadline: !range),
            typicalGap: 2.04 * 86_400, checkedAt: now)
        store.spend = [
            .anthropic: SpendState(spend: ApiSpend(today: 3.42, month: 61.8, remaining: 118.6)),
            .deepseek: SpendState(spend: ApiSpend(balances: [
                CurrencyBalance(currency: "USD", total: 20, granted: 0, toppedUp: 20),
                CurrencyBalance(currency: "CNY", total: 4.32, granted: 4.32, toppedUp: 0),
            ], usage: args.contains("--sample-fresh")
                ? BalanceUsage(today: [:], month: [:], since: now.addingTimeInterval(-2 * 3600))
                : BalanceUsage(today: ["CNY": 2.47], month: ["USD": 1.2, "CNY": 12.68], since: now.addingTimeInterval(-40 * 86_400),
                               recent: sampleRecent(now)))),
        ]
        store.deepseekHealth = ServiceHealth(level: .ok, checkedAt: now)
        if args.contains("--sample-signed-out") {
            store.codex = ProviderState(error: "本机未登录 Codex，登录后自动显示", signedOut: true)
            store.codexTokens = TokenTotals()
        }
        store.lastUpdated = now
    }

    private static func dump(_ store: Store) {
        func describe(_ name: String, _ state: ProviderState, _ tokens: TokenTotals) {
            print("== \(name)")
            if let q = state.quota {
                print("  套餐: \(q.plan ?? "-")  来源: \(q.source == .live ? "实时" : "日志")  时间: \(q.asOf)")
                for w in q.windows {
                    print("  \(w.label): 已用 \(w.usedPercent)%  剩 \(Int(w.remainingPercent))%  \(Fmt.reset(w.resetsAt) ?? "-")")
                }
                if let c = q.credits { print("  credits: \(c)") }
            }
            if let e = state.error { print("  错误: \(e)") }
            if let h = state.health {
                print("  服务状态: \(h.level.title) \(h.summary ?? "") \(h.stage.map { "（\($0)）" } ?? "")")
                if let o = h.original { print("    原文: \(o)") }
            }
            print("  今日已用周额度: \(state.todayUsed.map { Fmt.percent($0) } ?? "-")")
            print("  本机今日 token: 总 \(tokens.total) 输入 \(tokens.input) 输出 \(tokens.output) 缓存写 \(tokens.cacheWrite) 缓存读 \(tokens.cacheRead) 其他 \(tokens.other)")
        }
        describe("Claude", store.claude, store.claudeTokens)
        describe("ChatGPT / Codex", store.codex, store.codexTokens)
        if let s = store.resetSignal {
            let next = s.nextTexts()
            print("== Codex 全员重置（didcodexreset.com）")
            print("  上次: \(s.latestTexts().first ?? "-")  \(s.latest?.text ?? "")")
            print("  下次: \(next.texts.joined(separator: " / "))  \(next.kind)  \(s.next?.post.text ?? "")")
            print("  近期间隔中位数: \(s.typicalGap.map { String(format: "%.2f 天", $0 / 86_400) } ?? "-")  估算: \(s.estimate.map { Fmt.dayTime($0) } ?? "-")")
        }
        if let h = store.deepseekHealth {
            print("== DeepSeek 状态: \(h.level.title)  \(h.summary ?? "")  \(h.stage ?? "")")
        }
        for p in AdminProvider.allCases {
            guard let s = store.spend[p] else { print("== \(p.title) API: 未配置"); continue }
            print("== \(p.title) API: \(String(describing: s.spend)) \(s.error ?? "")")
            if let u = s.spend?.usage {
                print("  今日花费: \(u.today)  本月花费: \(u.month)  开始记录: \(Fmt.dayTime(u.since))")
            }
        }
    }

    /// 近 7 天：前两天还没开始记录，有一天没花钱，有一天花的是美元
    private static func sampleRecent(_ now: Date) -> [DaySpend] {
        let calendar = Calendar.current
        let values: [[String: Double]] = [[:], [:], ["CNY": 3.1], [:], ["CNY": 5.4], ["USD": 1.2, "CNY": 0.8], ["CNY": 2.47]]
        return values.enumerated().map { index, amounts in
            let day = calendar.date(byAdding: .day, value: index - 6, to: calendar.startOfDay(for: now))!
            return DaySpend(day: day, amounts: amounts, recorded: index >= 2)
        }
    }

    private static func snapshot(_ store: Store, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chrome = PanelChrome()
        chrome.shown = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let dark = appearance == .darkAqua
            let view = PanelRoot(chrome: chrome, store: store, actions: PanelActions())
                .background(dark ? Color(red: 0.23, green: 0.2, blue: 0.24) : Color(red: 0.86, green: 0.78, blue: 0.7))
                .environment(\.colorScheme, dark ? .dark : .light)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                write(view, to: dir.appendingPathComponent("popover-\(name).png"), scale: 2)
            }
            snapshotSettingsWindow(store, appearance: appearance, to: dir.appendingPathComponent("settings-\(name).png"))
        }
        // 不限高度的完整版本（看最下面的分区用）
        snapshotSettingsWindow(store, appearance: .aqua, maxHeight: 3000, to: dir.appendingPathComponent("settings-full.png"))
        // 屏幕不够高时的滚动版本
        snapshotSettingsWindow(store, appearance: .aqua, maxHeight: 600, to: dir.appendingPathComponent("settings-short.png"))
        let menu = Image(nsImage: MenuBarIcon.image(levels: store.iconLevels))
            .renderingMode(.template)
            .foregroundStyle(.black)
            .padding(6)
            .background(Color.white)
        write(menu, to: dir.appendingPathComponent("menubar.png"), scale: 6)
        print("已保存到 \(dir.path)")
    }

    /// 设置页里有原生输入框，ImageRenderer 画不出来，所以开一个真实窗口（放在屏幕外）再截取它的内容
    private static func snapshotSettingsWindow(_ store: Store, appearance: NSAppearance.Name, maxHeight: CGFloat? = nil,
                                               to url: URL) {
        let host = NSHostingController(rootView: SettingsView(maxHeight: maxHeight).environment(store).environment(SettingsModel()))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        print("设置窗口内容尺寸: \(window.contentLayoutRect.size)")
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    /// 同一个面板窗口开着，依次切换界面语言，每次截一张图：确认不用重新打开就能换语言
    private static func switchTest(_ store: Store, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chrome = PanelChrome()
        chrome.shown = true
        let host = NSHostingController(rootView: PanelRoot(chrome: chrome, store: store, actions: PanelActions()))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        for code in ["zh-Hans", "en", "vi", "zh-Hans"] {
            LanguageState.shared.code = code
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("switch-\(code).png"))
            }
        }
        window.orderOut(nil)
        print("已保存到 \(dir.path)")
    }

    private static func makeIconset(at dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let icon = AppGlyph(size: 824)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            .frame(width: 1024, height: 1024)
        for base in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let suffix = factor == 2 ? "@2x" : ""
                write(icon, to: dir.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"),
                      scale: CGFloat(base * factor) / 1024)
            }
        }
    }

    private static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
