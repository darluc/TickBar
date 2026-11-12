import Foundation

/// 币安 Binance 官方加密货币实时行情 Provider。
/// 全球无地域限制节点 (data-api.binance.vision / api.binance.us)，7x24 小时实时行情。
struct BinanceProvider: QuoteProvider {
    let id = "binance"
    let supportedMarkets: Set<Market> = [.crypto]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient

    init(http: HTTPClient = BinanceProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return HTTPClient(
            session: .shared,
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let cryptoSymbols = symbols.filter { $0.market == .crypto }
        guard !cryptoSymbols.isEmpty else { return [:] }

        // 将 symbols 格式化为 Binance 标准交易对 (如 BTC -> BTCUSDT)
        let pairs: [(SymbolID, String)] = cryptoSymbols.map { sid in
            (sid, normalizePair(sid.code))
        }

        // 分组批量拉取 24hr ticker 数据
        let chunks = pairs.chunked(by: 20)
        var result: [SymbolID: Quote] = [:]

        for chunk in chunks {
            let chunkQuotes = await fetchTickerBatch(chunk)
            result.merge(chunkQuotes) { _, new in new }
        }

        // 为成功获取行情的标的并发拉取 15m K线走势 (Sparkline)
        if !result.isEmpty {
            await withTaskGroup(of: (SymbolID, [Double]?).self) { group in
                for (sym, q) in result {
                    let pair = normalizePair(sym.code)
                    group.addTask {
                        (sym, await self.fetchKlines(pair))
                    }
                }
                for await (sym, klines) in group {
                    if let klines, let existing = result[sym] {
                        result[sym] = Quote(
                            symbol: existing.symbol,
                            name: existing.name,
                            price: existing.price,
                            prevClose: existing.prevClose,
                            open: existing.open,
                            high: existing.high,
                            low: existing.low,
                            volume: existing.volume,
                            currency: existing.currency,
                            timestamp: existing.timestamp,
                            isClosed: false,
                            sparklineHistory: klines
                        )
                    }
                }
            }
        }

        if result.isEmpty {
            throw ProviderError.empty
        }
        return result
    }

    private func fetchTickerBatch(_ items: [(SymbolID, String)]) async -> [SymbolID: Quote] {
        let pairList = items.map { "\"\($0.1)\"" }.joined(separator: ",")
        let encodedSymbols = "[\(pairList)]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        let hosts = ["data-api.binance.vision", "api.binance.us"]
        for host in hosts {
            let urlString = "https://\(host)/api/v3/ticker/24hr?symbols=\(encodedSymbols)"
            guard let url = URL(string: urlString) else { continue }

            do {
                let data = try await http.fetchData(url: url, timeout: 6)
                let parsed = parseBatch(data, items: items)
                if !parsed.isEmpty {
                    return parsed
                }
            } catch {
                Log.quote.warning("Binance ticker failed on \(host, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return [:]
    }

    private func parseBatch(_ data: Data, items: [(SymbolID, String)]) -> [SymbolID: Quote] {
        struct TickerItem: Decodable {
            let symbol: String?
            let lastPrice: String?
            let prevClosePrice: String?
            let openPrice: String?
            let highPrice: String?
            let lowPrice: String?
            let volume: String?
            let priceChange: String?
            let priceChangePercent: String?
        }

        guard let list = try? JSONDecoder().decode([TickerItem].self, from: data) else { return [:] }

        var map: [String: TickerItem] = [:]
        for it in list {
            if let sym = it.symbol { map[sym.uppercased()] = it }
        }

        var out: [SymbolID: Quote] = [:]
        for (sid, pair) in items {
            guard let it = map[pair.uppercased()] else { continue }
            guard let price = parseDecimal(it.lastPrice) else { continue }
            let prevClose = parseDecimal(it.prevClosePrice) ?? price
            let open = parseDecimal(it.openPrice)
            let high = parseDecimal(it.highPrice)
            let low = parseDecimal(it.lowPrice)
            let volume = parseDecimal(it.volume)

            // 名称优先展示简短币种名，例如 BTC/USDT -> BTC
            let baseName = formatBaseName(pair)

            out[sid] = Quote(
                symbol: sid,
                name: baseName,
                price: price,
                prevClose: prevClose > 0 ? prevClose : price,
                open: open,
                high: high,
                low: low,
                volume: volume,
                currency: .usd,
                timestamp: Date(),
                isClosed: false
            )
        }
        return out
    }

    /// 拉取 15m K线作为分时 Sparkline
    private func fetchKlines(_ pair: String) async -> [Double]? {
        let hosts = ["data-api.binance.vision", "api.binance.us"]
        for host in hosts {
            guard let url = URL(string: "https://\(host)/api/v3/klines?symbol=\(pair)&interval=15m&limit=30") else { continue }
            do {
                let data = try await http.fetchData(url: url, timeout: 5)
                guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { continue }
                let closes: [Double] = jsonArray.compactMap { row in
                    guard row.count > 4, let str = row[4] as? String else { return nil }
                    return Double(str)
                }
                if closes.count >= 2 { return closes }
            } catch {
                continue
            }
        }
        return nil
    }

    private func normalizePair(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.hasSuffix("USDT") || upper.hasSuffix("BUSD") || upper.hasSuffix("USDC") || upper.hasSuffix("BTC") {
            return upper
        }
        return "\(upper)USDT"
    }

    private func formatBaseName(_ pair: String) -> String {
        let upper = pair.uppercased()
        for quote in ["USDT", "BUSD", "USDC", "FDUSD"] {
            if upper.hasSuffix(quote) {
                return String(upper.dropLast(quote.count))
            }
        }
        return upper
    }

    private func parseDecimal(_ str: String?) -> Decimal? {
        guard let str, !str.isEmpty else { return nil }
        return Decimal(string: str.trimmingCharacters(in: .whitespacesAndNewlines))
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
