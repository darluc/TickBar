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

struct StockVolumeMinute: Equatable, Identifiable, Sendable {
    let slot: Int
    let total: Double
    var classified = [Double](repeating: 0, count: 3)
    var buyAmount: Double = 0
    var sellAmount: Double = 0
    var id: Int { slot }
    var covered: Double { classified.reduce(0, +) }
    var missing: Double { max(total - covered, 0) }
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
    let inconsistentMinutes: Int
    var total: Double { minutes.reduce(0) { $0 + $1.total } }
    var covered: Double { summaries.reduce(0) { $0 + $1.hands } }
    var coverage: Double { total > 0 ? covered / total : 0 }

    /// Only completed minutes shared by both snapshots are compared. A minute is classified
    /// only when its detail volume exactly matches the dated minute series. Gaps stay unknown.
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
        var summaries = [StockVolumeSummary](repeating: .init(), count: 3)
        var inconsistent = 0
        for slot in 0...through {
            guard let total = reference[slot] else { continue }
            let records = grouped[slot] ?? []
            let detailTotal = records.reduce(0) { $0 + $1.hands }
            var minute = StockVolumeMinute(slot: slot, total: total)
            if detailTotal == total {
                for trade in records {
                    let index = trade.band.rawValue
                    minute.classified[index] += trade.hands
                    summaries[index].hands += trade.hands
                    if trade.side == 2 {
                        summaries[index].buy += trade.estimatedAmount
                        minute.buyAmount += trade.estimatedAmount
                    } else if trade.side == 1 {
                        summaries[index].sell += trade.estimatedAmount
                        minute.sellAmount += trade.estimatedAmount
                    } else { summaries[index].neutral += trade.estimatedAmount }
                }
            } else {
                inconsistent += 1
            }
            minutes.append(minute)
        }
        guard !minutes.isEmpty else { throw StockVolumeError.noTrades }
        return Self(day: day, minuteSource: minuteSource, detailSource: detailSource,
                    throughSlot: through, minutes: minutes,
                    summaries: summaries, inconsistentMinutes: inconsistent)
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
    func fetch(symbol: SymbolID) async throws -> StockVolumeDisplay
}

struct StockVolumeService: StockVolumeFetching {
    let http: HTTPClient
    private let tencent: TencentStockVolumeService
    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
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
        return try await http.fetchData(url: url.url!, timeout: 15)
    }

    func fetch(symbol: SymbolID) async throws -> StockVolumeDisplay {
        guard Self.supports(symbol), let secid = SymbolEncoder.eastMoney(symbol) else {
            throw StockVolumeError.unsupported
        }
        async let minutes = fetchMinutes(symbol: symbol, secid: secid)
        async let details = fetchDetails(symbol: symbol, secid: secid)
        let (reference, snapshot) = try await (minutes, details)
        if let day = snapshot.day, day != reference.day { throw StockVolumeError.dateMismatch }
        return try StockVolumeDisplay.build(day: reference.day, reference: reference.volumes, trades: snapshot.trades,
                                            minuteSource: reference.source, detailSource: snapshot.source)
    }

    private func fetchMinutes(symbol: SymbolID, secid: String) async throws
        -> (day: String, volumes: [Int: Double], source: StockVolumeSource) {
        do {
            let data = try await request(path: "trends2", query: [
                "secid": secid, "fields1": "f1,f2,f3,f4,f5,f6,f7",
                "fields2": "f51,f52,f53,f54,f55,f56,f57,f58", "ndays": "1", "iscr": "0"
            ])
            let reference = try Self.parseMinutes(data, code: symbol.code)
            return (reference.day, reference.volumes, .eastMoney)
        } catch {
            try Task.checkCancellation()
            guard let code = SymbolEncoder.tencent(symbol) else { throw StockVolumeError.unsupported }
            let reference = try await tencent.fetchMinutes(symbol: code)
            return (reference.day, reference.volumes, .tencent)
        }
    }

    private func fetchDetails(symbol: SymbolID, secid: String) async throws
        -> (day: String?, trades: [StockVolumeTrade], source: StockVolumeSource) {
        do {
            let data = try await request(path: "details", query: [
                "secid": secid, "fields1": "f1,f2,f3,f4,f5",
                "fields2": "f51,f52,f53,f54,f55", "pos": "-100000", "iscca": "1"
            ])
            let trades = try Self.parseDetails(data, code: symbol.code)
            guard !trades.isEmpty else { throw StockVolumeError.noTrades }
            return (nil, trades, .eastMoney)
        } catch {
            try Task.checkCancellation()
            guard let code = SymbolEncoder.tencent(symbol) else { throw StockVolumeError.unsupported }
            let snapshot = try await tencent.fetchDetails(symbol: code)
            return (snapshot.day, snapshot.trades, .tencent)
        }
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
        guard let body = try JSONDecoder().decode(Envelope.self, from: data).data,
              body.code == code, let rows = body.details else { throw StockVolumeError.invalidResponse }
        // Repeated rows in a snapshot must not inflate volume. This is a snapshot, never an
        // append-only stream: each successful refresh replaces the previous classification.
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

/// Networking and full-snapshot parsing stay off the main thread.
actor StockVolumeWorker: StockVolumeFetching {
    private let service = StockVolumeService()
    func fetch(symbol: SymbolID) async throws -> StockVolumeDisplay { try await service.fetch(symbol: symbol) }
}
