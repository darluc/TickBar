import XCTest
@testable import TickBar

final class USExtendedQuoteTests: XCTestCase {
    private let symbol = SymbolID(code: "NVDA", market: .us)
    // Sunday 21:00 EST, after the overnight market opens.
    private let now = ISO8601DateFormatter().date(from: "2026-11-09T02:00:00Z")!

    func testSessionValidationRejectsFridayAndAcceptsSundayNight() {
        let clock = MarketClock()
        XCTAssertFalse(clock.isCurrentUSExtendedTrade(date("2026-11-07T00:59:59Z"), session: .overnight, at: now))
        XCTAssertTrue(clock.isCurrentUSExtendedTrade(date("2026-11-09T01:30:00Z"), session: .overnight, at: now))
        XCTAssertFalse(clock.isCurrentUSExtendedTrade(nil, session: .overnight, at: now))
        XCTAssertFalse(clock.isCurrentUSExtendedTrade(now.addingTimeInterval(120), session: .overnight, at: now))
        // The same overnight session crosses local midnight.
        XCTAssertTrue(clock.isCurrentUSExtendedTrade(now, session: .overnight, at: date("2026-11-09T06:00:00Z")))
    }

    func testXueqiuDoesNotRelabelPostMarketPriceAsOvernight() throws {
        let data = Data(#"{"data":{"items":[{"quote":{"symbol":"NVDA","current":186.64,"current_ext":188.70}}]}}"#.utf8)
        let quote = try XueqiuProvider().parse(data, symbols: [symbol], at: now)[symbol]
        XCTAssertNotNil(quote)
        XCTAssertEqual(quote?.isExtended, false)
    }

    func testXueqiuRequiresNightTradeTimestamp() throws {
        for timestamp in ["null", "1794013199000", "\(now.timeIntervalSince1970 * 1000)"] {
            let data = Data("""
            {"data":{"items":[{"quote":{"symbol":"NVDA","current":186.64,
            "current_night_session":190,"timestamp_night_session":\(timestamp)}}]}}
            """.utf8)
            let quote = try XueqiuProvider().parse(data, symbols: [symbol], at: now)[symbol]
            XCTAssertEqual(quote?.isExtended, timestamp == "\(now.timeIntervalSince1970 * 1000)")
        }
    }

    func testXueqiuAcceptsOnlyCurrentPreMarketTimestamp() throws {
        let preMarket = date("2026-11-09T10:00:00Z")
        let data = Data("""
        {"data":{"items":[{"quote":{"symbol":"NVDA","current":186.64,
        "current_ext":190,"timestamp_ext":\(preMarket.timeIntervalSince1970 * 1000)}}]}}
        """.utf8)
        let quote = try XueqiuProvider().parse(data, symbols: [symbol], at: preMarket)[symbol]
        XCTAssertEqual(quote?.extendedSession, .preMarket)
        XCTAssertEqual(quote?.timestamp, preMarket)
        let nextDay = preMarket.addingTimeInterval(86400)
        let stale = try XueqiuProvider().parse(data, symbols: [symbol], at: nextDay)[symbol]
        XCTAssertEqual(stale?.isExtended, false)
    }

    func testXueqiuBusinessErrorThrows() {
        XCTAssertThrowsError(try XueqiuProvider().parse(Data(#"{"error_code":400016}"#.utf8), symbols: [symbol], at: now))
    }

    func testRobinhoodRejectsFridayTradeAndKeepsActualTimestamp() throws {
        let data = Data(#"{"last_trade_price":"186.64","last_extended_hours_trade_price":"188.7001","venue_last_trade_time":"2026-11-06T20:59:59Z","venue_last_non_reg_trade_time":"2026-11-07T00:59:59.749781005Z"}"#.utf8)
        let quote = try RobinhoodProvider().parse(data, symbol: symbol, at: now)
        XCTAssertEqual(quote?.isExtended, false)
        XCTAssertEqual(quote?.timestamp, date("2026-11-06T20:59:59Z"))
    }

    func testRobinhoodAcceptsCurrentNightTrade() throws {
        let data = Data(#"{"last_trade_price":"186.64","last_non_reg_trade_price":"190","venue_last_non_reg_trade_time":"2026-11-09T01:59:00Z"}"#.utf8)
        let quote = try RobinhoodProvider().parse(data, symbol: symbol, at: now)
        XCTAssertEqual(quote?.extendedSession, .overnight)
        XCTAssertEqual(quote?.effectivePrice, 190)
        XCTAssertEqual(quote?.timestamp, date("2026-11-09T01:59:00Z"))
    }

    func testRobinhoodBatchUsesLatestRegularCloseAsNightBaseline() throws {
        let data = Data(#"{"results":[null,{"symbol":"NVDA","last_trade_price":"186.68","previous_close":"186.64","last_non_reg_trade_price":"179.19","venue_last_non_reg_trade_time":"2026-11-09T01:59:59.123456789Z"}]}"#.utf8)
        let quotes = try RobinhoodProvider().parseBatch(data, symbols: [symbol, SymbolID(code: "TSLA", market: .us)], at: now)
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes[symbol]?.extendedSession, .overnight)
        XCTAssertEqual(quotes[symbol]?.effectivePrice, Decimal(string: "179.19"))
        XCTAssertEqual(quotes[symbol]?.extendedChange, Decimal(string: "-7.45"))
    }

    func testYahooUsesDedicatedOvernightPriceAndTradeTime() throws {
        for time in ["null", "1794013199", "\(now.timeIntervalSince1970)"] {
            let data = Data("""
            {"quoteResponse":{"result":[{"symbol":"NVDA","regularMarketPrice":186.64,
            "regularMarketPreviousClose":181.60,"regularMarketTime":1793998800,
            "postMarketPrice":188.70,"overnightMarketPrice":179.96,"overnightMarketTime":\(time)}]}}
            """.utf8)
            let quote = try YahooProvider.parseQuotes(data, symbols: [symbol], at: now)[symbol]
            let valid = time == "\(now.timeIntervalSince1970)"
            XCTAssertEqual(quote?.isExtended, valid)
            XCTAssertEqual(quote?.effectivePrice, Decimal(string: valid ? "179.96" : "186.64"))
            XCTAssertEqual(quote?.timestamp, valid ? now : Date(timeIntervalSince1970: 1793998800))
        }
    }

    func testSinaDoesNotRelabelPostMarketPriceAsOvernightAndHandlesShortRows() {
        var fields = Array(repeating: "0", count: 30)
        fields[0] = "NVIDIA"
        fields[1] = "186.64"
        fields[21] = "188.7001"
        fields[24] = "Nov 06 08:01PM EST"
        fields[26] = "181.60"
        fields[29] = "2026"
        let provider = SinaProvider()
        let quotes = provider.parse("var hq_str_gb_nvda=\"\(fields.joined(separator: ","))\";", symbols: [symbol], at: now)
        XCTAssertEqual(quotes[symbol]?.isExtended, false)
        fields = Array(fields.prefix(26))
        XCTAssertTrue(provider.parse("var hq_str_gb_nvda=\"\(fields.joined(separator: ","))\";", symbols: [symbol], at: now).isEmpty)
    }

    func testSinaAcceptsCurrentPostMarketTimestamp() {
        var fields = Array(repeating: "0", count: 30)
        fields[0] = "NVIDIA"
        fields[1] = "186.64"
        fields[21] = "188.7001"
        fields[24] = "Nov 09 05:01PM EST"
        fields[26] = "181.60"
        fields[29] = "2026"
        let quote = SinaProvider().parse(
            "var hq_str_gb_nvda=\"\(fields.joined(separator: ","))\";",
            symbols: [symbol], at: date("2026-11-09T22:02:00Z")
        )[symbol]
        XCTAssertEqual(quote?.extendedSession, .postMarket)
        XCTAssertEqual(quote?.timestamp, date("2026-11-09T22:01:00Z"))
    }

    func testFallbackContinuesForOnlyMissingSymbolsAndRejectsStaleBase() async throws {
        let other = SymbolID(code: "TSLA", market: .us)
        let base = ExtendedTestProvider(id: "base", quotes: [symbol: quote(symbol, time: now.addingTimeInterval(-86400)), other: quote(other, time: now.addingTimeInterval(-86400))])
        let first = ExtendedTestProvider(id: "first", quotes: [symbol: quote(symbol, time: now)])
        // A non-empty regular-only response must not stop fallback.
        let second = ExtendedTestProvider(id: "second", quotes: [other: quote(other, time: now).withoutExtended()])
        let third = ExtendedTestProvider(id: "third", quotes: [other: quote(other, time: now)])
        let instant = now
        let orchestrator = ProviderOrchestrator(
            providers: [.tencent: base], preferences: [.us: ProviderPreference(order: [.tencent], enabled: [.tencent: true])],
            extendedProviders: [first, second, third], now: { instant }
        )
        let result = try await orchestrator.fetch([symbol, other])
        XCTAssertEqual(result[symbol]?.extendedSession, .overnight)
        XCTAssertEqual(result[other]?.extendedSession, .overnight)
        let secondBatches = await second.batches
        let thirdBatches = await third.batches
        XCTAssertEqual(secondBatches, [[other]])
        XCTAssertEqual(thirdBatches, [[other]])
    }

    func testNoCurrentQuoteRemovesStaleExtendedPrice() async throws {
        let base = ExtendedTestProvider(id: "base", quotes: [symbol: quote(symbol, time: now.addingTimeInterval(-86400))])
        let instant = now
        let orchestrator = ProviderOrchestrator(
            providers: [.tencent: base], preferences: [.us: ProviderPreference(order: [.tencent], enabled: [.tencent: true])],
            extendedProviders: [], now: { instant }
        )
        let result = try await orchestrator.fetch([symbol])
        XCTAssertEqual(result[symbol]?.isExtended, false)
        XCTAssertEqual(result[symbol]?.effectivePrice, 186.64)
    }

    private func date(_ raw: String) -> Date { ISO8601DateFormatter().date(from: raw)! }

    private func quote(_ symbol: SymbolID, time: Date) -> Quote {
        Quote(symbol: symbol, name: symbol.code, price: 186.64, prevClose: 181.60,
              currency: .usd, timestamp: time, extendedPrice: 190, extendedSession: .overnight)
    }
}

private actor ExtendedTestProvider: QuoteProvider {
    nonisolated let id: String
    nonisolated let supportedMarkets: Set<Market> = [.us]
    let quotes: [SymbolID: Quote]
    private(set) var batches: [[SymbolID]] = []

    init(id: String, quotes: [SymbolID: Quote]) {
        self.id = id
        self.quotes = quotes
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        batches.append(symbols)
        return quotes.filter { symbols.contains($0.key) }
    }
}
