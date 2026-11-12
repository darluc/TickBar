import Foundation

struct WatchItem: Equatable, Codable, Sendable, Identifiable {
    let id: UUID
    var symbol: SymbolID
    var name: String
    var order: Int
    var inTicker: Bool
    var createdAt: Date
    var watchlistId: UUID

    init(
        id: UUID = UUID(),
        symbol: SymbolID,
        name: String,
        order: Int = 0,
        inTicker: Bool = true,
        createdAt: Date = Date(),
        watchlistId: UUID = WatchlistGroup.defaultID
    ) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.order = order
        self.inTicker = inTicker
        self.createdAt = createdAt
        self.watchlistId = watchlistId
    }

    enum CodingKeys: String, CodingKey {
        case id, symbol, name, order, inTicker, createdAt, watchlistId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        symbol = try container.decode(SymbolID.self, forKey: .symbol)
        name = try container.decode(String.self, forKey: .name)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        inTicker = try container.decodeIfPresent(Bool.self, forKey: .inTicker) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        watchlistId = try container.decodeIfPresent(UUID.self, forKey: .watchlistId) ?? WatchlistGroup.defaultID
    }
}
