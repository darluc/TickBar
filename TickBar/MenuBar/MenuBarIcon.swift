import AppKit

/// 菜单栏 ticker 视图通用的 Pulse 脉搏波形图标绘制。
///
/// 采用 Pulse 标志性的青蓝电波(Pulse Waveform)设计:
/// 渐变蓝色圆角底板 + 精细流畅的心电/脉搏折线。
enum MenuBarIcon {
    private static let brandBlue = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)   // #0A84FF
    private static let brandCyan = NSColor(srgbRed: 0.125, green: 0.769, blue: 0.875, alpha: 1) // #20C4DF

    static func draw(in rect: NSRect) {
        let cornerRadius: CGFloat = max(3.5, rect.width * 0.24)
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        // 蓝青金融感渐变底色
        let gradient = NSGradient(colors: [brandBlue, brandCyan])
        gradient?.draw(in: bgPath, angle: 135)

        // 内部绘制 PulseWaveform 脉搏波形
        let inset: CGFloat = rect.width * 0.16
        let waveRect = rect.insetBy(dx: inset, dy: inset)
        let wave = PulseWaveform.bezierPath(in: waveRect)
        wave.lineWidth = max(1.2, rect.width * 0.08)
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round

        NSColor.white.setStroke()
        wave.stroke()
    }
}
