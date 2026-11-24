import SwiftUI
import XCTest
@testable import TickBar

final class StockVolumeDataTests: XCTestCase {
    private func data(_ body: String) -> Data { Data(body.utf8) }

    func testServiceRequestsBothSnapshotsAndReconcilesBeforePublishing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VolumeRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = StockVolumeService(http: HTTPClient(session: session))
        let display = try await service.fetch(symbol: .init(code: "000001", market: .a))
        XCTAssertEqual(display.day, "2026-11-12")
        XCTAssertEqual(display.throughSlot, 0)
        XCTAssertEqual(display.total, 100)
        XCTAssertEqual(display.coverage, 1)
        XCTAssertEqual(display.summaries[1].buy, 100_000)
    }

    func testOpeningAuctionAndIntervalEndMapping() {
        func slot(_ time: String) -> Int? { StockVolumeService.detailSlot(time[...]) }
        XCTAssertNil(slot("09:24:57"), "indicative auction volume must never count as executions")
        XCTAssertEqual(slot("09:25:00"), 0)
        XCTAssertNil(slot("09:29:00"))
        XCTAssertEqual(slot("09:30:00"), 1)
        XCTAssertEqual(slot("09:30:59"), 1)
        XCTAssertEqual(slot("09:31:00"), 2)
        XCTAssertEqual(slot("11:30:00"), 120)
        XCTAssertNil(slot("11:30:03"))
        XCTAssertNil(slot("12:00:00"))
        XCTAssertEqual(slot("13:00:00"), 121)
        XCTAssertEqual(slot("15:00:00"), 240)
        XCTAssertNil(slot("15:00:01"))
        XCTAssertNil(slot("09:30:60"))
    }

    func testDetailParsingDeduplicatesAndNormalizesHandsWithoutCountingIndicativeAuction() throws {
        let rows = data("""
        {"data":{"code":"000001","details":[
          "09:24:57,11.70,5414,0,4",
          "09:25:00,11.69,6975,449,2",
          "09:25:00,11.69,6975,449,2",
          "09:30:00,11.69,5255,173,2",
          "09:30:03,11.69,11374,341,1",
          "09:30:06,NaN,1,1,1",
          "09:30:09,11.68,-1,1,2",
          "09:30:12,11.68,1,1,9"]}}
        """)
        let trades = try StockVolumeService.parseDetails(rows, code: "000001")
        XCTAssertEqual(trades.count, 3)
        XCTAssertEqual(trades.map(\.slot), [0, 1, 1])
        XCTAssertEqual(trades[0].hands, 6975)
        XCTAssertEqual(trades[0].estimatedAmount, 8_153_775, accuracy: 0.01)
        XCTAssertEqual(trades[1].side, 2)
        XCTAssertEqual(trades[2].side, 1)
        XCTAssertThrowsError(try StockVolumeService.parseDetails(rows, code: "600519"))
        XCTAssertThrowsError(try StockVolumeService.parseDetails(data("{\"data\":null}"), code: "000001"))
    }

    func testMinuteParsingKeepsLatestDayAndCorrections() throws {
        let rows = data("""
        {"data":{"code":"000001","trends":[
          "2026-11-11 09:30,1,1,1,1,999,999,1",
          "2026-11-12 09:30,11.69,11.69,11.69,11.69,6975,8153775,11.69",
          "2026-11-12 09:31,1,1,1,1,34029,1,1",
          "2026-11-12 09:31,1,1,1,1,34030,1,1",
          "2026-11-12 09:32,1,1,1,1,-1,1,1",
          "2026-11-11 09:32,1,1,1,1,999,1,1"]}}
        """)
        let reference = try StockVolumeService.parseMinutes(rows, code: "000001")
        XCTAssertEqual(reference.day, "2026-11-12")
        XCTAssertEqual(reference.volumes, [0: 6975, 1: 34030])
        XCTAssertThrowsError(try StockVolumeService.parseMinutes(rows, code: "600519"))
    }

    func testTolerancePartialAndWindowEstimationPublishFuzzyButBoundedResults() throws {
        let trades: [StockVolumeTrade] = [
            .init(slot: 0, hands: 10, estimatedAmount: 99_999, side: 2),
            .init(slot: 1, hands: 100, estimatedAmount: 100_000, side: 1),
            .init(slot: 1, hands: 50, estimatedAmount: 1_000_000, side: 2),
            .init(slot: 2, hands: 30, estimatedAmount: 200_000, side: 4),
            .init(slot: 3, hands: 20, estimatedAmount: 200_000, side: 2),
            .init(slot: 4, hands: 99, estimatedAmount: 3_000_000, side: 2)
        ]
        let display = try StockVolumeDisplay.build(day: "2026-11-12", reference: [0: 10, 1: 150, 2: 40, 3: 10, 4: 99], trades: trades)
        XCTAssertEqual(display.throughSlot, 3, "the still-changing latest minute is excluded")
        XCTAssertEqual(display.total, 210)
        XCTAssertEqual(display.minutes.map(\.quality), [.exact, .exact, .partial, .estimated])
        XCTAssertEqual(display.coverage, 200.0 / 210.0, accuracy: 0.0001,
                       "observed under-count is published as partial; the over-count is windowed")
        XCTAssertEqual(display.estimatedMinutes, 1)
        XCTAssertEqual(display.partialMinutes, 1)
        XCTAssertEqual(display.inconsistentMinutes, 0)
        XCTAssertEqual(display.minutes[2].missing, 10)
        XCTAssertEqual(display.minutes[3].missing, 0)
        XCTAssertEqual(display.summaries.reduce(0) { $0 + $1.hands }, 200)
        XCTAssertEqual(display.summaries[0].neutral, 0)
    }

    func testWindowCompositionRepairsBoundaryAttributionWithoutInventingVolume() throws {
        let display = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100, 3: 100], trades: [
                .init(slot: 0, hands: 100, estimatedAmount: 100_000, side: 2),
                .init(slot: 2, hands: 200, estimatedAmount: 200_000, side: 2),
                .init(slot: 3, hands: 100, estimatedAmount: 100_000, side: 2)
            ])
        XCTAssertEqual(display.throughSlot, 2)
        XCTAssertEqual(display.minutes[0].quality, .exact)
        XCTAssertEqual(display.minutes[1].quality, .estimated)
        XCTAssertEqual(display.minutes[1].covered, 100, accuracy: 0.001)
        XCTAssertEqual(display.minutes[2].quality, .estimated)
        XCTAssertEqual(display.minutes[2].covered, 100, accuracy: 0.001)
        XCTAssertEqual(display.coverage, 1)
        XCTAssertEqual(display.inconsistentMinutes, 0)
        XCTAssertEqual(display.summaries.reduce(0) { $0 + $1.hands }, 300)
    }

    func testRoundingToleranceStaysExactAndPartialKeepsAnExplicitRemainder() throws {
        let exact = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100], trades: [
                .init(slot: 0, hands: 100, estimatedAmount: 100_000, side: 2),
                .init(slot: 1, hands: 99, estimatedAmount: 100_000, side: 2),
                .init(slot: 2, hands: 100, estimatedAmount: 100_000, side: 2)
            ])
        XCTAssertEqual(exact.minutes[1].quality, .exact)
        XCTAssertEqual(exact.minutes[1].covered, 100, accuracy: 0.001)
        XCTAssertEqual(exact.coverage, 1)

        let partial = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100], trades: [
                .init(slot: 0, hands: 100, estimatedAmount: 100_000, side: 2),
                .init(slot: 1, hands: 85, estimatedAmount: 100_000, side: 2),
                .init(slot: 2, hands: 100, estimatedAmount: 100_000, side: 2)
            ])
        XCTAssertEqual(partial.minutes[1].quality, .partial)
        XCTAssertEqual(partial.minutes[1].covered, 85)
        XCTAssertEqual(partial.minutes[1].missing, 15, "the unobserved remainder stays unknown")
        XCTAssertNil(partial.minutes[1].netAmounts)
        XCTAssertEqual(partial.partialMinutes, 1)
        XCTAssertEqual(partial.coverage, 185.0 / 200.0)
    }

    func testUnderCountStaysPartialAndMissingDetailStaysUnknown() throws {
        let display = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100], trades: [
                .init(slot: 0, hands: 40, estimatedAmount: 100_000, side: 2),
                .init(slot: 2, hands: 100, estimatedAmount: 100_000, side: 2)
            ])
        XCTAssertEqual(display.minutes[0].quality, .partial)
        XCTAssertEqual(display.minutes[0].missing, 60)
        XCTAssertEqual(display.minutes[1].quality, .unknown)
        XCTAssertEqual(display.inconsistentMinutes, 1)
        XCTAssertEqual(display.coverage, 0.2)
        XCTAssertEqual(display.summaries.reduce(0) { $0 + $1.hands }, 40)
    }

    func testMinuteNetAmountsPreserveBuySellZeroNeutralAndMissing() throws {
        let display = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100, 3: 100, 4: 100, 5: 10], trades: [
                .init(slot: 0, hands: 60, estimatedAmount: 60_000, side: 2),
                .init(slot: 0, hands: 40, estimatedAmount: 40_000, side: 1),
                .init(slot: 1, hands: 40, estimatedAmount: 40_000, side: 2),
                .init(slot: 1, hands: 60, estimatedAmount: 60_000, side: 1),
                .init(slot: 2, hands: 50, estimatedAmount: 50_000, side: 2),
                .init(slot: 2, hands: 50, estimatedAmount: 50_000, side: 1),
                .init(slot: 3, hands: 100, estimatedAmount: 100_000, side: 4),
                .init(slot: 5, hands: 10, estimatedAmount: 10_000, side: 2)
            ])
        XCTAssertEqual(display.minutes.map(\.netAmount), [20_000, -20_000, 0, 0, nil])
        XCTAssertEqual(display.minutes[0].buyAmount, 60_000)
        XCTAssertEqual(display.minutes[0].sellAmount, 40_000)
        XCTAssertEqual(display.minutes[3].buyAmount, 0, "neutral estimates never become net buys")
        XCTAssertEqual(display.minutes[4].quality, .unknown)
        XCTAssertEqual(display.minutes[4].buyAmount, 0, "unreconciled minutes must not be published")
        XCTAssertEqual(display.minutes.compactMap(\.netAmount).reduce(0, +), display.summaries.reduce(0) { $0 + $1.net })
        XCTAssertNil(display.minutes.first(where: { $0.slot == 5 }), "changing tail minutes stay excluded")
    }

    func testMinuteNetCategoriesKeepOpposingFlowsAndScaleBothStacks() throws {
        let display = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100, 3: 100], trades: [
                .init(slot: 0, hands: 30, estimatedAmount: 1_000_000, side: 2),
                .init(slot: 0, hands: 20, estimatedAmount: 500_000, side: 2),
                .init(slot: 0, hands: 20, estimatedAmount: 500_000, side: 2),
                .init(slot: 0, hands: 30, estimatedAmount: 50_000, side: 1),
                .init(slot: 1, hands: 40, estimatedAmount: 1_000_000, side: 1),
                .init(slot: 1, hands: 30, estimatedAmount: 500_000, side: 2),
                .init(slot: 1, hands: 30, estimatedAmount: 500_000, side: 2),
                .init(slot: 3, hands: 100, estimatedAmount: 100_000, side: 4)
            ])
        XCTAssertEqual(display.minutes[0].netAmounts, [1_000_000, 1_000_000, -50_000])
        XCTAssertEqual(display.minutes[0].netExtent, 2_000_000, "axis must contain the entire positive stack")
        XCTAssertEqual(display.minutes[1].netAmount, 0)
        XCTAssertEqual(display.minutes[1].netAmounts, [-1_000_000, 1_000_000, 0], "opposing categories remain visible when total net is zero")
        XCTAssertEqual(display.minutes[1].netExtent, 1_000_000)
        XCTAssertNil(display.minutes[2].netAmounts, "missing minutes must not publish per-category zeroes")
        for band in StockVolumeBand.allCases {
            XCTAssertEqual(display.minutes.compactMap(\.netAmounts).reduce(0) { $0 + $1[band.rawValue] },
                           display.summaries[band.rawValue].net)
        }
        let negative = StockVolumeMinute(slot: 0, total: 0, sellAmounts: [1_000_000, 200_000, 50_000])
        XCTAssertEqual(negative.netExtent, 1_250_000, "axis must contain the entire negative stack")
        XCTAssertEqual(StockVolumeChartMode.allCases, [.classified, .net])
    }

    func testClosingAuctionAndNeutralAmountsAreIncluded() throws {
        let display = try StockVolumeDisplay.build(day: "2026-11-12", reference: [240: 100], trades: [
            .init(slot: 240, hands: 100, estimatedAmount: 100_000, side: 4)
        ])
        XCTAssertEqual(display.throughSlot, 240)
        XCTAssertEqual(display.summaries[1].neutral, 100_000)
        XCTAssertEqual(display.summaries[1].net, 0)
        XCTAssertEqual(display.coverage, 1)
    }

    func testTruncatedSnapshotLeavesEarlierMinutesUnknown() throws {
        let display = try StockVolumeDisplay.build(day: "2026-11-12", reference: [0: 100, 1: 200, 2: 300, 3: 10], trades: [
            .init(slot: 2, hands: 300, estimatedAmount: 500_000, side: 2),
            .init(slot: 3, hands: 10, estimatedAmount: 20_000, side: 1)
        ])
        XCTAssertEqual(display.total, 600)
        XCTAssertEqual(display.covered, 300)
        XCTAssertEqual(display.minutes[0].missing, 100)
        XCTAssertEqual(display.minutes[1].missing, 200)
        XCTAssertEqual(display.inconsistentMinutes, 2)
        XCTAssertThrowsError(try StockVolumeDisplay.build(day: "2026-11-12", reference: [0: 100], trades: []))
    }

    func testSupportedSymbolsExcludeFundsAndForeignMarkets() {
        for code in ["600519", "000001", "300750", "688001"] {
            XCTAssertTrue(StockVolumeService.supports(SymbolID(code: code, market: .a)))
        }
        for code in ["510300", "159915", "399001", "899050", "AAPL", "00000", "0000011"] {
            XCTAssertFalse(StockVolumeService.supports(SymbolID(code: code, market: .a)))
        }
        XCTAssertFalse(StockVolumeService.supports(SymbolID(code: "000001", market: .hk)))
    }

    func testMergingKeepsCompleteMinutesWhenANewerSnapshotFallsBehindOrLosesReconciliation() throws {
        let previous = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 100, 2: 100], trades: [
                .init(slot: 0, hands: 100, estimatedAmount: 100_000, side: 2),
                .init(slot: 1, hands: 100, estimatedAmount: 200_000, side: 4),
                .init(slot: 2, hands: 100, estimatedAmount: 300_000, side: 1)
            ])
        let incoming = try StockVolumeDisplay.build(day: "2026-11-12",
            reference: [0: 100, 1: 10, 2: 100, 3: 100], trades: [
                .init(slot: 0, hands: 100, estimatedAmount: 150_000, side: 2),
                .init(slot: 3, hands: 100, estimatedAmount: 50_000, side: 1)
            ])
        let merged = StockVolumeDisplay.merging(previous: previous, incoming)
        XCTAssertEqual(merged.day, "2026-11-12")
        XCTAssertEqual(merged.throughSlot, 2, "range only moves forward")
        XCTAssertEqual(merged.minutes.map(\.slot), [0, 1, 2])
        XCTAssertEqual(merged.coverage, 200.0 / 300.0, "slot 1 keeps its earlier reconciliation")
        XCTAssertEqual(merged.inconsistentMinutes, 1)
        XCTAssertEqual(merged.summaries[1].neutral, 200_000, "summaries are rebuilt from merged minutes")
        XCTAssertEqual(merged.minutes[1].neutralAmounts[1], 200_000)

        let tomorrow = try StockVolumeDisplay.build(day: "2026-11-13", reference: [240: 50], trades: [
            .init(slot: 240, hands: 50, estimatedAmount: 50_000, side: 2)
        ])
        XCTAssertEqual(StockVolumeDisplay.merging(previous: merged, tomorrow), tomorrow)
        let yesterday = try StockVolumeDisplay.build(day: "2026-11-11", reference: [240: 10], trades: [
            .init(slot: 240, hands: 10, estimatedAmount: 10_000, side: 2)
        ])
        XCTAssertEqual(StockVolumeDisplay.merging(previous: merged, yesterday), merged,
                       "an older trading day never replaces the current one")
    }

    func testServiceReusesCachedDetailRowsForTheSameTradingDay() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VolumeRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = StockVolumeService(http: HTTPClient(session: session), gate: ETFRequestGate(spacing: 0))
        let snapshot = try await service.details(symbol: .init(code: "000001", market: .a),
                                                 cachedRows: ["09:30:00,10,1,0,2"])
        XCTAssertEqual(snapshot.rows.count, 3)
        XCTAssertEqual(snapshot.trades.count, 3)
        XCTAssertEqual(snapshot.source, .eastMoney)
    }

    func testTransientRequestFailureRetriesBeforeFallingBack() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryVolumeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        RetryVolumeProtocol.reset()
        let service = StockVolumeService(http: HTTPClient(session: session), gate: ETFRequestGate(spacing: 0))
        let minutes = try await service.minutes(symbol: .init(code: "000001", market: .a))
        XCTAssertEqual(minutes.source, .eastMoney)
        XCTAssertEqual(RetryVolumeProtocol.trendsCalls, 2)
    }
}

