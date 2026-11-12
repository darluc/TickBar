import Foundation

/// 雪球行情接口实现。
/// 批量提供常规、盘前盘后和部分标的夜盘字段；覆盖与及时性必须按成交时间校验。
struct XueqiuProvider: QuoteProvider {
    let id = "xueqiu"
    let supportedMarkets: Set<Market> = [.us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient
    private let clock = MarketClock()

    init(http: HTTPClient = XueqiuProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        HTTPClient(
            defaultHeaders: [
                "Referer": "https://xueqiu.com/",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ]
        )
    }

    private func ensureCookie() async {
        guard let url = URL(string: "https://xueqiu.com/hq") else { return }
        _ = try? await http.fetchData(url: url, timeout: 5)
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let us = symbols.filter { $0.market == .us }
        guard !us.isEmpty else { return [:] }

        await ensureCookie()

        let symList = us.map { $0.code.uppercased() }.joined(separator: ",")
        guard let url = URL(string: "https://stock.xueqiu.com/v5/stock/batch/quote.json?symbol=\(symList)&extend=detail") else {
            throw ProviderError.empty
        }

        do {
            let data = try await http.fetchData(url: url, timeout: 5)
            return try parse(data, symbols: us)
        } catch {
            // 如果遇到 cookie 失效，刷新 cookie 重试一次
            await ensureCookie()
            let data = try await http.fetchData(url: url, timeout: 5)
            return try parse(data, symbols: us)
        }
    }

    func parse(_ data: Data, symbols: [SymbolID], at now: Date = Date()) throws -> [SymbolID: Quote] {
        struct Resp: Decodable {
            let error_code: Int?
            let error_description: String?
            let data: DataBlock?
            struct DataBlock: Decodable {
                let items: [Item]?
            }
            struct Item: Decodable {
                let quote: QuoteBlock?
            }
            struct QuoteBlock: Decodable {
                let symbol: String?
                let name: String?
                let current: Double?
                let last_close: Double?
                let open: Double?
                let high: Double?
                let low: Double?
                let volume: Double?
                let timestamp: Double?
                let timestamp_ext: Double?
                let timestamp_night_session: Double?
                let current_ext: Double?
                let chg_ext: Double?
                let percent_ext: Double?
                let current_night_session: Double?
                let chg_night_session: Double?
                let percent_night_session: Double?
            }
        }

        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        if let code = decoded.error_code, code != 0 {
            throw ProviderError.upstream("Xueqiu \(code): \(decoded.error_description ?? "API error")")
        }
        let items = decoded.data?.items ?? []
        let symbolMap = Dictionary(symbols.map { ($0.code.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let currentSession = clock.usExtendedSession(at: now)
        func tradeDate(_ milliseconds: Double?) -> Date? {
            milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        var result: [SymbolID: Quote] = [:]

        for item in items {
            guard let q = item.quote,
                  let code = q.symbol?.uppercased(),
                  let symbolID = symbolMap[code],
                  let regPriceVal = q.current, regPriceVal > 0 else { continue }

            let regularPrice = Decimal(regPriceVal)
            let prevClose = Decimal(q.last_close ?? regPriceVal)
            let open = q.open.map { Decimal($0) }
            let high = q.high.map { Decimal($0) }
            let low = q.low.map { Decimal($0) }
            let volume = q.volume.map { Decimal($0) }

            var extPrice: Decimal?
            var extChange: Decimal?
            var extPct: Double?
            var extSession: ExtendedSession?
            var quoteTime = tradeDate(q.timestamp)

            if currentSession == .overnight, let night = q.current_night_session, night > 0,
               clock.isCurrentUSExtendedTrade(tradeDate(q.timestamp_night_session), session: .overnight, at: now) {
                extSession = .overnight
                quoteTime = tradeDate(q.timestamp_night_session)
                extPrice = Decimal(night)
                extChange = q.chg_night_session.map { Decimal($0) } ?? (Decimal(night) - regularPrice)
                extPct = (q.percent_night_session ?? 0) / 100.0
            } else if let session = currentSession, session != .overnight,
                      let ext = q.current_ext, ext > 0,
                      clock.isCurrentUSExtendedTrade(tradeDate(q.timestamp_ext), session: session, at: now) {
                extSession = session
                quoteTime = tradeDate(q.timestamp_ext)
                extPrice = Decimal(ext)
                extChange = q.chg_ext.map { Decimal($0) } ?? (Decimal(ext) - regularPrice)
                extPct = (q.percent_ext ?? 0) / 100.0
            }

            if currentSession == .overnight, extSession == nil {
                Log.quote.debug("xueqiu night unavailable symbol=\(code, privacy: .public) tradeTimeMs=\(q.timestamp_night_session ?? 0, privacy: .public)")
            }
            result[symbolID] = Quote(
                symbol: symbolID,
                name: q.name ?? symbolID.code,
                price: regularPrice,
                prevClose: prevClose,
                open: open,
                high: high,
                low: low,
                volume: volume,
                currency: .usd,
                timestamp: quoteTime ?? .distantPast,
                isClosed: currentSession != nil,
                extendedPrice: extPrice,
                extendedChange: extChange,
                extendedChangePct: extPct,
                extendedSession: extSession
            )
        }
        return result
    }
}
