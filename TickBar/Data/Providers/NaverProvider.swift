import Foundation

/// 韩国 Naver 财经行情接口实现。
/// 支持韩国主板 (KOSPI)、创业板 (KOSDAQ) 和 KONEX 行情。
struct NaverProvider: QuoteProvider {
    let id = "naver"
    let supportedMarkets: Set<Market> = [.kr]
    var supportsExtendedHours: Bool { false }

    let http: HTTPClient

    init(http: HTTPClient = NaverProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return HTTPClient(
            session: .shared,
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json",
                "Referer": "https://m.stock.naver.com/"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let krSymbols = symbols.filter { $0.market == .kr }
        guard !krSymbols.isEmpty else { return [:] }

        let chunks = krSymbols.chunked(by: 20)
        var result: [SymbolID: Quote] = [:]

        for chunk in chunks {
            let chunkQuotes = await fetchBatch(chunk)
            result.merge(chunkQuotes) { _, new in new }
        }

        // 针对未通过批量接口返回的标的，通过单股 basic 接口单独兜底
        let missing = krSymbols.filter { result[$0] == nil }
        if !missing.isEmpty {
            await withTaskGroup(of: (SymbolID, Quote?).self) { group in
                for s in missing {
                    group.addTask {
                        (s, try? await self.fetchSingle(s))
                    }
                }
                for await (sym, q) in group {
                    if let q { result[sym] = q }
                }
            }
        }

        if result.isEmpty {
            throw ProviderError.empty
        }
        return result
    }

    /// 批量拉取实时行情接口
    private func fetchBatch(_ symbols: [SymbolID]) async -> [SymbolID: Quote] {
        let codes = symbols.map(\.code).joined(separator: ",")
        guard let url = URL(string: "https://polling.finance.naver.com/api/realtime/domestic/stock/\(codes)") else { return [:] }

        do {
            let data = try await http.fetchData(url: url, timeout: 6)
            return parseBatch(data)
        } catch {
            Log.quote.warning("Naver polling failed for [\(codes, privacy: .public)]: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func parseBatch(_ data: Data) -> [SymbolID: Quote] {
        struct PollingResp: Decodable {
            struct Item: Decodable {
                let itemCode: String?
                let stockName: String?
                let closePriceRaw: String?
                let compareToPreviousClosePriceRaw: String?
                let openPriceRaw: String?
                let highPriceRaw: String?
                let lowPriceRaw: String?
                let accumulatedTradingVolumeRaw: String?
                let marketStatus: String?
                let localTradedAt: String?
            }
            let datas: [Item]?
        }

        guard let resp = try? JSONDecoder().decode(PollingResp.self, from: data),
              let list = resp.datas else { return [:] }

        var out: [SymbolID: Quote] = [:]
        for it in list {
            guard let code = it.itemCode, !code.isEmpty else { continue }
            let sym = SymbolID(code: code, market: .kr)
            guard let price = parseDecimal(it.closePriceRaw) else { continue }
            let change = parseDecimal(it.compareToPreviousClosePriceRaw) ?? 0
            let prevClose = price - change

            let open = parseDecimal(it.openPriceRaw)
            let high = parseDecimal(it.highPriceRaw)
            let low = parseDecimal(it.lowPriceRaw)
            let vol = parseDecimal(it.accumulatedTradingVolumeRaw)

            let isClosed = (it.marketStatus ?? "").uppercased() != "OPEN"
            let name = (it.stockName?.isEmpty == false) ? it.stockName! : code

            out[sym] = Quote(
                symbol: sym,
                name: name,
                price: price,
                prevClose: prevClose > 0 ? prevClose : price,
                open: open,
                high: high,
                low: low,
                volume: vol,
                currency: .krw,
                timestamp: Date(),
                isClosed: isClosed
            )
        }
        return out
    }

    /// 单标的 basic 接口兜底
    private func fetchSingle(_ symbol: SymbolID) async throws -> Quote? {
        guard let url = URL(string: "https://m.stock.naver.com/api/stock/\(symbol.code)/basic") else { return nil }
        let data = try await http.fetchData(url: url, timeout: 6)

        struct BasicResp: Decodable {
            let itemCode: String?
            let stockName: String?
            let closePrice: String?
            let compareToPreviousClosePrice: String?
            let marketStatus: String?
        }

        guard let r = try? JSONDecoder().decode(BasicResp.self, from: data) else { return nil }
        guard let price = parseDecimal(r.closePrice) else { return nil }
        let change = parseDecimal(r.compareToPreviousClosePrice) ?? 0
        let prevClose = price - change
        let name = (r.stockName?.isEmpty == false) ? r.stockName! : symbol.code
        let isClosed = (r.marketStatus ?? "").uppercased() != "OPEN"

        return Quote(
            symbol: symbol,
            name: name,
            price: price,
            prevClose: prevClose > 0 ? prevClose : price,
            currency: .krw,
            timestamp: Date(),
            isClosed: isClosed
        )
    }

    private func parseDecimal(_ raw: String?) -> Decimal? {
        guard var s = raw, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: s)
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