private actor SnapshotFixture: StockVolumeSnapshotFetching {
    private(set) var minuteCalls = 0
    private(set) var detailCalls = 0
    private(set) var lastCachedRows: [String] = []
    private var volumes: [Int: Double] = [0: 100, 1: 10]

    func advance() { volumes[2] = 10 }

    func minutes(symbol: SymbolID) async throws -> StockVolumeMinuteSnapshot {
        minuteCalls += 1
        return StockVolumeMinuteSnapshot(day: "2026-11-12", volumes: volumes, source: .eastMoney)
    }

    func details(symbol: SymbolID, cachedRows: [String]) async throws -> StockVolumeDetailSnapshot {
        detailCalls += 1
        lastCachedRows = cachedRows
        return StockVolumeDetailSnapshot(day: nil, trades: [
            StockVolumeTrade(slot: 0, hands: 100, estimatedAmount: 100_000, side: 2),
            StockVolumeTrade(slot: 1, hands: 10, estimatedAmount: 10_000, side: 1)
        ], rows: cachedRows + ["09:25:00,10,100,0,2"], source: .eastMoney)
    }
}

final class StockVolumeWorkerTests: XCTestCase {
    private let symbol = SymbolID(code: "000001", market: .a)

    func testDetailsAreSkippedUntilTheMinuteSeriesAdvancesAndManualRefreshForces() async throws {
        let fixture = SnapshotFixture()
        let worker = StockVolumeWorker(service: fixture)
        _ = try await worker.fetch(symbol: symbol, forceDetails: false)
        var calls = await fixture.detailCalls
        XCTAssertEqual(calls, 1)

        _ = try await worker.fetch(symbol: symbol, forceDetails: false)
        let minuteCalls = await fixture.minuteCalls
        calls = await fixture.detailCalls
        XCTAssertEqual(minuteCalls, 2)
        XCTAssertEqual(calls, 1, "the minute series did not advance")

        await fixture.advance()
        _ = try await worker.fetch(symbol: symbol, forceDetails: false)
        calls = await fixture.detailCalls
        XCTAssertEqual(calls, 2)
        let passed = await fixture.lastCachedRows
        XCTAssertEqual(passed, ["09:25:00,10,100,0,2"], "same-day rows are handed back to the detail service")

        _ = try await worker.fetch(symbol: symbol, forceDetails: true)
        calls = await fixture.detailCalls
        XCTAssertEqual(calls, 3, "manual refresh always fetches details")
    }
}

