import Foundation

protocol QuoteProvider: Sendable {
    var id: String { get }
    var supportedMarkets: Set<Market> { get }
    /// 是否提供美股盘前 / 盘后 / 夜盘报价。休市时段编排器会跳过不支持的源。
    var supportsExtendedHours: Bool { get }
    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote]
}

extension QuoteProvider {
    var supportsExtendedHours: Bool { false }
}

enum ProviderError: Error, CustomStringConvertible {
    case unsupportedMarket(Market)
    case parsing(String)
    case upstream(String)
    case empty

    var description: String {
        switch self {
        case .unsupportedMarket(let m): return "unsupported market: \(m.rawValue)"
        case .parsing(let msg):         return "parse error: \(msg)"
        case .empty:                    return "empty response"
        case .upstream(let message):    return message
        }
    }
}
