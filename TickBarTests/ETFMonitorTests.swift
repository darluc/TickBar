import SwiftUI
import XCTest
@testable import TickBar

final class ETFDataTests: XCTestCase {
    private let codes = ETFDescriptor.basket.map(\.code)
    private let shanghaiMorning = ISO8601DateFormatter().date(from: "2026-11-06T03:00:00Z")!

    // MARK: Time axis

    func testSessionSlotsSkipLunchAndMatchAxis() {
        func slot(_ stamp: String) -> Int? { ETFTime.parse(stamp[...])?.slot }
        XCTAssertEqual(slot("2026-11-06 09:30"), 0)
        XCTAssertEqual(slot("2026-11-06 11:30"), 120)
        XCTAssertEqual(slot("2026-11-06 13:01"), 121)
        XCTAssertEqual(slot("2026-11-06 15:00"), 240)
        for closed in ["09:29", "11:31", "12:15", "13:00", "15:01"] { XCTAssertNil(slot("2026-11-06 \(closed)"), closed) }
        XCTAssertNil(slot("2026-11-06T09:30"))
        XCTAssertNil(slot("2026-11-06 9:30"))
        XCTAssertEqual([0, 120, 121, 240].map(ETFTime.label(slot:)), ["09:30", "11:30", "13:01", "15:00"])
        XCTAssertEqual(ETFTime.axis.map(\.label), ETFTime.axis.map { ETFTime.label(slot: $0.slot) })
    }

    func testTradingDayUsesShanghaiTime() {
        let utc = ISO8601DateFormatter().date(from: "2026-11-05T16:01:00Z")!
        XCTAssertEqual(ETFTime.day(utc), "2026-11-06")
    }

    func testFixedBasketAndExchangeEncoding() {
        XCTAssertEqual(codes.count, 20)
        XCTAssertEqual(Set(codes).count, 20)
        XCTAssertFalse(codes.contains(ETFDescriptor.indexCode))
        XCTAssertEqual(ETFDescriptor.basket.first { $0.code == "159919" }?.secid, "0.159919")
        XCTAssertEqual(ETFDescriptor.basket.first?.secid, "1.510310")
    }

    // MARK: Parsing

    func testMinuteParsingKeepsLatestDayAndLastDuplicate() throws {
        let series = try XCTUnwrap(ETFService.parseMinutes([
            "2026-11-05 09:30,4,4,4,4,100,40000,4",
            "2026-11-06 09:30,4,4,4,4,100,41000,4",
            "2026-11-06 09:30,4,4,4,4,110,44000,4",
            "2026-11-06 12:00,4,4,4,4,100,99999,4",
            "2026-11-06 09:31,4,4,4,4,100,-1,4",
            "2026-11-05 09:31,4,4,4,4,100,5,4"
        ]))
        XCTAssertEqual(series.day, "2026-11-06")
        XCTAssertEqual(series.amount[0], 44000)
        XCTAssertNil(series.amount[1])
        XCTAssertEqual(series.lastSlot, 0)
        XCTAssertNil(ETFService.parseMinutes(["garbage", ""]))
    }

    func testQuoteParsingHandlesMissingValuesAndForeignCodes() {
        let json = """
        {"data":{"diff":[
          {"f12":"510310","f6":100000000.0,"f3":-1.38,"f124":1793952718},
          {"f12":"159919","f6":"-","f3":"-","f124":1793952718},
          {"f12":"510300","f6":0,"f3":"-","f124":1793952718},
          {"f12":"000001","f6":7.7e11,"f3":-1.1,"f124":1793952720},
          {"f12":"600519","f6":1,"f3":1,"f124":1793952718}
        ]}}
        """
        let rows = ETFService.parseQuotes(Data(json.utf8))
        XCTAssertEqual(rows.map(\.code), ["510310", "510300", "000001"])
        XCTAssertEqual(rows[0].amount, 1e8)
        XCTAssertEqual(rows[0].changePercent, -1.38)
        XCTAssertNil(rows[1].changePercent)
        XCTAssertTrue(ETFService.parseQuotes(Data("not json".utf8)).isEmpty)
    }

