import SwiftUI

extension Color {
    /// 不透明的浅色/深色自适应颜色
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// 全部使用不透明颜色，避免面板下的壁纸透出来影响辨识。
/// 浅灰底 + 白色卡片（深色模式下卡片比底色亮一级），卡片里的小格子再用浅灰
enum Theme {
    static let panel = Color(light: 0xF2F2F5, dark: 0x1C1C1E)
    static let panelBorder = Color(light: 0xD2D2D8, dark: 0x3A3A3E)
    static let card = Color(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let cardBorder = Color(light: 0xE4E4E9, dark: 0x37373B)
    static let tile = Color(light: 0xF5F5F8, dark: 0x333337)
    static let track = Color(light: 0xEAEAEF, dark: 0x3E3E43)
    static let text = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let secondaryText = Color(light: 0x6E6E73, dark: 0xA8A8AD)
    static let tertiaryText = Color(light: 0x8E8E93, dark: 0x86868B)
    static let control = Color(light: 0xFFFFFF, dark: 0x2C2C2F)
    static let controlHover = Color(light: 0xF8F8FA, dark: 0x343437)
    static let controlPressed = Color(light: 0xEDEDF1, dark: 0x3D3D41)
    static let controlBorder = Color(light: 0xDCDCE2, dark: 0x45454A)
}

enum Palette {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let codex = Color(red: 0.063, green: 0.639, blue: 0.498)    // #10A37F
    static let deepseek = Color(red: 0.302, green: 0.420, blue: 0.996) // #4D6BFE
    static let danger = Color(red: 0.92, green: 0.30, blue: 0.27)
    static let warn = Color(red: 0.96, green: 0.62, blue: 0.20)
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let info = Color(red: 0.25, green: 0.52, blue: 0.96)
}

/// 悬停状态。命令行工具链里没有 SwiftUI 的 @State 宏插件，所以用 @StateObject + ObservableObject 存
final class HoverState: ObservableObject {
    @Published var on = false
}

extension Color {
    /// 同色系的浅一档，用于渐变的起点
    func lighter(_ amount: Double = 0.22) -> Color {
        if #available(macOS 15, *) { return mix(with: .white, by: amount) }
        // macOS 14 没有 mix，用 AppKit 的混色，效果几乎一样
        let base = NSColor(self)
        return Color(nsColor: base.blended(withFraction: amount, of: .white) ?? base)
    }
}

extension View {
    /// tint 不为空时，卡片顶部带一层很淡的品牌色渐变
    func card(padding: CGFloat = 14, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Theme.card)
                    .overlay {
                        if let tint {
                            shape.fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0)],
                                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)))
                        }
                    }
                    .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
            .overlay(shape.strokeBorder(Theme.cardBorder))
    }
}

/// 应用图标：深色圆角方块里两层圆环，外圈 Claude、内圈 ChatGPT（与状态栏图标一致）
struct AppGlyph: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            ring(diameter: size * 0.62, level: 0.75, color: Palette.claude)
            ring(diameter: size * 0.32, level: 0.55, color: Palette.codex)
        }
        .frame(width: size, height: size)
    }

    private func ring(diameter: CGFloat, level: CGFloat, color: Color) -> some View {
        let width = size * 0.1
        return ZStack {
            Circle().stroke(Color(white: 0.3), lineWidth: width)
            Circle()
                .trim(from: 0, to: level)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 卡片左上角的品牌图标：优先用本机安装的 Claude / ChatGPT / DeepSeek Harness 应用图标
struct BrandIcon: View {
    enum Kind { case claude, chatgpt, deepseek }
    let kind: Kind
    let tint: Color

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [tint.lighter(), tint], startPoint: .top, endPoint: .bottom))
                .overlay(fallbackMark.font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                .frame(width: 30, height: 30)
        }
    }

    private var image: NSImage? {
        switch kind {
        case .claude: return AppIcons.claude
        case .chatgpt: return AppIcons.chatgpt
        case .deepseek: return AppIcons.deepseek
        }
    }

    @ViewBuilder private var fallbackMark: some View {
        switch kind {
        case .claude: Text("C")
        case .chatgpt: Text("G")
        case .deepseek: Image(systemName: "fish.fill")   // 没有鲸鱼，用鱼代替
        }
    }
}

enum AppIcons {
    static let claudeApp = locate(paths: ["/Applications/Claude.app"], bundleIDs: ["com.anthropic.claudefordesktop"])
    static let chatgptApp = locate(paths: ["/Applications/ChatGPT.app"], bundleIDs: ["com.openai.chat"])
    static let deepseekApp = locate(paths: ["/Applications/DeepSeek Harness.app"], bundleIDs: ["com.deepseek.dsh"])
    static let claude = claudeApp.flatMap { rasterized(NSWorkspace.shared.icon(forFile: $0.path)) }
    static let chatgpt = chatgptApp.flatMap { rasterized(NSWorkspace.shared.icon(forFile: $0.path)) }
    static let deepseek = deepseekApp.flatMap { rasterized(NSWorkspace.shared.icon(forFile: $0.path)) }

