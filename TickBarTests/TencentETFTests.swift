import XCTest
@testable import TickBar

final class TencentETFTests: XCTestCase {
    func testMinutesConvertCumulativeTurnoverAndRejectGaps() throws {
        let payload = Data(#"{"data":{"sh510300":{"data":{"date":"20261116","data":["0930 4.068 50313 20467328.00","0931 4.053 256524 104171858.00","0932 4.055 333619 135430497.00"]}}}}"#.utf8)
        let result = try TencentETFService.parseMinutes(payload, symbol: "sh510300")
        XCTAssertEqual(result.day, "2026-11-16")
        XCTAssertEqual(result.amount[0], 20467328)
        XCTAssertEqual(result.amount[1], 83704530)
        XCTAssertEqual(result.amount[2], 31258639)
        let missing = Data(#"{"data":{"sh510300":{"data":{"date":"20261116","data":["0930 4.068 50313 20467328.00","0932 4.055 333619 135430497.00"]}}}}"#.utf8)
        XCTAssertThrowsError(try TencentETFService.parseMinutes(missing, symbol: "sh510300"))
    }

    func testQuotesUseTransactionAmountInYuan() throws {
        var fields = [String](repeating: "", count: 36)
        fields[2] = "510300"
        fields[30] = "20261116161436"
        fields[32] = "-0.71"
        fields[35] = "4.054/19985629/8100953829"
        let rows = TencentETFService.parseQuotes("v_sh510300=\"\(fields.joined(separator: "~"))\";", codes: ["510300"])
        let quote = try XCTUnwrap(rows.first)
        XCTAssertEqual(quote.amount, 8100953829)
        XCTAssertEqual(quote.changePercent, -0.71)
        XCTAssertEqual(ETFTime.day(quote.timestamp), "2026-11-16")
    }

    func testRetryAfterSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(HTTPClient.retryAfter("60", now: now), 60)
        XCTAssertEqual(HTTPClient.retryAfter("Thu, 01 Jan 1970 00:01:30 GMT", now: now), 90)
        XCTAssertNil(HTTPClient.retryAfter("invalid", now: now))
    }

    func testProviderCooldownPreventsNewRequests() async throws {
        let gate = ETFRequestGate(spacing: 0)
        await gate.rateLimited(for: 60)
        let cooling = await gate.isCoolingDown()
        XCTAssertTrue(cooling)
        do {
            try await gate.wait()
            XCTFail("expected cooldown")
        } catch HTTPError.rateLimited(let remaining) {
            XCTAssertGreaterThan(remaining ?? 0, 0)
        }
        let fresh = await ETFRequestGate(spacing: 0).isCoolingDown()
        XCTAssertFalse(fresh)
    }

    func testConsecutiveFailuresCoolDownOnlyThatProvider() async throws {
        let primary = ETFRequestGate(spacing: 0)
        let fallback = ETFRequestGate(spacing: 0)
        await primary.failed()
        await primary.failed()
        try await primary.wait()
        await primary.failed()
        do {
            try await primary.wait()
            XCTFail("expected cooldown after repeated errors")
        } catch HTTPError.rateLimited { }
        try await fallback.wait()
    }

    func testWorkerUsesFallbackWhenPrimaryMinuteSeriesStalls() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ETFStaleSourceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let worker = ETFWorker(service: ETFService(http: client, gate: ETFRequestGate(spacing: 0)),
                               fallback: TencentETFService(http: client, gate: ETFRequestGate(spacing: 0)))
        let outcome = await worker.refresh()
        XCTAssertEqual(outcome.failedMinutes, 0)
        XCTAssertEqual(outcome.fallbackMinutes, 1)
        XCTAssertEqual(outcome.display.liveSlot, 7)
        XCTAssertEqual(outcome.display.cumulative.last, 1600)
    }

    func testWorkerFallsBackWithoutWaitingForHistory() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ETFSourceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let primary = ETFService(http: client, gate: ETFRequestGate(spacing: 0))
        let fallback = TencentETFService(http: client, gate: ETFRequestGate(spacing: 0))
        let outcome = await ETFWorker(service: primary, fallback: fallback).refresh()
        XCTAssertEqual(outcome.display.quoteCount, 20)
        XCTAssertEqual(outcome.display.minuteCount, 20)
        XCTAssertEqual(outcome.display.cumulative, [200, 600])
        XCTAssertEqual(outcome.failedMinutes, 0)
        XCTAssertTrue(outcome.fallbackQuotes)
        XCTAssertEqual(outcome.fallbackMinutes, 20)
        XCTAssertTrue(outcome.baselineMissing)
    }

    func testBaselineRequestsUseTheirOwnGate() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ETFHistoryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let realtime = ETFRequestGate(spacing: 0)
        await realtime.rateLimited(for: 60)
        let service = ETFService(http: HTTPClient(session: session), gate: realtime,
                                 historyGate: ETFRequestGate(spacing: 0))

        do {
            _ = try await service.minutes(secid: "1.510300")
            XCTFail("realtime requests must still honour the cooldown")
        } catch HTTPError.rateLimited { }

        let days = try await service.bars(secid: "1.510300")
        XCTAssertEqual(days["2026-11-18"]?.compactMap { $0 }.count, 2,
                       "a realtime cooldown must not swallow the history request")
    }
}

private final class ETFHistoryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload = ["data": ["klines": ["2026-11-18 09:35,10", "2026-11-18 09:40,20"]]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ETFStaleSourceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let payload: [String: Any]
        if url.path.contains("ulist.np") {
            let codes = (query.first { $0.name == "secids" }?.value ?? "").split(separator: ",")
            let timestamp = ISO8601DateFormatter().date(from: "2026-11-16T01:37:00Z")!.timeIntervalSince1970
            let rows = codes.map { code -> [String: Any] in
                ["f12": String(code.split(separator: ".").last!), "f6": 1000, "f3": 1, "f124": timestamp]
            }
            payload = ["data": ["diff": rows]]
        } else if url.host == "push2.eastmoney.com" {
            let secid = query.first { $0.name == "secid" }?.value ?? ""
            let count = secid.hasSuffix(".510300") ? 2 : 8
            let rows = (0..<count).map { "2026-11-16 09:\(String(format: "%02d", 30 + $0)),4,4,4,4,1,10,4" }
            payload = ["data": ["trends": rows]]
        } else {
            let symbol = query.first { $0.name == "code" }?.value ?? ""
            let rows = (0..<8).map { "09\(String(format: "%02d", 30 + $0)) 4 \($0 + 1) \(($0 + 1) * 10)" }
            payload = ["data": [symbol: ["data": ["date": "20261116", "data": rows]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ETFSourceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        if host.contains("eastmoney.com") {
            let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "30"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let data: Data
        if host == "qt.gtimg.cn" {
            let symbols = (query.first { $0.name == "q" }?.value ?? "").split(separator: ",")
            let text = symbols.map { symbol -> String in
                var fields = [String](repeating: "", count: 36)
                fields[2] = String(symbol.dropFirst(2))
                fields[30] = "20261116093100"
                fields[32] = "1.0"
                fields[35] = "4/10/1000"
                return "v_\(symbol)=\"\(fields.joined(separator: "~"))\";"
            }.joined()
            data = Data(text.utf8)
        } else {
            let symbol = query.first { $0.name == "code" }?.value ?? ""
            let payload: [String: Any] = ["data": [symbol: ["data": ["date": "20261116", "data": ["0930 4 1 10", "0931 4 3 30"]]]]]
            data = try! JSONSerialization.data(withJSONObject: payload)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
