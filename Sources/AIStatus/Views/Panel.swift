import AppKit
import SwiftUI

/// 带小箭头的不透明弹出面板（替代 MenuBarExtra 的半透明窗口）
@MainActor
@Observable
final class PanelChrome {
    var arrowX: CGFloat = PopoverView.width(columns: 2) / 2
    /// 驱动出现/收起动画
    var shown = false
}

struct PanelRoot: View {
    /// 面板四周留给阴影的透明边距；顶部只留 2pt，让箭头紧贴菜单栏。
    /// 边距必须大于阴影的扩散范围，否则阴影会被窗口的矩形边界截断，在浅色壁纸上露出一个方框。
    /// 当前阴影实测（alpha > 1%）：两侧 18pt、向下 27pt、向上 9pt（面板主体顶部离窗口顶 12pt）
    static let insets = EdgeInsets(top: 2, leading: 24, bottom: 34, trailing: 24)
    static let arrowHeight: CGFloat = 10
    static var windowWidth: CGFloat { PopoverView.width(columns: 2) + insets.leading + insets.trailing }

    let chrome: PanelChrome
    let store: Store
    let actions: PanelActions
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        let shape = CalloutShape(arrowX: chrome.arrowX, arrowHeight: Self.arrowHeight)
        let width = PopoverView.width(columns: PopoverView.layout(store).columns)
        PopoverView(actions: actions)
            .environment(store)
            .padding(.top, Self.arrowHeight)
            // 阴影只加在面板外形上，不能加在整个容器上，否则每张卡片都会带阴影
            .background(shape.fill(Theme.panel).shadow(color: .black.opacity(0.15), radius: 12, y: 9))
            .overlay(shape.stroke(Theme.panelBorder, lineWidth: 1))
            // 从箭头尖端处展开，像系统弹出框一样
            .scaleEffect(chrome.shown ? 1 : 0.9, anchor: UnitPoint(x: chrome.arrowX / width, y: 0))
            .opacity(chrome.shown ? 1 : 0)
            .padding(Self.insets)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}

/// 圆角矩形 + 顶部圆润的小箭头
struct CalloutShape: Shape {
    var arrowX: CGFloat
    var arrowWidth: CGFloat = 26
    var arrowHeight: CGFloat = 10
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight, width: rect.width, height: rect.height - arrowHeight)
        let half = arrowWidth / 2
        let ax = min(max(arrowX, body.minX + radius + half), body.maxX - radius - half)
        let tip = CGPoint(x: ax, y: rect.minY)

        var p = Path()
        p.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        p.addLine(to: CGPoint(x: ax - half, y: body.minY))
        p.addCurve(to: CGPoint(x: tip.x - 2, y: tip.y + 1),
                   control1: CGPoint(x: ax - half * 0.45, y: body.minY),
                   control2: CGPoint(x: ax - half * 0.35, y: tip.y + 2.5))
        p.addQuadCurve(to: CGPoint(x: tip.x + 2, y: tip.y + 1), control: tip)
        p.addCurve(to: CGPoint(x: ax + half, y: body.minY),
                   control1: CGPoint(x: ax + half * 0.35, y: tip.y + 2.5),
                   control2: CGPoint(x: ax + half * 0.45, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        p.closeSubpath()
        return p
    }
}

final class CalloutPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }

    /// Esc 收起面板
    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// 管理面板的显示位置与开关：点状态栏图标切换，点击其他地方或按 Esc 收起；不抢当前应用的焦点
@MainActor
final class PanelController {
    private let panel: CalloutPanel
    private let chrome = PanelChrome()
    private weak var button: NSStatusBarButton?
    private var anchor = NSRect.zero
    private var screenFrame = NSRect.zero
    /// 由 SwiftUI 布局回调（onGeometryChange）更新；面板创建时就会先算一次。
    /// 注意不能用 NSHostingView.fittingSize：关闭 sizingOptions 后它恒为 0。
    private var contentSize = CGSize(width: PanelRoot.windowWidth, height: 620)
    private var outsideClickMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusWindowObserver: NSObjectProtocol?
    /// 收起动画期间面板仍在屏幕上，用这个标记表示逻辑上的开关状态
    private(set) var isOpen = false
    private var generation = 0
    /// 上一次因为点了面板外面而收起的时间，见 toggle
    private var closedByOutsideClick = Date.distantPast
    var onOpen: () -> Void = {}

