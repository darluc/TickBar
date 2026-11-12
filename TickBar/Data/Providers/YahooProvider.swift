import Foundation

/// 常规行情 / 走势使用 v8 chart；美股扩展报价使用带成交时间的 v7 quote。
/// chart 不包含可靠夜盘成交，不能将 fulldayPrice 或末根 K 线当作夜盘。
struct YahooProvider: QuoteProvider {
    let id = "yahoo"
    let supportedMarkets: Set<Market> = [.a, .hk, .us, .kr]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient
    private let quoteAPI: YahooQuoteAPI

    init(http: HTTPClient = YahooProvider.makeHTTP()) {
        self.http = http
        self.quoteAPI = YahooQuoteAPI(http: http)
    }

    /// 保留浏览器 UA，动态跟随 NetworkConfig，代理切换后 Cookie / crumb 也重新获取。
    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return HTTPClient(
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json",
                "Referer": "https://finance.yahoo.com/"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        guard !symbols.isEmpty else { return [:] }

        var result: [SymbolID: Quote] = [:]
        var quoteError: Error?
        let extendedSymbols = MarketClock().usExtendedSession() == nil ? [] : symbols.filter { $0.market == .us }
        if !extendedSymbols.isEmpty {
            do {
                let data = try await quoteAPI.fetch(extendedSymbols)
                result = try Self.parseQuotes(data, symbols: extendedSymbols)
            } catch {
                quoteError = error
            }
        }
        // 夜盘不能 fallback 到无夜盘成交时间的 chart；其它市场仍使用原有走势接口。
        let chunks = symbols.filter { !extendedSymbols.contains($0) }.chunked(by: 8)
        for chunk in chunks {
            let pairs = try await withThrowingTaskGroup(of: (SymbolID, Quote?).self) { group in
                for s in chunk {
                    group.addTask {
                        do {
                            return (s, try await self.fetchOne(s))
                        } catch {
                            Log.quote.warning("yahoo \(s.code, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                            return (s, nil)
                        }
                    }
                }
                var out: [(SymbolID, Quote)] = []
                for try await (s, q) in group {
                    if let q = q { out.append((s, q)) }
                }
                return out
            }
            for (s, q) in pairs {
                result[s] = q
            }
        }
        if result.isEmpty {
            throw quoteError ?? ProviderError.empty
        }
        return result
    }

    private func fetchOne(_ symbol: SymbolID) async throws -> Quote? {
        guard let yahooCode = SymbolEncoder.yahoo(symbol) else { return nil }
        guard let escaped = yahooCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }

        // includePrePost=true 仅覆盖盘前、常规盘与盘后，不包含可靠的夜盘成交。
        let hosts = ["query2.finance.yahoo.com", "query1.finance.yahoo.com"]
        var lastError: Error?
        for host in hosts {
            let url = URL(string: "https://\(host)/v8/finance/chart/\(escaped)?range=1d&interval=5m&includePrePost=true")!
            do {
                let data = try await http.fetchData(url: url, timeout: 12)
                if let quote = try parse(data, symbol: symbol) {
                    Log.quote.info("yahoo \(symbol.code, privacy: .public) session=\(quote.extendedSession?.rawValue ?? "nil", privacy: .public) ext=\(quote.extendedPrice.map { "\($0)" } ?? "nil", privacy: .public) last=\(quote.price, privacy: .public)")
                    return quote
                }
            } catch {
                lastError = error
                Log.quote.warning("yahoo \(host, privacy: .public) \(symbol.code, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    static func parseQuotes(_ data: Data, symbols: [SymbolID], at now: Date = Date()) throws -> [SymbolID: Quote] {
        struct Response: Decodable {
            let quoteResponse: QuoteResponse
            struct QuoteResponse: Decodable { let result: [Snapshot]? }
            struct Snapshot: Decodable {
                let symbol: String
                let longName: String?
                let shortName: String?
                let currency: String?
                let regularMarketPrice: Double?
                let regularMarketPreviousClose: Double?
                let regularMarketTime: Double?
                let regularMarketOpen: Double?
                let regularMarketDayHigh: Double?
                let regularMarketDayLow: Double?
                let regularMarketVolume: Double?
                let preMarketPrice: Double?
                let preMarketTime: Double?
                let postMarketPrice: Double?
                let postMarketTime: Double?
                let overnightMarketPrice: Double?
                let overnightMarketTime: Double?
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let requested = Dictionary(symbols.map { ($0.code.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let clock = MarketClock()
        let session = clock.usExtendedSession(at: now)
        var result: [SymbolID: Quote] = [:]
        for item in response.quoteResponse.result ?? [] {
            guard let symbol = requested[item.symbol.uppercased()],
                  let price = item.regularMarketPrice, price > 0 else { continue }
            let extended: (price: Double?, time: Double?)
            switch session {
            case .preMarket: extended = (item.preMarketPrice, item.preMarketTime)
            case .postMarket: extended = (item.postMarketPrice, item.postMarketTime)
            case .overnight: extended = (item.overnightMarketPrice, item.overnightMarketTime)
            default: extended = (nil, nil)
            }
            let tradeTime = extended.time.map { Date(timeIntervalSince1970: $0) }
            let valid = session.map { clock.isCurrentUSExtendedTrade(tradeTime, session: $0, at: now) } == true
                && (extended.price ?? 0) > 0
            let extendedPrice = valid ? extended.price.map { Decimal($0) } : nil
            let change = extendedPrice.map { $0 - Decimal(price) }
            let regularTime = item.regularMarketTime.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let timestamp = valid ? (tradeTime ?? regularTime) : regularTime
            result[symbol] = Quote(
                symbol: symbol, name: item.longName ?? item.shortName ?? symbol.code,
                price: Decimal(price), prevClose: Decimal(item.regularMarketPreviousClose ?? price),
                open: item.regularMarketOpen.map { Decimal($0) },
                high: item.regularMarketDayHigh.map { Decimal($0) },
                low: item.regularMarketDayLow.map { Decimal($0) },
                volume: item.regularMarketVolume.map { Decimal($0) },
                currency: Currency(rawValue: item.currency ?? "") ?? .usd,
                timestamp: timestamp,
                isClosed: session != nil,
                extendedPrice: extendedPrice, extendedChange: change,
                extendedChangePct: change.map { ($0 as NSDecimalNumber).doubleValue / price },
                extendedSession: valid ? session : nil
            )
        }
        return result
    }

    private func parse(_ data: Data, symbol: SymbolID) throws -> Quote? {
        struct Resp: Decodable {
            let chart: Chart
            struct Chart: Decodable {
                let result: [Result]?
            }
            struct Result: Decodable {
                let meta: Meta
                let timestamp: [Int]?
                let indicators: Indicators?
            }
            struct Indicators: Decodable {
                let quote: [QuoteObj]?
            }
            struct QuoteObj: Decodable {
                let close: [Double?]?
            }
            struct Meta: Decodable {
                let currency: String?
                let regularMarketPrice: Double?
                let previousClose: Double?
                let chartPreviousClose: Double?
                let regularMarketDayHigh: Double?
                let regularMarketDayLow: Double?
                let regularMarketVolume: Double?
                let longName: String?
                let shortName: String?
                let preMarketPrice: Double?
                let preMarketChange: Double?
                let preMarketChangePercent: Double?
                let postMarketPrice: Double?
                let postMarketChange: Double?
                let postMarketChangePercent: Double?
                let fulldayPrice: Double?
                let fulldayChange: Double?
                let fulldayChangePercent: Double?
                let currentTradingPeriod: TradingPeriodContainer?
            }
            struct TradingPeriodContainer: Decodable {
                let pre: Period?
                let regular: Period?
                let post: Period?
            }
            struct Period: Decodable {
                let start: Int?
                let end: Int?
            }
        }

        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let firstResult = resp.chart.result?.first else { return nil }
        let meta = firstResult.meta
        guard let regPrice = meta.regularMarketPrice ?? meta.fulldayPrice else { return nil }
        let prevClose = meta.previousClose ?? meta.chartPreviousClose ?? regPrice
        let currency = Currency(rawValue: meta.currency ?? "") ?? symbol.market.defaultCurrency

        // 提取全天分时(含盘前盘后)走势,末根常是当前扩展时段最新价
        var sparklinePts: [Double] = []
        var sparklineTimestamps: [Date] = []
        if let closes = firstResult.indicators?.quote?.first?.close {
            for (index, close) in closes.enumerated() {
                guard let close else { continue }
                sparklinePts.append(close)
                if let timestamps = firstResult.timestamp, index < timestamps.count {
                    sparklineTimestamps.append(Date(timeIntervalSince1970: TimeInterval(timestamps[index])))
                }
            }
        }
        let lastTrade = sparklinePts.last

        // 解析 24h 及美股盘前 / 盘后当前时段。
        // chart meta 通常没有 preMarketPrice,用 fulldayPrice / 末根 K 线;涨跌相对上一笔常规收盘。
        var extSession: ExtendedSession?
        var extPrice: Decimal?
        var extChange: Decimal?
        var extChangePct: Double?

        let nowSec = Int(Date().timeIntervalSince1970)
        let periods = meta.currentTradingPeriod
        let lastRegular = Decimal(regPrice)

        func applyExtended(
            _ session: ExtendedSession,
            price: Double?,
            change: Double?,
            changePct: Double?
        ) {
            // Chart 接口没有可靠的夜盘成交时间；不能用上一交易日末根 K 线冒充夜盘。
            guard session != .overnight,
                  MarketClock().isCurrentUSExtendedTrade(sparklineTimestamps.last, session: session) else { return }
            let raw = price ?? lastTrade
            guard let raw, raw > 0 else { return }
            extSession = session
            extPrice = Decimal(raw)
            if let change {
                extChange = Decimal(change)
            } else {
                extChange = Decimal(raw) - lastRegular
            }
            if let changePct {
                extChangePct = changePct / 100.0
            } else if lastRegular > 0 {
                extChangePct = ((Decimal(raw) - lastRegular) as NSDecimalNumber).doubleValue
                    / (lastRegular as NSDecimalNumber).doubleValue
            }
        }

        if let pre = periods?.pre, let s = pre.start, let e = pre.end, nowSec >= s && nowSec < e {
            applyExtended(
                .preMarket,
                price: meta.preMarketPrice ?? meta.fulldayPrice,
                change: meta.preMarketChange ?? meta.fulldayChange,
                changePct: meta.preMarketChangePercent ?? meta.fulldayChangePercent
            )
        } else if let post = periods?.post, let s = post.start, let e = post.end, nowSec >= s && nowSec < e {
            applyExtended(
                .postMarket,
                price: meta.postMarketPrice ?? meta.fulldayPrice,
                change: meta.postMarketChange ?? meta.fulldayChange,
                changePct: meta.postMarketChangePercent ?? meta.fulldayChangePercent
            )
        } else if let reg = periods?.regular, let s = reg.start, let e = reg.end, nowSec >= s && nowSec <= e {
            extSession = .regular
        } else if symbol.market == .us {
            applyExtended(
                .overnight,
                price: meta.fulldayPrice,
                change: meta.fulldayChange,
                changePct: meta.fulldayChangePercent
            )
        }

        return Quote(
            symbol: symbol,
            name: meta.longName ?? meta.shortName ?? symbol.code,
            price: Decimal(regPrice),
            prevClose: Decimal(prevClose),
            open: nil,
            high: meta.regularMarketDayHigh.map { Decimal($0) },
            low: meta.regularMarketDayLow.map { Decimal($0) },
            volume: meta.regularMarketVolume.map { Decimal($0) },
            currency: currency,
            timestamp: sparklineTimestamps.last ?? .distantPast,
            isClosed: false,
            extendedPrice: extPrice,
            extendedChange: extChange,
            extendedChangePct: extChangePct,
            extendedSession: extSession,
            sparklineHistory: sparklinePts.isEmpty ? nil : sparklinePts,
            sparklineTimestamps: !sparklineTimestamps.isEmpty && sparklineTimestamps.count == sparklinePts.count
                ? sparklineTimestamps : nil
        )
    }
}

/// 匿名 Cookie 与 crumb 必须来自同一网络 session；401 时重新获取一次。
private actor YahooQuoteAPI {
    private let http: HTTPClient
    private var authenticatedSession: URLSession?
    private var crumb: String?

    init(http: HTTPClient) { self.http = http }

    func fetch(_ symbols: [SymbolID]) async throws -> Data {
        let session = http.session
        let client = HTTPClient(session: session, defaultHeaders: http.defaultHeaders)
        if authenticatedSession !== session {
            crumb = nil
            authenticatedSession = session
        }
        for attempt in 0..<2 {
            if crumb == nil {
                // fc.yahoo.com 正常返回 404，但同时通过 Set-Cookie 发匿名授权 Cookie。
                do {
                    _ = try await client.fetchData(url: URL(string: "https://fc.yahoo.com")!, timeout: 8)
                } catch HTTPError.badStatus(404) {
                    // 仅忽略预期的 404；连接失败 / 其它状态仍由上层报告。
                } catch {
                    throw ProviderError.upstream("Yahoo cookie: \(error)")
                }
                let data: Data
                do {
                    data = try await client.fetchData(
                        url: URL(string: "https://query1.finance.yahoo.com/v1/test/getcrumb")!,
                        headers: ["Accept": "text/plain"], timeout: 8
                    )
                } catch {
                    throw ProviderError.upstream("Yahoo crumb: \(error)")
                }
                guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty, value.count < 128, !value.contains("<"), !value.contains("{") else {
                    throw ProviderError.upstream("Yahoo anonymous authorization failed")
                }
                crumb = value
            }
            var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote")!
            components.queryItems = [
                URLQueryItem(name: "symbols", value: symbols.map { $0.code.uppercased() }.joined(separator: ",")),
                URLQueryItem(name: "overnightPrice", value: "true"),
                URLQueryItem(name: "formatted", value: "false"),
                URLQueryItem(name: "crumb", value: crumb)
            ]
            guard let url = components.url else { throw ProviderError.empty }
            do {
                return try await client.fetchData(url: url, timeout: 8)
            } catch HTTPError.badStatus(401) where attempt == 0 {
                crumb = nil
            }
        }
        throw ProviderError.empty
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}
