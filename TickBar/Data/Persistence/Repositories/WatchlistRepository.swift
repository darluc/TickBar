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

final class WatchlistRepository: @unchecked Sendable {
    let dbPool: DatabasePool
    private let settingsRepo: SettingsRepository
    private let cloudSync: WatchlistCloudSyncService

    private let lock = NSLock()
    private var cloudSnapshot: WatchlistCloudSnapshot?
    private var cloudActivated = false

    init(
        dbPool: DatabasePool,
        settingsRepo: SettingsRepository,
        cloudSync: WatchlistCloudSyncService = WatchlistCloudSyncService()
    ) {
        self.dbPool = dbPool
        self.settingsRepo = settingsRepo
        self.cloudSync = cloudSync

        cloudSync.startObservingExternalChanges { [weak self] in
            self?.reloadCloudSnapshotFromRemote()
        }

        if settingsRepo.iCloudWatchlistSyncEnabled {
            try? refreshCloudSession(activateIfNeeded: true)
        }
    }

    var iCloudWatchlistSyncEnabled: Bool {
        settingsRepo.iCloudWatchlistSyncEnabled
    }

    var canUseICloudWatchlistSync: Bool {
        cloudSync.canUseKeyValueStoreSync
    }

    var isSignedIntoICloud: Bool {
        cloudSync.isICloudAccountAvailable
    }

    var hasICloudKeyValueEntitlement: Bool {
        cloudSync.hasKeyValueStoreEntitlement
    }

    // MARK: - Sync settings

    func setICloudWatchlistSyncEnabled(_ enabled: Bool) throws {
        try settingsRepo.setICloudWatchlistSyncEnabled(enabled)
        if enabled {
            guard cloudSync.canUseKeyValueStoreSync else {
                throw WatchlistCloudSyncService.WatchlistCloudSyncError.iCloudUnavailable
            }
            try refreshCloudSession(activateIfNeeded: true)
        } else {
            lock.lock()
            cloudSnapshot = nil
            cloudActivated = false
            lock.unlock()
        }
        NotificationCenter.default.post(name: .tickbarWatchlistSyncModeDidChange, object: nil)
    }

    private func usesCloudStore() -> Bool {
        iCloudWatchlistSyncEnabled && cloudActivated
    }

    @discardableResult
    private func refreshCloudSession(activateIfNeeded: Bool) throws -> WatchlistCloudSnapshot {
        guard iCloudWatchlistSyncEnabled else {
            lock.lock()
            cloudSnapshot = nil
            cloudActivated = false
            lock.unlock()
            throw WatchlistCloudSyncService.WatchlistCloudSyncError.iCloudUnavailable
        }
        guard cloudSync.isICloudAccountAvailable else {
            throw WatchlistCloudSyncService.WatchlistCloudSyncError.iCloudUnavailable
        }

        let localSeed = try makeLocalSnapshot()
        let snapshot: WatchlistCloudSnapshot
        if activateIfNeeded {
            snapshot = try cloudSync.activate(preferring: localSeed)
        } else if let loaded = cloudSync.loadSnapshot(), loaded.hasCloudContent {
            snapshot = loaded
        } else {
            snapshot = localSeed
        }

        let normalized = WatchlistCloudSnapshot(
            groups: snapshot.normalizedGroups(),
            items: snapshot.items
        )
        lock.lock()
        cloudSnapshot = normalized
        cloudActivated = true
        lock.unlock()
        return normalized
    }

    private func reloadCloudSnapshotFromRemote() {
        guard usesCloudStore() else { return }
        try? refreshCloudSession(activateIfNeeded: false)
    }

    private func makeLocalSnapshot() throws -> WatchlistCloudSnapshot {
        WatchlistCloudSnapshot(
            groups: try localAllGroups(),
            items: try localAll()
        )
    }

    private func currentCloudSnapshot() throws -> WatchlistCloudSnapshot {
        lock.lock()
        if let cloudSnapshot {
            lock.unlock()
            return cloudSnapshot
        }
        lock.unlock()
        return try refreshCloudSession(activateIfNeeded: true)
    }

    private func persistCloudSnapshot(_ mutate: (inout WatchlistCloudSnapshot) -> Void) throws {
        var snap = try currentCloudSnapshot()
        mutate(&snap)
        snap = WatchlistCloudSnapshot(
            groups: snap.normalizedGroups(),
            items: snap.items
        )
        try cloudSync.saveSnapshot(snap)
        lock.lock()
        cloudSnapshot = snap
        lock.unlock()
    }

    // MARK: - Watchlist Groups

    func allGroups() throws -> [WatchlistGroup] {
        if usesCloudStore() {
            return try currentCloudSnapshot().normalizedGroups()
        }
        return try localAllGroups()
    }

