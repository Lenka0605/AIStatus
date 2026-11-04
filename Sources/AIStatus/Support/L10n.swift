import AppKit
import Observation

/// 界面文字：源码里写中文原文，按当前界面语言从 Resources/<语言>.lproj/Localizable.strings 里取译文。
/// 没有译文时显示原文（中文）。改了文案要检查翻译表，见 scripts/l10n.sh。
/// 界面上的文字一律经过 L()（不用 Text("中文") 这种由 SwiftUI 自己查表的写法），
/// 视图读到语言状态后会自动跟踪，在设置里换语言时立即重画，不用重新打开应用
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: AppLanguage.bundle, locale: AppLanguage.locale)
}

/// 运行时才知道的文字，按原文查表
func Ldynamic(_ key: String) -> String {
    AppLanguage.bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// 当前界面语言。可观察：SwiftUI 视图、状态栏图标的观察回调读到它，换语言时会自动刷新
@Observable
final class LanguageState: @unchecked Sendable {
    static let shared = LanguageState()

    static let supported = ["zh-Hans", "en", "vi"]

    /// 后台线程也会调用 L()，所以用锁保护，变化通知交给 Observation
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var _code: String

    var code: String {
        get {
            access(keyPath: \.code)
            return lock.withLock { _code }
        }
        set {
            withMutation(keyPath: \.code) { lock.withLock { _code = newValue } }
        }
    }

    private init() {
        // 启动时按系统的选择（含命令行 -AppleLanguages 和「系统设置」里给本应用单独设的语言）
        let first = Bundle.main.preferredLocalizations.first ?? "en"
        _code = Self.supported.contains(first) ? first : "en"
    }

    /// 不指定语言时用哪种：按系统的首选语言列表，挑第一个我们支持的，都不支持就用英文
    static func systemCode() -> String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let preferred = global?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
        for language in preferred {
            if language.hasPrefix("zh-Hans") || language == "zh" || language.hasPrefix("zh-CN") || language.hasPrefix("zh-SG") {
                return "zh-Hans"
            }
            if language.hasPrefix("en") { return "en" }
            if language.hasPrefix("vi") { return "vi" }
        }
        return "en"
    }
}

enum AppLanguage {
    static var code: String { LanguageState.shared.code }
    static var isChinese: Bool { code == "zh-Hans" }
    static var isEnglish: Bool { code == "en" }

    /// 日期、星期的写法跟着界面语言走，不然英文界面里会冒出「周四」
    static var locale: Locale { Locale(identifier: code) }

    /// 对应语言的 .lproj 目录；找不到（命令行直接运行没打包的程序时）就用主 bundle
    static var bundle: Bundle {
        let code = code
        return lock.withLock {
            if let cached = bundles[code] { return cached }
            let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
            bundles[code] = bundle
            return bundle
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundles: [String: Bundle] = [:]
}

/// 设置里的「语言」：跟随系统，或者只给本应用指定一种语言，切换后立即生效。
/// 选择同时写进本应用域里的 AppleLanguages，和「系统设置 › 通用 › 语言与地区 › 应用程序」是同一个设置，
/// 这样系统自带的文字（比如输入框的右键菜单）下次启动也跟着变
enum LanguageOption: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en
    case vi

    var id: String { rawValue }

    /// 语言名用它自己的文字写，不管当前界面是什么语言都认得出来
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        }
    }

    static var current: LanguageOption {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let first = (UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String])?.first
            else { return .system }
            return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                LanguageState.shared.code = LanguageState.systemCode()
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
                LanguageState.shared.code = newValue.rawValue
            }
        }
    }
}
