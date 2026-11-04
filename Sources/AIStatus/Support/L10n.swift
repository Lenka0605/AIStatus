import AppKit

/// 界面文字：源码里写中文原文，按系统语言从 Resources/<语言>.lproj/Localizable.strings 里取译文。
/// 没有译文时显示原文（中文）。改了文案要重新生成翻译表，见 scripts/l10n.sh
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

/// 运行时才知道的文字（比如从缓存里读出来的额度名称），按原文查表
func Ldynamic(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

enum AppLanguage {
    /// 应用实际使用的界面语言：zh-Hans / en / vi。跟随系统设置（含「系统设置 › 通用 › 语言与地区」里给本应用单独设的语言）
    static let code: String = {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return ["zh-Hans", "en", "vi"].contains(code) ? code : "en"
    }()

    static var isChinese: Bool { code == "zh-Hans" }
    static var isEnglish: Bool { code == "en" }

    /// 日期、星期的写法跟着界面语言走，不然英文界面里会冒出「周四」
    static let locale = Locale(identifier: code)
}

/// 设置里的「语言」：跟随系统，或者只给本应用指定一种语言。
/// 和「系统设置 › 通用 › 语言与地区 › 应用程序」用的是同一个设置（本应用域里的 AppleLanguages），两边改的效果一样。
/// macOS 只在启动时读这个设置，所以改完要重新打开应用
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
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// 启动时的设置。和它不一样说明改过、还没重新打开（AppDelegate 启动时先读一次）
    static let atLaunch = current

    /// 退出后马上重新打开自己
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2""#, "sh",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
