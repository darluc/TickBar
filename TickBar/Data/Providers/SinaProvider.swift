import Foundation

/// 新浪财经 hq.sinajs.cn 接口实现。
/// 提供美股盘前 / 盘后报价；不将盘后报价作为 24h 夜盘数据。
struct SinaProvider: QuoteProvider {
    let id = "sina"
    let supportedMarkets: Set<Market> = [.us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient
    private let clock = MarketClock()

    init(http: HTTPClient = SinaProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        HTTPClient(
            defaultHeaders: [
                "Referer": "https://finance.sina.com.cn",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let us = symbols.filter { $0.market == .us }
        guard !us.isEmpty else { return [:] }

        let listParam = us.map { "gb_" + $0.code.lowercased() }.joined(separator: ",")
        guard let url = URL(string: "https://hq.sinajs.cn/list=" + listParam) else {
            throw ProviderError.empty
        }

        let text = try await http.fetchString(url: url, encoding: GBKDecoder.encoding)
        return parse(text, symbols: us)
    }

    func parse(_ text: String, symbols: [SymbolID], at now: Date = Date()) -> [SymbolID: Quote] {
        let symbolMap = Dictionary(symbols.map { ($0.code.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SymbolID: Quote] = [:]
        let currentSession = clock.usExtendedSession(at: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Market.us.timeZone
        formatter.dateFormat = "MMM dd hh:mma zzz yyyy"

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("var hq_str_gb_") else { continue }
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }

            let prefix = "var hq_str_gb_"
            let codeEnd = eqIdx
            let code = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: prefix.count)..<codeEnd]).uppercased()
            guard let symbolID = symbolMap[code] else { continue }

            let valuePart = trimmed[trimmed.index(after: eqIdx)...]
            let stripped = valuePart.trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
            let fields = stripped.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 27 else { continue }
            let extendedTime: Date?
            if fields.count > 29 {
                extendedTime = formatter.date(from: fields[24] + " " + fields[29])
            } else {
                extendedTime = nil
            }

            let name = fields[0]
            guard let regularPrice = Decimal(string: fields[1]), regularPrice > 0 else { continue }
            let prevClose = Decimal(string: fields[26]) ?? regularPrice
            let open = Decimal(string: fields[5])
            let high = Decimal(string: fields[6])
            let low = Decimal(string: fields[7])
            let volume = Decimal(string: fields[10])

            var extPrice: Decimal?
            var extChange: Decimal?
            var extPct: Double?
            var extSession: ExtendedSession?

            if let currentSession, currentSession != .overnight,
               clock.isCurrentUSExtendedTrade(extendedTime, session: currentSession, at: now),
               let liveExt = Decimal(string: fields[21]),
               liveExt > 0 {
                extSession = currentSession
                extPrice = liveExt
                if let changeVal = Decimal(string: fields[23]) {
                    extChange = changeVal
                } else {
                    extChange = liveExt - regularPrice
                }
                if let pctVal = Double(fields[22]) {
                    extPct = pctVal / 100.0
                } else if regularPrice > 0 {
                    extPct = ((liveExt - regularPrice) as NSDecimalNumber).doubleValue / (regularPrice as NSDecimalNumber).doubleValue
                }
            }

            result[symbolID] = Quote(
                symbol: symbolID,
                name: name.isEmpty ? symbolID.code : name,
                price: regularPrice,
                prevClose: prevClose,
                open: open,
                high: high,
                low: low,
                volume: volume,
                currency: .usd,
                timestamp: extSession != nil ? (extendedTime ?? .distantPast) : .distantPast,
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
