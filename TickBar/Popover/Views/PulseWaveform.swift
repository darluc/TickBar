import SwiftUI
import AppKit

/// Pulse 经典的脉搏心电波形几何路径。
/// 根据 https://www.pulseticker.app/ 提取的精准矢量坐标转换。
struct PulseWaveform: Shape {
    func path(in rect: CGRect) -> Path {
        let vbX: CGFloat = 134
        let vbY: CGFloat = 215
        let vbW: CGFloat = 756
        let vbH: CGFloat = 580

        let scaleX = rect.width / vbW
        let scaleY = rect.height / vbH

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (x - vbX) * scaleX,
                y: rect.minY + (y - vbY) * scaleY
            )
        }

        var path = Path()
        // 起点
        path.move(to: pt(170, 512))
        // h122 -> (292, 512)
        path.addLine(to: pt(292, 512))
        // c24 0 36 -36 56 -36 -> cp1(316, 512), cp2(328, 476), end(348, 476)
        path.addCurve(to: pt(348, 476), control1: pt(316, 512), control2: pt(328, 476))
        // c23 0 35 61 57 61 -> cp1(371, 476), cp2(383, 537), end(405, 537)
        path.addCurve(to: pt(405, 537), control1: pt(371, 476), control2: pt(383, 537))
        // c20 0 39 -114 88 -259 -> cp1(425, 537), cp2(444, 423), end(493, 278)
        path.addCurve(to: pt(493, 278), control1: pt(425, 537), control2: pt(444, 423))
        // c9 -27 27 -27 36 2 -> cp1(502, 251), cp2(520, 251), end(529, 280)
        path.addCurve(to: pt(529, 280), control1: pt(502, 251), control2: pt(520, 251))
        // l98 448 -> (627, 728)
        path.addLine(to: pt(627, 728))
        // c7 31 27 31 39 2 -> cp1(634, 759), cp2(654, 759), end(666, 730)
        path.addCurve(to: pt(666, 730), control1: pt(634, 759), control2: pt(654, 759))
        // l72 -210 -> (738, 520)
        path.addLine(to: pt(738, 520))
        // c6 -17 18 -22 36 -22 -> cp1(744, 503), cp2(756, 498), end(774, 498)
        path.addCurve(to: pt(774, 498), control1: pt(744, 503), control2: pt(756, 498))
        // h80 -> (854, 498)
        path.addLine(to: pt(854, 498))

        return path
    }

    /// AppKit NSBezierPath 生成方法
    static func bezierPath(in rect: CGRect) -> NSBezierPath {
        let vbX: CGFloat = 134
        let vbY: CGFloat = 215
        let vbW: CGFloat = 756
        let vbH: CGFloat = 580

        let scaleX = rect.width / vbW
        // AppKit 坐标原点在左下,反转 Y 坐标使之正常显示
        let scaleY = rect.height / vbH

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(
                x: rect.minX + (x - vbX) * scaleX,
                y: rect.maxY - (y - vbY) * scaleY
            )
        }

        let path = NSBezierPath()
        path.move(to: pt(170, 512))
        path.line(to: pt(292, 512))
        path.curve(to: pt(348, 476), controlPoint1: pt(316, 512), controlPoint2: pt(328, 476))
        path.curve(to: pt(405, 537), controlPoint1: pt(371, 476), controlPoint2: pt(383, 537))
        path.curve(to: pt(493, 278), controlPoint1: pt(425, 537), controlPoint2: pt(444, 423))
        path.curve(to: pt(529, 280), controlPoint1: pt(502, 251), controlPoint2: pt(520, 251))
        path.line(to: pt(627, 728))
        path.curve(to: pt(666, 730), controlPoint1: pt(634, 759), controlPoint2: pt(654, 759))
        path.line(to: pt(738, 520))
        path.curve(to: pt(774, 498), controlPoint1: pt(744, 503), controlPoint2: pt(756, 498))
        path.line(to: pt(854, 498))

        return path
    }
}
