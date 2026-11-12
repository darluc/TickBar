import SwiftUI

extension View {
    /// Canvas content is invisible to VoiceOver; describe each chart by its title and latest value.
    func chartAccessibility(_ label: String, value: String) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
    }
}

/// Canvas-drawn charts. Each draws in a single pass with no per-mark views, so redrawing
/// 241 minutes costs a fraction of a millisecond and nothing scales with interaction.
private struct ETFPlot {
    static let gutter: CGFloat = 32
    static let axis: CGFloat = 12
    static let top: CGFloat = 5

    let size: CGSize
    var width: CGFloat { max(size.width - Self.gutter, 1) }
    var height: CGFloat { max(size.height - Self.axis - Self.top, 1) }
    var slotWidth: CGFloat { width / CGFloat(ETFTime.slotCount) }

    /// Horizontal centre of a minute slot.
    func x(_ slot: Int) -> CGFloat { Self.gutter + slotWidth * (CGFloat(slot) + 0.5) }
    func y(_ fraction: Double) -> CGFloat { Self.top + height * CGFloat(1 - fraction) }
    func slot(atX x: CGFloat) -> Int {
        min(max(Int(((x - Self.gutter) / slotWidth).rounded(.down)), 0), ETFTime.lastSlot)
    }

    /// Time labels, vertical grid lines, and three horizontal guides with value labels.
    func drawAxes(_ context: inout GraphicsContext, low: Double, high: Double, format: (Double) -> String) {
        let grid = Color.secondary.opacity(0.14)
        var lines = Path()
        for (slot, label) in ETFTime.axis {
            let x = self.x(slot)
            lines.move(to: CGPoint(x: x, y: Self.top))
            lines.addLine(to: CGPoint(x: x, y: Self.top + height))
            let anchor: UnitPoint = slot == 0 ? .topLeading : (slot == ETFTime.lastSlot ? .topTrailing : .top)
            let at = CGPoint(x: slot == 0 ? Self.gutter : (slot == ETFTime.lastSlot ? size.width : x), y: Self.top + height + 1)
            context.draw(context.resolve(Text(label).font(.system(size: 8)).foregroundColor(.secondary)), at: at, anchor: anchor)
        }
        for fraction in [0.0, 0.5, 1.0] {
            let y = self.y(fraction)
            lines.move(to: CGPoint(x: Self.gutter, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
            let label = context.resolve(Text(format(low + (high - low) * fraction)).font(.system(size: 8)).foregroundColor(.secondary))
            context.draw(label, at: CGPoint(x: Self.gutter - 4, y: y), anchor: .trailing)
        }
        context.stroke(lines, with: .color(grid), lineWidth: 0.5)
    }
}

/// One bar per minute slot.
struct ETFBarChart: View, Equatable {
    let values: [Double]
    let color: Color
    let format: (Double) -> String

    static func == (a: Self, b: Self) -> Bool { a.values == b.values && a.color == b.color }

    var body: some View {
        Canvas { context, size in
            let plot = ETFPlot(size: size)
            let peak = max(values.max() ?? 0, 1)
            plot.drawAxes(&context, low: 0, high: peak, format: format)
            var bars = Path()
            for (slot, value) in values.enumerated() where value > 0 {
                let top = plot.y(value / peak)
                bars.addRect(CGRect(x: plot.x(slot) - plot.slotWidth / 2, y: top,
                                    width: max(plot.slotWidth - 0.6, 0.8), height: plot.y(0) - top))
            }
            context.fill(bars, with: .color(color))
        }
    }
}

struct ETFSeries: Equatable {
    let slots: [Int]
    let values: [Double?]
    let color: Color
    var dashed = false

    /// Value `i` sits at minute slot `i`.
    static func minutes(_ values: [Double?], color: Color) -> ETFSeries {
        ETFSeries(slots: Array(0..<values.count), values: values, color: color)
    }
    static func curve(_ curve: ETFCurve, color: Color, dashed: Bool = false) -> ETFSeries {
        ETFSeries(slots: curve.slots, values: curve.values, color: color, dashed: dashed)
    }
}

/// Lines over the shared session axis. `fit` scales to the data range instead of from zero.
struct ETFLineChart: View, Equatable {
    let series: [ETFSeries]
    let fit: Bool
    let format: (Double) -> String

    static func == (a: Self, b: Self) -> Bool { a.series == b.series && a.fit == b.fit }

    var body: some View {
        Canvas { context, size in
            let plot = ETFPlot(size: size)
            let all = series.flatMap(\.values).compactMap { $0 }
            var low = fit ? (all.min() ?? 0) : 0
            var high = all.max() ?? 1
            if high - low < 1e-9 { high = low + 1 }
            if fit { let pad = (high - low) * 0.08; low -= pad; high += pad }
            plot.drawAxes(&context, low: low, high: high, format: format)
            for line in series {
                var path = Path()
                var open = false
                for (slot, value) in zip(line.slots, line.values) {
                    guard let value else { open = false; continue }
                    let point = CGPoint(x: plot.x(slot), y: plot.y((value - low) / (high - low)))
                    if open { path.addLine(to: point) } else { path.move(to: point); open = true }
                }
                context.stroke(path, with: .color(line.color),
                               style: StrokeStyle(lineWidth: line.dashed ? 1.3 : 1.5, lineCap: .round, lineJoin: .round,
                                                  dash: line.dashed ? [4, 3] : []))
            }
        }
    }
}

/// Minute bars with a drag-to-sum selection. The selection is state of this view alone, so a drag
/// redraws only the highlight and the readout; the bars are skipped through `Equatable`.
struct ETFMinuteChart: View, Equatable {
    let bars: [Double]
    let cumulative: [Double]

    @State private var selection: ClosedRange<Int>?

    static func == (a: Self, b: Self) -> Bool { a.bars == b.bars }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    ETFBarChart(values: bars, color: SemanticColors.pulseBrandBlue) { String(format: "%.1f", $0 / 1e8) }
                        .equatable()
                        .chartAccessibility(L("etf.section.minutes", comment: "分钟成交额"),
                                            value: String(format: "%.2f %@", (cumulative.last ?? 0) / 1e8, L("etf.unit", comment: "亿元")))
                    if let selection {
                        Canvas { context, size in
                            let plot = ETFPlot(size: size)
                            let left = plot.x(selection.lowerBound) - plot.slotWidth / 2
                            let right = plot.x(selection.upperBound) + plot.slotWidth / 2
                            context.fill(Path(CGRect(x: left, y: ETFPlot.top, width: right - left, height: plot.height)),
                                         with: .color(SemanticColors.pulseBrandBlue.opacity(0.16)))
                        }
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    let plot = ETFPlot(size: geo.size)
                    let a = plot.slot(atX: value.startLocation.x), b = plot.slot(atX: value.location.x)
                    let range = min(a, b)...max(a, b)
                    if range != selection { selection = range }
                })
                .onTapGesture { selection = nil }
            }
            .frame(height: 125)
            Text(readout).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var readout: String {
        guard let selection else { return L("etf.selection.hint", comment: "拖选查看区间成交额") }
        let last = cumulative.count - 1
        guard last >= 0, selection.lowerBound <= last else {
            return String(format: L("etf.selection", comment: "选区成交额 %@ 亿 · %@–%@"), "0.00",
                          ETFTime.label(slot: selection.lowerBound), ETFTime.label(slot: selection.upperBound))
        }
        let upper = min(selection.upperBound, last)
        let amount = cumulative[upper] - (selection.lowerBound > 0 ? cumulative[selection.lowerBound - 1] : 0)
        return String(format: L("etf.selection", comment: "选区成交额 %@ 亿 · %@–%@"), String(format: "%.2f", amount / 1e8),
                      ETFTime.label(slot: selection.lowerBound), ETFTime.label(slot: selection.upperBound))
    }
}
