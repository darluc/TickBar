import Foundation

enum HTTPError: Error, CustomStringConvertible {
    case badStatus(Int)
    case rateLimited(TimeInterval?)
    case decoding
    case transport(Error)

    var description: String {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        case .rateLimited: return "HTTP 429"
        case .decoding: return "decoding failed"
        case .transport(let e):    return "transport: \(e.localizedDescription)"
        }
    }
}

/// 极简 HTTPClient,负责构造请求 + 注入通用 header + 解码。
struct HTTPClient {
    /// nil 表示动态使用 NetworkConfig.sharedSession(每次请求重新读),
    /// 这样设置里改代理后所有 provider 立即生效,不用重建实例。
    let overrideSession: URLSession?
    let defaultHeaders: [String: String]

    var session: URLSession {
        overrideSession ?? NetworkConfig.sharedSession
    }

    init(session: URLSession? = nil, defaultHeaders: [String: String] = [:]) {
        self.overrideSession = session
        var headers = defaultHeaders
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = Self.defaultUA
        }
        self.defaultHeaders = headers
    }

    static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    func fetchData(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 8) async throws -> Data {
        // 实时报价不能命中 URLSession 上一次交易时段的本地缓存。
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (k, v) in defaultHeaders { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in headers        { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 429 {
                    throw HTTPError.rateLimited(Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
                }
                throw HTTPError.badStatus(http.statusCode)
            }
            return data
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport(error)
        }
    }

    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    func fetchString(url: URL, encoding: String.Encoding = .utf8, headers: [String: String] = [:]) async throws -> String {
        let data = try await fetchData(url: url, headers: headers)
        if encoding == .utf8 {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return GBKDecoder.decode(data) ?? String(data: data, encoding: .utf8) ?? ""
    }
}
