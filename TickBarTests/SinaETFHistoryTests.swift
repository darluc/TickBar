import XCTest
@testable import TickBar

final class SinaETFHistoryTests: XCTestCase {
    func testBarsParseAmountsAndOnlyKeepBarCloseLabels() throws {
        let json = """
        [{"day":"2026-11-19 09:30:00","amount":"1"},
         {"day":"2026-11-19 09:35:00","amount":"100"},
         {"day":"2026-11-19 09:40:00","amount":"250.5"},
         {"day":"2026-11-19 11:30:00","amount":"300"},
         {"day":"2026-11-19 13:05:00","amount":"400"},
         {"day":"2026-11-19 15:00:00","amount":"500"}]
        """
        let days = SinaETFHistoryService.parseBars(Data(json.utf8))
        let day = try XCTUnwrap(days["2026-11-19"])
        XCTAssertEqual(day.count, ETFTime.barsPerDay)
        XCTAssertEqual(day[0], 100)
        XCTAssertEqual(day[1], 250.5)
        XCTAssertEqual(day[23], 300)
        XCTAssertEqual(day[24], 400)
        XCTAssertEqual(day[47], 500)
        XCTAssertNil(day[2])
    }

    func testWorkerBuildsBaselineFromSinaWhenEastMoneyHistoryIsThrottled() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SinaHistoryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let worker = ETFWorker(
            service: ETFService(http: client, gate: ETFRequestGate(spacing: 0),
                                historyGate: ETFRequestGate(spacing: 0)),
            fallback: TencentETFService(http: client, gate: ETFRequestGate(spacing: 0)),
            historyFallback: SinaETFHistoryService(http: client, gate: ETFRequestGate(spacing: 0)),
            baselineCache: ETFBaselineCache(url: nil))

        let baseline = await worker.prepareBaseline(for: "2026-11-20")
        let result = try XCTUnwrap(baseline)
        XCTAssertEqual(result.previousDay, "2026-11-19")
        XCTAssertEqual(result.averageDays, 3)
        let total = Double(ETFDescriptor.basket.count * ETFTime.barsPerDay * 100)
        XCTAssertEqual(result.previous.values.last ?? 0, total)
    }
}

/// East Money's history host is throttled; Sina serves three complete sessions per symbol.
private final class SinaHistoryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        guard url.host == "quotes.sina.cn" else {
            let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                           headerFields: ["Retry-After": "30"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var rows: [[String: String]] = []
        for day in ["2026-11-17", "2026-11-18", "2026-11-19"] {
            for slot in stride(from: 5, through: ETFTime.lastSlot, by: 5) {
                rows.append(["day": "\(day) \(ETFTime.label(slot: slot)):00", "amount": "100"])
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
