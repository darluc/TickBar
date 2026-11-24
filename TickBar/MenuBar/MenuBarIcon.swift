import AppKit

/// 菜单栏 ticker 视图通用的极简扁平遥测图标绘制（低饱和股市红绿配色），与 AppIcon 保持视觉一致。
enum MenuBarIcon {
    private static let spaceDark  = NSColor(srgbRed: 20/255, green: 25/255, blue: 34/255, alpha: 1)    // #141922
    private static let mutedGreen = NSColor(srgbRed: 55/255, green: 139/255, blue: 110/255, alpha: 1)  // #378B6E
    private static let mutedRed   = NSColor(srgbRed: 196/255, green: 83/255, blue: 87/255, alpha: 1)   // #C45357
    private static let pureWhite  = NSColor(srgbRed: 246/255, green: 248/255, blue: 251/255, alpha: 1) // #F6F8FB

    static func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cornerRadius = max(3.5, rect.width * 0.24)
        let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()

        // 1. 哑光深空底色
        ctx.setFillColor(spaceDark.cgColor)
        ctx.fill(rect)

        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + ny * rect.height)
        }

        let r = rect.width * 0.044
        let pts = [
            pt(-0.08, 0.34),
            pt(0.24, 0.44),
            pt(0.45, 0.31),
            pt(0.75, 0.72),
            pt(1.08, 0.59)
        ]

        // 2. 单层低饱和股市绿色域
        let area = CGMutablePath()
        area.move(to: pts[0])
        area.addArc(tangent1End: pts[1], tangent2End: pts[2], radius: r)
        area.addArc(tangent1End: pts[2], tangent2End: pts[3], radius: r)
        area.addLine(to: pts[3])
        area.addLine(to: pts[4])
        area.addLine(to: CGPoint(x: rect.maxX + rect.width * 0.08, y: rect.minY - rect.height * 0.08))
        area.addLine(to: CGPoint(x: rect.minX - rect.width * 0.08, y: rect.minY - rect.height * 0.08))
        area.closeSubpath()
        ctx.addPath(area)
        ctx.setFillColor(mutedGreen.cgColor)
        ctx.fillPath()

        // 3. 白色行情折线
        let line = CGMutablePath()
        line.move(to: pts[0])
        line.addArc(tangent1End: pts[1], tangent2End: pts[2], radius: r)
        line.addArc(tangent1End: pts[2], tangent2End: pts[3], radius: r)
        line.addLine(to: pts[3])
        line.addLine(to: pts[4])

        ctx.addPath(line)
        ctx.setStrokeColor(pureWhite.cgColor)
        ctx.setLineWidth(max(1.4, rect.width * 0.085))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        // 4. 低饱和股市红峰值信标点
        let peak = pts[3]
        let outerR = max(1.8, rect.width * 0.115)
        ctx.setFillColor(pureWhite.cgColor)
        ctx.fillEllipse(in: CGRect(x: peak.x - outerR, y: peak.y - outerR, width: outerR * 2, height: outerR * 2))

        let innerR = outerR * 0.56
        ctx.setFillColor(mutedRed.cgColor)
        ctx.fillEllipse(in: CGRect(x: peak.x - innerR, y: peak.y - innerR, width: innerR * 2, height: innerR * 2))

        ctx.restoreGState()
    }
}
