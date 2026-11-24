import Foundation

/// These are sizes of public trade-detail records, which may combine several executions.
/// Amounts are estimates (last price × hands × 100), not original order amounts.
enum StockVolumeBand: Int, CaseIterable, Sendable {
    case large, medium, small

    static func classify(amount: Double) -> Self {
        if amount >= 1_000_000 { return .large }
        if amount >= 100_000 { return .medium }
        return .small
    }

    var title: String { L("volume.band.\(rawValue)") }
    var threshold: String { L("volume.threshold.\(rawValue)") }
}

struct StockVolumeTrade: Equatable, Sendable {
    let slot: Int
    let hands: Double
    let estimatedAmount: Double
    let side: Int // East Money: 1 = sell, 2 = buy, 4 = neutral.
    var band: StockVolumeBand { .classify(amount: estimatedAmount) }
}

enum StockVolumeQuality: String, Sendable {
    case exact, partial, estimated, unknown

    var title: String { L("volume.quality.\(rawValue)") }
}

struct StockVolumeMinute: Equatable, Identifiable, Sendable {
    let slot: Int
    let total: Double
    var classified = [Double](repeating: 0, count: 3)
    var buyAmounts = [Double](repeating: 0, count: 3)
    var sellAmounts = [Double](repeating: 0, count: 3)
    var neutralAmounts = [Double](repeating: 0, count: 3)
    var quality: StockVolumeQuality = .exact
    var buyAmount: Double { buyAmounts.reduce(0, +) }
    var sellAmount: Double { sellAmounts.reduce(0, +) }
    var netAmounts: [Double]? {
        missing == 0 ? zip(buyAmounts, sellAmounts).map { $0.0 - $0.1 } : nil
    }
    /// Positive and negative categories stack separately, even when their combined net is zero.
    var netExtent: Double {
        guard let netAmounts else { return 0 }
        return max(netAmounts.filter { $0 > 0 }.reduce(0, +),
                   -netAmounts.filter { $0 < 0 }.reduce(0, +))
    }
    var id: Int { slot }
    var covered: Double { classified.reduce(0, +) }
    /// Scaled estimates can leave sub-hand float noise; only a real residual is unknown.
    var missing: Double {
        let residual = total - covered
        return residual > 0.01 ? residual : 0
    }
    /// A missing minute has no known net amount; reconciled neutral-only volume has net zero.
    var netAmount: Double? { missing == 0 ? buyAmount - sellAmount : nil }
}

struct StockVolumeSummary: Equatable, Sendable {
    var hands: Double = 0
    var buy: Double = 0
    var sell: Double = 0
    var neutral: Double = 0
    var net: Double { buy - sell }
}

enum StockVolumeSource: String, Sendable {
    case eastMoney, tencent
    var title: String { L("volume.source.\(rawValue)") }
}

struct StockVolumeDisplay: Equatable, Sendable {
    let day: String
    let minuteSource: StockVolumeSource
    let detailSource: StockVolumeSource
    let throughSlot: Int
    let minutes: [StockVolumeMinute]
    let summaries: [StockVolumeSummary]
    var total: Double { minutes.reduce(0) { $0 + $1.total } }
    var covered: Double { summaries.reduce(0) { $0 + $1.hands } }
    var coverage: Double { total > 0 ? covered / total : 0 }
    var partialMinutes: Int { minutes.reduce(0) { $0 + ($1.quality == .partial ? 1 : 0) } }
    var estimatedMinutes: Int { minutes.reduce(0) { $0 + ($1.quality == .estimated ? 1 : 0) } }
    var inconsistentMinutes: Int { minutes.reduce(0) { $0 + ($1.quality == .unknown ? 1 : 0) } }

