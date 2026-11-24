import XCTest
@testable import TickBar

final class MCPQuoteBrokerTests: XCTestCase {
    func testNormalizeCodesPreservesLeadingZerosAndDedupes() async {
        let broker = MCPQuoteBroker(orchestrator: ProviderOrchestrator(
            providers: [:],
            preferences: [:],
            extendedProviders: [],
            extendedPreference: .defaults
        ))
        let response = await broker.fetch(
            market: .a,
            codes: ["00700", "00700", " 600519 "],
            seedQuotes: [:],
            seedRetrievedAt: nil
        )
        XCTAssertEqual(response.quotes.map(\.code), ["00700", "600519"])
        XCTAssertTrue(response.partial)
    }

    func testReuseIntervalMarksStale() async {
        let broker = MCPQuoteBroker(orchestrator: ProviderOrchestrator(
            providers: [:],
            preferences: [:],
            extendedProviders: [],
            extendedPreference: .defaults
        ))
        let symbol = SymbolID(code: "600519", market: .a)
        let quote = Quote(
            symbol: symbol,
            name: "MOUTAI",
            price: 100,
            prevClose: 99,
            currency: .cny,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let old = Date().addingTimeInterval(-30)
        await broker.ingestLiveQuotes([symbol: quote], retrievedAt: old)
        let response = await broker.fetch(
            market: .a,
            codes: ["600519"],
            seedQuotes: [:],
            seedRetrievedAt: nil
        )
        XCTAssertEqual(response.quotes.count, 1)
        XCTAssertTrue(response.quotes[0].stale)
        XCTAssertEqual(response.quotes[0].source, "cached")
    }
}
