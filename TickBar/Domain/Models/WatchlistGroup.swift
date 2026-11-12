import Foundation

struct WatchlistGroup: Equatable, Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var order: Int
    var createdAt: Date

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultName = "Watchlist"

    init(
        id: UUID = UUID(),
        name: String = defaultName,
        order: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.createdAt = createdAt
    }
}
