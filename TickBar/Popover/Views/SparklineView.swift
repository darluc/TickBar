import SwiftUI

/// 走势图统一坐标映射，确保折线、渐变填充、昨收参考线、日分隔线与现价圆点共用同一坐标系。
struct SparklineLayout: Equatable {
    let points: [Double]
    let prevClose: Double
    let size: CGSize
    let minY: Double
    let maxY: Double
    let verticalPadding: CGFloat
    let rightPadding: CGFloat

    /// 最小半振幅比例（默认 ±0.5%，防止微幅横盘股被强行拉满全高）。
    static let defaultMinAmplitudeRatio: Double = 0.005

    init(
        points: [Double],
        prevClose: Double,
        size: CGSize,
        minAmplitudeRatio: Double = SparklineLayout.defaultMinAmplitudeRatio,
        verticalPadding: CGFloat = 3,
        rightPadding: CGFloat = 3
    ) {
        self.points = points
        self.prevClose = prevClose
        self.size = size
        self.verticalPadding = verticalPadding
        self.rightPadding = rightPadding

        var low = points.min() ?? (prevClose > 0 ? prevClose : 0)
        var high = points.max() ?? (prevClose > 0 ? prevClose : 1)
        if prevClose > 0 {
            low = min(low, prevClose)
            high = max(high, prevClose)
        }

        let anchor = prevClose > 0 ? prevClose : (low + high) / 2
        let minHalfSpan = max(abs(anchor) * minAmplitudeRatio, 1e-6)
        let span = high - low

        if span < minHalfSpan * 2 {
            low = min(low, anchor - minHalfSpan)
            high = max(high, anchor + minHalfSpan)
        } else {
            let pad = span * 0.08
            low -= pad
            high += pad
        }

        self.minY = low
        self.maxY = high
    }

    var plotWidth: CGFloat {
        max(size.width - rightPadding, 1)
    }

    var plotHeight: CGFloat {
        max(size.height - verticalPadding * 2, 1)
    }

    var stepX: CGFloat {
        guard points.count >= 2 else { return 0 }
        return plotWidth / CGFloat(points.count - 1)
    }

    func x(at index: Int) -> CGFloat {
        CGFloat(index) * stepX
    }

    func y(for value: Double) -> CGFloat {
        let range = max(maxY - minY, 1e-9)
        let normY = 1.0 - CGFloat((value - minY) / range)
        let rawY = verticalPadding + normY * plotHeight
        return min(max(rawY, verticalPadding), size.height - verticalPadding)
    }

    var coordinates: [CGPoint] {
        points.enumerated().map { idx, val in
            CGPoint(x: x(at: idx), y: y(for: val))
        }
    }
}

/// 走势时序缓存，按 SymbolID 记录最近接收到的真实分时点或实时行情流。
@MainActor
final class SparklineStore: ObservableObject {
    static let shared = SparklineStore()

    @Published private(set) var history: [SymbolID: [Double]] = [:]
    @Published private(set) var timestamps: [SymbolID: [Date]] = [:]

    private var hasRealTimeline: [SymbolID: Bool] = [:]
    private var lastTimelineFetch: [SymbolID: Date] = [:]
    private let timelineRefreshInterval: TimeInterval = 60
    private let maxFallbackPoints = 50

    func record(quote: Quote) {
        if let apiPoints = quote.sparklineHistory, apiPoints.count >= 2 {
            history[quote.symbol] = apiPoints
            timestamps[quote.symbol] = quote.sparklineTimestamps ?? []
            hasRealTimeline[quote.symbol] = true
            return
        }

        let price = (quote.effectivePrice as NSDecimalNumber).doubleValue
        guard price > 0 else { return }

        let sym = quote.symbol
        var list = history[sym] ?? []
        var times = timestamps[sym] ?? []

        // 定期刷新真实分时序列，保证盘中曲线随完整时间轴自然演进
        let now = Date()
        if lastTimelineFetch[sym] == nil || now.timeIntervalSince(lastTimelineFetch[sym]!) >= timelineRefreshInterval {
            lastTimelineFetch[sym] = now
            loadRealTimelineAsync(for: quote)
        }

        if list.isEmpty {
            // 尚未拉到真实分时时，仅展示昨收价与现价两个真实点，绝不编造假数据
            let prev = (quote.prevClose as NSDecimalNumber).doubleValue
            if prev > 0 {
                list = [prev, price]
                times = [quote.timestamp.addingTimeInterval(-3600), quote.timestamp]
            } else {
                list = [price, price]
                times = [quote.timestamp, quote.timestamp]
            }
            hasRealTimeline[sym] = false
        } else if hasRealTimeline[sym] == true {
            // 已有完整分时：仅在同一交易日内原地更新末尾实时价，绝不 append 挤掉早盘或跨日拼出断崖
            if let lastTime = times.last, Self.isSameTradingDay(lastTime, quote.timestamp, market: sym.market) {
                list[list.count - 1] = price
                times[times.count - 1] = quote.timestamp
            }
        } else {
            // 无分时接口支持的市场兜底：保留实时采样流
            if list.last != price {
                list.append(price)
                times.append(quote.timestamp)
                if list.count > maxFallbackPoints {
                    list.removeFirst(list.count - maxFallbackPoints)
                    if times.count > maxFallbackPoints {
                        times.removeFirst(times.count - maxFallbackPoints)
                    }
                }
            }
        }

        history[sym] = list
        timestamps[sym] = times
    }