    /// Completed minutes are published with a confidence: exact (including a small rounding
    /// tolerance), partial (observed records with an explicit unknown remainder when the detail
    /// feed only covers part of the minute), estimated (a small over-count scaled down or a
    /// composition borrowed from a reconciled 3-minute window), or unknown. Observed records are
    /// never discarded; data is never invented for a minute that cannot be validated by its own
    /// or a neighbouring window.
    static func build(day: String, reference: [Int: Double], trades: [StockVolumeTrade],
                      minuteSource: StockVolumeSource = .eastMoney, detailSource: StockVolumeSource = .eastMoney) throws -> Self {
        guard let lastReference = reference.keys.max(), let lastTrade = trades.map(\.slot).max() else {
            throw StockVolumeError.noTrades
        }
        let last = min(lastReference, lastTrade)
        let through = last == ETFTime.lastSlot ? last : last - 1
        guard through >= 0 else { throw StockVolumeError.noTrades }
        let grouped = Dictionary(grouping: trades, by: \.slot)
        var minutes: [StockVolumeMinute] = []
        var deferred: [Int] = []
        for slot in 0...through {
            guard let total = reference[slot] else { continue }
            let records = grouped[slot] ?? []
            let detailTotal = records.reduce(0) { $0 + $1.hands }
            var minute = StockVolumeMinute(slot: slot, total: total)
            let tolerance = max(2, total * 0.001)
            if detailTotal == 0, total == 0 {
                minute.quality = .exact
            } else if detailTotal > 0, abs(detailTotal - total) <= tolerance {
                classify(records, into: &minute, scale: total / detailTotal)
                minute.quality = .exact
            } else if total > 0, detailTotal > total, detailTotal <= total * 1.02 {
                classify(records, into: &minute, scale: total / detailTotal)
                minute.quality = .estimated
            } else if total > 0, detailTotal > 0, detailTotal < total {
                // The observed records are authoritative for themselves; the remainder is
                // reported as unknown instead of being scaled away.
                classify(records, into: &minute, scale: 1)
                minute.quality = .partial
            } else {
                minute.quality = .unknown
                deferred.append(minutes.count)
            }
            minutes.append(minute)
        }
        guard !minutes.isEmpty else { throw StockVolumeError.noTrades }
        estimateFromWindows(&minutes, deferred: deferred, reference: reference, grouped: grouped, through: through)
        var summaries = [StockVolumeSummary](repeating: .init(), count: StockVolumeBand.allCases.count)
        for minute in minutes {
            for index in summaries.indices {
                summaries[index].hands += minute.classified[index]
                summaries[index].buy += minute.buyAmounts[index]
                summaries[index].sell += minute.sellAmounts[index]
                summaries[index].neutral += minute.neutralAmounts[index]
            }
        }
        return Self(day: day, minuteSource: minuteSource, detailSource: detailSource,
                    throughSlot: through, minutes: minutes, summaries: summaries)
    }

    /// Scales the observed composition to the reference total. Only used within the rounding
    /// tolerance or a small over-count, never to fabricate missing records.
    private static func classify(_ records: [StockVolumeTrade], into minute: inout StockVolumeMinute, scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        for trade in records {
            let index = trade.band.rawValue
            minute.classified[index] += trade.hands * scale
            if trade.side == 2 {
                minute.buyAmounts[index] += trade.estimatedAmount * scale
            } else if trade.side == 1 {
                minute.sellAmounts[index] += trade.estimatedAmount * scale
            } else {
                minute.neutralAmounts[index] += trade.estimatedAmount * scale
            }
        }
    }

    /// A minute with too few records can borrow the composition of a 3-minute window when the
    /// window as a whole reconciles. This repairs boundary attribution without inventing volume.
    private static func estimateFromWindows(_ minutes: inout [StockVolumeMinute], deferred: [Int],
                                            reference: [Int: Double], grouped: [Int: [StockVolumeTrade]],
                                            through: Int) {
        for index in deferred {
            let slot = minutes[index].slot
            let total = minutes[index].total
            let lower = max(0, slot - 1)
            let upper = min(through, slot + 1)
            var windowTotal = 0.0
            var windowDetail = 0.0
            var hands = [Double](repeating: 0, count: 3)
            var buy = hands, sell = hands, neutral = hands
            for candidate in lower...upper {
                guard let value = reference[candidate] else { continue }
                windowTotal += value
                for trade in grouped[candidate] ?? [] {
                    windowDetail += trade.hands
                    let band = trade.band.rawValue
                    hands[band] += trade.hands
                    if trade.side == 2 { buy[band] += trade.estimatedAmount }
                    else if trade.side == 1 { sell[band] += trade.estimatedAmount }
                    else { neutral[band] += trade.estimatedAmount }
                }
            }
            let tolerance = max(2, windowTotal * 0.01)
            guard windowTotal > 0, windowDetail > 0,
                  abs(windowDetail - windowTotal) <= tolerance else { continue }
            let scale = total / windowDetail
            guard scale.isFinite, scale >= 0 else { continue }
            var minute = minutes[index]
            minute.classified = hands.map { $0 * scale }
            minute.buyAmounts = buy.map { $0 * scale }
            minute.sellAmounts = sell.map { $0 * scale }
            minute.neutralAmounts = neutral.map { $0 * scale }
            minute.quality = .estimated
            minutes[index] = minute
        }
    }

