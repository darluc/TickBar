import SwiftUI

struct ETFPanel: View, Equatable {
    @ObservedObject var board: ETFBoard
    @EnvironmentObject var prefs: TickerPreferences

    /// The parent re-renders on every status flip; the panel only cares about its own data.
    static func == (a: Self, b: Self) -> Bool { a.board === b.board }

    var body: some View {
        let display = board.display
        VStack(spacing: 0) {
            ETFHeader(day: display.day, covered: display.quoteCount)
            ScrollView {
                ETFContent(display: display, scheme: prefs.colorScheme).padding(12)
            }
        }
    }
}

private struct ETFHeader: View {
    @EnvironmentObject var monitor: ETFMonitor
    let day: String
    let covered: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("etf.title", comment: "宽基 ETF 资金监控")).font(.system(size: 16, weight: .semibold))
                if !day.isEmpty {
                    Text("\(day) · \(covered)/\(ETFDescriptor.basket.count)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 2)
            Button(action: monitor.togglePause) {
                Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(monitor.paused ? L("etf.resume", comment: "恢复自动刷新") : L("etf.pause", comment: "暂停自动刷新"))
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct ETFContent: View {
    let display: ETFDisplay
    let scheme: TickerColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if display.isEmpty {
                Text(L("etf.empty", comment: "暂无数据，联网后自动加载"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                cards
                if display.quoteCount < ETFDescriptor.basket.count || display.minuteCount < ETFDescriptor.basket.count {
                    Text(String(format: L("etf.partial", comment: "数据不完整：行情 %d/20，分时 %d/20"),
                                display.quoteCount, display.minuteCount))
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                heading(L("etf.section.minutes", comment: "分钟成交额"))
                if display.bars.isEmpty { empty } else {
                    ETFMinuteChart(bars: display.bars, cumulative: display.cumulative).equatable()
                }
                if !display.index.isEmpty {
                    heading(L("etf.section.index", comment: "上证综指"))
                    ETFLineChart(series: [.minutes(display.index, color: SemanticColors.pulseBrandCyan)], fit: true) {
                        String(format: "%.0f", $0)
                    }
                    .equatable().frame(height: 75)
                    .chartAccessibility(L("etf.section.index", comment: "上证综指"),
                                        value: String(format: "%.2f", display.index.last.flatMap { $0 } ?? 0))
                }
                heading(L("etf.section.cumulative", comment: "累计成交额"))
                cumulative
                heading(L("etf.section.ranking", comment: "成交额排名"))
                ranking
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }
    private var empty: some View {
        Text(L("etf.empty", comment: "暂无数据，联网后自动加载"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 70)
    }

    // MARK: Cards

    private var cards: some View {
        HStack(spacing: 8) {
            let complete = display.quoteCount == ETFDescriptor.basket.count
            card(complete ? L("etf.card.turnover", comment: "篮子成交额") : L("etf.card.covered", comment: "已覆盖标的成交额"),
                 display.quoteCount == 0 ? "—" : String(format: "%.2f", display.total / 1e8),
                 unit: L("etf.unit", comment: "亿元"), caption: display.day)
            paceCard
        }
    }

    private var paceCard: some View {
        let reference = display.paceAverage != nil
        let main = reference ? display.paceAverage : display.pacePrevious
        let title = reference
            ? String(format: L("etf.card.paceAverage", comment: "较 %d 日均值"), display.averageDays)
            : L("etf.card.pacePrevious", comment: "较前一交易日")
        let caption = reference && display.pacePrevious != nil
            ? String(format: L("etf.card.paceCaption", comment: "同时刻 · 较 %@ %@"), String(display.previousDay.dropFirst(5)), Self.percent(display.pacePrevious))
            : L("etf.card.paceHint", comment: "同时刻累计成交额")
        return card(title, Self.percent(main), unit: "", caption: caption)
    }

    private static func percent(_ ratio: Double?) -> String {
        ratio.map { String(format: "%+.1f%%", $0 * 100) } ?? "—"
    }

    private func card(_ title: String, _ value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            (Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                + Text(unit.isEmpty ? "" : " \(unit)").font(.system(size: 11)).foregroundColor(.secondary))
                .monospacedDigit()
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Cumulative

    private var cumulative: some View {
        var series: [ETFSeries] = []
        if let average = display.average { series.append(.curve(average, color: .gray, dashed: true)) }
        if let previous = display.previous { series.append(.curve(previous, color: .orange)) }
        series.append(.minutes(display.cumulative, color: SemanticColors.pulseBrandBlue))
        return VStack(alignment: .leading, spacing: 6) {
            ETFLineChart(series: series, fit: false) { String(format: "%.0f", $0 / 1e8) }
                .equatable().frame(height: 155)
                .chartAccessibility(L("etf.section.cumulative", comment: "累计成交额"),
                                    value: String(format: "%.2f %@", (display.cumulative.last ?? 0) / 1e8, L("etf.unit", comment: "亿元")))
            HStack(spacing: 10) {
                legend(L("etf.legend.today", comment: "今日"), SemanticColors.pulseBrandBlue)
                if display.previous != nil { legend(String(display.previousDay.dropFirst(5)), .orange) }
                if display.average != nil {
                    legend(String(format: L("etf.legend.average", comment: "%d 日均值"), display.averageDays), .gray)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: Ranking

    private var ranking: some View {
        VStack(spacing: 3) {
            HStack {
                Text(L("etf.col.etf", comment: "ETF")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("etf.col.amount", comment: "成交额")).frame(width: 68, alignment: .trailing)
                Text(L("etf.col.share", comment: "占比")).frame(width: 50, alignment: .trailing)
                Text(L("etf.col.change", comment: "涨跌幅")).frame(width: 56, alignment: .trailing)
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(display.rows) { row in
                ETFRankingRow(row: row, scheme: scheme).equatable()
            }
        }
    }
}

private struct ETFRankingRow: View, Equatable {
    let row: ETFDisplay.Row
    let scheme: TickerColorScheme

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(row.code).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(row.amountText).frame(width: 68, alignment: .trailing)
            Text(row.shareText).frame(width: 50, alignment: .trailing)
            Text(row.changeText)
                .foregroundStyle(SemanticColors.directional(row.change, scheme: scheme))
                .frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced)).monospacedDigit().padding(.vertical, 5).padding(.horizontal, 4)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(SemanticColors.pulseBrandBlue.opacity(0.07))
                .scaleEffect(x: max(row.fraction, 0.001), anchor: .leading)
        }
    }
}