    func testBarParsingMapsLabelsToFortyEightBars() {
        let days = ETFService.parseBars([
            "2026-11-05 09:35,10", "2026-11-05 11:30,20", "2026-11-05 13:05,30", "2026-11-05 15:00,40",
            "2026-11-05 09:36,99", "2026-11-05 09:30,99", "2026-11-05 13:00,99", "2026-11-06 09:35,-1", "2026-11-06 09:40,50"
        ])
        let d = days["2026-11-05"]
        XCTAssertEqual(d?.count, 48)
        XCTAssertEqual([d?[0], d?[23], d?[24], d?[47]], [10, 20, 30, 40])
        XCTAssertEqual(d?.compactMap { $0 }.count, 4)
        XCTAssertEqual(days["2026-11-06"]?[1], 50)
        XCTAssertNil(days["2026-11-06"]?[0])
    }

    // MARK: Baseline curves

    private func bars(_ perDay: [String: Double], skipping skipped: (code: String, day: String)? = nil)
        -> [String: [String: [Double?]]] {
        Dictionary(uniqueKeysWithValues: codes.map { code in
            (code, Dictionary(uniqueKeysWithValues: perDay.map { day, value in
                var values = [Double?](repeating: value, count: ETFTime.barsPerDay)
                if skipped?.code == code, skipped?.day == day { values[10] = nil }
                return (day, values)
            }))
        })
    }

    func testBaselineUsesPreviousSessionAndTwentyDayMean() throws {
        var perDay: [String: Double] = [:]
        for i in 1...25 { perDay[String(format: "2026-10-%02d", i)] = Double(i) }
        perDay["2026-11-06"] = 1000 // the live day never feeds its own baseline
        let baseline = try XCTUnwrap(ETFBaseline.build(bars: bars(perDay), liveDay: "2026-11-06"))
        XCTAssertEqual(baseline.previousDay, "2026-10-25")
        XCTAssertEqual(baseline.averageDays, 20)
        XCTAssertEqual(baseline.previous.slots, [0] + (1...48).map { $0 * 5 })
        // 20 ETFs x value per bar, accumulated: first bar then the full session.
        XCTAssertEqual(baseline.previous.values[1], 20 * 25)
        XCTAssertEqual(baseline.previous.values[48], 20 * 25 * 48)
        let mean = (6...25).reduce(0.0) { $0 + Double($1) } / 20
        XCTAssertEqual(try XCTUnwrap(baseline.average).values[48], 20 * mean * 48, accuracy: 1e-6)
    }

    func testBaselineSkipsDaysAnyETFIsMissingAndNeedsEveryETF() throws {
        let perDay = ["2026-11-03": 1.0, "2026-11-04": 2.0, "2026-11-05": 3.0, "2026-11-06": 9.0]
        let gap = bars(perDay, skipping: ("510310", "2026-11-05"))
        let baseline = try XCTUnwrap(ETFBaseline.build(bars: gap, liveDay: "2026-11-06"))
        XCTAssertEqual(baseline.previousDay, "2026-11-04")
        XCTAssertEqual(baseline.averageDays, 2)
        XCTAssertNil(baseline.average, "fewer than three sessions is not an average")
        var missing = bars(perDay)
        missing["159919"] = nil
        XCTAssertNil(ETFBaseline.build(bars: missing, liveDay: "2026-11-06"))
        XCTAssertNil(ETFBaseline.build(bars: bars(["2026-11-06": 1]), liveDay: "2026-11-06"))
    }

