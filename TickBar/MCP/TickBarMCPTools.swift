import Foundation

@MainActor
final class TickBarMCPTools {
    private weak var container: DependencyContainer?
    private let quoteBroker: MCPQuoteBroker

    init(quoteBroker: MCPQuoteBroker) {
        self.quoteBroker = quoteBroker
    }

    func bind(_ container: DependencyContainer) {
        self.container = container
    }

    func getStockQuotes(arguments: [String: Any]) async throws -> String {
        guard let marketRaw = arguments["market"] as? String,
              let market = Market(rawValue: marketRaw.lowercased()) else {
            throw TickBarMCPError.invalidArgument("market must be one of: a, hk, us, kr")
        }
        guard market != .crypto else {
            throw TickBarMCPError.invalidArgument("crypto is not supported by this tool")
        }
        let codes: [String]
        if let list = arguments["codes"] as? [String] {
            codes = list
        } else if let list = arguments["codes"] as? [Any] {
            codes = list.compactMap { $0 as? String }
        } else {
            throw TickBarMCPError.invalidArgument("codes must be an array of strings")
        }
        guard !codes.isEmpty else {
            throw TickBarMCPError.invalidArgument("codes must not be empty")
        }

        guard let container else {
            throw TickBarMCPError.internalFailure("TickBar is not ready")
        }
        let refresher = container.refresher
        let response = await quoteBroker.fetch(
            market: market,
            codes: codes,
            seedQuotes: refresher.quotes,
            seedRetrievedAt: refresher.lastUpdated
        )
        return try Self.encode(response)
    }

    func getEtfSnapshot() async throws -> String {
        guard let container else {
            throw TickBarMCPError.internalFailure("TickBar is not ready")
        }
        await container.etfMonitor.prepareForMCPSnapshot()
        let response = MCPEtfSnapshotBuilder.build(monitor: container.etfMonitor)
        return try Self.encode(response)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TickBarMCPError.internalFailure("encoding failed")
        }
        return text
    }
}

enum TickBarMCPError: Error, LocalizedError {
    case invalidArgument(String)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        case .internalFailure(let message): return message
        }
    }
}