    /// Fills minutes a newer snapshot could not reconcile with the last complete ones.
    /// Within one trading day the visible range and classified coverage only move forward;
    /// a slower, truncated or fallback snapshot never removes earlier results.
    static func merging(previous: StockVolumeDisplay?, _ incoming: StockVolumeDisplay) -> StockVolumeDisplay {
        guard let previous else { return incoming }
        if incoming.day < previous.day { return previous }
        if incoming.day > previous.day { return incoming }
        let new = Dictionary(incoming.minutes.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
        let old = Dictionary(previous.minutes.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
        let through = max(previous.throughSlot, incoming.throughSlot)
        var minutes: [StockVolumeMinute] = []
        minutes.reserveCapacity(max(new.count, old.count))
        for slot in 0...through {
            let candidate = new[slot]
            let fallback = old[slot]
            let chosen: StockVolumeMinute?
            if let candidate, candidate.missing == 0 {
                chosen = candidate
            } else if let fallback, fallback.missing == 0 {
                chosen = fallback
            } else {
                chosen = candidate ?? fallback
            }
            if let chosen { minutes.append(chosen) }
        }
        guard !minutes.isEmpty else { return incoming }
        var summaries = [StockVolumeSummary](repeating: .init(), count: StockVolumeBand.allCases.count)
        for minute in minutes {
            for index in summaries.indices {
                summaries[index].hands += minute.classified[index]
                summaries[index].buy += minute.buyAmounts[index]
                summaries[index].sell += minute.sellAmounts[index]
                summaries[index].neutral += minute.neutralAmounts[index]
            }
        }
        return Self(day: incoming.day, minuteSource: incoming.minuteSource, detailSource: incoming.detailSource,
                    throughSlot: through, minutes: minutes, summaries: summaries)
    }
}

enum StockVolumeError: LocalizedError {
    case unsupported, invalidResponse, noTrades, dateMismatch
    var errorDescription: String? {
        switch self {
        case .unsupported: return L("volume.unsupported")
        case .invalidResponse: return L("volume.invalidResponse")
        case .noTrades: return L("volume.noTrades")
        case .dateMismatch: return L("volume.dateMismatch")
        }
    }
}

protocol StockVolumeFetching: Sendable {
    /// `forceDetails` bypasses the "minute series did not advance" cache and is used by manual refresh.
    func fetch(symbol: SymbolID, forceDetails: Bool) async throws -> StockVolumeDisplay
}

extension StockVolumeFetching {
    func fetch(symbol: SymbolID) async throws -> StockVolumeDisplay {
        try await fetch(symbol: symbol, forceDetails: true)
    }
}

struct StockVolumeMinuteSnapshot: Sendable {
    let day: String
    let volumes: [Int: Double]
    let source: StockVolumeSource
    var lastSlot: Int { volumes.keys.max() ?? -1 }
}

struct StockVolumeDetailSnapshot: Sendable {
    /// East Money has no date field; Tencent supplies one for validation.
    let day: String?
    let trades: [StockVolumeTrade]
    /// East Money rows for next-round merging; empty for Tencent.
    let rows: [String]
    let source: StockVolumeSource
}

/// The two data legs kept separate so the worker can reuse cached rows and skip a details
/// request when the minute series has not advanced.
protocol StockVolumeSnapshotFetching: Sendable {
    func minutes(symbol: SymbolID) async throws -> StockVolumeMinuteSnapshot
    func details(symbol: SymbolID, cachedRows: [String]) async throws -> StockVolumeDetailSnapshot
}

struct StockVolumeService: StockVolumeFetching, StockVolumeSnapshotFetching {
    let http: HTTPClient
    let gate: ETFRequestGate
    private let tencent: TencentStockVolumeService
    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"]),
         gate: ETFRequestGate = ETFRequestGate()) {
        self.http = http
        self.gate = gate
        self.tencent = TencentStockVolumeService(http: http)
    }

    /// A-share individual stocks only; exclude indices and funds sharing the same market tag.
    static func supports(_ symbol: SymbolID) -> Bool {
        guard symbol.market == .a, symbol.code.count == 6, symbol.code.allSatisfy(\.isNumber) else { return false }
        return ["600", "601", "603", "605", "688", "689", "000", "001", "002", "003", "300", "301"]
            .contains { symbol.code.hasPrefix($0) }
    }

    private func request(path: String, query: [String: String]) async throws -> Data {
        var url = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/\(path)/get")!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await Self.retrying {
            try await etfRequest(gate: self.gate) {
                try await self.http.fetchData(url: url.url!, timeout: 15)
            }
        }
    }

