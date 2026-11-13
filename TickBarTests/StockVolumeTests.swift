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

    func testOnlyReconciledCompletedMinutesContributeToClassificationAndAmounts() throws {
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
        XCTAssertEqual(display.covered, 160)
        XCTAssertEqual(display.inconsistentMinutes, 2, "under-counted and over-counted minutes stay unknown")
        XCTAssertEqual(display.minutes[2].missing, 40)
        XCTAssertEqual(display.minutes[3].missing, 10)
        XCTAssertEqual(display.summaries[0].hands, 50)
        XCTAssertEqual(display.summaries[0].buy, 1_000_000)
        XCTAssertEqual(display.summaries[1].net, -100_000)
        XCTAssertEqual(display.summaries[2].buy, 99_999)
        XCTAssertEqual(display.coverage, 160.0 / 210.0)
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
                .init(slot: 4, hands: 50, estimatedAmount: 50_000, side: 2),
                .init(slot: 5, hands: 10, estimatedAmount: 10_000, side: 2)
            ])
        XCTAssertEqual(display.minutes.map(\.netAmount), [20_000, -20_000, 0, 0, nil])
        XCTAssertEqual(display.minutes[0].buyAmount, 60_000)
        XCTAssertEqual(display.minutes[0].sellAmount, 40_000)
        XCTAssertEqual(display.minutes[3].buyAmount, 0, "neutral estimates never become net buys")
        XCTAssertEqual(display.minutes[4].buyAmount, 0, "unreconciled estimates must not be published")
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
                .init(slot: 2, hands: 50, estimatedAmount: 1_000_000, side: 2),
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

private actor VolumeTestWorker: StockVolumeFetching {
    private(set) var calls = 0
    var fails = false
    var delay: UInt64 = 0
    var snapshot: StockVolumeDisplay?
    func setSnapshot(_ value: StockVolumeDisplay) { snapshot = value }
    func setFailure(_ value: Bool) { fails = value }
    func setDelay(_ value: UInt64) { delay = value }
    func fetch(symbol: SymbolID) async throws -> StockVolumeDisplay {
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
        for mode in StockVolumeChartMode.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = StockVolumePanel(monitor: model, chartMode: mode).environment(\.colorScheme, scheme)
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
