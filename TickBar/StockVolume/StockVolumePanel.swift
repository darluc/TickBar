import AppKit
import SwiftUI

enum StockVolumeChartMode: String, CaseIterable {
    case classified = "volume.classified"
    case net = "volume.netChart"

    var title: String { L(rawValue) }
}

struct StockVolumePanel: View {
    @ObservedObject var monitor: StockVolumeMonitor
    @StateObject private var holdings: StockHoldingsMonitor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @State private var chartMode: StockVolumeChartMode
    @State private var texture = false
    @State private var selectedSlot: Int?
    private let hasTransparentTitlebar: Bool

    init(monitor: StockVolumeMonitor, chartMode: StockVolumeChartMode = .classified,
         holdings: StockHoldingsMonitor? = nil, hasTransparentTitlebar: Bool = false) {
        self.monitor = monitor
        _chartMode = State(initialValue: chartMode)
        _holdings = StateObject(wrappedValue: holdings
                                ?? StockHoldingsMonitor(code: monitor.symbol.code, name: monitor.name))
        self.hasTransparentTitlebar = hasTransparentTitlebar
    }

    var body: some View {
        ZStack {
            StockVolumeGlassBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.35)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let display = monitor.display {
                            content(display)
                        } else if monitor.refreshing {
                            ProgressView(L("volume.loading"))
                                .controlSize(.small)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            Label(monitor.error ?? L("volume.noTrades"), systemImage: "exclamationmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        }
                        Text(L("volume.method"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        StockHoldingsSection(monitor: holdings)
                    }
                    .padding(12)
                }
                Divider().opacity(0.35)
                footer
            }
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    // MARK: - Popover-Consistent Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                MarketBadge(market: monitor.symbol.market)
                Text(monitor.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(monitor.symbol.code)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("· \(L("stockAnalysis.title"))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                toolButton(
                    systemName: monitor.paused ? "play.fill" : "pause",
                    active: monitor.paused,
                    help: L(monitor.paused ? "volume.resume" : "volume.pause")
                ) {
                    monitor.togglePause()
                }
                toolButton(
                    systemName: "arrow.clockwise",
                    active: false,
                    help: L("volume.refresh"),
                    disabled: monitor.refreshing
                ) {
                    monitor.refreshNow()
                }
            }
        }
        .padding(.leading, hasTransparentTitlebar ? 76 : 12)
        .padding(.trailing, 12)
        .padding(.top, hasTransparentTitlebar ? 10 : 9)
        .padding(.bottom, 8)
    }

