import AppKit
import ServiceManagement

enum Preferences {
    private static let defaults = UserDefaults.standard
    private static let keychainService = "AIStatus"

    static func adminKey(for p: AdminProvider) -> String? {
        SecurityCLI.read(service: keychainService, account: "\(p.rawValue)-admin-key")
    }

    static func setAdminKey(_ key: String?, for p: AdminProvider) {
        let account = "\(p.rawValue)-admin-key"
        if let key, !key.isEmpty {
            SecurityCLI.write(service: keychainService, account: account, value: key)
        } else {
            SecurityCLI.delete(service: keychainService, account: account)
        }
    }

    static func anchor(for p: AdminProvider) -> BalanceAnchor? {
        guard let data = defaults.data(forKey: "anchor.\(p.rawValue)") else { return nil }
        return try? JSONDecoder().decode(BalanceAnchor.self, from: data)
    }

    static func setAnchor(_ anchor: BalanceAnchor?, for p: AdminProvider) {
        let key = "anchor.\(p.rawValue)"
        if let anchor, let data = try? JSONEncoder().encode(anchor) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// 额度剩余不多时发通知
    static var notifyLow: Bool {
        get { defaults.object(forKey: "notify.low") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notify.low") }
    }

    /// 额度重置后发通知
    static var notifyReset: Bool {
        get { defaults.object(forKey: "notify.reset") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notify.reset") }
    }

    /// Tibo 预告或宣布 Codex 全员重置时发通知
    static var notifyResetSignal: Bool {
        get { defaults.object(forKey: "notify.resetSignal") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notify.resetSignal") }
    }

    /// 状态栏图标旁显示剩余百分比
    static var menuBarPercent: Bool {
        get { defaults.object(forKey: "menuBar.percent") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "menuBar.percent") }
    }

    /// 后台多久自动查一次额度（状态栏数字靠它更新）
    static var quotaRefresh: QuotaRefresh {
        get { defaults.string(forKey: "quotaRefresh").flatMap(QuotaRefresh.init(rawValue:)) ?? .every5 }
        set { defaults.set(newValue.rawValue, forKey: "quotaRefresh") }
    }

    /// 面板和设置窗口的外观，默认跟随系统
    static var appearance: AppearanceMode {
        get { defaults.string(forKey: "appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    static var hotKey: HotKeyOption {
        get { defaults.string(forKey: "hotKey").flatMap(HotKeyOption.init(rawValue:)) ?? .optionCommandA }
        set { defaults.set(newValue.rawValue, forKey: "hotKey") }
    }
}

enum QuotaRefresh: String, CaseIterable, Identifiable {
    case every2, every5, every10
    /// 只在本机正在用 Claude Code / Codex 时查，最多每 10 分钟一次
    case whenActive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .every2: return "每 2 分钟"
        case .every5: return "每 5 分钟"
        case .every10: return "每 10 分钟"
        case .whenActive: return "仅在使用时"
        }
    }

    /// 固定间隔；仅在使用时为 nil
    var interval: TimeInterval? {
        switch self {
        case .every2: return 120
        case .every5: return 300
        case .every10: return 600
        case .whenActive: return nil
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 自动时为 nil，窗口跟随系统
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> SMAppService.Status {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AIStatus: 开机启动设置失败 \(error)")
        }
        return SMAppService.mainApp.status
    }
}
