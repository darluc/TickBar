import XCTest
@testable import TickBar

final class TencentStockVolumeTests: XCTestCase {
    private func session(_ scenario: String) -> (URLSession, HTTPClient) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TencentVolumeProtocol.self]
        let session = URLSession(configuration: config)
        return (session, HTTPClient(session: session, defaultHeaders: ["X-Volume-Fixture": scenario]))
    }

    func testInfoRequiresMatchingSymbolAndReturnsTradingDate() throws {
        let info = try TencentStockVolumeService.parseInfo(
            "v_detail_time_sz000001=[20261112,\"09:25:00~09:30:00|09:31:00~09:31:00\"];", symbol: "sz000001")
        XCTAssertEqual(info.day, "2026-11-12")
        XCTAssertEqual(info.pages, 2)
        XCTAssertThrowsError(try TencentStockVolumeService.parseInfo(
            "v_detail_time_sh600519=[20261112,\"09:25:00~09:30:00\"]", symbol: "sz000001"))
    }

    func testMinuteCumulativeVolumesSkipLunchAndPostMarketWithoutInventingGaps() throws {
        let data = Data("""
        {"data":{"sz000001":{"data":{"date":"20261112","data":[
          "0930 10 100 100000", "0931 10 130 130000", "0931 10 150 150000",
          "0933 10 200 200000", "0934 10 210 210000", "1300 10 210 210000", "1501 10 220 220000"]}}}}
        """.utf8)
        let series = try TencentStockVolumeService.parseMinutes(data, symbol: "sz000001")
        XCTAssertEqual(series.day, "2026-11-12")
        XCTAssertEqual(series.volumes, [0: 100, 1: 50, 4: 10])
        XCTAssertThrowsError(try TencentStockVolumeService.parseMinutes(data, symbol: "sh600519"))
        let decreasing = Data("""
        {"data":{"sz000001":{"data":{"date":"20261112","data":["0930 10 100","0931 10 99"]}}}}
        """.utf8)
        XCTAssertThrowsError(try TencentStockVolumeService.parseMinutes(decreasing, symbol: "sz000001"))
    }

    func testTradeFailureFallsBackButKeepsSuccessfulEastMoneyMinuteFeed() async throws {
        let (session, http) = session("details")
        defer { session.invalidateAndCancel() }
        let result = try await StockVolumeService(http: http).fetch(symbol: .init(code: "000001", market: .a))
        XCTAssertEqual(result.minuteSource, .eastMoney)
        XCTAssertEqual(result.detailSource, .tencent)
        XCTAssertEqual(result.total, 200)
        XCTAssertEqual(result.coverage, 1)
        XCTAssertEqual(result.minutes[0].buyAmount, 120_001, "use source turnover, not price × volume")
        XCTAssertEqual(result.minutes[1].sellAmount, 99_999)
        XCTAssertEqual(result.summaries[1].buy, 120_001)
        XCTAssertEqual(result.summaries[2].sell, 99_999)
    }

    func testBothFeedsFallBackWhenEastMoneyIsUnavailable() async throws {
        let (session, http) = session("both")
        defer { session.invalidateAndCancel() }
        let result = try await StockVolumeService(http: http).fetch(symbol: .init(code: "000001", market: .a))
        XCTAssertEqual(result.minuteSource, .tencent)
        XCTAssertEqual(result.detailSource, .tencent)
        XCTAssertEqual(result.coverage, 1)
        XCTAssertEqual(result.day, "2026-11-12")
    }

    func testFallbackDoesNotCombineDifferentTradingDates() async throws {
        let (session, http) = session("stale")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await StockVolumeService(http: http).fetch(symbol: .init(code: "000001", market: .a))
            XCTFail("different trade dates must not be combined")
        } catch StockVolumeError.dateMismatch { }
    }

    func testCompletedPagesAreCachedButLastPageIsRefreshed() async throws {
        let (session, http) = session("cache")
        defer { session.invalidateAndCancel() }
        let service = TencentStockVolumeService(http: http)
        let first = try await service.fetchDetails(symbol: "sz000001")
        let second = try await service.fetchDetails(symbol: "sz000001")
        XCTAssertEqual(first.trades, second.trades)
        XCTAssertEqual(first.trades.count, 3)
        XCTAssertEqual(TencentVolumeProtocol.count(scenario: "cache", key: "data-0"), 1)
        XCTAssertEqual(TencentVolumeProtocol.count(scenario: "cache", key: "data-1"), 2)
        XCTAssertEqual(TencentVolumeProtocol.count(scenario: "cache", key: "info-"), 2)
    }

    func testInvalidPageFailsWholeSnapshotInsteadOfReturningPartialData() async throws {
        let (session, http) = session("badPage")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await TencentStockVolumeService(http: http).fetchDetails(symbol: "sz000001")
            XCTFail("page indexes must match the requested page")
        } catch StockVolumeError.invalidResponse { }
    }

    func testDelayedSessionCloseAndNeutralTradeDirection() async throws {
        let (session, http) = session("close")
        defer { session.invalidateAndCancel() }
        let result = try await TencentStockVolumeService(http: http).fetchDetails(symbol: "sz000001")
        XCTAssertEqual(result.trades.map(\.slot), [0, 120, 240])
        XCTAssertEqual(result.trades.map(\.side), [2, 1, 4])
    }
}

private final class TencentVolumeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [String: [String: Int]] = [:]
    static func count(scenario: String, key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests[scenario]?[key] ?? 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let scenario = request.value(forHTTPHeaderField: "X-Volume-Fixture")!
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        let action = query["action"] ?? ""
        let page = query["p"] ?? ""
        Self.lock.lock()
        Self.requests[scenario, default: [:]]["\(action)-\(page)", default: 0] += 1
        Self.lock.unlock()
        var status = 200
        let body: String
        if url.host == "push2.eastmoney.com" {
            if url.path.contains("details") || scenario == "both" {
                status = 502
                body = "unavailable"
            } else {
                body = """
                {"data":{"code":"000001","trends":[
                  "2026-11-12 09:30,10,10,10,10,100,100000,10",
                  "2026-11-12 09:31,10,10,10,10,100,100000,10",
                  "2026-11-12 09:32,10,10,10,10,10,10000,10"]}}
                """
            }
        } else if url.host == "web.ifzq.gtimg.cn" {
            body = """
            {"data":{"sz000001":{"data":{"date":"20261112","data":["0930 10 100","0931 10 200","0932 10 210"]}}}}
            """
        } else if action == "info" {
            let day = scenario == "stale" ? 20261111 : 20261112
            body = "v_detail_time_sz000001=[\(day),\"09:25:00~09:30:00|09:31:00~09:31:00\"]"
        } else if page == "0" {
            let second = scenario == "close" ? "11:30:02" : "09:30:00"
            body = "v_detail_data_sz000001=[0,\"0/09:25:00/10/0/100/120001/B|1/\(second)/10/0/100/99999/S\"]"
        } else {
            let index = scenario == "badPage" ? 0 : 1
            let time = scenario == "close" ? "15:00:04" : "09:31:00"
            body = "v_detail_data_sz000001=[\(index),\"2/\(time)/10/0/10/10000/M\"]"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