    private func toolButton(
        systemName: String,
        active: Bool,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? SemanticColors.pulseBrandBlue : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ display: StockVolumeDisplay) -> some View {
        kpiCards(display)

        if display.inconsistentMinutes > 0 {
            Label(L("volume.gaps"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }

        chartCard(display)
        summaryTable(display)
    }

    private func kpiCards(_ display: StockVolumeDisplay) -> some View {
        HStack(spacing: 8) {
            metricCard(
                title: L("volume.total"),
                value: Self.number(display.total),
                unit: L("volume.hands"),
                caption: "\(display.day) · \(L("volume.through")) \(ETFTime.label(slot: display.throughSlot))"
            )
            metricCard(
                title: L("volume.quality"),
                value: String(format: "%.0f%%", display.coverage * 100),
                unit: "",
                caption: display.partialMinutes + display.estimatedMinutes > 0
                    ? String(format: L("volume.qualityNote"), display.partialMinutes, display.estimatedMinutes)
                    : String(format: L("volume.coverage"), display.coverage * 100)
            )
        }
    }

    private func metricCard(title: String, value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            (Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                + Text(unit.isEmpty ? "" : " \(unit)").font(.system(size: 11)).foregroundColor(.secondary))
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func chartCard(_ display: StockVolumeDisplay) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Picker(L("volume.chart"), selection: $chartMode) {
                    ForEach(StockVolumeChartMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle(L("volume.texture"), isOn: $texture)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                    legend(band.title, index: band.rawValue)
                }
                legend(L(chartMode == .net ? "volume.netMissing" : "volume.unknown"), index: 3)
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
                            line.addLine(to: CGPoint(x: x, y: size.height - 20))
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
            .frame(height: 185)
            .chartAccessibility(chartMode.title, value: chartMode == .net
                                ? (display.minutes.contains { $0.netAmount != nil }
                                   ? StockVolumeBand.allCases.map { band in
                                       "\(band.title) \(Self.amount(display.summaries[band.rawValue].net))"
                                   }.joined(separator: " · ") + " " + L("volume.unitAmount")
                                   : L("volume.netMissing"))
                                : Self.hands(display.total))
            if chartMode == .net {
                Text(L("volume.netHint"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            readout(display)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func legend(_ title: String, index: Int) -> some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                StockVolumeChart.fill(&context, rect: CGRect(origin: .zero, size: size), index: index,
                                      dark: scheme == .dark, texture: texture || differentiate)
            }
            .frame(width: 11, height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
        }
        .font(.system(size: 9.5))
    }

    @ViewBuilder
    private func readout(_ display: StockVolumeDisplay) -> some View {
        if let slot = selectedSlot, let minute = display.minutes.first(where: { $0.slot == slot }) {
            VStack(alignment: .leading, spacing: 3) {
                if chartMode == .net {
                    Text("\(ETFTime.label(slot: slot))  ·  \(L("volume.net")) \(minute.netAmount.map(Self.amount) ?? "—") \(L("volume.unitAmount"))  ·  \(minute.quality.title)")
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    if let nets = minute.netAmounts {
                        HStack(spacing: 12) {
                            ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                                Text("\(band.title) \(Self.amount(nets[band.rawValue]))")
                            }
                        }
                        .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(L("volume.netMissing")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(ETFTime.label(slot: slot))  ·  \(L("volume.totalChart")) \(Self.hands(minute.total))  ·  \(minute.quality.title)")
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    HStack(spacing: 12) {
                        ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                            Text("\(band.title) \(Self.number(minute.classified[band.rawValue]))")
                        }
                        Text("\(L("volume.unknown")) \(Self.number(minute.missing))")
                    }
                    .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 30, alignment: .topLeading)
        } else {
            Text(L("volume.hover"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(minHeight: 30, alignment: .topLeading)
        }
    }

    private func summaryTable(_ display: StockVolumeDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("volume.summary")).font(.system(size: 12, weight: .semibold))
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L("volume.band")).gridColumnAlignment(.leading)
                    Text(L("volume.unitHands"))
                    Text(L("volume.buy"))
                    Text(L("volume.sell"))
                    Text(L("volume.neutral"))
                    Text(L("volume.net"))
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)

                ForEach(StockVolumeBand.allCases, id: \.rawValue) { band in
                    let summary = display.summaries[band.rawValue]
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            legend(band.title, index: band.rawValue)
                            Text(band.threshold)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.number(summary.hands))
                        Text(Self.amount(summary.buy))
                        Text(Self.amount(summary.sell))
                        Text(Self.amount(summary.neutral))
                        Text(Self.amount(summary.net))
                    }
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .monospacedDigit()
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Popover-Consistent Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(footerStatusColor)
                .frame(width: 5, height: 5)

            Text(footerStatusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(footerStatusText)

            Spacer()

            if monitor.refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else if let updated = monitor.updated {
                Text(Self.timeFormatter.string(from: updated))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footerStatusColor: Color {
        if monitor.error != nil { return .orange }
        if monitor.paused { return .secondary }
        return Color(red: 0.04, green: 0.66, blue: 0.35)
    }

    private var footerStatusText: String {
        if let error = monitor.error, monitor.display != nil {
            return "\(L("volume.keptPrevious")) \(error)"
        }
        if monitor.paused {
            return L("volume.paused")
        }
        if let display = monitor.display {
            return String(format: L("volume.sources"), display.detailSource.title, display.minuteSource.title)
                + " · " + L("volume.source")
        }
        return L("volume.source")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func number(_ value: Double) -> String { String(format: "%.0f", value) }
    static func hands(_ value: Double) -> String { "\(number(value)) \(L("volume.hands"))" }
    static func amount(_ value: Double) -> String { String(format: "%.2f", value / 10_000) }
}

private struct StockVolumeGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct StockVolumeChart: View, Equatable {
    let minutes: [StockVolumeMinute]
    let mode: StockVolumeChartMode
    let dark: Bool
    let texture: Bool
    private static let gutter: CGFloat = 46

    static func surface(dark: Bool) -> Color {
        dark ? Color(red: 28/255, green: 30/255, blue: 34/255) : Color(red: 248/255, green: 249/255, blue: 251/255)
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
            let height = max(size.height - 24, 1)
            let netMode = mode == .net
            let peak = netMode ? max(minutes.map(\.netExtent).max() ?? 0, 10_000)
                               : max(minutes.map(\.total).max() ?? 0, 1)
            let width = max((size.width - Self.gutter) / CGFloat(ETFTime.slotCount) - 2, 0.5)
            for fraction in [0.0, 0.5, 1.0] {
                let y = 4 + height * (1 - fraction)
                var line = Path()
                line.move(to: CGPoint(x: Self.gutter, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                let zero = netMode && fraction == 0.5
                context.stroke(line, with: .color(.secondary.opacity(zero ? 0.45 : 0.14)), lineWidth: zero ? 1 : 0.5)
                let value = peak * (netMode ? fraction * 2 - 1 : fraction)
                let label = netMode ? (zero ? "0" : String(format: "%+.1f", value / 10_000))
                                    : (value >= 1000 ? String(format: "%.1fk", value / 1000) : String(format: "%.0f", value))
                context.draw(Text(label).font(.system(size: 8.5, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.gutter - 5, y: y), anchor: .trailing)
            }
            for (slot, label) in ETFTime.axis {
                context.draw(Text(label).font(.system(size: 8.5, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.x(slot, width: size.width), y: size.height - 8),
                             anchor: slot == 240 ? .trailing : (slot == 0 ? .leading : .center))
            }
            for minute in minutes {
                let x = Self.x(minute.slot, width: size.width) - width / 2
                if netMode {
                    let zeroY = 4 + height / 2
                    if let nets = minute.netAmounts {
                        var positive: Double = 0
                        var negative: Double = 0
                        for (index, net) in nets.enumerated() where net != 0 {
                            let offset = net > 0 ? positive : negative
                            let barHeight = CGFloat(abs(net) / peak) * height / 2
                            let y = net > 0 ? zeroY - CGFloat((offset + net) / peak) * height / 2
                                            : zeroY + CGFloat(offset / peak) * height / 2
                            let rect = CGRect(x: x, y: y, width: width, height: max(barHeight - 2, 0))
                            Self.fill(&context, rect: rect, index: index, dark: dark, texture: texture)
                            if net > 0 { positive += net } else { negative -= net }
                        }
                    } else {
                        // A hatched marker means unknown, not a zero-valued bar.
                        Self.fill(&context, rect: CGRect(x: x, y: zeroY - 4, width: width, height: 8),
                                  index: 3, dark: dark, texture: true)
                    }
                } else {
                    let values = minute.classified + [minute.missing]
                    var sum: Double = 0
                    for (index, value) in values.enumerated() where value > 0 {
                        let segmentHeight = CGFloat(value / peak) * height
                        let top = 4 + height * CGFloat(1 - (sum + value) / peak)
                        let rect = CGRect(x: x, y: top, width: width,
                                          height: max(segmentHeight - 2, 0))
                        Self.fill(&context, rect: rect, index: index, dark: dark, texture: texture)
                        sum += value
                    }
                }
            }
        }
    }
}
