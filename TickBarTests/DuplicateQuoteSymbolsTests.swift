import XCTest
@testable import TickBar

final class DuplicateQuoteSymbolsTests: XCTestCase {
    func testTencentParserAcceptsSecurityRepeatedAcrossWatchlists() {
        let symbol = SymbolID(code: "SNDK", market: .us)
        let quotes = TencentProvider().parse(
            "v_usSNDK=\"200~Sandisk~SNDK~100~99~99~1000\";",
            encodedPairs: [("usSNDK", symbol), ("usSNDK", symbol)]
        )
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes[symbol]?.price, 100)
    }

    func testOrchestratorDeduplicatesBeforeCallingProviderAndKeepsMarketsSeparate() async throws {
        let provider = RecordingProvider()
        let preferences = Dictionary(uniqueKeysWithValues: [Market.a, .hk].map {
            ($0, ProviderPreference(order: [.tencent], enabled: [.tencent: true]))
        })
        let orchestrator = ProviderOrchestrator(providers: [.tencent: provider], preferences: preferences)
        let a = SymbolID(code: "000001", market: .a)
        let hk = SymbolID(code: "000001", market: .hk)
        _ = try await orchestrator.fetch([a, a, hk, hk])
        let batches = await provider.batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { $0.count == 1 })
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set([a, hk]))
    }
}

private actor RecordingProvider: QuoteProvider {
    nonisolated let id = "tencent"
    nonisolated let supportedMarkets: Set<Market> = [.a, .hk]
    private(set) var batches: [[SymbolID]] = []

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        batches.append(symbols)
        return [:]
    }
}