    func testCurveInterpolatesAndClamps() {
        let curve = ETFCurve(slots: [0, 5, 10], values: [0, 10, 30])
        XCTAssertEqual(curve.value(at: 0), 0)
        XCTAssertEqual(curve.value(at: 7), 18, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 10), 30)
        XCTAssertEqual(curve.value(at: 99), 30)
        XCTAssertEqual(curve.value(at: -3), 0)
    }

    // MARK: Display

    private func series(day: String = "2026-11-06", through last: Int, amount: Double, close: Double = 3000) -> ETFMinuteSeries {
        var s = ETFMinuteSeries(day: day, amount: [Double?](repeating: nil, count: ETFTime.slotCount),
                                close: [Double?](repeating: nil, count: ETFTime.slotCount))
        for slot in 0...last { s.amount[slot] = amount; s.close[slot] = close + Double(slot) }
        return s
    }
    private func quotes(offset: Double = 0) -> [ETFQuote] {
        codes.enumerated().map { i, code in
            ETFQuote(code: code, amount: (Double(i) + 1 + offset) * 1e8, changePercent: i == 0 ? nil : Double(i) - 10, timestamp: shanghaiMorning)
        } + [ETFQuote(code: ETFDescriptor.indexCode, amount: 9e11, changePercent: 1, timestamp: shanghaiMorning)]
    }

    func testStaleDetectionAllowsFiveMinuteDelayAndDetectsOlderSessions() {
        let current = series(through: 10, amount: 1)
        XCTAssertFalse(ETFWorker.isStale(current, day: "2026-11-06", slot: 15))
        XCTAssertTrue(ETFWorker.isStale(current, day: "2026-11-06", slot: 16))
        XCTAssertTrue(ETFWorker.isStale(current, day: "2026-11-09", slot: 0))
    }

    func testMinuteCacheRejectsOlderAndTruncatedResponsesAndRetainsGaps() throws {
        let cached = series(through: 4, amount: 10)
        XCTAssertNil(ETFWorker.mergeMinutes(cached, series(through: 2, amount: 20)))
        XCTAssertNil(ETFWorker.mergeMinutes(cached, series(day: "2026-11-05", through: 5, amount: 20)))
        var incoming = series(through: 5, amount: 20)
        incoming.amount[2] = nil
        incoming.close[2] = nil
        let merged = try XCTUnwrap(ETFWorker.mergeMinutes(cached, incoming))
        XCTAssertEqual(merged.amount[2], 10)
        XCTAssertEqual(merged.amount[1], 20, "newer responses can correct historical values")
        XCTAssertEqual(merged.lastSlot, 5)
        let nextDay = series(day: "2026-11-09", through: 1, amount: 30)
        XCTAssertEqual(ETFWorker.mergeMinutes(cached, nextDay)?.day, "2026-11-09")
    }

    func testQuoteCachePreservesMissingAndOlderSymbols() {
        let old = quotes()
        let stale = ETFQuote(code: codes[0], amount: 1, changePercent: 0,
                             timestamp: shanghaiMorning.addingTimeInterval(-60))
        let fresh = ETFQuote(code: codes[1], amount: 99, changePercent: 1,
                             timestamp: shanghaiMorning.addingTimeInterval(60))
        let merged = Dictionary(uniqueKeysWithValues: ETFWorker.mergeQuotes(old, [stale, fresh]).map { ($0.code, $0) })
        XCTAssertEqual(merged.count, old.count)
        XCTAssertEqual(merged[codes[0]], old[0])
        XCTAssertEqual(merged[codes[1]], fresh)
        XCTAssertEqual(merged[codes[2]], old[2])
    }

    func testDisplayTotalsRankingAndMinutes() {
        var minutes = Dictionary(uniqueKeysWithValues: codes.map { ($0, series(through: 2, amount: 1e6)) })
        minutes[ETFDescriptor.indexCode] = series(through: 3, amount: 5e9)
        let d = ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: nil)
        XCTAssertEqual(d.day, "2026-11-06")
        XCTAssertEqual(d.quoteCount, 20)
        XCTAssertEqual(d.minuteCount, 20)
        XCTAssertEqual(d.total, 210e8, "index turnover is never part of the basket total")
        XCTAssertEqual(d.rows.first?.code, codes.last)
        XCTAssertEqual(d.rows.first?.fraction, 1)
        XCTAssertEqual(d.rows.first?.amountText, "20.00")
        XCTAssertEqual(d.rows.last?.changeText, "—")
        XCTAssertEqual(d.rows.map(\.amountText), d.rows.map(\.amountText).sorted { Double($0)! > Double($1)! })
        XCTAssertEqual(d.bars, [20e6, 20e6, 20e6])
        XCTAssertEqual(d.cumulative, [20e6, 40e6, 60e6])
        XCTAssertEqual(d.index.count, 4, "the index line keeps its own newest minute")
        XCTAssertNil(d.previous)
        XCTAssertNil(d.paceAverage)
    }

    func testDisplayStopsAtNewestMinuteEveryCachedETFReported() {
        var minutes = Dictionary(uniqueKeysWithValues: codes.map { ($0, series(through: 5, amount: 1)) })
        minutes[codes[0]] = series(through: 4, amount: 1)      // answered a minute late
        minutes[codes[1]] = series(through: 1, amount: 1)      // request failed: stale series
        let d = ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: nil)
        XCTAssertEqual(d.liveSlot, 1)
        XCTAssertEqual(d.bars, [20, 20], "a stale ETF must not be counted as zero in later minutes")
        XCTAssertEqual(ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: nil).liveSlot, 1)
    }

    func testDisplayExcludesOtherDaysAndMissingETFs() {
        var minutes = Dictionary(uniqueKeysWithValues: codes.dropFirst().map { ($0, series(through: 1, amount: 1)) })
        minutes[codes[0]] = series(day: "2026-11-05", through: 1, amount: 1)
        var q = quotes()
        q[1] = ETFQuote(code: codes[1], amount: 5e8, changePercent: 0, timestamp: shanghaiMorning.addingTimeInterval(-86_400))
        let d = ETFDisplay.build(quotes: q, minutes: minutes, baseline: nil)
        XCTAssertEqual(d.minuteCount, 19)
        XCTAssertEqual(d.quoteCount, 19)
        XCTAssertEqual(d.bars, [19, 19])
        XCTAssertTrue(ETFDisplay.build(quotes: [], minutes: [:], baseline: nil).isEmpty)
    }

    func testPaceComparesRunningTotalAtTheSameMinute() throws {
        let minutes = Dictionary(uniqueKeysWithValues: codes.map { ($0, series(through: 10, amount: 1)) })
        let slots = [0] + (1...48).map { $0 * 5 }
        let flat = ETFCurve(slots: slots, values: slots.map { Double($0) * 10 })
        let baseline = ETFBaseline(liveDay: "2026-11-06", previousDay: "2026-11-05", previous: flat,
                                   average: ETFCurve(slots: slots, values: slots.map { Double($0) * 40 }), averageDays: 20)
        let d = ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: baseline)
        // 11 minutes x 20 ETFs = 220 so far; previous day had 100 at slot 10, the mean 400.
        XCTAssertEqual(try XCTUnwrap(d.pacePrevious), 220.0 / 100 - 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(d.paceAverage), 220.0 / 400 - 1, accuracy: 1e-9)
        XCTAssertEqual(d.previousDay, "2026-11-05")
        let stale = ETFBaseline(liveDay: "2026-11-05", previousDay: "2026-11-04", previous: flat, average: nil, averageDays: 0)
        XCTAssertNil(ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: stale).previous)
    }

    func testIdenticalRefreshProducesEqualDisplay() {
        let minutes = Dictionary(uniqueKeysWithValues: codes.map { ($0, series(through: 3, amount: 1e6)) })
        let a = ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: nil)
        let b = ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: nil)
        XCTAssertEqual(a, b, "an unchanged refresh must not republish the board")
        XCTAssertNotEqual(a, ETFDisplay.build(quotes: quotes(offset: 1), minutes: minutes, baseline: nil))
    }

    // MARK: Rendering

    @MainActor
    func testPanelContentRendersFullSessionWithoutBlockingMainThread() throws {
        var minutes = Dictionary(uniqueKeysWithValues: codes.map { ($0, series(through: 240, amount: 1e6)) })
        minutes[ETFDescriptor.indexCode] = series(through: 240, amount: 5e9)
        let slots = [0] + (1...48).map { $0 * 5 }
        let curve = ETFCurve(slots: slots, values: slots.map { Double($0) * 18e6 })
        let baseline = ETFBaseline(liveDay: "2026-11-06", previousDay: "2026-11-05", previous: curve,
                                   average: ETFCurve(slots: slots, values: slots.map { Double($0) * 22e6 }), averageDays: 20)
        let display = ETFDisplay.build(quotes: quotes(), minutes: minutes, baseline: baseline)
        let renderer = ImageRenderer(content: ETFContent(display: display, scheme: .east).frame(width: 486).padding(12)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        let start = CFAbsoluteTimeGetCurrent()
        let image = try XCTUnwrap(renderer.nsImage)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertGreaterThan(image.size.height, 600, "all sections lay out")
        print("ETFContent first render \(String(format: "%.1f", elapsed)) ms, \(Int(image.size.width))x\(Int(image.size.height)) pt")
        if let dir = ProcessInfo.processInfo.environment["ETF_RENDER_DIR"],
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("etf-panel.png"))
        }
    }
}

