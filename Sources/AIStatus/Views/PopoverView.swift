import SwiftUI

struct PanelActions {
    var openSettings: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }
}

/// 两列卡片：上面一行是订阅额度（Claude Code / Codex），下面一行是按量付费的 API 余额
struct PopoverView: View {
    static let columnWidth: CGFloat = 298
    static let width: CGFloat = columnWidth * 2 + 12 + 32

    @Environment(Store.self) private var store
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 12) {
            header
            row {
                ProviderCard(info: .claude, state: store.claude, tokens: store.claudeTokens)
                ProviderCard(info: .chatgpt, state: store.codex, tokens: store.codexTokens, signal: store.resetSignal)
            }
            row {
                DeepSeekCard(openSettings: actions.openSettings)
                ApiBalanceCard(openSettings: actions.openSettings)
            }
            footer
        }
        .padding(16)
        .frame(width: Self.width)
    }

    /// 一行两张卡片，等宽等高（卡片自己要能在高度上撑开）
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) { content() }
            .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppGlyph(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 余量").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text(store.lastUpdated.map { "更新于 " + Fmt.clock($0) } ?? "正在获取…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            StatusPill(kind: store.isFetching ? .busy : (store.hasError ? .warn : .ok))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.refreshNow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .modifier(Spinning(active: store.isFetching))
                    Text(store.isFetching ? "刷新中…" : "立即刷新")
                }
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(store.isFetching)

            Button(action: actions.openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(SoftButtonStyle(square: true))
                .help("设置")

            Button(action: actions.quit) { Image(systemName: "power") }
                .buttonStyle(SoftButtonStyle(square: true))
                .help("退出")
        }
    }
}

/// 卡片的固定信息：名称、配色、月费，以及快捷入口
struct ProviderInfo {
    let name: String
    let product: String
    let kind: BrandIcon.Kind
    let tint: Color
    /// 套餐名 -> 月费（美元）
    let price: (String) -> Int?
    /// 本机安装的桌面应用；没装就打开 web
    let app: URL?
    let web: URL
    let usage: URL
    let status: URL

    static let claude = ProviderInfo(
        name: "Claude", product: "Claude Code", kind: .claude, tint: Palette.claude,
        price: ClaudeUsageClient.monthlyPrice, app: AppIcons.claudeApp,
        web: URL(string: "https://claude.ai")!,
        usage: URL(string: "https://claude.ai/settings/usage")!,
        status: ServiceStatusClient.claude.pageURL
    )

    static let chatgpt = ProviderInfo(
        name: "ChatGPT", product: "Codex", kind: .chatgpt, tint: Palette.codex,
        price: CodexUsageClient.monthlyPrice, app: AppIcons.chatgptApp,
        web: URL(string: "https://chatgpt.com")!,
        usage: URL(string: "https://chatgpt.com/codex/settings/usage")!,
        status: ServiceStatusClient.openai.pageURL
    )

    /// 没装 DeepSeek Harness 时打开开放平台
    static let deepseek = ProviderInfo(
        name: "DeepSeek", product: "开放平台", kind: .deepseek, tint: Palette.deepseek,
        price: { _ in nil }, app: AppIcons.deepseekApp,
        web: URL(string: "https://platform.deepseek.com")!,
        usage: URL(string: "https://platform.deepseek.com/usage")!,
        status: DeepSeekStatusClient.pageURL
    )

    func openApp() {
        if let app {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(web)
        }
    }
}

struct ProviderCard: View {
    let info: ProviderInfo
    let state: ProviderState
    let tokens: TokenTotals
    /// 只有 Codex 有：全员重置信号
    var signal: ResetSignal? = nil