private final class VolumeRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["secid"], "0.000001")
        let body: String
        if request.url!.path.contains("trends2") {
            XCTAssertTrue(values["fields2"]!.contains("f56"))
            body = """
            {"data":{"code":"000001","trends":[
              "2026-11-12 09:30,10,10,10,10,100,100000,10",
              "2026-11-12 09:31,10,10,10,10,10,10000,10"]}}
            """
        } else {
            XCTAssertEqual(request.url!.path, "/api/qt/stock/details/get")
            XCTAssertEqual(values["pos"], "-100000")
            XCTAssertEqual(values["iscca"], "1")
            body = """
            {"data":{"code":"000001","details":["09:25:00,10,100,5,2","09:30:00,10,10,3,1"]}}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RetryVolumeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var calls = 0
    static var trendsCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    static func reset() {
        lock.lock()
        calls = 0
        lock.unlock()
    }
    private static func nextCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status: Int
        let body: String
        if Self.nextCall() == 1 {
            status = 502
            body = "unavailable"
        } else {
            status = 200
            body = """
            {"data":{"code":"000001","trends":[
              "2026-11-12 09:30,10,10,10,10,100,100000,10",
              "2026-11-12 09:31,10,10,10,10,10,10000,10"]}}
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor VolumeTestWorker: StockVolumeFetching {
    private(set) var calls = 0
    var fails = false
    var delay: UInt64 = 0
    var snapshot: StockVolumeDisplay?
    func setSnapshot(_ value: StockVolumeDisplay) { snapshot = value }
    func setFailure(_ value: Bool) { fails = value }
    func setDelay(_ value: UInt64) { delay = value }
    func fetch(symbol: SymbolID, forceDetails: Bool) async throws -> StockVolumeDisplay {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw HTTPError.badStatus(502) }
        if let snapshot { return snapshot }
        return try StockVolumeDisplay.build(day: "2026-11-12", reference: [0: 100, 1: 10], trades: [
            .init(slot: 0, hands: 100, estimatedAmount: 100_000, side: 2),
            .init(slot: 1, hands: 10, estimatedAmount: 10_000, side: 1)
        ])
    }
}

