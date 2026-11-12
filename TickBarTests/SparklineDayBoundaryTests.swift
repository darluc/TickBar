import XCTest
@testable import TickBar

final class SparklineDayBoundaryTests: XCTestCase {
    private func quote(market: Market = .us, times: [String]?, points: [Double]? = nil) -> Quote {
        let formatter = ISO8601DateFormatter()
        let timestamps = times?.map { formatter.date(from: $0)! }
        return Quote(
            symbol: SymbolID(code: "TEST", market: market),
            name: "Test",
            price: 100,
            prevClose: 99,
            currency: market.defaultCurrency,
            sparklineHistory: points ?? timestamps.map { Array(repeating: 100, count: $0.count) },
            sparklineTimestamps: timestamps
        )
    }

    func testUSBoundaryUsesNewYorkMidnightInsteadOfUTCMidnight() {
        let value = quote(times: [
            "2026-07-01T23:55:00Z", "2026-07-02T00:00:00Z",
            "2026-07-02T03:55:00Z", "2026-07-02T04:00:00Z"
        ])
        XCTAssertEqual(value.sparklineDayBoundaryIndices, [3])
    }

    func testUSWinterBoundaryUsesStandardTime() {
        let value = quote(times: ["2026-01-02T04:55:00Z", "2026-01-02T05:00:00Z"])
        XCTAssertEqual(value.sparklineDayBoundaryIndices, [1])
    }

    func testAsianMarketsUseLocalDates() {
        for market in [Market.a, .hk, .kr] {
            let value = quote(market: market, times: ["2026-07-01T14:55:00Z", "2026-07-01T16:00:00Z"])
            XCTAssertEqual(value.sparklineDayBoundaryIndices, [1], "\(market)")
        }
    }

    func testSeparateTradingDaysIncludingWeekendGap() {
        let value = quote(times: [
            "2026-07-03T19:55:00Z", "2026-07-06T13:30:00Z", "2026-07-07T13:30:00Z"
        ])
        XCTAssertEqual(value.sparklineDayBoundaryIndices, [1, 2])
    }

    func testCryptoDoesNotShowSeparators() {
        let value = quote(market: .crypto, times: ["2026-07-01T23:55:00Z", "2026-07-02T00:00:00Z"])
        XCTAssertTrue(value.sparklineDayBoundaryIndices.isEmpty)
    }

    func testMissingOrMismatchedTimestampsDoNotInventBoundaries() {
        XCTAssertTrue(quote(times: nil, points: [99, 100]).sparklineDayBoundaryIndices.isEmpty)
        XCTAssertTrue(quote(times: [], points: []).sparklineDayBoundaryIndices.isEmpty)
        XCTAssertTrue(quote(times: ["2026-07-01T14:00:00Z"]).sparklineDayBoundaryIndices.isEmpty)
        XCTAssertTrue(quote(times: ["2026-07-01T14:00:00Z", "2026-07-02T14:00:00Z"], points: [99, 100, 101]).sparklineDayBoundaryIndices.isEmpty)
    }

    func testOverlayKeepsTimestampsPairedWithTheirPrices() {
        let original = quote(times: ["2026-07-01T14:00:00Z", "2026-07-02T14:00:00Z"])
        let withoutHistory = quote(times: nil)
        XCTAssertEqual(original.overlayingExtended(from: withoutHistory).sparklineDayBoundaryIndices, [1])

        let withoutTimestamps = quote(times: nil, points: [101, 102])
        let merged = original.overlayingExtended(from: withoutTimestamps)
        XCTAssertEqual(merged.sparklineHistory, [101, 102])
        XCTAssertNil(merged.sparklineTimestamps)
    }

    func testOldCachedQuoteWithoutTimestampsStillDecodes() throws {
        let original = quote(times: nil, points: [99, 100])
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sparklineTimestamps")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Quote.self, from: oldData)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.sparklineDayBoundaryIndices.isEmpty)
    }
}
