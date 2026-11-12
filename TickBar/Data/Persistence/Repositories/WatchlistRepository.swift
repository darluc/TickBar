import Foundation
import GRDB

private struct GroupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "watchlistGroup"

    var id: String
    var name: String
    var order: Int
    var createdAt: Date

    func toDomain() -> WatchlistGroup? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return WatchlistGroup(id: uuid, name: name, order: order, createdAt: createdAt)
    }

    static func from(_ g: WatchlistGroup) -> GroupRecord {
        GroupRecord(id: g.id.uuidString, name: g.name, order: g.order, createdAt: g.createdAt)
    }
}

private struct WatchRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "watchItem"

    var id: String
    var code: String
    var market: String
    var name: String
    var order: Int
    var inTicker: Bool
    var createdAt: Date
    var watchlistId: String

    func toDomain() -> WatchItem? {
        guard let market = Market(rawValue: market),
              let id = UUID(uuidString: id) else { return nil }
        let wId = UUID(uuidString: watchlistId) ?? WatchlistGroup.defaultID
        return WatchItem(
            id: id,
            symbol: SymbolID(code: code, market: market),
            name: name,
            order: order,
            inTicker: inTicker,
            createdAt: createdAt,
            watchlistId: wId
        )
    }

    static func from(_ w: WatchItem) -> WatchRecord {
        WatchRecord(
            id: w.id.uuidString,
            code: w.symbol.code,
            market: w.symbol.market.rawValue,
            name: w.name,
            order: w.order,
            inTicker: w.inTicker,
            createdAt: w.createdAt,
            watchlistId: w.watchlistId.uuidString
        )
    }
}

struct WatchlistRepository {
    let dbPool: DatabasePool

    // MARK: - Watchlist Groups

    func allGroups() throws -> [WatchlistGroup] {
        var groups = try dbPool.read { db in
            try GroupRecord.order(Column("order").asc, Column("createdAt").asc).fetchAll(db)
        }.compactMap { $0.toDomain() }

        if groups.isEmpty {
            let defaultGroup = WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)
            try upsertGroup(defaultGroup)
            groups = [defaultGroup]
        }
        return groups
    }

    func upsertGroup(_ group: WatchlistGroup) throws {
        try dbPool.write { db in
            try GroupRecord.from(group).save(db)
        }
    }

    func deleteGroup(id: UUID) throws {
        try dbPool.write { db in
            _ = try WatchRecord.filter(Column("watchlistId") == id.uuidString).deleteAll(db)
            _ = try GroupRecord.deleteOne(db, key: id.uuidString)

            let count = try GroupRecord.fetchCount(db)
            if count == 0 {
                let defaultGroup = WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)
                try GroupRecord.from(defaultGroup).save(db)
            }
        }
    }

    func reorderGroups(ids: [UUID]) throws {
        try dbPool.write { db in
            for (i, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE watchlistGroup SET \"order\" = ? WHERE id = ?",
                    arguments: [i, id.uuidString]
                )
            }
        }
    }

    func observeGroups() -> AsyncStream<[WatchlistGroup]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db -> [WatchlistGroup] in
                var groups = try GroupRecord.order(Column("order").asc, Column("createdAt").asc).fetchAll(db).compactMap { $0.toDomain() }
                if groups.isEmpty {
                    groups = [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)]
                }
                return groups
            }
            let cancellable = observation.start(in: dbPool, onError: { _ in }) { groups in
                continuation.yield(groups)
            }
            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }

    // MARK: - Watch Items

    func all(watchlistId: UUID? = nil) throws -> [WatchItem] {
        try dbPool.read { db in
            var request = WatchRecord.order(Column("order").asc, Column("createdAt").asc)
            if let watchlistId = watchlistId {
                request = request.filter(Column("watchlistId") == watchlistId.uuidString)
            }
            return try request.fetchAll(db)
        }.compactMap { $0.toDomain() }
    }

    func upsert(_ item: WatchItem) throws {
        try dbPool.write { db in
            try WatchRecord.from(item).save(db)
        }
    }

    func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try WatchRecord.deleteOne(db, key: id.uuidString)
        }
    }

    func deleteAll(watchlistId: UUID? = nil) throws {
        _ = try dbPool.write { db in
            if let watchlistId = watchlistId {
                _ = try WatchRecord.filter(Column("watchlistId") == watchlistId.uuidString).deleteAll(db)
            } else {
                _ = try WatchRecord.deleteAll(db)
            }
        }
    }

    /// 用户拖拽改顺序后,把当前完整 id 序列 → 各自 order = 数组下标。
    func reorder(ids: [UUID]) throws {
        try dbPool.write { db in
            for (i, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE watchItem SET \"order\" = ? WHERE id = ?",
                    arguments: [i, id.uuidString]
                )
            }
        }
    }

    func observeAll(watchlistId: UUID? = nil) -> AsyncStream<[WatchItem]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db -> [WatchItem] in
                var request = WatchRecord.order(Column("order").asc, Column("createdAt").asc)
                if let watchlistId = watchlistId {
                    request = request.filter(Column("watchlistId") == watchlistId.uuidString)
                }
                return try request.fetchAll(db).compactMap { $0.toDomain() }
            }
            let cancellable = observation.start(in: dbPool, onError: { _ in }) { items in
                continuation.yield(items)
            }
            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }
}