    var body: some View {
        let health = state.currentHealth
        VStack(alignment: .leading, spacing: 13) {
            ProviderHeader(info: info, badge: state.quota?.plan, detail: detail, health: health)

            if let health, health.level > .ok {
                ServiceNotice(health: health) { NSWorkspace.shared.open(info.status) }
            }

            if let quota = state.quota, quota.source == .log {
                staleNote("离线数据 · 截至 " + Fmt.clock(quota.asOf), help: "联网获取失败，显示本地日志里最近一次记录")
            } else if let quota = state.quota, Date().timeIntervalSince(quota.asOf) > 120 {
                staleNote("截至 " + Fmt.clock(quota.asOf), help: "显示的是上一次查询的结果")
            }

            if let quota = state.quota {
                ForEach(quota.windows) { QuotaRow(window: $0, tint: info.tint) }
                if let credits = quota.credits {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.circle.fill").font(.system(size: 12)).foregroundStyle(info.tint)
                        Text("Credits 余额").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text(Fmt.integer(credits))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            if let error = state.error, state.notInUse {
                // 不用这家不算异常，不用警告图标
                Label(error, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            } else if let error = state.error {
                InlineNotice(text: error)
            } else if state.quota == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在获取额度…").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }

            // 本机没用过这家（没登录、也没有用量）时只留上面一行提示，不占地方
            if !(state.notInUse && tokens.total == 0) {
                VStack(alignment: .leading, spacing: 13) {
                    if let signal {
                        ResetSignalTile(signal: signal, tint: info.tint)
                    }
                    TodaySummary(todayUsed: state.todayUsedIfCurrent, tokens: tokens)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)   // 和旁边卡片等高时，今日数据贴底对齐
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(tint: info.tint)
    }

    /// 名称下方的一行：「Claude Code · $200/月」
    private var detail: String {
        let monthly = state.quota?.plan.flatMap(info.price).map { "$\($0)/月" }
        return ([info.product] + [monthly].compactMap { $0 }).joined(separator: " · ")
    }

    private func staleNote(_ text: String, help: String) -> some View {
        Label(text, systemImage: "clock")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
            .help(help)
    }
}

/// 卡片顶部一行：品牌图标、名称和徽章、说明，右边是状态灯和快捷入口
struct ProviderHeader: View {
    let info: ProviderInfo
    let badge: String?
    let detail: String
    let health: ServiceHealth?

    var body: some View {
        HStack(spacing: 10) {
            BrandIcon(kind: info.kind, tint: info.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if let badge {
                        PlanBadge(text: badge, tint: info.tint)
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                IconButton(help: statusHelp, action: { NSWorkspace.shared.open(info.status) }) {
                    StatusLight(level: health?.level)
                }
                IconButton(help: "打开 \(info.app?.deletingPathExtension().lastPathComponent ?? info.name)", action: info.openApp) {
                    Image(systemName: "arrow.up.forward.app")
                }
                IconButton(help: "在网页上查看用量", action: { NSWorkspace.shared.open(info.usage) }) {
                    Image(systemName: "chart.bar.xaxis")
                }
            }
        }
    }

    private var statusHelp: String {
        guard let health else { return "服务状态：还没查到，点击打开官方状态页" }
        return "服务状态：\(health.level == .ok ? "正常" : health.summary ?? health.level.title)，点击打开官方状态页"
    }
}

/// DeepSeek 只有按量付费的 API：显示账户余额（充值和赠金分开，可能是不同币种）和服务状态
struct DeepSeekCard: View {
    @Environment(Store.self) private var store
    let openSettings: () -> Void

    var body: some View {
        let info = ProviderInfo.deepseek
        let health = store.deepseekHealth?.ifCurrent
        VStack(alignment: .leading, spacing: 13) {
            ProviderHeader(info: info, badge: "API", detail: "开放平台 · 按量付费", health: health)
            if let health, health.level > .ok {
                ServiceNotice(health: health) { NSWorkspace.shared.open(info.status) }
            }
            if let state = store.spend[.deepseek] {
                if let spend = state.spend {
                    VStack(alignment: .leading, spacing: 3) {
                        balanceRow(spend)
                        Text(balanceCaption(spend))
                            .font(.system(size: 11))
                            .foregroundStyle(spend.available ? Theme.tertiaryText : Palette.danger)
                            .monospacedDigit()
                    }
                    if let usage = spend.usage {
                        usageTiles(usage, spend: spend)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                if let error = state.error {
                    InlineNotice(text: error)
                } else if state.spend == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在查询余额…").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
            } else {
                SetupPrompt(text: "填写 API Key 后显示余额和用量", action: openSettings)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(tint: info.tint)
    }

    /// 「账户余额  $20.00 + ¥4.32」：每个币种一个数
    private func balanceRow(_ spend: ApiSpend) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("账户余额").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            ForEach(Array(spend.balances.enumerated()), id: \.element.id) { index, balance in
                if index > 0 {
                    Text("+").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                }
                Text(Fmt.money(balance.total, currency: balance.currency))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(spend.isLow ? Palette.danger : Theme.text)
            }
        }
        .lineLimit(1)
    }

    /// 「充值 $20.00 · 赠金 ¥4.32，先扣赠金」
    private func balanceCaption(_ spend: ApiSpend) -> String {
        if !spend.available { return "余额不足，API 已无法调用" }
        let parts = "充值 \(amounts(spend.balances.map { ($0.currency, $0.toppedUp) }, spend))"
            + " · 赠金 \(amounts(spend.balances.map { ($0.currency, $0.granted) }, spend))"
        return spend.balances.contains { $0.granted > 0 } ? parts + "，先扣赠金" : parts
    }

    private func usageTiles(_ usage: BalanceUsage, spend: ApiSpend) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                StatTile(icon: "calendar", title: "今日花费", value: amounts(usage.today.map { ($0, $1) }, spend))
                StatTile(icon: "chart.bar.fill", title: "本月花费", value: amounts(usage.month.map { ($0, $1) }, spend))
            }
            .help("DeepSeek 的 API Key 查不到用量明细，这里每次查余额都和上一次比，减少的部分记为花费；"
                  + "充值和新到的赠金不算。应用没运行期间的花费，会在下次查到余额时算到那一天")
            DailySpendChart(days: usage.recent) { amounts($0.map { ($0, $1) }, spend) }
                .padding(.top, 6)
            Text(usageCaption(usage))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 2)
        }
    }

    private func usageCaption(_ usage: BalanceUsage) -> String {
        let now = Date()
        // 记录还没覆盖整个月时，说明本月花费从哪天开始算
        guard usage.since > Calendar.current.dateInterval(of: .month, for: now)?.start ?? now else {
            return "根据余额变化推算，充值和新到的赠金不算"
        }
        return "根据余额变化推算 · \(Fmt.dayTime(usage.since, now: now, weekday: false)) 开始记录"
    }

    /// 各币种的金额，按余额列表的币种顺序，为 0 的不写；全是 0 时写一个 0，币种取正在扣的那个（有赠金先扣赠金）
    private func amounts(_ values: [(currency: String, amount: Double)], _ spend: ApiSpend) -> String {
        let order = spend.balances.map(\.currency)
        let parts = values.filter { $0.amount >= 0.005 }
            .sorted { (order.firstIndex(of: $0.currency) ?? .max) < (order.firstIndex(of: $1.currency) ?? .max) }
            .map { Fmt.money($0.amount, currency: $0.currency) }
        let zero = (spend.balances.first { $0.granted > 0 } ?? spend.balances.first(where: { $0.total > 0 }) ?? spend.balances.first)?.currency
        return parts.isEmpty ? Fmt.money(0, currency: zero ?? "CNY") : parts.joined(separator: " + ")
    }
}

/// 近 7 天每天的花费。只有一组数据，不画图例，也不在每根柱子上标数字：悬停在某一天上，右上角显示那天的金额
struct DailySpendChart: View {
    let days: [DaySpend]
    /// 金额的写法和格子里一致（多个币种用「+」连起来）
    let format: ([String: Double]) -> String
    @StateObject private var hover = HoveredDay()

    private static let plotHeight: CGFloat = 30

    var body: some View {
        let peak = days.map { Self.magnitude($0.amounts) }.max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 7 天").foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(headline).foregroundStyle(Theme.text).monospacedDigit()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)
            HStack(spacing: 0) {
                ForEach(days) { column($0, peak: peak) }
            }
        }
    }

    /// 柱子 + 基线 + 星期；各列之间没有间距，基线连成一条
    private func column(_ day: DaySpend, peak: Double) -> some View {
        let value = Self.magnitude(day.amounts)
        let today = Calendar.current.isDateInToday(day.day)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if value > 0, peak > 0 {
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                        .fill(Palette.deepseek.opacity(hover.day == nil || hover.day == day.day ? 1 : 0.35))
                        .frame(width: 16, height: max(4, Self.plotHeight * value / peak))
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.plotHeight, maxHeight: Self.plotHeight, alignment: .bottom)
            Rectangle().fill(Theme.cardBorder).frame(height: 1)
            Text(today ? "今天" : Fmt.weekday(day.day))
                .font(.system(size: 10, weight: today ? .semibold : .regular))
                .foregroundStyle(today ? Theme.secondaryText : Theme.tertiaryText)
                .opacity(day.recorded ? 1 : 0.5)
                .padding(.top, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hover.day = day.day } else if hover.day == day.day { hover.day = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.day(day.day)) \(day.recorded ? format(day.amounts) : "未记录")")
    }

    private var headline: String {
        if let hovered = hover.day, let day = days.first(where: { $0.day == hovered }) {
            return "\(Fmt.day(day.day))  \(day.recorded ? format(day.amounts) : "未记录")"
        }
        let total = days.reduce(into: [String: Double]()) { $0.merge($1.amounts, uniquingKeysWith: +) }
        return "合计 \(format(total))"
    }

    /// 柱子高度要用同一把尺子：人民币按约 7:1 折成美元。只影响高度，金额文字照实写
    private static func magnitude(_ amounts: [String: Double]) -> Double {
        amounts.reduce(0) { $0 + ($1.key == "CNY" ? $1.value / 7 : $1.value) }
    }
}

/// 悬停的是哪一天（理由同 HoverState）
final class HoveredDay: ObservableObject {
    @Published var day: Date?
}

/// Anthropic / OpenAI 的 API 花费和余额（用 Admin Key 查）
struct ApiBalanceCard: View {
    @Environment(Store.self) private var store
    let openSettings: () -> Void

    var body: some View {
        let providers = AdminProvider.allCases.filter { !$0.reportsBalance && store.spend[$0] != nil }
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.tile)
                    .overlay(Image(systemName: "creditcard.fill").font(.system(size: 13)).foregroundStyle(Theme.secondaryText))
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API 余额").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Anthropic · OpenAI，用 Admin Key 查询")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if providers.isEmpty {
                Text("填写 Admin Key 后，这里显示 API 当天和当月的花费；再填上当前余额，就能算出还剩多少")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                SetupPrompt(text: "还没有配置", action: openSettings)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                ForEach(providers) { provider in
                    SpendRow(title: provider.title, state: store.spend[provider] ?? SpendState())
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

/// 卡片里的「去设置」入口
struct SetupPrompt: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text).foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 4)
                Text("去设置").foregroundStyle(Theme.text)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SpendRow: View {
    let title: String
    let state: SpendState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                if let spend = state.spend {
                    Text(Fmt.usd(spend.remaining ?? spend.month ?? 0))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(spend.isLow ? Palette.danger : Theme.text)
                } else if state.error == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            if let error = state.error {
                InlineNotice(text: error)
            } else if let spend = state.spend {
                let today = Fmt.usd(spend.today ?? 0)
                Text(spend.remaining == nil
                     ? "本月花费 · UTC 今日 \(today) · 未填写余额"
                     : "UTC 今日 \(today) · 本月 \(Fmt.usd(spend.month ?? 0))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}
