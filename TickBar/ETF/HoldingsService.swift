import Foundation

struct DisclosedHolding: Codable, Identifiable, Equatable {
    let code: String
    let name: String
    let holder: String
    let period: String
    let notice: String
    let shares: Double?
    let percent: Double?
    var id: String { "\(code)|\(period)|\(holder)" }
}

struct StockHoldingResult: Codable, Equatable {
    let code: String
    let name: String
    let latestPeriod: String
    let holdings: [DisclosedHolding]
    var fetchedAt: Date? = nil
}

struct ETFShareSnapshot: Codable, Equatable, Identifiable {
    let code: String
    let observedDay: String
    let shares: Double
    var id: String { "\(code)|\(observedDay)" }
}

struct HoldingsService {
    let http = HTTPClient(defaultHeaders: ["Referer": "https://data.eastmoney.com/"])

    func etfShares(day: String) async throws -> [ETFShareSnapshot] {
        var url = URLComponents(string: "https://push2.eastmoney.com/api/qt/ulist.np/get")!
        let query = ["fltt": "2", "secids": ETFDescriptor.basket.map(\.secid).joined(separator: ","),
                     "fields": "f12,f38"]
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await http.fetchData(url: url.url!, timeout: 15)
        return try Self.parseETFShares(data, day: day)
    }

    static func parseETFShares(_ data: Data, day: String) throws -> [ETFShareSnapshot] {
        let response = try JSONDecoder().decode(ETFEnvelope.self, from: data)
        guard let rows = response.data?.diff else { throw HTTPError.decoding }
        let results = rows.compactMap { row -> ETFShareSnapshot? in
            guard ETFDescriptor.names[row.code] != nil, let shares = row.shares?.value, shares > 0 else { return nil }
            return ETFShareSnapshot(code: row.code, observedDay: day, shares: shares)
        }
        guard !results.isEmpty else { throw HTTPError.decoding }
        return results
    }

    private struct ETFEnvelope: Decodable {
        struct Body: Decodable {
            struct Row: Decodable {
                let code: String
                let shares: Number?
                enum CodingKeys: String, CodingKey { case code = "f12", shares = "f38" }
            }
            let diff: [Row]?
        }
        let data: Body?
    }

    func stock(code: String, name: String) async throws -> StockHoldingResult {
        var url = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
        url.queryItems = [
            URLQueryItem(name: "reportName", value: "RPT_F10_EH_FREEHOLDERS"),
            URLQueryItem(name: "columns", value: "ALL"),
            URLQueryItem(name: "filter", value: "(SECURITY_CODE=\"\(code)\")"),
            URLQueryItem(name: "pageNumber", value: "1"),
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "sortColumns", value: "END_DATE,HOLDER_RANK"),
            URLQueryItem(name: "sortTypes", value: "-1,1")
        ]
        let data = try await http.fetchData(url: url.url!, timeout: 15)
        return try Self.parseStock(data, code: code, name: name)
    }

    static func parseStock(_ data: Data, code: String, name: String) throws -> StockHoldingResult {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.success == true, let rows = envelope.result?.data, !rows.isEmpty else {
            throw HTTPError.decoding
        }
        let latest = rows.map(\.period).max() ?? ""
        let records = rows.filter { row in
            row.holder.contains("中央汇金") || row.holder.contains("全国社保基金") ||
            row.holder.contains("全国社会保障基金理事会")
        }.map { row in
            DisclosedHolding(code: code, name: name, holder: row.holder, period: row.period,
                             notice: row.notice ?? "", shares: row.shares?.value, percent: row.percent?.value)
        }
        return StockHoldingResult(code: code, name: name, latestPeriod: latest, holdings: records)
    }

    private struct Envelope: Decodable {
        struct Result: Decodable { let data: [Row]? }
        let success: Bool?
        let result: Result?
    }

    private struct Row: Decodable {
        let holder: String
        let period: String
        let notice: String?
        let shares: Number?
        let percent: Number?
        enum CodingKeys: String, CodingKey {
            case holder = "HOLDER_NAME", period = "END_DATE", notice = "NOTICE_DATE"
            case shares = "HOLD_NUM", percent = "FREE_HOLDNUM_RATIO"
        }
    }

    private struct Number: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { value = number.isFinite ? number : nil }
            else if let text = try? container.decode(String.self) { value = Double(text).flatMap { $0.isFinite ? $0 : nil } }
            else { value = nil }
        }
    }
}
