import Foundation

/// Robinhood 实时行情接口。
/// bounds=24_5 包含 BOATS / Bruce 夜盘成交；仍须校验成交属于当前时段。
struct RobinhoodProvider: QuoteProvider {
    let id = "robinhood"
    let supportedMarkets: Set<Market> = [.us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient
    private let clock = MarketClock()

    init(http: HTTPClient = RobinhoodProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return HTTPClient(
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let us = symbols.filter { $0.market == .us }
        guard !us.isEmpty else { return [:] }

        var components = URLComponents(string: "https://api.robinhood.com/marketdata/quotes/")!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: us.map { $0.code.uppercased() }.joined(separator: ",")),
            URLQueryItem(name: "bounds", value: "24_5")
        ]
        guard let url = components.url else { throw ProviderError.empty }
        let data = try await http.fetchData(url: url, timeout: 8)
        return try parseBatch(data, symbols: us)
    }

    private struct Response: Decodable {
        let symbol: String?
        let last_trade_price: String?
        let last_extended_hours_trade_price: String?
        let last_non_reg_trade_price: String?
        let previous_close: String?
        let adjusted_previous_close: String?
        let venue_last_trade_time: String?
        let venue_last_non_reg_trade_time: String?
    }

    func parseBatch(_ data: Data, symbols: [SymbolID], at now: Date = Date()) throws -> [SymbolID: Quote] {
        struct Batch: Decodable { let results: [Response?] }
        let batch = try JSONDecoder().decode(Batch.self, from: data)
        let requested = Dictionary(symbols.map { ($0.code.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var quotes: [SymbolID: Quote] = [:]
        for response in batch.results.compactMap({ $0 }) {
            guard let code = response.symbol, let symbol = requested[code.uppercased()],
                  let quote = parse(response, symbol: symbol, at: now) else { continue }
            quotes[symbol] = quote
        }
        return quotes
    }

    func parse(_ data: Data, symbol: SymbolID, at now: Date = Date()) throws -> Quote? {
        parse(try JSONDecoder().decode(Response.self, from: data), symbol: symbol, at: now)
    }

    private func parse(_ resp: Response, symbol: SymbolID, at now: Date) -> Quote? {
        guard let regPrice = decimal(resp.last_trade_price), regPrice > 0 else { return nil }
        let prevClose = decimal(resp.previous_close) ?? decimal(resp.adjusted_previous_close) ?? regPrice

        // 判断当前处于哪个时段
        let currentSession = clock.usExtendedSession(at: now)
        func tradeDate(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        let extendedTime = tradeDate(resp.venue_last_non_reg_trade_time)
        let nonRegPrice = decimal(resp.last_non_reg_trade_price) ?? decimal(resp.last_extended_hours_trade_price)
        // 夜盘 / 盘前的 previous_close 是最近一次常规收盘；NLS last_trade_price 可能与正式收盘不同。
        let extendedBaseline = currentSession == .overnight || currentSession == .preMarket ? prevClose : regPrice

        var extPrice: Decimal?
        var extChange: Decimal?
        var extPct: Double?
        var extSession: ExtendedSession?

        if let currentSession, let live = nonRegPrice, live > 0,
           clock.isCurrentUSExtendedTrade(extendedTime, session: currentSession, at: now) {
            extSession = currentSession
            extPrice = live
            extChange = live - extendedBaseline
            if extendedBaseline > 0 {
                extPct = ((live - extendedBaseline) as NSDecimalNumber).doubleValue / (extendedBaseline as NSDecimalNumber).doubleValue
            }
        }

        return Quote(
            symbol: symbol,
            name: symbol.code,
            price: regPrice,
            prevClose: prevClose,
            currency: .usd,
            timestamp: (extSession != nil ? extendedTime : tradeDate(resp.venue_last_trade_time)) ?? .distantPast,
            isClosed: currentSession != nil,
            extendedPrice: extPrice,
            extendedChange: extChange,
            extendedChangePct: extPct,
            extendedSession: extSession
        )
    }

    private func decimal(_ str: String?) -> Decimal? {
        guard let str, !str.isEmpty else { return nil }
        return Decimal(string: str.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
