import Foundation

/// Native adapter for the Tencent endpoints used by AkShare stock_zh_a_tick_tx_js.
/// Page metadata supplies a trading date; completed pages are cached for this symbol/day.
actor TencentStockVolumeService {
    let http: HTTPClient
    private var cachedSymbol = ""
    private var cachedDay = ""
    private var cachedPages: [Int: [Row]] = [:]

    init(http: HTTPClient) { self.http = http }

    private struct Row: Sendable {
        let id: Int
        let trade: StockVolumeTrade
    }

    private func request(symbol: String, action: String, page: Int? = nil) async throws -> String {
        var url = URLComponents(string: "https://stock.gtimg.cn/data/index.php")!
        var query = ["appn": "detail", "action": action, "c": symbol]
        if let page { query["p"] = String(page) }
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await http.fetchData(url: url.url!, headers: ["Referer": "https://gu.qq.com/"], timeout: 15)
        guard let text = String(data: data, encoding: .utf8) else { throw StockVolumeError.invalidResponse }
        return text
    }

    /// Parses a known assignment envelope as JSON, never as executable JavaScript.
    private static func payload(_ text: String, prefix: String) throws -> [Any] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix) else { throw StockVolumeError.invalidResponse }
        let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "; \r\n\t"))
        guard let array = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [Any], array.count == 2 else {
            throw StockVolumeError.invalidResponse
        }
        return array
    }

    private static func day(_ compact: String) throws -> String {
        guard compact.count == 8, compact.allSatisfy(\.isNumber) else { throw StockVolumeError.invalidResponse }
        return "\(compact.prefix(4))-\(compact.dropFirst(4).prefix(2))-\(compact.suffix(2))"
    }

    static func parseInfo(_ text: String, symbol: String) throws -> (day: String, pages: Int) {
        let values = try payload(text, prefix: "v_detail_time_\(symbol)=")
        guard let date = values[0] as? Int, let ranges = values[1] as? String else {
            throw StockVolumeError.invalidResponse
        }
        let count = ranges.split(separator: "|").count
        guard count > 0 else { throw StockVolumeError.noTrades }
        return (try day(String(date)), count)
    }

    private static func parsePage(_ text: String, symbol: String, page: Int) throws -> [Row] {
        let values = try payload(text, prefix: "v_detail_data_\(symbol)=")
        guard let index = values[0] as? Int, index == page, let records = values[1] as? String else {
            throw StockVolumeError.invalidResponse
        }
        return try records.split(separator: "|").compactMap { record in
            let f = record.split(separator: "/", omittingEmptySubsequences: false)
            guard f.count == 7, let id = Int(f[0]),
                  let price = Double(f[2]), price.isFinite, price > 0,
                  let hands = Double(f[4]), hands.isFinite, hands > 0,
                  let amount = Double(f[5]), amount.isFinite, amount >= 0 else {
                throw StockVolumeError.invalidResponse
            }
            let side: Int
            switch f[6] {
            case "B": side = 2
            case "S": side = 1
            case "M": side = 4
            default: throw StockVolumeError.invalidResponse
            }
            // Tencent timestamps can report the closing print seconds after 11:30 / 15:00.
            // Still validate the full time before allowing those session-end records.
            let parts = f[1].split(separator: ":")
            guard f[1].count == 8, parts.count == 3, let seconds = Int(parts[2]), (0...59).contains(seconds) else {
                throw StockVolumeError.invalidResponse
            }
            let slot: Int?
            if f[1].hasPrefix("11:30:") { slot = 120 }
            else if f[1].hasPrefix("15:00:") { slot = 240 }
            else { slot = StockVolumeService.detailSlot(f[1]) }
            guard let slot else { return nil }
            return Row(id: id, trade: StockVolumeTrade(slot: slot, hands: hands, estimatedAmount: amount, side: side))
        }
    }

    private func page(symbol: String, index: Int) async throws -> [Row] {
        let text = try await request(symbol: symbol, action: "data", page: index)
        return try Self.parsePage(text, symbol: symbol, page: index)
    }

    func fetchDetails(symbol: String) async throws -> (day: String, trades: [StockVolumeTrade]) {
        let info = try Self.parseInfo(try await request(symbol: symbol, action: "info"), symbol: symbol)
        if cachedSymbol != symbol || cachedDay != info.day {
            cachedPages = [:]
            cachedSymbol = symbol
            cachedDay = info.day
        }
        var pages = cachedPages.filter { $0.key < info.pages - 1 }
        let missing = (0..<info.pages).filter { pages[$0] == nil }
        try await withThrowingTaskGroup(of: (Int, [Row]).self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<min(4, missing.count) {
                if let index = iterator.next() {
                    group.addTask { (index, try await self.page(symbol: symbol, index: index)) }
                }
            }
            while let (index, rows) = try await group.next() {
                pages[index] = rows
                if let next = iterator.next() {
                    group.addTask { (next, try await self.page(symbol: symbol, index: next)) }
                }
            }
        }
        try Task.checkCancellation()
        cachedPages = pages.filter { $0.key < info.pages - 1 }
        var trades: [Int: StockVolumeTrade] = [:]
        for index in 0..<info.pages {
            for row in pages[index] ?? [] {
                if let previous = trades[row.id], previous != row.trade { throw StockVolumeError.invalidResponse }
                trades[row.id] = row.trade
            }
        }
        guard !trades.isEmpty else { throw StockVolumeError.noTrades }
        return (info.day, trades.keys.sorted().compactMap { trades[$0] })
    }

    func fetchMinutes(symbol: String) async throws -> (day: String, volumes: [Int: Double]) {
        var url = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query")!
        url.queryItems = [URLQueryItem(name: "code", value: symbol)]
        let data = try await http.fetchData(url: url.url!, headers: ["Referer": "https://gu.qq.com/"], timeout: 15)
        return try Self.parseMinutes(data, symbol: symbol)
    }

    static func parseMinutes(_ data: Data, symbol: String) throws -> (day: String, volumes: [Int: Double]) {
        struct Response: Decodable {
            struct Stock: Decodable {
                struct Series: Decodable { let date: String; let data: [String] }
                let data: Series
            }
            let data: [String: Stock]
        }
        guard let series = try JSONDecoder().decode(Response.self, from: data).data[symbol]?.data else {
            throw StockVolumeError.invalidResponse
        }
        let date = try day(series.date)
        var cumulativeBySlot: [Int: Double] = [:]
        for row in series.data {
            let f = row.split(separator: " ")
            guard f.count >= 3, f[0].count == 4,
                  let h = Int(f[0].prefix(2)), let m = Int(f[0].suffix(2)),
                  (0...23).contains(h), (0...59).contains(m),
                  let cumulative = Double(f[2]), cumulative.isFinite, cumulative >= 0 else {
                throw StockVolumeError.invalidResponse
            }
            // Tencent also returns 13:00 and post-market points; keep the regular-session axis.
            guard let slot = ETFTime.slot(hour: h, minute: m) else { continue }
            cumulativeBySlot[slot] = cumulative
        }
        var volumes: [Int: Double] = [:]
        var previous: Double = 0
        var previousSlot = -1
        for slot in cumulativeBySlot.keys.sorted() {
            let cumulative = cumulativeBySlot[slot]!
            guard cumulative >= previous else { throw StockVolumeError.invalidResponse }
            // A missing minute cannot be reconstructed by assigning its volume to the next one.
            if slot == previousSlot + 1 { volumes[slot] = cumulative - previous }
            previous = cumulative
            previousSlot = slot
        }
        guard !volumes.isEmpty else { throw StockVolumeError.noTrades }
        return (date, volumes)
    }
}