    private func localAllGroups() throws -> [WatchlistGroup] {
        var groups = try dbPool.read { db in
            try GroupRecord.order(Column("order").asc, Column("createdAt").asc).fetchAll(db)
        }.compactMap { $0.toDomain() }

        if groups.isEmpty {
            let defaultGroup = WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)
            try localUpsertGroup(defaultGroup)
            groups = [defaultGroup]
        }
        return groups
    }

    func upsertGroup(_ group: WatchlistGroup) throws {
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                if let i = snap.groups.firstIndex(where: { $0.id == group.id }) {
                    snap.groups[i] = group
                } else {
                    snap.groups.append(group)
                }
            }
            return
        }
        try localUpsertGroup(group)
    }

    private func localUpsertGroup(_ group: WatchlistGroup) throws {
        try dbPool.write { db in
            try GroupRecord.from(group).save(db)
        }
    }

    func deleteGroup(id: UUID) throws {
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                snap.items.removeAll { $0.watchlistId == id }
                snap.groups.removeAll { $0.id == id }
                if snap.groups.isEmpty {
                    snap.groups = [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)]
                }
            }
            return
        }
        try localDeleteGroup(id: id)
    }

    private func localDeleteGroup(id: UUID) throws {
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
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                var byId = Dictionary(uniqueKeysWithValues: snap.groups.map { ($0.id, $0) })
                for (i, id) in ids.enumerated() {
                    byId[id]?.order = i
                }
                snap.groups = ids.compactMap { byId[$0] }
            }
            return
        }
        try localReorderGroups(ids: ids)
    }

    private func localReorderGroups(ids: [UUID]) throws {
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
        if usesCloudStore() {
            return AsyncStream { continuation in
                let initial = (try? allGroups()) ?? []
                continuation.yield(initial)
                let token = cloudSync.addChangeHandler {
                    continuation.yield((try? self.allGroups()) ?? [])
                }
                continuation.onTermination = { @Sendable _ in
                    self.cloudSync.removeChangeHandler(token)
                }
            }
        }
        return observeGroupsLocal()
    }

    private func observeGroupsLocal() -> AsyncStream<[WatchlistGroup]> {
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
        let items: [WatchItem]
        if usesCloudStore() {
            items = try currentCloudSnapshot().items.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.createdAt < $1.createdAt
            }
        } else {
            items = try localAll()
        }
        if let watchlistId {
            return items.filter { $0.watchlistId == watchlistId }
        }
        return items
    }

    private func localAll() throws -> [WatchItem] {
        try dbPool.read { db in
            try WatchRecord.order(Column("order").asc, Column("createdAt").asc).fetchAll(db)
        }.compactMap { $0.toDomain() }
    }

    func upsert(_ item: WatchItem) throws {
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                if let i = snap.items.firstIndex(where: { $0.id == item.id }) {
                    snap.items[i] = item
                } else {
                    snap.items.append(item)
                }
            }
            return
        }
        try localUpsert(item)
    }

    private func localUpsert(_ item: WatchItem) throws {
        try dbPool.write { db in
            try WatchRecord.from(item).save(db)
        }
    }

    func delete(id: UUID) throws {
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                snap.items.removeAll { $0.id == id }
            }
            return
        }
        _ = try dbPool.write { db in
            try WatchRecord.deleteOne(db, key: id.uuidString)
        }
    }

    func deleteAll(watchlistId: UUID? = nil) throws {
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                if let watchlistId {
                    snap.items.removeAll { $0.watchlistId == watchlistId }
                } else {
                    snap.items = []
                    snap.groups = [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)]
                }
            }
            return
        }
        try localDeleteAll(watchlistId: watchlistId)
    }

    private func localDeleteAll(watchlistId: UUID? = nil) throws {
        _ = try dbPool.write { db in
            if let watchlistId {
                _ = try WatchRecord.filter(Column("watchlistId") == watchlistId.uuidString).deleteAll(db)
            } else {
                _ = try WatchRecord.deleteAll(db)
            }
        }
    }

    func reorder(ids: [UUID]) throws {
        if usesCloudStore() {
            try persistCloudSnapshot { snap in
                for (i, id) in ids.enumerated() {
                    if let idx = snap.items.firstIndex(where: { $0.id == id }) {
                        snap.items[idx].order = i
                    }
                }
            }
            return
        }
        try localReorder(ids: ids)
    }

    private func localReorder(ids: [UUID]) throws {
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
        if usesCloudStore() {
            return AsyncStream { continuation in
                let initial = (try? all(watchlistId: watchlistId)) ?? []
                continuation.yield(initial)
                let token = cloudSync.addChangeHandler {
                    continuation.yield((try? self.all(watchlistId: watchlistId)) ?? [])
                }
                continuation.onTermination = { @Sendable _ in
                    self.cloudSync.removeChangeHandler(token)
                }
            }
        }
        return observeAllLocal(watchlistId: watchlistId)
    }

    private func observeAllLocal(watchlistId: UUID? = nil) -> AsyncStream<[WatchItem]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db -> [WatchItem] in
                var request = WatchRecord.order(Column("order").asc, Column("createdAt").asc)
                if let watchlistId {
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
