import XCTest
@testable import TickBar

final class HoldingsTests: XCTestCase {
    func testStockRecordsKeepPeriodAndFilterHolders() throws {
        let data = Data("""
        {"success":true,"result":{"data":[
          {"HOLDER_NAME":"其他股东","END_DATE":"2026-09-30 00:00:00","NOTICE_DATE":"2026-10-30 00:00:00","HOLD_NUM":10,"FREE_HOLDNUM_RATIO":1},
          {"HOLDER_NAME":"中央汇金资产管理有限责任公司","END_DATE":"2026-06-30 00:00:00","NOTICE_DATE":"2026-08-30 00:00:00","HOLD_NUM":"25000","FREE_HOLDNUM_RATIO":"2.5"},
          {"HOLDER_NAME":"全国社保基金一零一组合","END_DATE":"2026-03-31 00:00:00","NOTICE_DATE":null,"HOLD_NUM":null,"FREE_HOLDNUM_RATIO":null}
        ]}}
        """.utf8)
        let result = try HoldingsService.parseStock(data, code: "600000", name: "测试")
        XCTAssertEqual(result.latestPeriod, "2026-09-30 00:00:00")
        XCTAssertEqual(result.holdings.count, 2)
        XCTAssertEqual(result.holdings[0].shares, 25000)
        XCTAssertEqual(result.holdings[0].percent, 2.5)
        XCTAssertNil(result.holdings[1].shares)
    }

    func testETFShareSnapshotsRejectMissingAndUnknownValues() throws {
        let data = Data(#"{"data":{"diff":[{"f12":"510300","f38":46342387712},{"f12":"510050","f38":"-"},{"f12":"999999","f38":1}]}}"#.utf8)
        let result = try HoldingsService.parseETFShares(data, day: "2026-11-16")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.code, "510300")
        XCTAssertEqual(result.first?.observedDay, "2026-11-16")
        XCTAssertEqual(result.first?.shares, 46342387712)
    }

    func testFailureIsNotAnEmptyHolding() {
        let data = Data(#"{"success":false,"result":null}"#.utf8)
        XCTAssertThrowsError(try HoldingsService.parseStock(data, code: "600000", name: "测试"))
    }

    @MainActor
    func testStockHoldingsMonitorLoadsOnceAndRefreshesOnDemand() async {
        var calls = 0
        let monitor = StockHoldingsMonitor(code: "600000", name: "测试", cacheURL: nil) { code, name in
            calls += 1
            return StockHoldingResult(code: code, name: name, latestPeriod: "2026-09-30 00:00:00", holdings: [])
        }
        await monitor.load()
        await monitor.load()
        XCTAssertEqual(calls, 1, "opening the panel must not refetch disclosed holdings")
        XCTAssertEqual(monitor.result?.code, "600000")
        XCTAssertNotNil(monitor.result?.fetchedAt)
        XCTAssertNil(monitor.error)
        await monitor.refresh()
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(monitor.loading)
    }

    @MainActor
    func testStockHoldingsCacheSkipsFreshRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("holdings.json")
        var calls = 0
        let fetch: (String, String) async throws -> StockHoldingResult = { code, name in
            calls += 1
            return StockHoldingResult(code: code, name: name, latestPeriod: "2026-09-30 00:00:00", holdings: [])
        }

        let first = StockHoldingsMonitor(code: "600000", name: "测试", cacheURL: cacheURL, fetch: fetch)
        await first.load()
        XCTAssertEqual(calls, 1)

        let second = StockHoldingsMonitor(code: "600000", name: "测试", cacheURL: cacheURL, fetch: fetch)
        await second.load()
        XCTAssertEqual(calls, 1, "a fresh cache must avoid another request")
        XCTAssertEqual(second.result?.code, "600000")

        await second.refresh()
        XCTAssertEqual(calls, 2, "manual refresh must bypass the cache")
    }
}
