import Foundation

/// Sina's 5-minute K-lines. Used only when East Money's history host refuses the request;
/// quotes and minutes still come from East Money/Tencent.
struct SinaETFHistoryService: Sendable {
    let http: HTTPClient
    let gate: ETFRequestGate

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://finance.sina.com.cn/"]),
         gate: ETFRequestGate = ETFRequestGate()) {
        self.http = http
        self.gate = gate
    }

    func bars(code: String) async throws -> [String: [Double?]] {
        var url = URLComponents(string: "https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData")!
        url.queryItems = [
            URLQueryItem(name: "symbol", value: TencentETFService.symbol(code: code)),
            URLQueryItem(name: "scale", value: "5"),
            URLQueryItem(name: "ma", value: "no"),
            URLQueryItem(name: "datalen", value: "\(ETFTime.barsPerDay * 21)"),
        ]
        let data = try await etfRequest(gate: gate) { try await http.fetchData(url: url.url!, timeout: 10) }
        let days = Self.parseBars(data)
        guard !days.isEmpty else { throw ETFDataError.invalidResponse }
        return days
    }

    /// Rows look like `{"day":"2026-11-19 09:35:00","amount":"11293465481.7500",...}`.
    /// The amount is yuan, matching East Money's `f57`, so both sources share the bar format.
    static func parseBars(_ data: Data) -> [String: [Double?]] {
        struct Row: Decodable {
            let day: String
            let amount: String?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [:] }
        var days: [String: [Double?]] = [:]
        for row in rows {
            guard row.day.count >= 16, let t = ETFTime.parse(row.day.prefix(16)),
                  t.slot >= 5, t.slot % 5 == 0,
                  let value = row.amount.flatMap(Double.init), value.isFinite, value >= 0 else { continue }
            days[String(t.day), default: [Double?](repeating: nil, count: ETFTime.barsPerDay)][t.slot / 5 - 1] = value
        }
        return days
    }
}
