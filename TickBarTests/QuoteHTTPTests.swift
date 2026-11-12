import XCTest
@testable import TickBar

final class QuoteHTTPTests: XCTestCase {
    func testQuoteRequestsBypassLocalCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuoteRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let data = try await client.fetchData(url: URL(string: "https://quotes.invalid/latest")!)
        let request = try JSONDecoder().decode(RequestSnapshot.self, from: data)
        XCTAssertEqual(request.cachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue)
        XCTAssertEqual(request.cacheControl, "no-cache")
    }
}

private struct RequestSnapshot: Codable {
    let cachePolicy: UInt
    let cacheControl: String?
}

private final class QuoteRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let snapshot = RequestSnapshot(cachePolicy: request.cachePolicy.rawValue, cacheControl: request.value(forHTTPHeaderField: "Cache-Control"))
        let data = try! JSONEncoder().encode(snapshot)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
