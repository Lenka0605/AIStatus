import AppKit

/// 状态栏图标：两层圆环（外圈 Claude、内圈 ChatGPT，各取剩余最少的那个额度），粗弧越长剩得越多。
/// 不用半透明：细实线做底轨，粗实线做进度；还没有数据时底轨画成虚线，和「剩 0%」区分开。
/// 模板图自动适配深浅色菜单栏。
enum MenuBarIcon {
    static func image(levels: [Double?]) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let rings: [(radius: CGFloat, level: Double?)] = [
                (7.2, levels.first ?? nil),
                (3.4, levels.count > 1 ? levels[1] : nil),
            ]
            NSColor.black.setStroke()
            for ring in rings {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: ring.radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 1
                if ring.level == nil { track.setLineDash([1.6, 1.6], count: 2, phase: 0) }
                track.stroke()

                let level = max(0, min(1, ring.level ?? 0))
                guard level > 0 else { continue }
                let arc = NSBezierPath()
                if level >= 0.999 {
                    arc.appendArc(withCenter: center, radius: ring.radius, startAngle: 0, endAngle: 360)
                } else {
                    arc.appendArc(withCenter: center, radius: ring.radius, startAngle: 90,
                                  endAngle: 90 - 360 * level, clockwise: true)
                    arc.lineCapStyle = .round
                }
                arc.lineWidth = 2.6
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 服务异常时叠在状态栏图标右上角的小圆点。图标是模板图只能单色，所以圆点用子视图画成彩色
final class MenuBarAlertDot: NSView {
    private static let size: CGFloat = 6

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不挡住状态栏按钮的点击
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(level: ServiceLevel, on button: NSStatusBarButton) {
        isHidden = !level.alertsMenuBar
        guard !isHidden else { return }
        layer?.backgroundColor = (level >= .partial ? NSColor.systemRed : NSColor.systemOrange).cgColor
        // 等按钮按新的标题和宽度重新布局后，再对齐到图标的右上角
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button, let rect = button.cell?.imageRect(forBounds: button.bounds) else { return }
            let y = button.isFlipped ? rect.minY : rect.maxY - Self.size
            self.setFrameOrigin(NSPoint(x: rect.maxX - Self.size + 1, y: y))
        }
    }
}