    private static func locate(paths: [String], bundleIDs: [String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = paths.flatMap { [$0, home + $0] }
            + bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// 系统应用图标带 HDR 表示，会让渲染结果整体变灰；先画成 8 位 sRGB 位图再用
    private static func rasterized(_ icon: NSImage, points: CGFloat = 32, scale: Int = 3) -> NSImage? {
        let pixels = Int(points) * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return icon }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return icon }
        return NSImage(cgImage: cg, size: NSSize(width: points, height: points))
    }
}

/// 订阅档位徽章，如「Ultra」「Pro」
struct PlanBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(LinearGradient(colors: [tint.lighter(0.15), tint], startPoint: .top, endPoint: .bottom)))
            .fixedSize()
    }
}

struct StatusPill: View {
    enum Kind { case ok, busy, warn }
    let kind: Kind

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 2.5)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }

    private var color: Color {
        switch kind {
        case .ok: return Palette.ok
        case .busy: return Theme.tertiaryText
        case .warn: return Palette.warn
        }
    }

    private var text: String {
        switch kind {
        case .ok: return "正常"
        case .busy: return "更新中"
        case .warn: return "部分异常"
        }
    }
}

struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: [tint.lighter(), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fraction <= 0 ? 0 : max(height, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// 大号数字 + 小号百分号
struct PercentText: View {
    let value: Double
    var color: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(value.rounded()))")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: value))
            Text("%").font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

struct QuotaRow: View {
    let window: QuotaWindow
    let tint: Color

    var body: some View {
        let remaining = window.remainingPercent
        let low = remaining < 15
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                if let note = window.note {
                    // 单个模型的周额度和总的周额度同时重置，不再重复写重置时间
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                } else {
                    TimelineView(.everyMinute) { context in
                        if let reset = Fmt.reset(window.resetsAt, now: context.date) {
                            Text(reset).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }
                Spacer(minLength: 4)
                Text("剩余").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                PercentText(value: remaining, color: low ? Palette.danger : Theme.text)
            }
            MeterBar(fraction: remaining / 100, tint: low ? Palette.danger : tint)
        }
    }
}

/// 卡片底部的「今日」区域：今日已用周额度（含所有设备）+ 本机今日 Token
struct TodaySummary: View {
    let todayUsed: Double?
    let tokens: TokenTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let todayUsed {
                    StatTile(icon: "calendar", title: "今日已用周额度", value: Fmt.percent(todayUsed))
                        .help("根据服务器额度计算，包含网页、云端任务、手机和其他电脑上的使用")
                }
                StatTile(icon: "cpu", title: "本机今日 Token", value: Fmt.tokens(tokens.total))
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .monospacedDigit()
                .padding(.horizontal, 2)
        }
    }

    private var caption: String {
        if tokens.total == 0 { return "这台电脑今天还没有使用" }
        let known = tokens.total - tokens.other
        if known == 0 { return "来自运行日志，只有总数，可能少算" }
        let detail = "输入 \(Fmt.tokens(tokens.input)) · 输出 \(Fmt.tokens(tokens.output)) · 缓存 \(Fmt.tokens(tokens.cache))"
        return tokens.other > 0 ? detail + " · 其他 \(Fmt.tokens(tokens.other))" : detail
    }

}

/// 卡片里的小格子：上面一行小标题，下面一个大数字
struct StatTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(Theme.secondaryText)
            // 「$1.20 + ¥12.68」这种较长的值缩小一点，不换行。缩小后行高也会变小，
            // 用一个不缩小的占位撑住高度，并排的格子才一样高
            ZStack(alignment: .leading) {
                Text("0").hidden()
                Text(value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.tile))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.cardBorder).frame(height: 1)
    }
}

/// 卡片右上角的小图标按钮（快捷入口）
struct IconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover.on ? Theme.text : Theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.on ? Theme.track : Theme.tile))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .help(help)
    }
}

extension ServiceLevel {
    var color: Color {
        switch self {
        case .ok: return Palette.ok
        case .notice: return Palette.info
        case .maintenance: return Palette.info
        case .degraded, .partial: return Palette.warn
        case .major: return Palette.danger
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .notice: return "info.circle.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .degraded, .partial: return "exclamationmark.triangle.fill"
        case .major: return "xmark.octagon.fill"
        }
    }
}

/// 服务状态指示灯：绿色正常，橙色/红色异常，灰色表示还没查到
struct StatusLight: View {
    let level: ServiceLevel?

    var body: some View {
        let color = level?.color ?? Theme.tertiaryText
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: level == nil ? .clear : color.opacity(0.6), radius: 2.5)
    }
}