    init(store: Store, actions: PanelActions) {
        panel = CalloutPanel(contentRect: NSRect(x: 0, y: 0, width: PanelRoot.windowWidth, height: 600),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        var root = PanelRoot(chrome: chrome, store: store, actions: actions)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        root.onSize = { [weak self] size in self?.sizeChanged(size) }
        host.rootView = root
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// nil 跟随系统
    var appearance: NSAppearance? {
        get { panel.appearance }
        set { panel.appearance = newValue }
    }

    /// click：点状态栏图标打开时鼠标的位置，用来校验系统给的图标位置（见 updateAnchor）；用快捷键打开时没有
    func toggle(from button: NSStatusBarButton, click: NSPoint? = nil) {
        // 点状态栏图标时，「点了面板外面」的监听会抢先把面板收起，紧接着才轮到图标的点击。
        // 不跳过的话，这一下会把刚收起的面板又打开，看起来就是怎么点都收不起来
        if !isOpen && Date().timeIntervalSince(closedByOutsideClick) < 0.3 { return }
        isOpen ? close() : show(from: button, click: click)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let current = generation
        button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        if let observer = statusWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            statusWindowObserver = nil
        }
        panel.ignoresMouseEvents = true
        withAnimation(.easeIn(duration: 0.14)) { chrome.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            // 动画期间又被打开了就不要隐藏
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    private func show(from button: NSStatusBarButton, click: NSPoint?) {
        guard let window = button.window else { return }
        isOpen = true
        generation += 1
        self.button = button
        updateAnchor(click: click)
        place()
        onOpen()

        if !panel.isVisible { chrome.shown = false }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { self.chrome.shown = true }
        }
        // 状态栏按钮在鼠标抬起、结束跟踪时会自动取消高亮；只在 default 模式执行，确保排在跟踪结束之后
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.button?.highlight(true)
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                self.closedByOutsideClick = Date()
                self.close()
            }
        }
        // 图标还在往状态栏里滑的时候打开的，等它停下再对准一次
        statusWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window,
                                                                      queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                self.updateAnchor()
                self.place()
            }
        }
        // Cmd-Tab 切到别的应用、切换桌面时也收起
        let center = NSWorkspace.shared.notificationCenter
        let ownPID = ProcessInfo.processInfo.processIdentifier
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != ownPID else { return }   // 打开自己的设置窗口不算
                Task { @MainActor in self?.close() }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.close() }
            },
        ]
    }

    /// 横向对准图标中心，纵向贴住整条状态栏的下沿（图标按钮本身比状态栏矮）。
    /// 应用刚启动时图标宽度会变（加上百分比文字），状态栏要重新排版，这期间系统给的图标位置可能是滑动途中的
    /// （实测横向偏过 140pt、纵向偏过 19pt）。点图标打开时鼠标一定在图标上，横向对不上就以鼠标为准；
    /// 纵向等图标停下、窗口移动的通知到了再对准（见 show）
    private func updateAnchor(click: NSPoint? = nil) {
        guard let button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        anchor = NSRect(x: buttonRect.minX, y: window.frame.minY, width: buttonRect.width, height: window.frame.height)
        if let click, !(anchor.minX - 2...anchor.maxX + 2).contains(click.x) {
            anchor.origin.x = click.x - anchor.width / 2
        }
        screenFrame = (window.screen ?? NSScreen.main)?.frame ?? .zero
    }

    private func sizeChanged(_ size: CGSize) {
        guard size != contentSize else { return }
        contentSize = size
        if isOpen { place() }
    }

    /// 保持箭头尖端贴在状态栏图标正下方；面板靠近屏幕边缘时左右收进来，箭头仍指向图标
    private func place() {
        let insets = PanelRoot.insets
        var x = anchor.midX - contentSize.width / 2
        x = min(max(x, screenFrame.minX + 6 - insets.leading), screenFrame.maxX - 6 - contentSize.width + insets.trailing)
        let top = anchor.minY - 3 + insets.top
        panel.setFrame(NSRect(x: x, y: top - contentSize.height, width: contentSize.width, height: contentSize.height),
                       display: true)
        chrome.arrowX = anchor.midX - x - insets.leading
    }
}
