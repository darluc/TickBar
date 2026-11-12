import SwiftUI

enum StockVolumeChartMode: String, CaseIterable {
    case classified = "volume.classified"
    case total = "volume.totalChart"
    case net = "volume.netChart"

    var title: String { L(rawValue) }
}

struct StockVolumePanel: View {
    @ObservedObject var monitor: StockVolumeMonitor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @State private var chartMode: StockVolumeChartMode
    @State private var texture = false
    @State private var selectedSlot: Int?

    init(monitor: StockVolumeMonitor, chartMode: StockVolumeChartMode = .classified) {
        self.monitor = monitor
        _chartMode = State(initialValue: chartMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let display = monitor.display {
                        content(display)
                    } else if monitor.refreshing {
                        ProgressView(L("volume.loading")).frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        Label(monitor.error ?? L("volume.noTrades"), systemImage: "exclamationmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                    Text(L("volume.method")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.name).font(.system(size: 20, weight: .semibold))
                Text("\(monitor.symbol.code) · \(L("volume.title"))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.togglePause() } label: {
                Label(L(monitor.paused ? "volume.resume" : "volume.pause"),
                      systemImage: monitor.paused ? "play" : "pause")
            }
            Button { monitor.refreshNow() } label: {
                Label(L("volume.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(monitor.refreshing)
        }
    }

    @ViewBuilder
    private func content(_ display: StockVolumeDisplay) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("volume.total")).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(Self.hands(display.total)).font(.system(size: 26, weight: .semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(display.day) · \(L("volume.through")) \(ETFTime.label(slot: display.throughSlot))")
                Text(String(format: L("volume.coverage"), display.coverage * 100))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if display.inconsistentMinutes > 0 {
            Label(L("volume.gaps"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L("volume.chart"), selection: $chartMode) {
                    ForEach(StockVolumeChartMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 380)
                Spacer()
                Toggle(L("volume.texture"), isOn: $texture).toggleStyle(.checkbox).font(.system(size: 11))
            }
            HStack(spacing: 18) {
                if chartMode == .classified {
                    ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                        legend(band.title, index: band.rawValue)
                    }
                    legend(L("volume.unknown"), index: 3)
                } else if chartMode == .net {
                    legend(L("volume.netBuy"), index: 0)
                    legend(L("volume.netSell"), index: 4)
                    legend(L("volume.netMissing"), index: 3)
                } else {
                    Text(L("volume.unitHands")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack {
                    StockVolumeChart(minutes: display.minutes, mode: chartMode, dark: scheme == .dark,
                                     texture: texture || differentiate).equatable()
                    if let selectedSlot {
                        Canvas { context, size in
                            let x = StockVolumeChart.x(selectedSlot, width: size.width)
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: 4))
                            line.addLine(to: CGPoint(x: x, y: size.height - 22))
                            context.stroke(line, with: .color(.primary.opacity(0.45)), lineWidth: 1)
                        }.allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        selectedSlot = StockVolumeChart.slot(at: point.x, width: geo.size.width)
                    case .ended: selectedSlot = nil
                    }
                }
            }
            .frame(height: 190)
            .chartAccessibility(chartMode.title, value: chartMode == .net
                                ? (display.minutes.contains { $0.netAmount != nil }
                                   ? Self.amount(display.summaries.reduce(0) { $0 + $1.net }) + " " + L("volume.unitAmount")
                                   : L("volume.netMissing"))
                                : Self.hands(display.total))
            if chartMode == .net {
                Text(L("volume.netHint")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            readout(display)
        }
        .padding(12)
        .background(StockVolumeChart.surface(dark: scheme == .dark))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        summaryTable(display)
        DisclosureGroup(L(chartMode == .net ? "volume.netTable" : "volume.minuteTable")) {
            Group {
                if chartMode == .net {
                    Table(display.minutes) {
                        TableColumn(L("volume.time")) { Text(ETFTime.label(slot: $0.slot)) }.width(65)
                        TableColumn(L("volume.buy")) { Text($0.netAmount == nil ? "—" : Self.amount($0.buyAmount)) }
                        TableColumn(L("volume.sell")) { Text($0.netAmount == nil ? "—" : Self.amount($0.sellAmount)) }
                        TableColumn(L("volume.net")) { Text($0.netAmount.map(Self.amount) ?? "—") }
                    }
                } else {
                    Table(display.minutes) {
                        TableColumn(L("volume.time")) { Text(ETFTime.label(slot: $0.slot)) }.width(65)
                        TableColumn(L("volume.totalChart")) { Text(Self.number($0.total)) }
                        TableColumn(StockVolumeBand.large.title) { Text(Self.number($0.classified[0])) }
                        TableColumn(StockVolumeBand.medium.title) { Text(Self.number($0.classified[1])) }
                        TableColumn(StockVolumeBand.small.title) { Text(Self.number($0.classified[2])) }
                        TableColumn(L("volume.unknown")) { Text(Self.number($0.missing)) }
                    }
                }
            }
            .font(.system(size: 11)).monospacedDigit().frame(height: 200)
        }
        .font(.system(size: 11))
    }

    private func legend(_ title: String, index: Int) -> some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                StockVolumeChart.fill(&context, rect: CGRect(origin: .zero, size: size), index: index,
                                      dark: scheme == .dark, texture: texture || differentiate)
            }.frame(width: 12, height: 10).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
        }.font(.system(size: 10))
    }

    @ViewBuilder
    private func readout(_ display: StockVolumeDisplay) -> some View {
        if let slot = selectedSlot, let minute = display.minutes.first(where: { $0.slot == slot }) {
            if chartMode == .net {
                Text("\(ETFTime.label(slot: slot))  ·  \(L("volume.net")) \(minute.netAmount.map(Self.amount) ?? "—") \(L("volume.unitAmount"))")
                    .font(.system(size: 11)).monospacedDigit()
                if minute.netAmount != nil {
                    HStack(spacing: 14) {
                        Text("\(L("volume.buy")) \(Self.amount(minute.buyAmount))")
                        Text("\(L("volume.sell")) \(Self.amount(minute.sellAmount))")
                    }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(L("volume.netMissing")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("\(ETFTime.label(slot: slot))  ·  \(L("volume.totalChart")) \(Self.hands(minute.total))")
                    .font(.system(size: 11)).monospacedDigit()
                HStack(spacing: 14) {
                    ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                        Text("\(band.title) \(Self.number(minute.classified[band.rawValue]))")
                    }
                    Text("\(L("volume.unknown")) \(Self.number(minute.missing))")
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            Text(L("volume.hover")).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(height: 38, alignment: .topLeading)
        }
    }

    private func summaryTable(_ display: StockVolumeDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("volume.summary")).font(.system(size: 12, weight: .semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(L("volume.band")).gridColumnAlignment(.leading)
                    Text(L("volume.unitHands"))
                    Text(L("volume.buy"))
                    Text(L("volume.sell"))
                    Text(L("volume.neutral"))
                    Text(L("volume.net"))
                }.foregroundStyle(.secondary)
                ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                    let summary = display.summaries[band.rawValue]
                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            legend(band.title, index: band.rawValue)
                            Text(band.threshold).font(.system(size: 9)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.number(summary.hands))
                        Text(Self.amount(summary.buy))
                        Text(Self.amount(summary.sell))
                        Text(Self.amount(summary.neutral))
                        Text(Self.amount(summary.net))
                    }
                }
            }
            .font(.system(size: 11)).monospacedDigit()
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            if monitor.refreshing { ProgressView().controlSize(.small) }
            if let error = monitor.error, monitor.display != nil {
                Label("\(L("volume.keptPrevious")) \(error)", systemImage: "exclamationmark.triangle")
            } else if monitor.paused {
                Text(L("volume.paused"))
            } else if let display = monitor.display {
                Text(String(format: L("volume.sources"), display.detailSource.title, display.minuteSource.title)
                     + " · " + L("volume.source"))
            } else {
                Text(L("volume.source"))
            }
            Spacer()
            if let updated = monitor.updated {
                Text(updated, style: .time)
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func number(_ value: Double) -> String { String(format: "%.0f", value) }
    static func hands(_ value: Double) -> String { "\(number(value)) \(L("volume.hands"))" }
    static func amount(_ value: Double) -> String { String(format: "%.2f", value / 10_000) }
}

private struct StockVolumeChart: View, Equatable {
    let minutes: [StockVolumeMinute]
    let mode: StockVolumeChartMode
    let dark: Bool
    let texture: Bool
    private static let gutter: CGFloat = 48

    static func surface(dark: Bool) -> Color {
        dark ? Color(red: 26/255, green: 26/255, blue: 25/255) : Color(red: 252/255, green: 252/255, blue: 251/255)
    }

    private static func color(_ index: Int, dark: Bool) -> Color {
        let light = [(42.0, 120.0, 214.0), (235.0, 104.0, 52.0), (27.0, 175.0, 122.0), (160.0, 160.0, 160.0), (227.0, 73.0, 72.0)]
        let night = [(57.0, 135.0, 229.0), (217.0, 89.0, 38.0), (25.0, 158.0, 112.0), (140.0, 140.0, 140.0), (230.0, 103.0, 103.0)]
        let c = (dark ? night : light)[index]
        return Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
    }

    static func x(_ slot: Int, width: CGFloat) -> CGFloat {
        gutter + (width - gutter) * (CGFloat(slot) + 0.5) / CGFloat(ETFTime.slotCount)
    }
    static func slot(at x: CGFloat, width: CGFloat) -> Int {
        min(max(Int((x - gutter) / max(width - gutter, 1) * CGFloat(ETFTime.slotCount)), 0), ETFTime.lastSlot)
    }

    static func fill(_ context: inout GraphicsContext, rect: CGRect, index: Int, dark: Bool, texture: Bool) {
        context.fill(Path(rect), with: .color(color(index, dark: dark)))
        guard texture || index == 3 else { return }
        var hatch = context
        hatch.clip(to: Path(rect))
        var lines = Path()
        for offset in stride(from: -rect.height, through: rect.width + rect.height, by: 6) {
            let a = CGPoint(x: rect.minX + offset, y: rect.maxY)
            let b = CGPoint(x: a.x + (index == 1 || index == 4 ? -rect.height : rect.height), y: rect.minY)
            lines.move(to: a)
            lines.addLine(to: b)
        }
        hatch.stroke(lines, with: .color(surface(dark: dark).opacity(index == 2 ? 0.8 : 0.55)), lineWidth: index == 2 ? 2 : 1)
    }

    var body: some View {
        Canvas { context, size in
            let height = max(size.height - 26, 1)
            let netMode = mode == .net
            let peak = netMode ? max(minutes.compactMap(\.netAmount).map { abs($0) }.max() ?? 0, 10_000)
                               : max(minutes.map(\.total).max() ?? 0, 1)
            let width = max((size.width - Self.gutter) / CGFloat(ETFTime.slotCount) - 2, 0.5)
            for fraction in [0.0, 0.5, 1.0] {
                let y = 4 + height * (1 - fraction)
                var line = Path()
                line.move(to: CGPoint(x: Self.gutter, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                let zero = netMode && fraction == 0.5
                context.stroke(line, with: .color(.secondary.opacity(zero ? 0.55 : 0.16)), lineWidth: zero ? 1 : 0.5)
                let value = peak * (netMode ? fraction * 2 - 1 : fraction)
                let label = netMode ? (zero ? "0" : String(format: "%+.1f", value / 10_000))
                                    : (value >= 1000 ? String(format: "%.1fk", value / 1000) : String(format: "%.0f", value))
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.gutter - 5, y: y), anchor: .trailing)
            }
            for (slot, label) in ETFTime.axis {
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.x(slot, width: size.width), y: size.height - 10),
                             anchor: slot == 240 ? .trailing : (slot == 0 ? .leading : .center))
            }
            for minute in minutes {
                let x = Self.x(minute.slot, width: size.width) - width / 2
                if netMode {
                    let zeroY = 4 + height / 2
                    if let net = minute.netAmount {
                        let barHeight = CGFloat(abs(net) / peak) * height / 2
                        let rect = CGRect(x: x, y: net > 0 ? zeroY - barHeight : zeroY,
                                          width: width, height: barHeight)
                        Self.fill(&context, rect: rect, index: net >= 0 ? 0 : 4, dark: dark, texture: texture)
                    } else {
                        // A hatched marker means unknown, not a zero-valued bar.
                        Self.fill(&context, rect: CGRect(x: x, y: zeroY - 4, width: width, height: 8),
                                  index: 3, dark: dark, texture: true)
                    }
                } else {
                    let values = mode == .classified ? minute.classified + [minute.missing] : [minute.total]
                    var sum: Double = 0
                    for (index, value) in values.enumerated() where value > 0 {
                        let segmentHeight = CGFloat(value / peak) * height
                        let top = 4 + height * CGFloat(1 - (sum + value) / peak)
                        let rect = CGRect(x: x, y: top, width: width,
                                          height: max(segmentHeight - (mode == .classified ? 2 : 0), 0))
                        Self.fill(&context, rect: rect, index: index, dark: dark, texture: texture)
                        sum += value
                    }
                }
            }
        }
    }
}
