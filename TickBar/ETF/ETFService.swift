import Foundation

/// East Money requests for the ETF panel. Everything is fetched live; nothing is stored.
struct ETFService: Sendable {
    let http: HTTPClient
    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
    }

    private func fetch(_ host: String, _ path: String, _ query: [String: String]) async throws -> Data {
        var url = URLComponents(string: "https://\(host)/api/qt/\(path)")!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await http.fetchData(url: url.url!, timeout: 10)
    }

    /// One batched request: turnover and change for the 20 ETFs plus the index.
    func quotes() async throws -> [ETFQuote] {
        let data = try await fetch("push2.eastmoney.com", "ulist.np/get", [
            "fltt": "2", "invt": "2", "fields": "f12,f3,f6,f124",
            "secids": (ETFDescriptor.basket.map(\.secid) + [ETFDescriptor.indexSecid]).joined(separator: ",")
        ])
        let values = Self.parseQuotes(data)
        guard !values.isEmpty else { throw ETFDataError.invalidResponse }
        return values
    }

    /// Today's (or the latest trading day's) one-minute series; 241 rows at most.
    func minutes(secid: String) async throws -> ETFMinuteSeries {
        let data = try await fetch("push2.eastmoney.com", "stock/trends2/get", [
            "secid": secid, "fields1": "f1,f2,f3,f4,f5,f6,f7",
            "fields2": "f51,f52,f53,f54,f55,f56,f57,f58", "ndays": "1", "iscr": "0"
        ])
        guard let series = Self.parseMinutes(Self.body(data)?.trends ?? []) else { throw ETFDataError.invalidResponse }
        return series
    }

    /// Five-minute turnover of the last ~21 sessions, grouped by day. Used once per day for comparison curves.
    func bars(secid: String) async throws -> [String: [Double?]] {
        let data = try await fetch("push2his.eastmoney.com", "stock/kline/get", [
            "secid": secid, "klt": "5", "fqt": "0", "lmt": "\(ETFTime.barsPerDay * 21)", "end": "20500101",
            "fields1": "f1,f2,f3", "fields2": "f51,f57"
        ])
        let days = Self.parseBars(Self.body(data)?.klines ?? [])
        guard !days.isEmpty else { throw ETFDataError.invalidResponse }
        return days
    }

    // MARK: Parsing

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let diff: [Row]?
            let trends: [String]?
            let klines: [String]?
        }
        struct Row: Decodable {
            let f12: String?
            let f3: Loose?
            let f6: Loose?
            let f124: Loose?
        }
        let data: Body?
    }
    /// East Money sends "-" for missing numbers.
    private struct Loose: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d.isFinite ? d : nil }
            else if let s = try? c.decode(String.self) { value = Double(s).flatMap { $0.isFinite ? $0 : nil } }
            else { value = nil }
        }
    }

    private static func body(_ data: Data) -> Envelope.Body? {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.data
    }

    static func parseQuotes(_ data: Data) -> [ETFQuote] {
        let allowed = Set(ETFDescriptor.basket.map(\.code) + [ETFDescriptor.indexCode])
        return (body(data)?.diff ?? []).compactMap { row in
            guard let code = row.f12, allowed.contains(code),
                  let amount = row.f6?.value, amount >= 0,
                  let stamp = row.f124?.value, stamp > 0 else { return nil }
            return ETFQuote(code: code, amount: amount, changePercent: row.f3?.value,
                            timestamp: Date(timeIntervalSince1970: stamp))
        }
    }

    /// Rows are `time,open,close,high,low,volume,amount,avg`. Only the latest day is kept;
    /// a repeated minute replaces the earlier one, so corrections never double count.
    static func parseMinutes(_ rows: [String]) -> ETFMinuteSeries? {
        var day: Substring?
        var amount = [Double?](repeating: nil, count: ETFTime.slotCount)
        var close = amount
        for row in rows {
            let f = row.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 7, let t = ETFTime.parse(f[0]),
                  let price = Double(f[2]), price.isFinite, price > 0,
                  let value = Double(f[6]), value.isFinite, value >= 0 else { continue }
            if let current = day {
                if t.day < current { continue }
                if t.day > current {
                    day = t.day
                    amount = [Double?](repeating: nil, count: ETFTime.slotCount)
                    close = amount
                }
            } else { day = t.day }
            amount[t.slot] = value
            close[t.slot] = price
        }
        guard let day else { return nil }
        return ETFMinuteSeries(day: String(day), amount: amount, close: close)
    }

    /// Rows are `yyyy-MM-dd HH:mm,amount`, labelled by bar close. Bar k covers slots 5k-4...5k+5.
    static func parseBars(_ rows: [String]) -> [String: [Double?]] {
        var days: [String: [Double?]] = [:]
        for row in rows {
            let f = row.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 2, let t = ETFTime.parse(f[0]), t.slot >= 5, t.slot % 5 == 0,
                  let value = Double(f[1]), value.isFinite, value >= 0 else { continue }
            days[String(t.day), default: [Double?](repeating: nil, count: ETFTime.barsPerDay)][t.slot / 5 - 1] = value
        }
        return days
    }
}
