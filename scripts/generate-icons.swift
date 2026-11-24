#!/usr/bin/env swift
//
// TickBar 图标生成器 — 极简扁平航天遥测风格（低饱和度股市红绿配色），导出所有 macOS 所需尺寸。
//
// 运行:  swift scripts/generate-icons.swift
// 输出:  TickBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png
//

import AppKit
import CoreGraphics

// MARK: 配置

/// macOS AppIcon 需要的所有像素尺寸。
let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]

/// 输出目录(相对项目根)。
let outDir = "TickBar/Resources/Assets.xcassets/AppIcon.appiconset"

let cs = CGColorSpaceCreateDeviceRGB()

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255.0, g / 255.0, b / 255.0, a])!
}

// MARK: 调色板 (SpaceX 克制暗底 + 低饱和度股市绿/红，纯扁平无反光)

enum Palette {
    static let spaceDark   = rgba(20, 25, 34)    // #141922 哑光深空灰蓝
    static let mutedGreen  = rgba(55, 139, 110)  // #378B6E 低饱和度股市绿
    static let mutedRed    = rgba(196, 83, 87)   // #C45357 低饱和度股市红
    static let pureWhite   = rgba(246, 248, 251) // #F6F8FB 洁净遥测白
}

// MARK: 几何路径

/// macOS Big Sur+ 风格连续圆角超椭圆 (Continuous Squircle)。
func macSquirclePath(in rect: CGRect) -> CGPath {
    let w = rect.width
    let h = rect.height
    let x = rect.minX
    let y = rect.minY
    let r = min(w, h) * 0.2237
    let c = r * 1.28195

    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + c, y: y + h))
    p.addLine(to: CGPoint(x: x + w - c, y: y + h))
    p.addCurve(
        to: CGPoint(x: x + w, y: y + h - c),
        control1: CGPoint(x: x + w - r * 0.45, y: y + h),
        control2: CGPoint(x: x + w, y: y + h - r * 0.45)
    )
    p.addLine(to: CGPoint(x: x + w, y: y + c))
    p.addCurve(
        to: CGPoint(x: x + w - c, y: y),
        control1: CGPoint(x: x + w, y: y + r * 0.45),
        control2: CGPoint(x: x + w - r * 0.45, y: y)
    )
    p.addLine(to: CGPoint(x: x + c, y: y))
    p.addCurve(
        to: CGPoint(x: x, y: y + c),
        control1: CGPoint(x: x + r * 0.45, y: y),
        control2: CGPoint(x: x, y: y + r * 0.45)
    )
    p.addLine(to: CGPoint(x: x, y: y + h - c))
    p.addCurve(
        to: CGPoint(x: x + c, y: y + h),
        control1: CGPoint(x: x, y: y + h - r * 0.45),
        control2: CGPoint(x: x + r * 0.45, y: y + h)
    )
    p.closeSubpath()
    return p
}

/// 生成圆角折线路径（顶点 index 3 由峰值圆点覆盖，保持直线相交以保证同心对称）。
func trendPath(
    _ points: [CGPoint],
    radius: CGFloat,
    closedBottom: (rightX: CGFloat, leftX: CGFloat, bottomY: CGFloat)? = nil
) -> CGPath {
    let path = CGMutablePath()
    path.move(to: points[0])
    path.addArc(tangent1End: points[1], tangent2End: points[2], radius: radius)
    path.addArc(tangent1End: points[2], tangent2End: points[3], radius: radius)
    path.addLine(to: points[3])
    path.addLine(to: points[4])

    if let b = closedBottom {
        path.addLine(to: CGPoint(x: b.rightX, y: b.bottomY))
        path.addLine(to: CGPoint(x: b.leftX, y: b.bottomY))
        path.closeSubpath()
    }
    return path
}

// MARK: 绘制单个图标

/// 渲染一张 size×size 的 TickBar AppIcon。
func renderIcon(size: Int) -> Data? {
    let dim = CGFloat(size)
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.clear(CGRect(x: 0, y: 0, width: dim, height: dim))

    // macOS HIG 标准 824/1024 视觉网格边距，纯扁平无反光无阴影
    let inset = dim * 0.098
    let iconRect = CGRect(x: inset, y: inset, width: dim - 2 * inset, height: dim - 2 * inset)
    let squircle = macSquirclePath(in: iconRect)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 1. 哑光深空底色
    ctx.setFillColor(Palette.spaceDark)
    ctx.fill(iconRect)

    func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
        CGPoint(x: iconRect.minX + nx * iconRect.width, y: iconRect.minY + ny * iconRect.height)
    }

    let cornerR = iconRect.width * 0.044
    let pts = [
        pt(-0.08, 0.34),
        pt(0.24, 0.44),
        pt(0.45, 0.31),
        pt(0.75, 0.72),
        pt(1.08, 0.59)
    ]

    // 2. 单层纯扁平低饱和度股市绿色域（去除反光与斜切分层）
    let bottomBox = (
        rightX: iconRect.maxX + iconRect.width * 0.08,
        leftX: iconRect.minX - iconRect.width * 0.08,
        bottomY: iconRect.minY - iconRect.height * 0.08
    )
    let area = trendPath(pts, radius: cornerR, closedBottom: bottomBox)
    ctx.addPath(area)
    ctx.setFillColor(Palette.mutedGreen)
    ctx.fillPath()

    // 3. 洁净白色行情折线
    let lineWidth = max(1.6, iconRect.width * (size <= 32 ? 0.076 : 0.062))
    let line = trendPath(pts, radius: cornerR)
    ctx.addPath(line)
    ctx.setStrokeColor(Palette.pureWhite)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // 4. 低饱和度股市红峰值信标点（白环 + 哑光红芯）
    let peak = pts[3]
    let outerR = max(2.1, iconRect.width * (size <= 32 ? 0.102 : 0.090))
    ctx.setFillColor(Palette.pureWhite)
    ctx.fillEllipse(in: CGRect(x: peak.x - outerR, y: peak.y - outerR, width: outerR * 2, height: outerR * 2))

    let innerR = outerR * 0.56
    ctx.setFillColor(Palette.mutedRed)
    ctx.fillEllipse(in: CGRect(x: peak.x - innerR, y: peak.y - innerR, width: innerR * 2, height: innerR * 2))

    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

// MARK: 执行生成

print("🎨 生成 TickBar 极简低饱和红绿遥测应用图标...")

let fm = FileManager.default
let outURL = URL(fileURLWithPath: outDir)
try? fm.createDirectory(at: outURL, withIntermediateDirectories: true)

for s in sizes {
    guard let pngData = renderIcon(size: s) else {
        print("❌ 尺寸 \(s) 渲染失败")
        continue
    }
    let fileURL = outURL.appendingPathComponent("icon_\(s).png")
    do {
        try pngData.write(to: fileURL)
        print("  ✓ icon_\(s).png (\(s)×\(s), \(max(1, pngData.count / 1024)) KB)")
    } catch {
        print("❌ 写入 \(fileURL.lastPathComponent) 失败: \(error)")
    }
}

print("✅ 所有应用图标已更新完成")
