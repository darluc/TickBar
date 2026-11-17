import Foundation

/// Tencent's minute rows contain cumulative turnover in yuan, not per-minute turnover.
struct TencentETFService: Sendable {
    let http: HTTPClient
    let gate: ETFRequestGate

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://gu.qq.com/"]),
         gate: ETFRequestGate = ETFRequestGate()) {
        self.http = http
        self.gate = gate
    }

    static func symbol(code: String) -> String {
        if code == ETFDescriptor.indexCode { return "sh\(code)" }
        return "\(code.hasPrefix("15") ? "sz" : "sh")\(code)"
    }

    func quotes(codes: [String]) async throws -> [ETFQuote] {
        var url = URLComponents(string: "https://qt.gtimg.cn/")!
        url.queryItems = [URLQueryItem(name: "q", value: codes.map(Self.symbol).joined(separator: ","))]
        let data = try await etfRequest(gate: gate) { try await http.fetchData(url: url.url!, timeout: 10) }
        guard let text = GBKDecoder.decode(data) else { throw ETFDataError.invalidResponse }
        let quotes = Self.parseQuotes(text, codes: codes)
        guard !quotes.isEmpty else { throw ETFDataError.invalidResponse }
        return quotes
    }

    func minutes(code: String) async throws -> ETFMinuteSeries {
        let symbol = Self.symbol(code: code)
        var url = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query")!
        url.queryItems = [URLQueryItem(name: "code", value: symbol)]
        let data = try await etfRequest(gate: gate) { try await http.fetchData(url: url.url!, timeout: 10) }
        return try Self.parseMinutes(data, symbol: symbol)
    }

    static func parseQuotes(_ text: String, codes: [String]) -> [ETFQuote] {
        let allowed = Set(codes)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return text.split(whereSeparator: { $0 == "\n" || $0 == ";" }).compactMap { line in
            guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else { return nil }
            let fields = line[line.index(after: first)..<last].split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count > 35, allowed.contains(String(fields[2])),
                  let timestamp = formatter.date(from: String(fields[30])),
                  let amountText = fields[35].split(separator: "/").last,
                  fields[35].split(separator: "/").count == 3,
                  let amount = Double(amountText), amount.isFinite, amount >= 0 else { return nil }
            let change = Double(fields[32]).flatMap { $0.isFinite ? $0 : nil }
            return ETFQuote(code: String(fields[2]), amount: amount, changePercent: change, timestamp: timestamp)
        }
    }

    static func parseMinutes(_ data: Data, symbol: String) throws -> ETFMinuteSeries {
        struct Response: Decodable {
            struct Stock: Decodable {
                struct Series: Decodable { let date: String; let data: [String] }
                let data: Series
            }
            let data: [String: Stock]
        }
        guard let response = try JSONDecoder().decode(Response.self, from: data).data[symbol]?.data,
              response.date.count == 8, response.date.allSatisfy(\.isNumber) else { throw ETFDataError.invalidResponse }
        let date = response.date
        let day = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
        var rows: [Int: (Double, Double)] = [:]
        for row in response.data {
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, fields[0].count == 4,
                  let hour = Int(fields[0].prefix(2)), let minute = Int(fields[0].suffix(2)),
                  let price = Double(fields[1]), price.isFinite, price > 0,
                  let cumulative = Double(fields[3]), cumulative.isFinite, cumulative >= 0 else {
                throw ETFDataError.invalidResponse
            }
            guard let slot = ETFTime.slot(hour: hour, minute: minute) else { continue }
            rows[slot] = (price, cumulative)
        }
        guard let last = rows.keys.max(), rows[0] != nil else { throw ETFDataError.invalidResponse }
        var amounts = [Double?](repeating: nil, count: ETFTime.slotCount)
        var closes = amounts
        var previous = 0.0
        for slot in 0...last {
            guard let (price, cumulative) = rows[slot], cumulative >= previous else { throw ETFDataError.invalidResponse }
            amounts[slot] = cumulative - previous
            closes[slot] = price
            previous = cumulative
        }
        return ETFMinuteSeries(day: day, amount: amounts, close: closes)
    }
}
