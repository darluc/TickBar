import Foundation

/// Everything the panel draws, prepared off the main actor. It has a fixed upper size
/// (≤ 241 minutes, 49 curve points, 20 rows) and is cheap to compare, so an unchanged
/// refresh publishes nothing and views never rescan data.
struct ETFDisplay: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let code: String
        let name: String
        let amountText: String
        let shareText: String
        let changeText: String
        let change: Double
        /// Bar length relative to the largest row.
        let fraction: Double
        var id: String { code }
    }

    var day = ""
    var updated: Date?
    var quoteCount = 0
    var minuteCount = 0
    var total = 0.0
    var rows: [Row] = []
    /// Basket turnover per minute slot and its running sum, for slots 0...liveSlot.
    var bars: [Double] = []
    var cumulative: [Double] = []
    var index: [Double?] = []
    var previous: ETFCurve?
    var previousDay = ""
    var average: ETFCurve?
    var averageDays = 0
    /// Today's running turnover relative to the 20-day average / previous day at the same minute.
    var paceAverage: Double?
    var pacePrevious: Double?

    var isEmpty: Bool { day.isEmpty }
    var liveSlot: Int { bars.count - 1 }

    static func build(quotes: [ETFQuote], minutes: [String: ETFMinuteSeries],
                      baseline: ETFBaseline?) -> ETFDisplay {
        var out = ETFDisplay()
        let basket = ETFDescriptor.names
        let live = quotes.filter { $0.code != ETFDescriptor.indexCode }.map { ETFTime.day($0.timestamp) }
            + minutes.filter { $0.key != ETFDescriptor.indexCode }.values.map(\.day)
        guard let day = live.max() else { return out }
        out.day = day

        let current = quotes.filter { basket[$0.code] != nil && ETFTime.day($0.timestamp) == day }
            .sorted { $0.amount == $1.amount ? $0.code < $1.code : $0.amount > $1.amount }
        out.quoteCount = current.count
        out.total = current.reduce(0) { $0 + $1.amount }
        out.updated = current.map(\.timestamp).max()
        let largest = max(current.first?.amount ?? 1, 1)
        out.rows = current.map { q in
            Row(code: q.code, name: basket[q.code] ?? q.code,
                amountText: String(format: "%.2f", q.amount / 1e8),
                shareText: out.total > 0 ? String(format: "%.1f%%", q.amount / out.total * 100) : "—",
                changeText: q.changePercent.map { String(format: "%+.2f%%", $0) } ?? "—",
                change: q.changePercent ?? 0, fraction: q.amount / largest)
        }

        let covered = ETFDescriptor.basket.map(\.code).compactMap { code in
            minutes[code].flatMap { $0.day == day ? (code, $0) : nil }
        }
        out.minuteCount = covered.count
        // A failed request may leave a cached series behind the others. Do not advance
        // past it and silently count its missing minutes as zero.
        let edge = covered.map { $0.1.lastSlot }.min() ?? -1
        if edge >= 0 {
            var bars = [Double](repeating: 0, count: edge + 1)
            for (_, series) in covered {
                for slot in 0...edge { bars[slot] += series.amount[slot] ?? 0 }
            }
            var sum = 0.0
            out.bars = bars
            out.cumulative = bars.map { sum += $0; return sum }
        }
        if let series = minutes[ETFDescriptor.indexCode], series.day == day, series.lastSlot >= 0 {
            out.index = Array(series.close[0...series.lastSlot])
        }

        if let baseline, baseline.liveDay == day {
            out.previous = baseline.previous
            out.previousDay = baseline.previousDay
            out.average = baseline.average
            out.averageDays = baseline.averageDays
            if let now = out.cumulative.last, edge >= 0 {
                func pace(_ curve: ETFCurve?) -> Double? {
                    guard let reference = curve?.value(at: edge), reference > 0 else { return nil }
                    return now / reference - 1
                }
                out.paceAverage = pace(baseline.average)
                out.pacePrevious = pace(baseline.previous)
            }
        }
        return out
    }
}

/// Comparison curves built once per trading day from five-minute bars.
struct ETFBaseline: Equatable, Sendable {
    static let averageWindow = 20
    static let minimumAverageDays = 3

    let liveDay: String
    let previousDay: String
    let previous: ETFCurve
    let average: ETFCurve?
    let averageDays: Int

    /// `bars`: code → day → 48 five-minute turnover values. A day counts only when all 20 ETFs
    /// have every bar, so the curves are never under-counted.
    static func build(bars: [String: [String: [Double?]]], liveDay: String) -> ETFBaseline? {
        let codes = ETFDescriptor.basket.map(\.code)
        guard codes.allSatisfy({ bars[$0] != nil }) else { return nil }
        let candidates = Set(bars.values.flatMap { $0.keys }).filter { $0 < liveDay }.sorted()
        var curves: [(day: String, cumulative: [Double])] = []
        for day in candidates {
            var basket = [Double](repeating: 0, count: ETFTime.barsPerDay)
            var complete = true
            for code in codes {
                guard let values = bars[code]?[day], values.count == ETFTime.barsPerDay, !values.contains(where: { $0 == nil }) else {
                    complete = false
                    break
                }
                for k in 0..<ETFTime.barsPerDay { basket[k] += values[k] ?? 0 }
            }
            guard complete else { continue }
            var sum = 0.0
            curves.append((day, basket.map { sum += $0; return sum }))
        }
        guard let last = curves.last else { return nil }
        let slots = [0] + (1...ETFTime.barsPerDay).map { $0 * 5 }
        let window = curves.suffix(averageWindow)
        var average: ETFCurve?
        if window.count >= minimumAverageDays {
            let mean = (0..<ETFTime.barsPerDay).map { k in window.reduce(0) { $0 + $1.cumulative[k] } / Double(window.count) }
            average = ETFCurve(slots: slots, values: [0] + mean)
        }
        return ETFBaseline(liveDay: liveDay, previousDay: last.day, previous: ETFCurve(slots: slots, values: [0] + last.cumulative),
                           average: average, averageDays: window.count)
    }
}

