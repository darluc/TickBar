import Foundation

/// Nasdaq 官方报价。URLSession 能通,且盘前走 primaryData(Yahoo chart 会被 CFNetwork 403)。
struct NasdaqProvider: QuoteProvider {
    let id = "nasdaq"
    let supportedMarkets: Set<Market> = [.us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient

    init(http: HTTPClient = NasdaqProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return HTTPClient(
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json,text/plain,*/*",
                "Accept-Language": "en-US,en;q=0.9"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let us = symbols.filter { $0.market == .us }
        guard !us.isEmpty else { return [:] }

        var out: [SymbolID: Quote] = [:]
        try await withThrowingTaskGroup(of: (SymbolID, Quote?).self) { group in
            for s in us {
                group.addTask {
                    do {
                        return (s, try await self.fetchOne(s))
                    } catch {
                        Log.quote.warning("nasdaq \(s.code, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                        return (s, nil)
                    }
                }
            }
            for try await (s, q) in group {
                if let q { out[s] = q }
            }
        }
        return out
    }

    private func fetchOne(_ symbol: SymbolID) async throws -> Quote? {
        let code = symbol.code.uppercased()
        guard let url = URL(string: "https://api.nasdaq.com/api/quote/\(code)/info?assetclass=stocks") else { return nil }
        let data = try await http.fetchData(url: url, headers: [
            "Referer": "https://www.nasdaq.com/market-activity/stocks/\(code.lowercased())"
        ], timeout: 4)
        return try parse(data, symbol: symbol)
    }

    private func parse(_ data: Data, symbol: SymbolID) throws -> Quote? {
        struct Resp: Decodable {
            let data: Block?
            struct Block: Decodable {
                let symbol: String?
                let companyName: String?
                let marketStatus: String?
                let primaryData: Tape?
                let secondaryData: Tape?
            }
            struct Tape: Decodable {
                let lastSalePrice: String?
                let netChange: String?
                let percentageChange: String?
                let lastTradeTimestamp: String?
                let isRealTime: Bool?
            }
        }

        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let block = resp.data else { return nil }
        let primary = block.primaryData
        let secondary = block.secondaryData
        guard let lastRegular = money(secondary?.lastSalePrice) ?? money(primary?.lastSalePrice) else { return nil }

        let status = (block.marketStatus ?? "").lowercased()
        var session: ExtendedSession?
        if status.contains("pre") {
            session = .preMarket
        } else if status.contains("after") {
            session = .postMarket
        } else if status.contains("open") {
            session = .regular
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Market.us.timeZone
        var tradeTime: Date?
        let rawTime = (primary?.lastTradeTimestamp ?? "").replacingOccurrences(of: "As of ", with: "")
        for format in ["MMM d, yyyy h:mm a zzz", "MMM d, yyyy h:mm:ss a zzz"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: rawTime) {
                tradeTime = parsed
                break
            }
        }
        if let extended = session, extended != .regular,
           !MarketClock().isCurrentUSExtendedTrade(tradeTime, session: extended) {
            session = nil
        }

        var extPrice: Decimal?
        var extChange: Decimal?
        var extPct: Double?
        if session != nil, session != .regular, let live = money(primary?.lastSalePrice) {
            extPrice = live
            extChange = money(primary?.netChange)
            extPct = percent(primary?.percentageChange)
            if extChange == nil, lastRegular > 0 {
                extChange = live - lastRegular
            }
            if extPct == nil, lastRegular > 0 {
                extPct = ((live - lastRegular) as NSDecimalNumber).doubleValue
                    / (lastRegular as NSDecimalNumber).doubleValue
            }
        }

        return Quote(
            symbol: symbol,
            name: block.companyName ?? symbol.code,
            price: lastRegular,
            prevClose: lastRegular,
            currency: .usd,
            timestamp: tradeTime ?? .distantPast,
            isClosed: session != .regular,
            extendedPrice: extPrice,
            extendedChange: extChange,
            extendedChangePct: extPct,
            extendedSession: session
        )
    }

    private func money(_ raw: String?) -> Decimal? {
        guard var s = raw, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: "+", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: s)
    }

    private func percent(_ raw: String?) -> Double? {
        guard var s = raw, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "%", with: "")
        s = s.replacingOccurrences(of: "+", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Double(s) else { return nil }
        return v / 100.0
    }
}
