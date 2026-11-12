import AppKit
import SwiftUI

/// 全局涨跌配色。统一从这里取,确保:
///  - 菜单栏 ticker(深色背景)对比度足够
///  - Popover 半透明面板上文字在深色 / 浅色模式都清晰
///  - 三种 scheme(East / West / Mono)语义一致
enum SemanticColors {
    // MARK: 动态颜色(深色 / 浅色自适应) — Pulse 风格高辨识度金融色盘

    /// 红 — Pulse 风格:深色 #F04245(0.941, 0.259, 0.271),浅色 #D9383B(0.851, 0.220, 0.231)
    private static let dynamicRed = NSColor(name: "panbar.red") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.941, green: 0.259, blue: 0.271, alpha: 1) // #F04245
        }
        return NSColor(srgbRed: 0.851, green: 0.220, blue: 0.231, alpha: 1)     // #D9383B
    }

    /// 绿 — Pulse 风格:深色 #0AA859(0.039, 0.659, 0.349),浅色 #088746(0.031, 0.529, 0.275)
    private static let dynamicGreen = NSColor(name: "panbar.green") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.039, green: 0.659, blue: 0.349, alpha: 1) // #0AA859
        }
        return NSColor(srgbRed: 0.031, green: 0.529, blue: 0.275, alpha: 1)     // #088746
    }

    // MARK: NSColor 版本(菜单栏 ticker)

    /// 菜单栏始终深底(背景由系统模糊产生 vibrancy),用偏亮的色保证对比度。
    static func upNS(scheme: TickerColorScheme) -> NSColor {
        switch scheme {
        case .east: return NSColor(srgbRed: 0.941, green: 0.259, blue: 0.271, alpha: 1) // #F04245
        case .west: return NSColor(srgbRed: 0.039, green: 0.659, blue: 0.349, alpha: 1) // #0AA859
        case .mono: return NSColor.labelColor
        }
    }
    static func downNS(scheme: TickerColorScheme) -> NSColor {
        switch scheme {
        case .east: return NSColor(srgbRed: 0.039, green: 0.659, blue: 0.349, alpha: 1)
        case .west: return NSColor(srgbRed: 0.941, green: 0.259, blue: 0.271, alpha: 1)
        case .mono: return NSColor.labelColor
        }
    }

    // MARK: SwiftUI 版本(Popover / 设置面板)— 动态适配

    static func up(scheme: TickerColorScheme = .east) -> Color {
        switch scheme {
        case .east: return Color(nsColor: dynamicRed)
        case .west: return Color(nsColor: dynamicGreen)
        case .mono: return .primary
        }
    }
    static func down(scheme: TickerColorScheme = .east) -> Color {
        switch scheme {
        case .east: return Color(nsColor: dynamicGreen)
        case .west: return Color(nsColor: dynamicRed)
        case .mono: return .primary
        }
    }

    /// 涨色填充背景(pct pill 等)— Pulse 风格微透明胶囊背景
    static func upPillBg(scheme: TickerColorScheme = .east) -> Color {
        up(scheme: scheme).opacity(0.14)
    }
    static func downPillBg(scheme: TickerColorScheme = .east) -> Color {
        down(scheme: scheme).opacity(0.14)
    }

    /// Pulse 品牌青蓝渐变色
    static let pulseBrandBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let pulseBrandCyan = Color(red: 0.125, green: 0.769, blue: 0.875)

    /// 根据 Decimal 值方向取颜色。
    static func directional(_ value: Decimal, scheme: TickerColorScheme = .east) -> Color {
        if value > 0 { return up(scheme: scheme) }
        if value < 0 { return down(scheme: scheme) }
        return .primary
    }
    static func directional(_ value: Double, scheme: TickerColorScheme = .east) -> Color {
        if value > 0 { return up(scheme: scheme) }
        if value < 0 { return down(scheme: scheme) }
        return .primary
    }
}
