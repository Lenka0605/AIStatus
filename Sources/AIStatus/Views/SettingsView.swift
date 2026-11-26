import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    struct Draft {
        var key = ""
        var balance = ""
        var hasKey = false
        var anchor: BalanceAnchor?
    }

    var drafts = AdminProvider.allCases.map { _ in Draft() }
    var launchAtLogin = LaunchAtLogin.isEnabled
    var loginNote: String?
    /// 保存成功后显示的提示，随后窗口淡出关闭
    var toast: String?
    var saveError: String?
    /// 由 AppDelegate 设置：淡出并关闭设置窗口
    @ObservationIgnored var close: () -> Void = {}
    // 下面这些开关改了立即生效，不需要点「保存」
    var notifyLow = Preferences.notifyLow
    var notifyReset = Preferences.notifyReset
    var notifyResetSignal = Preferences.notifyResetSignal
    var notifyNote: String?
    var menuBarPercent = Preferences.menuBarPercent
    var quotaRefresh = Preferences.quotaRefresh
    var appearance = Preferences.appearance
    var language = LanguageOption.current
    var hotKey = Preferences.hotKey
    var hotKeyNote: String?
    var autoCheckUpdates = Preferences.autoCheckUpdates

    func load() {
        drafts = AdminProvider.allCases.map { p in
            Draft(hasKey: Preferences.adminKey(for: p) != nil, anchor: Preferences.anchor(for: p))
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        loginNote = nil
        toast = nil
        saveError = nil
        notifyLow = Preferences.notifyLow
        notifyReset = Preferences.notifyReset
        notifyResetSignal = Preferences.notifyResetSignal
        menuBarPercent = Preferences.menuBarPercent
        quotaRefresh = Preferences.quotaRefresh
        appearance = Preferences.appearance
        language = LanguageOption.current
        hotKey = Preferences.hotKey
        autoCheckUpdates = Preferences.autoCheckUpdates
        Task { await refreshNotifyNote() }
    }

    func setNotifyLow(_ on: Bool) {
        Preferences.notifyLow = on
        notifyLow = on
        if on { requestNotifications() }
    }

    func setNotifyReset(_ on: Bool) {
        Preferences.notifyReset = on
        notifyReset = on
        if on { requestNotifications() } else { Notifier.shared.cancelResetReminders() }
    }

    func setNotifyResetSignal(_ on: Bool) {
        Preferences.notifyResetSignal = on
        notifyResetSignal = on
        if on { requestNotifications() }
    }

    func sendTestNotification() {
        Notifier.shared.sendTest()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshNotifyNote()
        }
    }

    func setMenuBarPercent(_ on: Bool) {
        Preferences.menuBarPercent = on
        menuBarPercent = on
    }

    /// 下一次后台检查（一分钟内）生效
    func setQuotaRefresh(_ option: QuotaRefresh) {
        Preferences.quotaRefresh = option
        quotaRefresh = option
    }

    /// AppDelegate 观察这个属性，立即应用到面板和设置窗口
    func setLanguage(_ option: LanguageOption) {
        LanguageOption.current = option
        language = option
    }

    func setAppearance(_ mode: AppearanceMode) {
        Preferences.appearance = mode
        appearance = mode
    }

    func setAutoCheckUpdates(_ on: Bool) {
        Preferences.autoCheckUpdates = on
        autoCheckUpdates = on
    }

    func setHotKey(_ option: HotKeyOption) {
        Preferences.hotKey = option
        hotKey = option
        hotKeyNote = GlobalHotKey.apply(option) ? nil : L("\(option.title) 注册失败，可能已被其他应用占用，换一个试试")
    }

    private func requestNotifications() {
        Notifier.shared.requestAuthorization {
            Task { @MainActor in await self.refreshNotifyNote() }
        }
    }

    private func refreshNotifyNote() async {
        notifyNote = await Notifier.shared.isDenied()
            ? L("通知权限已关闭，请在「系统设置 › 通知 › AI 余量」里允许")
            : nil
    }

    func save(_ store: Store) {
        // 先校验余额，有填错的就整体不保存，避免「已保存」但其实没生效
        var balances: [AdminProvider: Double] = [:]
        var invalid: [String] = []
        for (index, provider) in AdminProvider.allCases.enumerated() {
            let raw = drafts[index].balance.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let cleaned = raw.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let value = Double(cleaned), value >= 0 { balances[provider] = value } else { invalid.append(provider.title) }
        }
        guard invalid.isEmpty else {
            saveError = L("\(invalid.joined(separator: L("、"))) 的余额格式不对，请填美元金额，例如 120.50")
            return
        }

        for (index, provider) in AdminProvider.allCases.enumerated() {
            let key = drafts[index].key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Preferences.setAdminKey(key, for: provider) }
            if let value = balances[provider] {
                Preferences.setAnchor(BalanceAnchor(balance: value, day: UTC.dayStart(Date()), snapshot: nil, setAt: Date()),
                                      for: provider)
            }
        }
        store.reloadConfiguredProviders()
        store.refreshNow()
        load()
        // 先让提示停留一会儿再关窗口，否则一闪而过看不清
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) { toast = L("设置已保存") }
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            close()
        }
    }

    func clear(_ provider: AdminProvider, _ store: Store) {
        Preferences.setAdminKey(nil, for: provider)
        Preferences.setAnchor(nil, for: provider)
        store.reloadConfiguredProviders()
        load()
    }

    func setLaunchAtLogin(_ on: Bool) {
        let status = LaunchAtLogin.set(on)
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginNote = L("需要在「系统设置 › 通用 › 登录项」里允许 AI 余量")
            SMAppService.openSystemSettingsLoginItems()
        } else {
            loginNote = nil
        }
    }
}