    /// One retry for transient failures; 429 and invalid data fall through to Tencent at once.
    private static func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard !Task.isCancelled, isTransient(error) else { throw error }
            try await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...700_000_000))
            return try await operation()
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let http = error as? HTTPError else { return false }
        switch http {
        case .transport: return true
        case .badStatus(let status): return status >= 500
        case .rateLimited, .decoding: return false
        }
    }

    func fetch(symbol: SymbolID, forceDetails: Bool) async throws -> StockVolumeDisplay {
        async let minuteLeg = minutes(symbol: symbol)
        async let detailLeg = details(symbol: symbol, cachedRows: [])
        return try Self.build(minutes: try await minuteLeg, details: try await detailLeg)
    }

    func minutes(symbol: SymbolID) async throws -> StockVolumeMinuteSnapshot {
        guard Self.supports(symbol), let secid = SymbolEncoder.eastMoney(symbol) else {
            throw StockVolumeError.unsupported
        }
        do {
            let data = try await request(path: "trends2", query: [
                "secid": secid, "fields1": "f1,f2,f3,f4,f5,f6,f7",
                "fields2": "f51,f52,f53,f54,f55,f56,f57,f58", "ndays": "1", "iscr": "0"
            ])
            let reference = try Self.parseMinutes(data, code: symbol.code)
            return StockVolumeMinuteSnapshot(day: reference.day, volumes: reference.volumes, source: .eastMoney)
        } catch {
            try Task.checkCancellation()
            guard let code = SymbolEncoder.tencent(symbol) else { throw StockVolumeError.unsupported }
            let reference = try await tencent.fetchMinutes(symbol: code)
            return StockVolumeMinuteSnapshot(day: reference.day, volumes: reference.volumes, source: .tencent)
        }
    }

    func details(symbol: SymbolID, cachedRows: [String]) async throws -> StockVolumeDetailSnapshot {
        guard Self.supports(symbol), let secid = SymbolEncoder.eastMoney(symbol) else {
            throw StockVolumeError.unsupported
        }
        do {
            let data = try await request(path: "details", query: [
                "secid": secid, "fields1": "f1,f2,f3,f4,f5",
                "fields2": "f51,f52,f53,f54,f55", "pos": "-100000", "iscca": "1"
            ])
            let incoming = try Self.extractDetailRows(data, code: symbol.code)
            let rows = Self.mergeDetailRows(cachedRows, incoming)
            let trades = try Self.parseDetailRows(rows, code: symbol.code)
            guard !trades.isEmpty else { throw StockVolumeError.noTrades }
            return StockVolumeDetailSnapshot(day: nil, trades: trades, rows: rows, source: .eastMoney)
        } catch {
            try Task.checkCancellation()
            guard let code = SymbolEncoder.tencent(symbol) else { throw StockVolumeError.unsupported }
            let snapshot = try await tencent.fetchDetails(symbol: code)
            guard !snapshot.trades.isEmpty else { throw StockVolumeError.noTrades }
            return StockVolumeDetailSnapshot(day: snapshot.day, trades: snapshot.trades, rows: [], source: .tencent)
        }
    }

    static func build(minutes: StockVolumeMinuteSnapshot,
                      details: StockVolumeDetailSnapshot) throws -> StockVolumeDisplay {
        if let day = details.day, day != minutes.day { throw StockVolumeError.dateMismatch }
        return try StockVolumeDisplay.build(day: minutes.day, reference: minutes.volumes, trades: details.trades,
                                            minuteSource: minutes.source, detailSource: details.source)
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String
            let trends: [String]?
            let details: [String]?
        }
        let data: Body?
    }

    static func parseMinutes(_ data: Data, code: String) throws -> (day: String, volumes: [Int: Double]) {
        guard let body = try JSONDecoder().decode(Envelope.self, from: data).data,
              body.code == code, let rows = body.trends else { throw StockVolumeError.invalidResponse }
        var day = ""
        var volumes: [Int: Double] = [:]
        for row in rows {
            let f = row.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6, let time = ETFTime.parse(f[0]),
                  let volume = Double(f[5]), volume.isFinite, volume >= 0 else { continue }
            let rowDay = String(time.day)
            if rowDay > day { day = rowDay; volumes = [:] }
            if rowDay == day { volumes[time.slot] = volume }
        }
        guard !day.isEmpty, !volumes.isEmpty else { throw StockVolumeError.noTrades }
        return (day, volumes)
    }

    static func parseDetails(_ data: Data, code: String) throws -> [StockVolumeTrade] {
        try parseDetailRows(extractDetailRows(data, code: code), code: code)
    }

    static func extractDetailRows(_ data: Data, code: String) throws -> [String] {
        guard let body = try JSONDecoder().decode(Envelope.self, from: data).data,
              body.code == code, let rows = body.details else { throw StockVolumeError.invalidResponse }
        return rows
    }

    static func mergeDetailRows(_ cached: [String], _ incoming: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        merged.reserveCapacity(cached.count + incoming.count)
        for row in cached {
            if seen.insert(row).inserted { merged.append(row) }
        }
        for row in incoming {
            if seen.insert(row).inserted { merged.append(row) }
        }
        return merged
    }

    static func parseDetailRows(_ rows: [String], code: String) throws -> [StockVolumeTrade] {
        // Repeated rows in a snapshot must not inflate volume.
        var seen = Set<String>()
        return rows.compactMap { row in
            guard seen.insert(row).inserted else { return nil }
            let f = row.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 5, let slot = detailSlot(f[0]),
                  let price = Double(f[1]), price.isFinite, price > 0,
                  let hands = Double(f[2]), hands.isFinite, hands > 0,
                  let side = Int(f[4]), [1, 2, 4].contains(side) else { return nil }
            let amount = price * hands * 100
            guard amount.isFinite else { return nil }
            return StockVolumeTrade(slot: slot, hands: hands, estimatedAmount: amount, side: side)
        }
    }

    /// The minute API labels by interval end; 09:30:00 belongs to 09:31. Actual opening
    /// auction trades at 09:25 belong to 09:30. Earlier indicative auction quotes are excluded.
    static func detailSlot(_ time: Substring) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 8, parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              (0...23).contains(h), (0...59).contains(m), (0...59).contains(s) else { return nil }
        let minute = h * 60 + m
        if minute == 565 { return 0 }
        if (570..<690).contains(minute) { return ETFTime.slot(minuteOfDay: minute + 1) }
        if minute == 690 && s == 0 { return 120 }
        if (780..<900).contains(minute) { return ETFTime.slot(minuteOfDay: minute + 1) }
        if minute == 900 && s == 0 { return 240 }
        return nil
    }
}

