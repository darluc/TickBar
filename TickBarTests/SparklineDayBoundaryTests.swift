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

    func testSparklineLayoutAlignsBaselineAndCurveWithMinimumAmplitudeFloor() {
        let size = CGSize(width: 120, height: 28)
        // 微幅波动 ±0.1%，应受 ±0.5% 最小振幅地板约束，不撑满全高
        let flatLayout = SparklineLayout(points: [99.9, 100.0, 100.1], prevClose: 100.0, size: size)
        XCTAssertEqual(flatLayout.minY, 99.5, accuracy: 1e-6)
        XCTAssertEqual(flatLayout.maxY, 100.5, accuracy: 1e-6)
        // 昨收与价格 100.0 应完全重合在竖直中线
        XCTAssertEqual(flatLayout.y(for: 100.0), size.height / 2, accuracy: 0.01)
        XCTAssertEqual(flatLayout.coordinates[1].y, flatLayout.y(for: 100.0), accuracy: 0.001)
        // 波动幅度只占总绘区约 20%，而非 100%
        let spanY = abs(flatLayout.coordinates[0].y - flatLayout.coordinates[2].y)
        XCTAssertLessThan(spanY, flatLayout.plotHeight * 0.25)

        // 高开回落但仍涨 +2.3%，整条曲线应位于昨收虚线上方（Y 值更小）
        let gapUpLayout = SparklineLayout(points: [103.5, 103.0, 102.3], prevClose: 100.0, size: size)
        let baselineY = gapUpLayout.y(for: 100.0)
        for coord in gapUpLayout.coordinates {
            XCTAssertLessThan(coord.y, baselineY)
            XCTAssertGreaterThanOrEqual(coord.y, gapUpLayout.verticalPadding)
            XCTAssertLessThanOrEqual(coord.x, size.width - gapUpLayout.rightPadding + 0.001)
        }
    }

    func testLTTBDownsamplePreservesFirstLastAndSharpPeak() {
        let count = 240
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var prices = Array(repeating: 100.0, count: count)
        prices[0] = 99.5
        prices[117] = 108.0 // 盘中急拉峰值
        prices[count - 1] = 101.2
        let dates = (0..<count).map { baseDate.addingTimeInterval(Double($0) * 60) }

        let sampled = TimelineHistoryFetcher.downsample(prices: prices, dates: dates, targetCount: 48)
        XCTAssertEqual(sampled.points.count, 48)
        XCTAssertEqual(sampled.dates.count, 48)
        XCTAssertEqual(sampled.points.first, 99.5)
        XCTAssertEqual(sampled.points.last, 101.2)
        XCTAssertTrue(sampled.points.contains(108.0), "LTTB should preserve sharp intraday peak")
    }

    @MainActor
    func testSparklineStoreUpdatesTailInPlaceAndAvoidsCrossDayCliff() {
        let store = SparklineStore()
        let sym = SymbolID(code: "600519", market: .a)
        let formatter = ISO8601DateFormatter()
        let day1Open = formatter.date(from: "2026-07-01T01:30:00Z")! // 北京 09:30
        let day1Mid  = formatter.date(from: "2026-07-01T02:00:00Z")! // 北京 10:00
        let day1Tick = formatter.date(from: "2026-07-01T02:01:00Z")! // 北京 10:01
        let day2Open = formatter.date(from: "2026-07-02T01:30:00Z")! // 次日 09:30

        store.applyTimeline(points: [100.0, 101.0, 102.0], dates: [day1Open, day1Mid, day1Mid], for: sym)

        // 同交易日实时行情：仅更新末点，不新增点数、不裁掉早盘
        let sameDayQuote = Quote(symbol: sym, name: "茅台", price: 102.5, prevClose: 100, currency: .cny, timestamp: day1Tick)
        store.record(quote: sameDayQuote)
        XCTAssertEqual(store.points(for: sameDayQuote), [100.0, 101.0, 102.5])

        // 跨日实时行情：不把次日跳空价强拼到昨日分时末尾制造垂直断崖
        let nextDayQuote = Quote(symbol: sym, name: "茅台", price: 109.0, prevClose: 102.5, currency: .cny, timestamp: day2Open)
        store.record(quote: nextDayQuote)
        XCTAssertEqual(store.points(for: nextDayQuote), [100.0, 101.0, 102.5])
    }
}
