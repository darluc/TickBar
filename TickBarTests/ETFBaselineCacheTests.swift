import XCTest
@testable import TickBar

final class ETFBaselineCacheTests: XCTestCase {
    private func temporaryCache() throws -> (ETFBaselineCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ETFBaselineCache(url: directory.appendingPathComponent("etf-baseline.json")), directory)
    }

    func testCacheRoundTripsOnlyForTheSameTradingDay() throws {
        let (cache, directory) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let curve = ETFCurve(slots: [0, 5], values: [0, 10])
        let baseline = ETFBaseline(liveDay: "2026-11-19", previousDay: "2026-11-18",
                                   previous: curve, average: curve, averageDays: 3)
        cache.save(baseline)
        XCTAssertEqual(cache.load(day: "2026-11-19"), baseline)
        XCTAssertNil(cache.load(day: "2026-11-20"), "a new session must fetch its own curves")
    }

    func testPrepareBaselineReusesCachedCurvesWithoutRequests() async throws {
        let (cache, directory) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let curve = ETFCurve(slots: [0, 5], values: [0, 10])
        let baseline = ETFBaseline(liveDay: "2026-11-19", previousDay: "2026-11-18",
                                   previous: curve, average: curve, averageDays: 3)
        cache.save(baseline)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let worker = ETFWorker(
            service: ETFService(http: client, gate: ETFRequestGate(spacing: 0),
                                historyGate: ETFRequestGate(spacing: 0)),
            fallback: TencentETFService(http: client, gate: ETFRequestGate(spacing: 0)),
            historyFallback: SinaETFHistoryService(http: client, gate: ETFRequestGate(spacing: 0)),
            baselineCache: cache)

        let result = await worker.prepareBaseline(for: "2026-11-19")
        XCTAssertEqual(result, baseline)
    }
}

/// Every network call fails; the only way the test can pass is by using the cache.
private final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
