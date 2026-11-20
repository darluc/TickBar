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

        out.applyBaseline(baseline)
        return out
    }

    mutating func applyBaseline(_ baseline: ETFBaseline?) {
        guard let baseline, baseline.liveDay == day else { return }
        previous = baseline.previous
        previousDay = baseline.previousDay
        average = baseline.average
        averageDays = baseline.averageDays
        if let now = cumulative.last, liveSlot >= 0 {
            func pace(_ curve: ETFCurve?) -> Double? {
                guard let reference = curve?.value(at: liveSlot), reference > 0 else { return nil }
                return now / reference - 1
            }
            paceAverage = pace(baseline.average)
            pacePrevious = pace(baseline.previous)
        }
    }
}

/// Comparison curves built once per trading day from five-minute bars.
struct ETFBaseline: Equatable, Sendable, Codable {
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
/// main actor. Only the current day's comparison curves are written to disk; everything
/// else is bounded to one day of minutes in memory.
actor ETFWorker: ETFRefreshing {
    private let service: ETFService
    private let fallback: TencentETFService
    private let historyFallback: SinaETFHistoryService
    private let baselineCache: ETFBaselineCache
    private var quotes: [ETFQuote] = []
    private var minutes: [String: ETFMinuteSeries] = [:]
    private var bars: [String: [String: [Double?]]] = [:]
    private var barsDay = ""
    private var baseline: ETFBaseline?
    private var baselineRetryDay = ""
    private var baselineRetryAfter = Date.distantPast

    init(service: ETFService = ETFService(), fallback: TencentETFService = TencentETFService(),
         historyFallback: SinaETFHistoryService = SinaETFHistoryService(),
         baselineCache: ETFBaselineCache = ETFBaselineCache()) {
        self.service = service
        self.fallback = fallback
        self.historyFallback = historyFallback
        self.baselineCache = baselineCache
    }

    func refresh() async -> ETFOutcome {
        var outcome = ETFOutcome()
        let service = service
        let fallback = fallback
        let cachedMinutes = minutes
        let cachedQuotes = quotes
        let targets = ETFDescriptor.basket.map { ($0.code, $0.secid) } + [(ETFDescriptor.indexCode, ETFDescriptor.indexSecid)]

        async let quoteResult = etfAttempt(source: "East Money", operation: "quotes") { try await service.quotes() }
        let minuteResults = await concurrently(targets, limit: 6) { target -> (String, ETFMinuteSeries?, Bool) in
            if let value = await etfAttempt(source: "East Money", operation: "minutes \(target.0)", {
                try await service.minutes(secid: target.1)
            }), let merged = Self.mergeMinutes(cachedMinutes[target.0], value) {
                return (target.0, merged, false)
            }
            if let value = await etfAttempt(source: "Tencent", operation: "minutes \(target.0)", {
                try await fallback.minutes(code: target.0)
            }), let merged = Self.mergeMinutes(cachedMinutes[target.0], value) {
                return (target.0, merged, true)
            }
            return (target.0, nil, false)
        }
        let fetched = await quoteResult ?? []
        guard !Task.isCancelled else { return outcome }
        let fetchedQuotes = Dictionary(fetched.map { ($0.code, $0) }, uniquingKeysWith: { a, b in
            a.timestamp >= b.timestamp ? a : b
        })
        // Use a median of the current basket and each symbol's quote time, rather
        // than wall-clock time or a single outlier, to detect a stalled feed.
        let days = minuteResults.filter { $0.0 != ETFDescriptor.indexCode }.compactMap { $0.1?.day }
        let counts = Dictionary(days.map { ($0, 1) }, uniquingKeysWith: +)
        let referenceDay = counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?.key
        let slots = minuteResults.compactMap { code, series, _ -> Int? in
            guard code != ETFDescriptor.indexCode, let series, series.day == referenceDay else { return nil }
            return series.lastSlot
        }.sorted()
        let referenceSlot = slots.count >= 5 ? slots[slots.count / 2] : nil
        func stalled(_ code: String, _ series: ETFMinuteSeries) -> Bool {
            if let referenceDay, let referenceSlot, Self.isStale(series, day: referenceDay, slot: referenceSlot) { return true }
            if let quote = fetchedQuotes[code], let slot = Self.quoteSlot(quote.timestamp) {
                return Self.isStale(series, day: ETFTime.day(quote.timestamp), slot: slot)
            }
            return false
        }
        let stale = minuteResults.filter { code, series, _ in
            guard code != ETFDescriptor.indexCode, let series else { return false }
            return stalled(code, series)
        }
        let recovered = await concurrently(stale, limit: 6) { entry -> (String, ETFMinuteSeries?, Bool) in
            guard !entry.2, let existing = entry.1 else { return entry }
            guard let value = await etfAttempt(source: "Tencent", operation: "stale minutes \(entry.0)", {
                try await fallback.minutes(code: entry.0)
            }), let merged = Self.mergeMinutes(existing, value),
                  merged.day > existing.day || merged.lastSlot > existing.lastSlot else { return entry }
            return (entry.0, merged, true)
        }
        let recoveredByCode = Dictionary(uniqueKeysWithValues: recovered.map { ($0.0, $0) })
        var nextMinutes = cachedMinutes
        for result in minuteResults {
            let (code, series, usedFallback) = recoveredByCode[result.0] ?? result
            if let series {
                nextMinutes[code] = series
                if usedFallback && code != ETFDescriptor.indexCode { outcome.fallbackMinutes += 1 }
                if code != ETFDescriptor.indexCode, stalled(code, series) { outcome.failedMinutes += 1 }
            } else if code != ETFDescriptor.indexCode { outcome.failedMinutes += 1 }
        }

        guard !Task.isCancelled else { return outcome }
        let oldQuotes = Dictionary(cachedQuotes.map { ($0.code, $0) }, uniquingKeysWith: { a, b in a.timestamp >= b.timestamp ? a : b })
        let minuteDay = ETFDescriptor.basket.compactMap { nextMinutes[$0.code]?.day }.max()
        func usableQuote(_ quote: ETFQuote) -> Bool {
            (oldQuotes[quote.code].map { quote.timestamp >= $0.timestamp } ?? true) &&
                (minuteDay.map { ETFTime.day(quote.timestamp) >= $0 } ?? true)
        }
        let usable = fetched.filter(usableQuote)
        let primaryCodes = Set(usable.map(\.code))
        let missing = targets.map(\.0).filter { !primaryCodes.contains($0) }
        var replacement: [ETFQuote] = []
        if !missing.isEmpty {
            replacement = await etfAttempt(source: "Tencent", operation: "quotes") {
                try await fallback.quotes(codes: missing)
            } ?? []
            replacement = replacement.filter(usableQuote)
        }
        let available = primaryCodes.union(replacement.map(\.code))
        outcome.fallbackQuotes = !replacement.isEmpty
        outcome.quotesFailed = ETFDescriptor.basket.contains { !available.contains($0.code) }
        guard !Task.isCancelled else { return outcome }
        quotes = Self.mergeQuotes(cachedQuotes, usable + replacement)
        minutes = nextMinutes
        let display = ETFDisplay.build(quotes: quotes, minutes: minutes, baseline: baseline)
        outcome.baselineMissing = !display.isEmpty && display.previous == nil
        outcome.display = display
        outcome.rateLimited = await service.gate.isCoolingDown()
        return outcome
    }

    private static func quoteSlot(_ date: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return ETFTime.slot(hour: hour, minute: minute)
    }

    /// Five slots tolerate normal provider delays without letting a stalled series freeze the basket.
    static func isStale(_ series: ETFMinuteSeries, day: String, slot: Int) -> Bool {
        series.day < day || (series.day == day && series.lastSlot + 5 < slot)
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

    func prepareBaseline(for day: String) async -> ETFBaseline? {
        if baseline?.liveDay == day { return baseline }
        // Reuse today's curves after a restart or upgrade instead of refetching them.
        if let cached = baselineCache.load(day: day) {
            baseline = cached
            return cached
        }
        if baselineRetryDay == day && Date() < baselineRetryAfter { return nil }
        await loadBaseline(for: day)
        guard !Task.isCancelled else { return nil }
        if let baseline, baseline.liveDay == day {
            baselineCache.save(baseline)
        } else {
            baselineRetryDay = day
            baselineRetryAfter = Date().addingTimeInterval(300)
        }
        return baseline?.liveDay == day ? baseline : nil
    }

    private func loadBaseline(for day: String) async {
        if barsDay != day { bars = [:]; barsDay = day }
        let service = service
        let historyFallback = historyFallback
        let missing = ETFDescriptor.basket.filter { bars[$0.code] == nil }
        let fetched = await concurrently(missing, limit: 6) { etf -> (String, [String: [Double?]]?) in
            let primary = await etfAttempt(source: "East Money", operation: "history \(etf.code)") {
                try await service.bars(secid: etf.secid)
            }
            if let primary { return (etf.code, primary) }
            // East Money blocks the whole history host under load; Sina serves the same
            // bar-close-labelled 5-minute turnover, so one source failing does not blank the curves.
            let value = await etfAttempt(source: "Sina", operation: "history \(etf.code)") {
                try await historyFallback.bars(code: etf.code)
            }
            return (etf.code, value)
        }
        guard !Task.isCancelled, barsDay == day else { return }
        for (code, days) in fetched { if let days { bars[code] = days } }
        baseline = ETFBaseline.build(bars: bars, liveDay: day)
        // Incomplete data must be fetched again, otherwise one partial response blocks recovery all day.
        if baseline != nil || bars.count == ETFDescriptor.basket.count { bars = [:] }
    }
}

struct ETFOutcome: Sendable {
    var display = ETFDisplay()
    var quotesFailed = false
    var failedMinutes = 0
    var baselineMissing = false
    var fallbackQuotes = false
    var fallbackMinutes = 0
    /// The realtime gate is cooling down after throttling or repeated transport failures;
    /// automatic polling should back off.
    var rateLimited = false
}

protocol ETFRefreshing: Sendable {
    func refresh() async -> ETFOutcome
    func prepareBaseline(for day: String) async -> ETFBaseline?
}

extension ETFRefreshing {
    func prepareBaseline(for day: String) async -> ETFBaseline? { nil }
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