/// Serial owner of the live data. All parsing and aggregation happens here, never on the
/// main actor, and nothing is written to disk: state is bounded to one day of minutes plus
/// two comparison curves.
actor ETFWorker: ETFRefreshing {
    private let service: ETFService
    private var quotes: [ETFQuote] = []
    private var minutes: [String: ETFMinuteSeries] = [:]
    private var bars: [String: [String: [Double?]]] = [:]
    private var barsDay = ""
    private var baseline: ETFBaseline?

    init(service: ETFService = ETFService()) { self.service = service }

    func refresh() async -> ETFOutcome {
        var outcome = ETFOutcome()
        let service = service

        async let quoteResult: [ETFQuote]? = try? await service.quotes()
        var nextMinutes = minutes
        var pending = ETFDescriptor.basket.map { ($0.code, $0.secid) } + [(ETFDescriptor.indexCode, ETFDescriptor.indexSecid)]
        for _ in 0..<2 where !pending.isEmpty && !Task.isCancelled {
            let results = await concurrently(pending, limit: 6) { target in
                (target, try? await service.minutes(secid: target.1))
            }
            pending = []
            for (target, series) in results {
                if let series, let merged = Self.mergeMinutes(nextMinutes[target.0], series) {
                    nextMinutes[target.0] = merged
                } else { pending.append(target) }
            }
        }
        outcome.failedMinutes = pending.filter { $0.0 != ETFDescriptor.indexCode }.count
        let fetched = await quoteResult
        guard !Task.isCancelled else { return outcome }
        let nextQuotes = Self.mergeQuotes(quotes, fetched ?? [])
        let fetchedCodes = Set((fetched ?? []).map(\.code))
        let oldQuotes = Dictionary(quotes.map { ($0.code, $0) }, uniquingKeysWith: { a, b in a.timestamp >= b.timestamp ? a : b })
        outcome.quotesFailed = fetched == nil || ETFDescriptor.basket.contains { !fetchedCodes.contains($0.code) }
            || (fetched ?? []).contains { quote in oldQuotes[quote.code].map { quote.timestamp < $0.timestamp } ?? false }
        var display = ETFDisplay.build(quotes: nextQuotes, minutes: nextMinutes, baseline: baseline)
        if !display.isEmpty, baseline?.liveDay != display.day, !Task.isCancelled {
            await loadBaseline(for: display.day)
            display = ETFDisplay.build(quotes: nextQuotes, minutes: nextMinutes, baseline: baseline)
        }
        guard !Task.isCancelled else { return outcome }
        minutes = nextMinutes
        quotes = nextQuotes
        outcome.baselineMissing = !display.isEmpty && display.previous == nil
        outcome.display = display
        return outcome
    }

    /// Keep newer per-symbol quotes when the server returns a partial or delayed batch.
    static func mergeQuotes(_ cached: [ETFQuote], _ incoming: [ETFQuote]) -> [ETFQuote] {
        var merged = Dictionary(cached.map { ($0.code, $0) }, uniquingKeysWith: { a, b in
            a.timestamp >= b.timestamp ? a : b
        })
        for quote in incoming where merged[quote.code].map({ quote.timestamp >= $0.timestamp }) ?? true {
            merged[quote.code] = quote
        }
        return Array(merged.values)
    }

    /// Reject older or truncated responses; fill gaps from the existing same-day series.
    /// Values present in a current response still replace old values, allowing corrections.
    static func mergeMinutes(_ cached: ETFMinuteSeries?, _ incoming: ETFMinuteSeries) -> ETFMinuteSeries? {
        guard let cached else { return incoming }
        if incoming.day < cached.day { return nil }
        if incoming.day > cached.day { return incoming }
        guard incoming.lastSlot >= cached.lastSlot else { return nil }
        var merged = incoming
        for slot in 0..<min(merged.amount.count, cached.amount.count) {
            if merged.amount[slot] == nil {
                merged.amount[slot] = cached.amount[slot]
                merged.close[slot] = cached.close[slot]
            }
        }
        return merged
    }

    private func loadBaseline(for day: String) async {
        if barsDay != day { bars = [:]; barsDay = day }
        let service = service
        let missing = ETFDescriptor.basket.filter { bars[$0.code] == nil }
        let fetched = await concurrently(missing, limit: 6) { etf in
            (etf.code, try? await service.bars(secid: etf.secid))
        }
        for (code, days) in fetched { if let days { bars[code] = days } }
        baseline = ETFBaseline.build(bars: bars, liveDay: day)
        if baseline != nil { bars = [:] }
    }
}

struct ETFOutcome: Sendable {
    var display = ETFDisplay()
    var quotesFailed = false
    var failedMinutes = 0
    var baselineMissing = false
}

protocol ETFRefreshing: Sendable {
    func refresh() async -> ETFOutcome
}

/// Runs `work` over `items` with at most `limit` in flight.
private func concurrently<Item: Sendable, Result: Sendable>(
    _ items: [Item], limit: Int, _ work: @escaping @Sendable (Item) async -> Result
) async -> [Result] {
    await withTaskGroup(of: Result.self) { group in
        var iterator = items.makeIterator()
        var results: [Result] = []
        for _ in 0..<limit {
            guard let item = iterator.next() else { break }
            group.addTask { await work(item) }
        }
        while let result = await group.next() {
            results.append(result)
            if let item = iterator.next() { group.addTask { await work(item) } }
        }
        return results
    }
}