    /// 供测试或异步回调写入真实分时数据。
    func applyTimeline(points: [Double], dates: [Date], for symbol: SymbolID, liveQuote: Quote? = nil) {
        guard points.count >= 2 else { return }
        var updatedPoints = points
        var updatedDates = dates
        if let quote = liveQuote,
           let lastDate = updatedDates.last,
           Self.isSameTradingDay(lastDate, quote.timestamp, market: symbol.market) {
            let livePrice = (quote.effectivePrice as NSDecimalNumber).doubleValue
            if livePrice > 0 {
                updatedPoints[updatedPoints.count - 1] = livePrice
                updatedDates[updatedDates.count - 1] = quote.timestamp
            }
        }
        history[symbol] = updatedPoints
        timestamps[symbol] = updatedDates
        hasRealTimeline[symbol] = true
        lastTimelineFetch[symbol] = Date()
    }

    /// 纯读取，不在 SwiftUI body 渲染期间产生状态变更副作用。
    func points(for quote: Quote) -> [Double]? {
        if let apiPoints = quote.sparklineHistory, apiPoints.count >= 2 {
            return apiPoints
        }
        if let existing = history[quote.symbol], existing.count >= 2 {
            return existing
        }
        return nil
    }

    static func isSameTradingDay(_ lhs: Date, _ rhs: Date, market: Market) -> Bool {
        if market == .crypto { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }

    private func loadRealTimelineAsync(for quote: Quote) {
        let sym = quote.symbol
        Task {
            if let timeline = await TimelineHistoryFetcher.shared.fetchHistory(for: sym), timeline.points.count >= 2 {
                await MainActor.run {
                    self.applyTimeline(points: timeline.points, dates: timeline.dates, for: sym, liveQuote: quote)
                }
            }
        }
    }
}

/// 金融风格的单行迷你走势折线图 (Sparkline)。
struct SparklineView: View {
    let quote: Quote?
    let scheme: TickerColorScheme
    var height: CGFloat = 26

    @ObservedObject private var store = SparklineStore.shared

    var body: some View {
        GeometryReader { geo in
            if let q = quote, let pts = resolvedPoints(for: q), pts.count >= 2 {
                let prev = (q.prevClose as NSDecimalNumber).doubleValue
                let color = q.effectiveChange >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
                let layout = SparklineLayout(points: pts, prevClose: prev, size: geo.size)
                let coords = layout.coordinates

                ZStack {
                    if prev > 0 {
                        baseline(y: layout.y(for: prev), width: layout.plotWidth)
                    }

                    areaGradient(coords: coords, color: color, height: geo.size.height)

                    daySeparators(indices: q.sparklineDayBoundaryIndices, layout: layout)

                    linePath(coords: coords)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))

                    if let last = coords.last {
                        currentPriceDot(at: last, color: color)
                    }
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(height: height)
        .onAppear {
            if let q = quote {
                store.record(quote: q)
            }
        }
        .onChange(of: quote?.effectivePrice) { _ in
            if let q = quote {
                store.record(quote: q)
            }
        }
        .onChange(of: quote?.timestamp) { _ in
            if let q = quote {
                store.record(quote: q)
            }
        }
    }

    private func resolvedPoints(for q: Quote) -> [Double]? {
        let pts = store.points(for: q)
        return (pts?.count ?? 0) >= 2 ? pts : nil
    }

    private func baseline(y: CGFloat, width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
    }

    private func daySeparators(indices: [Int], layout: SparklineLayout) -> some View {
        Path { path in
            guard layout.points.count >= 2 else { return }
            let stepX = layout.stepX
            for index in indices {
                let x = (CGFloat(index) - 0.5) * stepX
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: layout.size.height))
            }
        }
        .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
    }

    private func linePath(coords: [CGPoint]) -> Path {
        var path = Path()
        guard let first = coords.first else { return path }
        path.move(to: first)
        for point in coords.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func areaGradient(coords: [CGPoint], color: Color, height: CGFloat) -> some View {
        guard let first = coords.first, let last = coords.last else {
            return AnyView(EmptyView())
        }
        var path = linePath(coords: coords)
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()

        let gradient = LinearGradient(
            colors: [color.opacity(0.14), color.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )

        return AnyView(path.fill(gradient))
    }

    private func currentPriceDot(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 3.5, height: 3.5)
            .position(x: point.x, y: point.y)
    }
}
