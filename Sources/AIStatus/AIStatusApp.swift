import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if ["--dump", "--snapshot", "--make-icon", "--check-update", "--install-update"].contains(where: args.contains) {
            DebugTools.run(args)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let settings = SettingsModel()
    private var statusItem: NSStatusItem?
    private var panel: PanelController?
    private var settingsWindow: NSWindow?
    private let alertDot = MenuBarAlertDot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.addSubview(alertDot)
        statusItem = item

        let actions = PanelActions(openSettings: { [weak self] in self?.openSettings() })
        let controller = PanelController(store: store, actions: actions)
        controller.onOpen = { [weak self] in self?.store.panelOpened() }
        panel = controller

        Notifier.shared.onOpen = { [weak self] in self?.openPanel() }
        settings.close = { [weak self] in self?.closeSettings() }
        Notifier.shared.setUp()
        GlobalHotKey.action = { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            self.panel?.toggle(from: button)
        }
        if !GlobalHotKey.apply(Preferences.hotKey) {
            NSLog("AIStatus: 快捷键 \(Preferences.hotKey.title) 注册失败")
        }
        store.startBackgroundWork()
        Updater.shared.startAutomaticChecks()

        installEditMenu()
        updateIcon()
        updateAppearance()
    }

    /// 状态栏应用不显示菜单栏，但 ⌘C / ⌘V 等快捷键要靠主菜单里的「编辑」菜单才能送到输入框
    private func installEditMenu() {
        let edit = NSMenu(title: L("编辑"))
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())   // 第一项会被当成应用菜单，占个位
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panel?.toggle(from: sender, click: NSEvent.mouseLocation)
    }

    private func openPanel() {
        guard let button = statusItem?.button, panel?.isOpen == false else { return }
        panel?.toggle(from: button)
    }

    /// 额度、服务状态或相关设置变化时重画状态栏图标
    private func updateIcon() {
        withObservationTracking {
            guard let item = statusItem, let button = item.button else { return }
            button.image = MenuBarIcon.image(levels: store.iconLevels)
            if settings.menuBarPercent {
                item.length = NSStatusItem.variableLength
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.title = store.menuBarText
            } else {
                item.length = NSStatusItem.squareLength
                button.imagePosition = .imageOnly
                button.title = ""
            }
            button.toolTip = settings.hotKey == .off ? L("AI 余量") : L("AI 余量（\(settings.hotKey.title)）")
            alertDot.show(level: store.serviceLevel, on: button)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    /// 外观设置只作用于面板和设置窗口；状态栏图标始终跟随菜单栏本身的深浅
    private func updateAppearance() {
        withObservationTracking {
            let appearance = settings.appearance.nsAppearance
            panel?.appearance = appearance
            settingsWindow?.appearance = appearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateAppearance() }
        }
    }

    private func openSettings() {
        panel?.close()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(store).environment(settings))
            host.sizingOptions = [.preferredContentSize]   // 窗口大小跟随内容
            let window = NSWindow(contentViewController: host)
            window.title = L("AI 余量设置")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.appearance = settings.appearance.nsAppearance
            window.layoutIfNeeded()
            settingsWindow = window
        }
        settings.load()   // 窗口是复用的，重新打开时清掉上次没保存的输入和提示
        settingsWindow?.alphaValue = 1
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 淡出后再关，比直接消失柔和
    private func closeSettings() {
        guard let window = settingsWindow, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }
    }
}
