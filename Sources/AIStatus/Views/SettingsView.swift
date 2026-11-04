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

/// 设置页：和面板同样的卡片风格；不用 Form（它是滚动视图，没有固有高度，会让窗口塌成一条）
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(SettingsModel.self) private var model
    /// 窗口内容最多这么高；屏幕放不下时（比如笔记本屏幕底部有程序坞）改成滚动，保存按钮固定在底部
    var maxHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                sections
                ScrollView { sections }
                    .overlay(alignment: .bottom) { Divider() }
            }
            saveBar
        }
        .frame(width: 440)
        .frame(maxHeight: maxHeight ?? Self.screenMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Toast(text: toast)
                    .padding(.bottom, 18)
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

    private var sections: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            section(L("API 余额"),
                    footnote: L("余额 = 填写的余额 − 之后的花费，花费按 UTC 日统计，有几分钟延迟；DeepSeek 直接查账户余额，花费由余额变化推算。Key 只保存在本机钥匙串。")) {
                ForEach(Array(AdminProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { CardDivider() }
                    providerFields(provider, draft: $model.drafts[index])
                }
            }

            section(L("提醒"), footnote: model.notifyNote
                    ?? L("额度剩余低于 20% 和 5% 时各提醒一次，API 余额不到 $5（或 ¥35）时也会提醒；用掉一半以上的额度，到重置时间会提醒你已恢复。Codex 全员重置信号来自 didcodexreset.com（非官方，根据 Tibo 的推文判断）。点通知可以打开面板。")) {
                toggleRow(L("额度和余额不足提醒"), isOn: Binding(get: { model.notifyLow }, set: { model.setNotifyLow($0) }))
                toggleRow(L("额度恢复提醒"), isOn: Binding(get: { model.notifyReset }, set: { model.setNotifyReset($0) }))
                toggleRow(L("Codex 全员重置预告和完成"), isOn: Binding(get: { model.notifyResetSignal }, set: { model.setNotifyResetSignal($0) }))
                HStack(spacing: 16) {
                    Button(L("发送一条测试通知")) { model.sendTestNotification() }
                    if model.notifyNote != nil {
                        Button(L("打开系统通知设置")) { NSWorkspace.shared.open(Notifier.settingsURL) }
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            section(L("通用"), footnote: model.loginNote ?? model.hotKeyNote
                    ?? L("额度在后台按上面的间隔自动更新，状态栏数字跟着变；「仅在使用时」只在你正在用 Claude Code / Codex 时每 10 分钟查一次。服务状态和 Codex 重置信号每 5 分钟检查一次。查询太频繁被限流时会自动暂停，到时间再继续。")) {
                pickerRow(L("外观"), selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) }),
                          options: AppearanceMode.allCases, title: \.title, style: .segmented)
                pickerRow(L("语言"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) }),
                          options: LanguageOption.allCases, title: \.title, width: 120)
                toggleRow(L("开机自动启动"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                toggleRow(L("状态栏显示剩余百分比"), isOn: Binding(get: { model.menuBarPercent }, set: { model.setMenuBarPercent($0) }))
                pickerRow(L("自动刷新额度"), selection: Binding(get: { model.quotaRefresh }, set: { model.setQuotaRefresh($0) }),
                          options: QuotaRefresh.allCases, title: \.title, width: 120)
                pickerRow(L("打开面板的快捷键"), selection: Binding(get: { model.hotKey }, set: { model.setHotKey($0) }),
                          options: HotKeyOption.allCases, title: \.title, width: 120)
            }

            section(L("关于"), footnote: updateNote) {
                HStack {
                    Text(L("当前版本 \(Updater.currentVersion)")).font(.system(size: 13)).foregroundStyle(Theme.text)
                    Spacer()
                    Button(L("GitHub 主页")) { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    if let release = updater.available {
                        Button(L("更新到 \(release.version)")) { Task { await updater.install() } }
                            .controlSize(.small)
                            .disabled(updater.isBusy)
                    } else {
                        Button(L("检查更新")) { Task { await updater.check(manual: true) } }
                            .controlSize(.small)
                            .disabled(updater.isBusy)
                    }
                }
                toggleRow(L("自动检查更新"), isOn: Binding(get: { model.autoCheckUpdates }, set: { model.setAutoCheckUpdates($0) }))
            }
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
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

    private var saveBar: some View {
        HStack {
            if let error = model.saveError {
                InlineNotice(text: error)
            }
            Spacer()
            Button(L("保存")) { model.save(store) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.toast != nil)   // 已经在关窗口了，避免连点
        }
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 8)
    }

    private func providerFields(_ provider: AdminProvider, draft: Binding<SettingsModel.Draft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(provider.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
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

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
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
        _ label: String, selection: Binding<Option>, options: [Option], title: KeyPath<Option, String>,
        style: Style = .menu, width: CGFloat? = nil
    ) -> some View {
        HStack {
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

    private func section<Content: View>(_ title: String, footnote: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .card()
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func balanceHint(_ draft: SettingsModel.Draft) -> String {
        guard let anchor = draft.anchor else { return L("美元，例如 120.50（留空只显示花费）") }
        return L("已设为 \(Fmt.usd(anchor.balance))（\(Fmt.date(anchor.setAt ?? anchor.day))），留空不修改")
    }
}
