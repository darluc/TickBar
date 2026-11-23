import Foundation

/// East Money trade details for basket ETFs (same endpoint as stock analysis).
struct ETFVolumeDetailsService: Sendable {
    let http: HTTPClient
    let gate: ETFRequestGate

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"]),
         gate: ETFRequestGate = ETFRequestGate()) {
        self.http = http
        self.gate = gate
    }

    func detailRows(code: String, secid: String) async throws -> [String] {
        let data = try await fetch(secid: secid)
        return try StockVolumeService.extractDetailRows(data, code: code)
    }

    func details(code: String, secid: String) async throws -> [StockVolumeTrade] {
        try await details(code: code, secid: secid, merging: []).trades
    }

    /// Merges a new provider snapshot onto prior rows so a rolling window does not drop history.
    func details(code: String, secid: String, merging cachedRows: [String]) async throws -> (mergedRows: [String], trades: [StockVolumeTrade]) {
        let incoming = try await detailRows(code: code, secid: secid)
        let merged = StockVolumeService.mergeDetailRows(cachedRows, incoming)
        let trades = try StockVolumeService.parseDetailRows(merged, code: code)
        return (merged, trades)
    }

    private func fetch(secid: String) async throws -> Data {
        var url = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/details/get")!
        url.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55"),
            URLQueryItem(name: "pos", value: "-100000"),
            URLQueryItem(name: "iscca", value: "1")
        ]
        return try await etfRequest(gate: gate) {
            try await http.fetchData(url: url.url!, timeout: 15)
        }
    }
}