/// Serial owner of the live snapshot. Results are merged per trading day so a slow, truncated
/// or fallback snapshot never removes minutes a previous round already reconciled. Detail rows
/// are kept for the same day so East Money's rolling `pos` window cannot drop earlier trades.
actor StockVolumeWorker: StockVolumeFetching {
    private let service: any StockVolumeSnapshotFetching
    private var day = ""
    private var symbol: SymbolID?
    private var detailRows: [String] = []
    private var detailSlot = -1
    private var latest: StockVolumeDisplay?

    init(service: any StockVolumeSnapshotFetching = StockVolumeService()) {
        self.service = service
    }

    func fetch(symbol: SymbolID, forceDetails: Bool) async throws -> StockVolumeDisplay {
        guard latest != nil else {
            // First load, or the first round after a trading-day change: both legs in parallel.
            let service = self.service
            async let minuteLeg = service.minutes(symbol: symbol)
            async let detailLeg = service.details(symbol: symbol, cachedRows: [])
            return try publish(minutes: try await minuteLeg, details: try await detailLeg, symbol: symbol)
        }
        let minutes = try await service.minutes(symbol: symbol)
        if day != minutes.day || self.symbol != symbol { reset(minutes: minutes, symbol: symbol) }
        if !forceDetails, let latest, detailSlot >= minutes.lastSlot { return latest }
        let details = try await service.details(symbol: symbol, cachedRows: detailRows)
        return try publish(minutes: minutes, details: details, symbol: symbol)
    }

    private func reset(minutes: StockVolumeMinuteSnapshot, symbol: SymbolID) {
        day = minutes.day
        self.symbol = symbol
        detailRows = []
        detailSlot = -1
        latest = nil
    }

    private func publish(minutes: StockVolumeMinuteSnapshot, details: StockVolumeDetailSnapshot,
                         symbol: SymbolID) throws -> StockVolumeDisplay {
        if day != minutes.day || self.symbol != symbol { reset(minutes: minutes, symbol: symbol) }
        let incoming = try StockVolumeService.build(minutes: minutes, details: details)
        if details.source == .eastMoney { detailRows = details.rows }
        detailSlot = minutes.lastSlot
        let merged = StockVolumeDisplay.merging(previous: latest, incoming)
        latest = merged
        return merged
    }
}