/// 服务异常时卡片里的提示条，点击打开官方状态页
struct ServiceNotice: View {
    let health: ServiceHealth
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: health.level.symbol).foregroundStyle(health.level.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(health.summary ?? health.level.title).foregroundStyle(Theme.text)
                    if let stage = health.stage {
                        Text(stage).font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("状态页").foregroundStyle(Theme.secondaryText)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(health.level.color.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(health.original.map { "原文：\($0)\n点击打开官方状态页" } ?? "打开官方状态页")
    }
}

/// Codex 卡片里的「全员重置」：上次什么时候、下次预计什么时候（本机时区）。点击打开 didcodexreset.com
struct ResetSignalTile: View {
    let signal: ResetSignal
    let tint: Color

    var body: some View {
        // 每分钟重画一次，「6 分钟前」才会跟着走
        TimelineView(.everyMinute) { context in
            tile(now: context.date)
        }
    }

    private func tile(now: Date) -> some View {
        let next = signal.nextTexts(now: now)
        let scheduled = next.kind == .scheduled
        let fresh = signal.latest.map { now.timeIntervalSince($0.at) < 12 * 3600 } ?? false
        let latest = signal.latestTexts(now: now)
        return Button { NSWorkspace.shared.open(ResetSignalClient.pageURL) } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: scheduled ? "bell.badge.fill" : fresh ? "checkmark.seal.fill" : "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(scheduled ? tint : fresh ? Palette.ok : Theme.secondaryText)
                    .frame(width: 18)
                // 两个标签字数相同，中文等宽，所以不用 Grid 也能对齐。
                // 时间有从详细到简略几种说法，ViewThatFits 挑第一个一行放得下的，始终不换行
                VStack(alignment: .leading, spacing: 4) {
                    row("上次全员重置") {
                        ViewThatFits(in: .horizontal) {
                            ForEach(latest.isEmpty ? ["暂无记录"] : latest, id: \.self) { text in
                                Text(text).foregroundStyle(Theme.text).lineLimit(1)
                            }
                        }
                    }
                    row("下次全员重置") {
                        ViewThatFits(in: .horizontal) {
                            ForEach(next.texts, id: \.self) { text in
                                nextLine(text, kind: next.kind, badge: true)
                            }
                            // 最简略的说法加上标签还放不下，就去掉标签（悬停提示里有说明）
                            if let last = next.texts.last {
                                nextLine(last, kind: next.kind, badge: false)
                            }
                        }
                    }
                }
                .layoutPriority(1)   // 先满足文字，剩下的才给 Spacer
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(scheduled ? tint.opacity(0.10) : Theme.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(now: now))
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.secondaryText).fixedSize()
            value()
        }
    }

    private func nextLine(_ text: String, kind: ResetSignal.NextKind, badge: Bool) -> some View {
        let scheduled = kind == .scheduled
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(text)
                .foregroundStyle(scheduled ? tint : Theme.text)
                .fontWeight(scheduled ? .semibold : .regular)
                .lineLimit(1)
            if badge && kind != .unknown {
                Text(scheduled ? "预告" : "估算")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(scheduled ? tint : Theme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(scheduled ? tint.opacity(0.14) : Theme.track))
                    .fixedSize()
            }
        }
    }

    private func help(now: Date) -> String {
        var lines: [String] = []
        if let latest = signal.latest {
            lines.append("上次全员重置：\(Fmt.dayTime(latest.at, now: now))")
            if let text = latest.text { lines.append("上次 Tibo 说：\(text)") }
        }
        if let next = signal.next {
            // 面板里可能只放得下简略说法，这里给完整时间段
            lines.append("预告时间：\(next.whenTexts(now: now)[0])")
            if let text = next.post.text { lines.append("Tibo 预告原话：\(text)") }
        }
        if signal.next == nil, let gap = signal.typicalGap {
            let days = String(format: "%.1f", gap / 86_400)
            lines.append("没有预告时，按最近 10 次全员重置的间隔中位数（约 \(days) 天）估算，仅供参考")
        }
        lines.append("时间按本机时区（\(TimeZone.current.identifier)）显示")
        lines.append("数据来自 didcodexreset.com（非官方，根据 Codex 负责人 Tibo 的推文判断），点击打开")
        return lines.joined(separator: "\n")
    }
}

/// 操作完成的小提示：绿色对勾 + 一句话
struct Toast: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
            Text(text).foregroundStyle(Theme.text)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.16), radius: 12, y: 4))
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

struct InlineNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
            Text(text).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}

/// 刷新时图标转圈；macOS 14 没有转圈效果，用闪烁代替
struct Spinning: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.symbolEffect(.rotate, options: .repeating, isActive: active)
        } else {
            content.symbolEffect(.pulse, options: .repeating, isActive: active)
        }
    }
}

struct SoftButtonStyle: ButtonStyle {
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration, square: square)
    }

    private struct SoftButton: View {
        let configuration: Configuration
        let square: Bool
        @StateObject private var hover = HoverState()

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: square ? 34 : .infinity, minHeight: 34)
                .frame(width: square ? 34 : nil)
                .background(
                    shape.fill(configuration.isPressed ? Theme.controlPressed : hover.on ? Theme.controlHover : Theme.control)
                        .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                )
                .overlay(shape.strokeBorder(Theme.controlBorder))
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
                .animation(.easeOut(duration: 0.12), value: hover.on)
        }
    }
}
