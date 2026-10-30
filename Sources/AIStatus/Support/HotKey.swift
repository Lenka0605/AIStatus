import Carbon.HIToolbox

enum HotKeyOption: String, CaseIterable, Identifiable {
    case off
    case optionCommandA
    case controlOptionA
    case controlOptionCommandA

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "不使用"
        case .optionCommandA: return "⌥⌘A"
        case .controlOptionA: return "⌃⌥A"
        case .controlOptionCommandA: return "⌃⌥⌘A"
        }
    }

    fileprivate var modifiers: UInt32? {
        switch self {
        case .off: return nil
        case .optionCommandA: return UInt32(optionKey | cmdKey)
        case .controlOptionA: return UInt32(controlKey | optionKey)
        case .controlOptionCommandA: return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

/// 全局快捷键：用 Carbon 的 RegisterEventHotKey，不需要辅助功能权限
@MainActor
enum GlobalHotKey {
    static var action: () -> Void = {}
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    /// 返回 false 表示注册失败（通常是被其他应用占用了）
    @discardableResult
    static func apply(_ option: HotKeyOption) -> Bool {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        guard let modifiers = option.modifiers else { return true }
        installHandler()
        let id = EventHotKeyID(signature: 0x4149_5354, id: 1)   // 'AIST'
        return RegisterEventHotKey(UInt32(kVK_ANSI_A), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.action() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
