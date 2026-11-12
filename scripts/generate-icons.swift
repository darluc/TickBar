#!/usr/bin/env swift
//
// TickBar 图标生成器 — 绘制 PulseWaveform 极简电波 Logo,导出所有 macOS 需要的尺寸。
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

// MARK: 绘制心电电波路径

func createWaveformPath(in rect: CGRect) -> CGPath {
    let vbX: CGFloat = 134
    let vbY: CGFloat = 215
    let vbW: CGFloat = 756
    let vbH: CGFloat = 580

    let scaleX = rect.width / vbW
    let scaleY = rect.height / vbH

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(
            x: rect.minX + (x - vbX) * scaleX,
            y: rect.maxY - (y - vbY) * scaleY
        )
    }

    let path = CGMutablePath()
    path.move(to: pt(170, 512))
    path.addLine(to: pt(292, 512))
    path.addCurve(to: pt(348, 476), control1: pt(316, 512), control2: pt(328, 476))
    path.addCurve(to: pt(405, 537), control1: pt(371, 476), control2: pt(383, 537))
    path.addCurve(to: pt(493, 278), control1: pt(425, 537), control2: pt(444, 423))
    path.addCurve(to: pt(529, 280), control1: pt(502, 251), control2: pt(520, 251))
    path.addLine(to: pt(627, 728))
    path.addCurve(to: pt(666, 730), control1: pt(634, 759), control2: pt(654, 759))
    path.addLine(to: pt(738, 520))
    path.addCurve(to: pt(774, 498), control1: pt(744, 503), control2: pt(756, 498))
    path.addLine(to: pt(854, 498))

    return path
}

// MARK: 绘制单个图标

/// 渲染一张 size×size 的 TickBar AppIcon。
func renderIcon(size: Int) -> Data? {
    let dim = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
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

    // ====== macOS 标准 Squircle 比例 ======
    let inset = dim * 0.11
    let iconRect = CGRect(x: inset, y: inset, width: dim - 2 * inset, height: dim - 2 * inset)
    let cornerRadius = iconRect.width * 0.224

    let squirclePath = CGPath(
        roundedRect: iconRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // ====== 底部微弱外阴影 (仅大尺寸绘制增强质感) ======
    if size >= 64 {
        ctx.saveGState()
        let shadowBlur = dim * 0.035
        let shadowOffset = CGSize(width: 0, height: -dim * 0.02)
        let shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
        ctx.addPath(squirclePath)
        ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // ====== 背景裁切与暗夜金融科技深色渐变 ======
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // 渐变背景: 从顶部的深蓝石墨黑到沉稳纯黑
    let bgColors = [
        CGColor(red: 0.110, green: 0.125, blue: 0.165, alpha: 1.0), // 顶部 #1C202A
        CGColor(red: 0.045, green: 0.050, blue: 0.070, alpha: 1.0)  // 底部 #0B0D12
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 1.0]
    if let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.midX, y: iconRect.minY),
            options: []
        )
    }

    // ====== 顶部微高光 (增添拟物玻璃立体感) ======
    if size >= 32 {
        let rimRect = CGRect(x: iconRect.minX, y: iconRect.midY, width: iconRect.width, height: iconRect.height / 2)
        let rimColors = [
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.10),
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.00)
        ] as CFArray
        if let rimGrad = CGGradient(colorsSpace: cs, colors: rimColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                rimGrad,
                start: CGPoint(x: iconRect.midX, y: rimRect.maxY),
                end: CGPoint(x: iconRect.midX, y: rimRect.minY),
                options: []
            )
        }
    }

    // ====== 内部边框 (Subtle Inner Border) ======
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08))
    ctx.setLineWidth(max(1.0, dim * 0.008))
    ctx.strokePath()

    // ====== 绘制 PulseWaveform 电波图形 ======
    let waveWidth = iconRect.width * 0.70
    let waveHeight = waveWidth * (580.0 / 756.0)
    let waveRect = CGRect(
        x: iconRect.midX - waveWidth / 2,
        y: iconRect.midY - waveHeight / 2,
        width: waveWidth,
        height: waveHeight
    )

    let wavePath = createWaveformPath(in: waveRect)
    let lineWidth = max(2.0, iconRect.width * 0.068)

    // 1. 电波外发光 (Glow)
    if size >= 64 {
        ctx.saveGState()
        let glowColor = CGColor(red: 0.0, green: 0.65, blue: 1.0, alpha: 0.40)
        ctx.setShadow(offset: .zero, blur: lineWidth * 1.1, color: glowColor)
        ctx.addPath(wavePath)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.60, blue: 1.0, alpha: 0.85))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 2. 亮蓝到青色渐变的主线条
    ctx.saveGState()
    ctx.addPath(wavePath)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()

    let waveColors = [
        CGColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1.0), // PulseBrandBlue #007AFF
        CGColor(red: 0.12, green: 0.80, blue: 0.95, alpha: 1.0)  // PulseBrandCyan #1FCBF2
    ] as CFArray
    let waveLocations: [CGFloat] = [0.0, 1.0]
    if let waveGradient = CGGradient(colorsSpace: cs, colors: waveColors, locations: waveLocations) {
        ctx.drawLinearGradient(
            waveGradient,
            start: CGPoint(x: waveRect.minX, y: waveRect.midY),
            end: CGPoint(x: waveRect.maxX, y: waveRect.midY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState() // 还原背景裁剪

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

// MARK: 执行生成

print("🎨 生成 TickBar PulseWaveform 矢量应用图标...")

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
        print("  ✓ icon_\(s).png (\(s)×\(s), \(pngData.count / 1024) KB)")
    } catch {
        print("❌ 写入 \(fileURL.lastPathComponent) 失败: \(error)")
    }
}

print("✅ 所有应用图标已更新完成")