@MainActor
final class StockVolumeMonitorTests: XCTestCase {
    private func monitor(_ worker: VolumeTestWorker, market: MarketStatus = .closed) -> StockVolumeMonitor {
        StockVolumeMonitor(symbol: .init(code: "000001", market: .a), name: "平安银行", worker: worker,
                           interval: 0.02, marketStatus: { market })
    }

    private func settle(_ monitor: StockVolumeMonitor) async throws {
        for _ in 0..<100 {
            if !monitor.refreshing { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("refresh did not settle")
    }

    func testHiddenAndClosedMarketDoNotPollAndFreshReopenUsesCache() async throws {
        let worker = VolumeTestWorker()
        let model = monitor(worker)
        model.refreshNow()
        var count = await worker.calls
        XCTAssertEqual(count, 0)
        model.setVisible(true)
        try await settle(model)
        try await Task.sleep(nanoseconds: 60_000_000)
        count = await worker.calls
        XCTAssertEqual(count, 1)
        model.setVisible(false)
        model.setVisible(true)
        try await settle(model)
        count = await worker.calls
        XCTAssertEqual(count, 1)
        model.setVisible(false)
    }

    func testFailureRetainsDisplayAndSuccessfulTimestamp() async throws {
        let worker = VolumeTestWorker()
        let model = monitor(worker)
        model.setVisible(true)
        try await settle(model)
        let previous = model.display
        let updated = model.updated
        await worker.setFailure(true)
        model.refreshNow()
        try await settle(model)
        XCTAssertEqual(model.display, previous)
        XCTAssertEqual(model.updated, updated)
        XCTAssertEqual(model.error, "HTTP 502")
        model.setVisible(false)
    }

    func testTransientFailureBacksOffAndASuccessRestoresTheInterval() async throws {
        let worker = VolumeTestWorker()
        let model = monitor(worker)
        await worker.setFailure(true)
        model.setVisible(true)
        try await settle(model)
        XCTAssertEqual(model.pollDelay, 60)
        await worker.setFailure(false)
        model.refreshNow()
        try await settle(model)
        XCTAssertEqual(model.pollDelay, 0.02)
        model.setVisible(false)
    }

    func testPauseAllowsManualRefreshAndClosingCancelsRequests() async throws {
        let worker = VolumeTestWorker()
        let model = monitor(worker, market: .open)
        model.togglePause()
        model.setVisible(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        var count = await worker.calls
        XCTAssertEqual(count, 0)
        model.refreshNow()
        try await settle(model)
        count = await worker.calls
        XCTAssertEqual(count, 1)
        await worker.setDelay(1_000_000_000)
        model.refreshNow()
        model.setVisible(false)
        try await settle(model)
        XCTAssertFalse(model.refreshing)
        XCTAssertEqual(model.updated != nil, true)
        XCTAssertNil(model.error, "cancellation is not an upstream failure")
    }

    func testPanelRendersInBothAppearances() async throws {
        let worker = VolumeTestWorker()
        let reference = Dictionary(uniqueKeysWithValues: (0...60).map { ($0, 100.0) })
        let trades: [StockVolumeTrade] = (0...60).flatMap { slot -> [StockVolumeTrade] in
            if slot % 4 == 3 { return [.init(slot: slot, hands: 50, estimatedAmount: 50_000, side: 2)] }
            if slot % 4 == 2 { return [.init(slot: slot, hands: 100, estimatedAmount: 100_000, side: 4)] }
            let side = slot % 4 == 0 ? 2 : 1
            return [.init(slot: slot, hands: 40, estimatedAmount: 1_000_000, side: side),
                    .init(slot: slot, hands: 30, estimatedAmount: 500_000, side: 3 - side),
                    .init(slot: slot, hands: 30, estimatedAmount: 50_000, side: side)]
        }
        await worker.setSnapshot(try StockVolumeDisplay.build(day: "2026-11-12", reference: reference, trades: trades))
        let model = monitor(worker)
        model.setVisible(true)
        try await settle(model)
        let holdings = StockHoldingsMonitor(code: "000001", name: "平安银行", cacheURL: nil) { code, name in
            StockHoldingResult(code: code, name: name, latestPeriod: "2026-09-30 00:00:00", holdings: [
                DisclosedHolding(code: code, name: name, holder: "中央汇金资产管理有限责任公司",
                                 period: "2026-09-30 00:00:00", notice: "2026-10-30 00:00:00",
                                 shares: 250_000_000, percent: 2.5)
            ])
        }
        for mode in StockVolumeChartMode.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = StockVolumePanel(monitor: model, chartMode: mode, holdings: holdings)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                window.close()
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(mode.rawValue) \(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        model.setVisible(false)
    }
}
