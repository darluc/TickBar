import XCTest
@testable import TickBar

final class MCPEtfSnapshotBuilderTests: XCTestCase {
    @MainActor
    func testBuildsTurnoverHistoryAndTradeSizeBands() {
        var display = ETFDisplay()
        display.day = "2026-03-20"
        display.quoteCount = 20
        display.minuteCount = 18
        display.total = 3_000_000_000
        display.cumulative = [0, 500_000_000, 3_000_000_000]
        display.previousDay = "2026-03-19"
        display.averageDays = 10
        display.previous = ETFCurve(slots: [0, 2], values: [0, 2_000_000_000])
        display.average = ETFCurve(slots: [0, 2], values: [0, 2_500_000_000])
        display.pacePrevious = 3_000_000_000 / 2_000_000_000 - 1
        display.paceAverage = 3_000_000_000 / 2_500_000_000 - 1
        display.volumeBands = ETFBasketVolumeClassification(
            amounts: [1_000_000, 50_000_000, 200_000],
            coveredTurnover: 800_000_000,
            referenceTurnover: 1_000_000_000,
            inconsistentMinutes: 1
        )

        let snap = MCPEtfSnapshotBuilder.build(
            display: display,
            paused: false,
            refreshing: false,
            panelVisible: false,
            market: "open",
            statusText: "ok",
            warning: false,
            lastSuccessfulRefresh: nil
        )

        XCTAssertEqual(snap.turnoverStatistics.totalTurnoverYuan, 3_000_000_000)
        XCTAssertEqual(snap.turnoverStatistics.liveMinuteSlot, 2)
        XCTAssertEqual(snap.historicalComparison.referencePreviousYuan!, 2_000_000_000, accuracy: 1)
        XCTAssertEqual(snap.historicalComparison.referenceAverageYuan!, 2_500_000_000, accuracy: 1)
        XCTAssertNotNil(snap.tradeSizeBands)
        XCTAssertEqual(snap.tradeSizeBands?.large.turnoverYuan, 1_000_000)
        XCTAssertEqual(snap.tradeSizeBands?.small.turnoverYuan, 200_000)
    }
}