@MainActor
final class ETFMonitorSchedulingTests: XCTestCase {
    private final class FakeWorker: ETFRefreshing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var outcome = ETFOutcome()
        var preparedBaseline: ETFBaseline?
        func prepareBaseline(for day: String) async -> ETFBaseline? { preparedBaseline }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func refresh() async -> ETFOutcome {
            lock.lock(); count += 1; lock.unlock()
            return outcome
        }
    }

    private actor LifecycleWorker: ETFRefreshing {
        let outcome: ETFOutcome
        let baseline: ETFBaseline
        var holdRefresh: Bool
        var firstBaselineWaits: Bool
        var firstBaselineFails: Bool
        var refreshStarted = false
        var refreshContinuation: CheckedContinuation<ETFOutcome, Never>?
        var baselineCalls = 0

        init(outcome: ETFOutcome, baseline: ETFBaseline, holdRefresh: Bool = false,
             firstBaselineWaits: Bool = false, firstBaselineFails: Bool = false) {
            self.outcome = outcome
            self.baseline = baseline
            self.holdRefresh = holdRefresh
            self.firstBaselineWaits = firstBaselineWaits
            self.firstBaselineFails = firstBaselineFails
        }

        func refresh() async -> ETFOutcome {
            refreshStarted = true
            if holdRefresh {
                return await withCheckedContinuation { refreshContinuation = $0 }
            }
            return outcome
        }

        func finishRefresh() {
            refreshContinuation?.resume(returning: outcome)
            refreshContinuation = nil
        }

        func prepareBaseline(for day: String) async -> ETFBaseline? {
            baselineCalls += 1
            if baselineCalls == 1 && firstBaselineWaits {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return nil }
            }
            if baselineCalls == 1 && firstBaselineFails { return nil }
            return baseline
        }
    }

    private func lifecycleData() -> (ETFOutcome, ETFBaseline) {
        var display = ETFDisplay()
        display.day = "2026-11-06"
        display.cumulative = [10, 40]
        display.bars = [10, 30]
        let curve = ETFCurve(slots: [0, 1], values: [1, 20])
        let baseline = ETFBaseline(liveDay: display.day, previousDay: "2026-11-05",
                                   previous: curve, average: nil, averageDays: 0)
        return (ETFOutcome(display: display, baselineMissing: true), baseline)
    }

    private var defaultsBackup: Bool!
    private var monitors: [ETFMonitor] = []
    override func setUp() {
        defaultsBackup = UserDefaults.standard.bool(forKey: "etfPanelSelected")
    }
    override func tearDown() {
        // A polling loop retains its monitor; stop them so none keeps ticking through the rest of the suite.
        for monitor in monitors { monitor.setVisible(.popover, false); monitor.setVisible(.pinned, false) }
        monitors = []
        UserDefaults.standard.set(defaultsBackup, forKey: "etfPanelSelected")
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private func makeMonitor(_ worker: ETFRefreshing, market: MarketStatus = .open) -> ETFMonitor {
        let monitor = ETFMonitor(worker: worker, interval: 0.05, marketStatus: { market })
        monitor.selectedPage = true
        monitors.append(monitor)
        return monitor
    }

    func testNothingRunsWhileHidden() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker)
        await settle()
        XCTAssertEqual(worker.calls, 0)
        XCTAssertFalse(monitor.isPolling)
    }

    func testPollsOnlyWhileVisibleAndStopsOnHide() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker)
        monitor.setVisible(.popover, true)
        await settle()
        XCTAssertTrue(monitor.isPolling)
        XCTAssertGreaterThanOrEqual(worker.calls, 3)
        monitor.setVisible(.popover, false)
        XCTAssertFalse(monitor.isPolling)
        await settle(0.1)
        let stopped = worker.calls
        await settle()
        XCTAssertEqual(worker.calls, stopped, "no requests once the panel is hidden")
    }

    func testPinnedWindowKeepsPollingAcrossPopoverClose() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker)
        monitor.setVisible(.popover, true)
        monitor.setVisible(.pinned, true)
        monitor.setVisible(.popover, false)
        XCTAssertTrue(monitor.isPolling)
        monitor.setVisible(.pinned, false)
        XCTAssertFalse(monitor.isPolling)
    }

    func testLeavingTheETFPageStopsPolling() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker)
        monitor.setVisible(.popover, true)
        XCTAssertTrue(monitor.isPolling)
        monitor.selectedPage = false
        XCTAssertFalse(monitor.isPolling)
        monitor.selectedPage = true
        XCTAssertTrue(monitor.isPolling)
    }

    func testClosedMarketRefreshesOnlyOnOpenAndOnlyWhenStale() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker, market: .closed)
        monitor.setVisible(.popover, true)
        await settle()
        XCTAssertEqual(worker.calls, 1, "one load on open, no timer refreshes after the close")
        monitor.setVisible(.popover, false)
        monitor.setVisible(.popover, true)
        await settle()
        XCTAssertEqual(worker.calls, 1, "fresh data is not fetched again on reopen")
    }

    func testPauseStopsAllAutomaticRequestsButNotManualOnes() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker)
        monitor.togglePause()
        monitor.setVisible(.popover, true)
        await settle()
        XCTAssertEqual(worker.calls, 0, "neither the load on open nor the timer runs while paused")
        await monitor.refresh()
        XCTAssertEqual(worker.calls, 1)
        XCTAssertTrue(monitor.paused)
        monitor.togglePause()
        await settle()
        XCTAssertGreaterThan(worker.calls, 1, "resuming refreshes again")
    }

    func testPausingDuringAutomaticRefreshDoesNotStartBaseline() async {
        let (outcome, baseline) = lifecycleData()
        let worker = LifecycleWorker(outcome: outcome, baseline: baseline, holdRefresh: true)
        let monitor = makeMonitor(worker, market: .closed)
        monitor.setVisible(.popover, true)
        await settle(0.05)
        let started = await worker.refreshStarted
        XCTAssertTrue(started)
        monitor.togglePause()
        await worker.finishRefresh()
        await settle(0.05)
        let calls = await worker.baselineCalls
        XCTAssertEqual(calls, 0)
    }

    func testManualRefreshWhilePausedCanLoadBaseline() async {
        let (outcome, baseline) = lifecycleData()
        let worker = LifecycleWorker(outcome: outcome, baseline: baseline)
        let monitor = makeMonitor(worker, market: .closed)
        monitor.togglePause()
        await monitor.refresh()
        await settle(0.05)
        let calls = await worker.baselineCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(monitor.board.display.previousDay, "2026-11-05")
    }

    func testReopeningRestartsCancelledBaselineWithoutRefreshingQuotes() async {
        let (outcome, baseline) = lifecycleData()
        let worker = LifecycleWorker(outcome: outcome, baseline: baseline, firstBaselineWaits: true)
        let monitor = makeMonitor(worker, market: .closed)
        monitor.setVisible(.popover, true)
        await settle(0.05)
        let initialCalls = await worker.baselineCalls
        XCTAssertEqual(initialCalls, 1)
        monitor.setVisible(.popover, false)
        monitor.setVisible(.popover, true)
        await settle(0.1)
        let calls = await worker.baselineCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(monitor.board.display.previousDay, "2026-11-05")
    }

    func testClosedMarketRetriesFailedBaselineWhileVisible() async {
        let (outcome, baseline) = lifecycleData()
        let worker = LifecycleWorker(outcome: outcome, baseline: baseline, firstBaselineFails: true)
        let monitor = makeMonitor(worker, market: .closed)
        monitor.setVisible(.popover, true)
        await settle(0.2)
        let calls = await worker.baselineCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(monitor.board.display.previousDay, "2026-11-05")
        XCTAssertFalse(monitor.status.warning, "a loaded baseline clears the failure warning")
    }

    func testBaselineWarningAppearsOnlyAfterAFailedAttempt() async {
        let (outcome, baseline) = lifecycleData()
        let worker = LifecycleWorker(outcome: outcome, baseline: baseline, firstBaselineFails: true)
        let monitor = makeMonitor(worker, market: .closed)
        await monitor.refresh()
        await settle(0.1)
        XCTAssertTrue(monitor.status.warning)
        XCTAssertEqual(monitor.status.text, L("etf.error.baseline"))
    }

    func testBaselineStillLoadingDoesNotWarn() async {
        let (outcome, baseline) = lifecycleData()
        let worker = LifecycleWorker(outcome: outcome, baseline: baseline, firstBaselineWaits: true)
        let monitor = makeMonitor(worker, market: .closed)
        await monitor.refresh()
        await settle(0.1)
        XCTAssertFalse(monitor.status.warning, "loading the baseline is not a failure")
        XCTAssertFalse(monitor.status.text.contains(L("etf.error.baseline")))
    }

    func testBaselineLoadsSeparatelyAndUpdatesTheCurrentDisplay() async {
        let worker = FakeWorker()
        let curve = ETFCurve(slots: [0, 1], values: [1, 20])
        worker.preparedBaseline = ETFBaseline(liveDay: "2026-11-06", previousDay: "2026-11-05",
                                             previous: curve, average: nil, averageDays: 0)
        var display = ETFDisplay()
        display.day = "2026-11-06"
        display.cumulative = [10, 40]
        display.bars = [10, 30]
        worker.outcome = ETFOutcome(display: display, baselineMissing: true)
        let monitor = makeMonitor(worker, market: .closed)
        await monitor.refresh()
        await settle(0.05)
        XCTAssertEqual(monitor.board.display.previousDay, "2026-11-05")
        XCTAssertEqual(monitor.board.display.pacePrevious, 1)
    }

    func testNewSessionWaitsForCompleteBasket() async {
        let worker = FakeWorker()
        let monitor = makeMonitor(worker, market: .closed)
        var previous = ETFDisplay()
        previous.day = "2026-11-06"
        previous.quoteCount = 20
        previous.minuteCount = 20
        previous.total = 123
        worker.outcome.display = previous
        await monitor.refresh()

        var partial = ETFDisplay()
        partial.day = "2026-11-09"
        partial.quoteCount = 1
        partial.minuteCount = 1
        worker.outcome.display = partial
        await monitor.refresh()
        XCTAssertEqual(monitor.board.display, previous)
        XCTAssertTrue(monitor.status.warning)

        partial.quoteCount = 20
        partial.minuteCount = 20
        worker.outcome.display = partial
        await monitor.refresh()
        XCTAssertEqual(monitor.board.display, partial)
    }

    func testFailedRefreshKeepsDataAndFlagsWarning() async {
        let worker = FakeWorker()
        worker.outcome = ETFOutcome(display: ETFDisplay(), quotesFailed: true, failedMinutes: 3, baselineMissing: false)
        let monitor = makeMonitor(worker, market: .closed)
        await monitor.refresh()
        XCTAssertTrue(monitor.status.warning)
        XCTAssertNotNil(monitor.status.updated, "some requests succeeded")
        worker.outcome = ETFOutcome(display: ETFDisplay(), quotesFailed: true, failedMinutes: 20, baselineMissing: false)
        let offline = makeMonitor(worker, market: .closed)
        await offline.refresh()
        XCTAssertTrue(offline.status.warning)
        XCTAssertNil(offline.status.updated, "an offline attempt is not a successful update")
    }
}
