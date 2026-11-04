import Foundation

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