/// 设置页的分页。除了「API 余额」要点保存，其他页的开关改了立即生效
enum SettingsTab: String, CaseIterable, Identifiable {
    case balance, notify, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balance: return L("API 余额")
        case .notify: return L("提醒")
        case .general: return L("通用")
        case .about: return L("关于")
        }
    }

    var symbol: String {
        switch self {
        case .balance: return "creditcard.fill"
        case .notify: return "bell.badge.fill"
        case .general: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .balance: return Palette.info
        case .notify: return Palette.danger
        case .general: return Color(white: 0.5)
        case .about: return Palette.ok
        }
    }
}

/// 行首的彩色小图标，和系统设置里的风格一致
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [color.lighter(), color], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
    }
}

/// 设置页：和面板同样的卡片风格，上面是应用头和分页，每页的内容都放得下，放不下的页内滚动。
/// 不用 Form（它是滚动视图，没有固有高度，会让窗口塌成一条）
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(SettingsModel.self) private var model
    /// 窗口内容最多这么高；屏幕放不下时（比如笔记本屏幕底部有程序坞）缩短内容区，页内滚动
    var maxHeight: CGFloat?
    @State private var tab: SettingsTab

    init(maxHeight: CGFloat? = nil, tab: SettingsTab = .balance) {
        self.maxHeight = maxHeight
        _tab = State(initialValue: tab)
    }

    /// 应用头、分页条、底栏占的高度
    private static let chromeHeight: CGFloat = 196
    private static let contentHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { pageContent }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: max(240, min(Self.contentHeight, (maxHeight ?? Self.screenMaxHeight) - Self.chromeHeight)))
            .id(tab)
            .transition(.opacity)
            Divider()
            footer
        }
        .frame(width: 460)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Toast(text: toast)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.panel)
        .onAppear { model.load() }
    }

    /// 屏幕可用高度减去标题栏和一点边距
    private static var screenMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 60
    }

    // MARK: 应用头和分页条

    private var header: some View {
        HStack(spacing: 14) {
            AppGlyph(size: 48)
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("AI 余量")).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Text(L("当前版本 \(Updater.currentVersion)")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if let release = updater.available {
                Button { Task { await updater.install() } } label: {
                    Label(L("更新到 \(release.version)"), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.ok))
                }
                .buttonStyle(.plain)
                .disabled(updater.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                let selected = item == tab
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? item.color : Theme.tertiaryText)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.card)
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.track))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.saveError, tab == .balance {
                InlineNotice(text: error)
            } else {
                Label(tab == .balance ? L("填好 Key 和余额后点保存") : L("这里的修改立即生效"),
                      systemImage: tab == .balance ? "key.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            if tab == .balance {
                Button(L("保存")) { model.save(store) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(model.toast != nil)   // 已经在关窗口了，避免连点
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: 各页内容

    @ViewBuilder private var pageContent: some View {
        @Bindable var model = model
        switch tab {
        case .balance:
            ForEach(Array(AdminProvider.allCases.enumerated()), id: \.element) { index, provider in
                providerFields(provider, draft: $model.drafts[index])
                    .card()
            }
            footnote(L("余额 = 填写的余额 − 之后的花费，花费按 UTC 日统计，有几分钟延迟；DeepSeek 直接查账户余额，花费由余额变化推算。Key 只保存在本机钥匙串。"))

        case .notify:
            VStack(alignment: .leading, spacing: 14) {
                toggleRow(L("额度和余额不足提醒"), icon: "exclamationmark.triangle.fill", color: Palette.warn,
                          isOn: Binding(get: { model.notifyLow }, set: { model.setNotifyLow($0) }))
                toggleRow(L("额度恢复提醒"), icon: "arrow.counterclockwise", color: Palette.ok,
                          isOn: Binding(get: { model.notifyReset }, set: { model.setNotifyReset($0) }))
                toggleRow(L("Codex 全员重置预告和完成"), icon: "bell.badge.fill", color: Palette.codex,
                          isOn: Binding(get: { model.notifyResetSignal }, set: { model.setNotifyResetSignal($0) }))
                CardDivider()
                HStack(spacing: 16) {
                    Button(L("发送一条测试通知")) { model.sendTestNotification() }
                    if model.notifyNote != nil {
                        Button(L("打开系统通知设置")) { NSWorkspace.shared.open(Notifier.settingsURL) }
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .card()
            footnote(model.notifyNote
                     ?? L("额度剩余低于 20% 和 5% 时各提醒一次，API 余额不到 $5（或 ¥35）时也会提醒；用掉一半以上的额度，到重置时间会提醒你已恢复。Codex 全员重置信号来自 didcodexreset.com（非官方，根据 Tibo 的推文判断）。点通知可以打开面板。"))

        case .general:
            VStack(alignment: .leading, spacing: 14) {
                pickerRow(L("外观"), icon: "circle.lefthalf.filled", color: Color(white: 0.35),
                          selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) }),
                          options: AppearanceMode.allCases, title: \.title, style: .segmented)
                pickerRow(L("语言"), icon: "globe", color: Palette.info,
                          selection: Binding(get: { model.language }, set: { model.setLanguage($0) }),
                          options: LanguageOption.allCases, title: \.title, width: 120)
                toggleRow(L("开机自动启动"), icon: "power", color: Palette.ok,
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                toggleRow(L("状态栏显示剩余百分比"), icon: "percent", color: Palette.warn,
                          isOn: Binding(get: { model.menuBarPercent }, set: { model.setMenuBarPercent($0) }))
                pickerRow(L("自动刷新额度"), icon: "arrow.clockwise", color: Palette.codex,
                          selection: Binding(get: { model.quotaRefresh }, set: { model.setQuotaRefresh($0) }),
                          options: QuotaRefresh.allCases, title: \.title, width: 120)
                pickerRow(L("打开面板的快捷键"), icon: "command", color: Color(red: 0.55, green: 0.42, blue: 0.92),
                          selection: Binding(get: { model.hotKey }, set: { model.setHotKey($0) }),
                          options: HotKeyOption.allCases, title: \.title, width: 120)
            }
            .card()
            footnote(model.loginNote ?? model.hotKeyNote
                     ?? L("额度在后台按上面的间隔自动更新，状态栏数字跟着变；「仅在使用时」只在你正在用 Claude Code / Codex 时每 10 分钟查一次。服务状态和 Codex 重置信号每 5 分钟检查一次。查询太频繁被限流时会自动暂停，到时间再继续。"))

        case .about:
            VStack(spacing: 6) {
                AppGlyph(size: 64)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .padding(.top, 4)
                Text(L("AI 余量")).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(L("当前版本 \(Updater.currentVersion)")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 10) {
                    if let release = updater.available {
                        Button(L("更新到 \(release.version)")) { Task { await updater.install() } }
                            .disabled(updater.isBusy)
                    } else {
                        Button(L("检查更新")) { Task { await updater.check(manual: true) } }
                            .disabled(updater.isBusy)
                    }
                    Button(L("GitHub 主页")) { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!) }
                }
                .controlSize(.regular)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .card()
            toggleRow(L("自动检查更新"), icon: "arrow.triangle.2.circlepath", color: Palette.info,
                      isOn: Binding(get: { model.autoCheckUpdates }, set: { model.setAutoCheckUpdates($0) }))
                .card()
            footnote(updateNote)
        }
    }

    private var updater: Updater { Updater.shared }

    private var updateNote: String {
        switch updater.phase {
        case .checking: return L("正在检查更新…")
        case .downloading: return L("正在下载新版本…")
        case .installing: return L("正在安装，完成后会自动重新打开")
        case .failed(let message): return message
        case .upToDate where updater.available == nil:
            return L("已是最新版本（\(Fmt.clock(updater.lastChecked ?? Date())) 检查）")
        default:
            if let release = updater.available {
                return L("新版本 \(release.version) 已发布。点「更新」会下载并替换当前版本，然后自动重新打开")
            }
            return L("每 6 小时到 GitHub 检查一次新版本，有更新时通知你")
        }
    }

    // MARK: 零件

    private func providerFields(_ provider: AdminProvider, draft: Binding<SettingsModel.Draft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIcon(kind: brand(provider).kind, tint: brand(provider).tint)
                    .scaleEffect(0.9)
                    .frame(width: 30, height: 30)
                Text(provider.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if draft.wrappedValue.hasKey {
                    Text(L("已配置"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.ok))
                }
                Spacer()
                if draft.wrappedValue.hasKey {
                    Button(L("清除")) { model.clear(provider, store) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            labeled(provider.keyName) {
                SecureField(provider.keyName, text: draft.key,
                            prompt: Text(draft.wrappedValue.hasKey ? L("已保存，留空则不修改") : provider.keyHint))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            if !provider.reportsBalance {
                labeled(L("当前余额")) {
                    TextField(L("当前余额"), text: draft.balance, prompt: Text(balanceHint(draft.wrappedValue)))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
        }
    }

    private func brand(_ provider: AdminProvider) -> (kind: BrandIcon.Kind, tint: Color) {
        switch provider {
        case .anthropic: return (.claude, Palette.claude)
        case .openai: return (.chatgpt, Palette.codex)
        case .deepseek: return (.deepseek, Palette.deepseek)
        }
    }

    private func toggleRow(_ title: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: icon, color: color)
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// 下拉菜单样式要给固定宽度：它报给 fixedSize 的理想宽度会塌成只剩箭头，文字被截断
    private func pickerRow<Option: Hashable & Identifiable, Style: PickerStyle>(
        _ label: String, icon: String, color: Color, selection: Binding<Option>, options: [Option],
        title: KeyPath<Option, String>, style: Style = .menu, width: CGFloat? = nil
    ) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: icon, color: color)
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.text)
            Spacer()
            Picker(label, selection: selection) {
                ForEach(options) { Text($0[keyPath: title]).tag($0) }
            }
            .pickerStyle(style)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: width)
            .fixedSize()
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
    }

    private func balanceHint(_ draft: SettingsModel.Draft) -> String {
        guard let anchor = draft.anchor else { return L("美元，例如 120.50（留空只显示花费）") }
        return L("已设为 \(Fmt.usd(anchor.balance))（\(Fmt.date(anchor.setAt ?? anchor.day))），留空不修改")
    }
}
