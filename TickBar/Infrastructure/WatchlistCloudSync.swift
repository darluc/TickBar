import Foundation
import os
import Security

extension Notification.Name {
    static let tickbarWatchlistSyncModeDidChange = Notification.Name("tickbar.watchlistSyncModeDidChange")
}

/// iCloud 上的自选 + 分类快照（不与本地 SQLite 合并）。
struct WatchlistCloudSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let snapshotKey = "tickbar.watchlist.snapshot.v1"

    var schemaVersion: Int
    var updatedAt: Date
    var groups: [WatchlistGroup]
    var items: [WatchItem]

    init(
        schemaVersion: Int = Self.schemaVersion,
        updatedAt: Date = Date(),
        groups: [WatchlistGroup],
        items: [WatchItem]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.groups = groups
        self.items = items
    }

    /// iCloud 上是否已有「有意义」的数据（非空列表，或除默认空分组外还有分组）。
    var hasCloudContent: Bool {
        if !items.isEmpty { return true }
        if groups.count > 1 { return true }
        if let only = groups.first, only.id != WatchlistGroup.defaultID || only.name != WatchlistGroup.defaultName {
            return true
        }
        return false
    }

    func normalizedGroups() -> [WatchlistGroup] {
        var groups = groups.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.createdAt < $1.createdAt
        }
        if groups.isEmpty {
            groups = [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName, order: 0)]
        }
        return groups
    }

    static func chooseDisplaySnapshot(
        local: WatchlistCloudSnapshot,
        remote: WatchlistCloudSnapshot?
    ) -> (snapshot: WatchlistCloudSnapshot, seededToCloud: Bool) {
        if let remote, remote.hasCloudContent {
            return (remote, false)
        }
        return (local, true)
    }
}

// MARK: - Key-value storage (testable)

protocol WatchlistCloudKeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

final class UbiquitousKeyValueStoreAdapter: WatchlistCloudKeyValueStoring {
    private let store = NSUbiquitousKeyValueStore.default

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    func synchronize() -> Bool {
        store.synchronize()
    }
}

final class InMemoryWatchlistCloudKeyValueStore: WatchlistCloudKeyValueStoring {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let data {
            values[key] = data
        } else {
            values.removeValue(forKey: key)
        }
    }

    func synchronize() -> Bool { true }
}

// MARK: - Sync service

final class WatchlistCloudSyncService: @unchecked Sendable {
    private let store: WatchlistCloudKeyValueStoring
    private let lock = NSLock()
    private var changeHandlers: [UUID: () -> Void] = [:]
    private var externalObserver: NSObjectProtocol?

    private let accountAvailable: () -> Bool
    private let keyValueEntitlementAvailable: () -> Bool

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        store: WatchlistCloudKeyValueStoring = UbiquitousKeyValueStoreAdapter(),
        iCloudAccountAvailable: (() -> Bool)? = nil,
        keyValueEntitlementAvailable: (() -> Bool)? = nil
    ) {
        self.store = store
        self.accountAvailable = iCloudAccountAvailable ?? { FileManager.default.ubiquityIdentityToken != nil }
        self.keyValueEntitlementAvailable = keyValueEntitlementAvailable ?? { Self.hasUbiquityKeyValueStoreEntitlement }
    }

    deinit {
        if let externalObserver {
            NotificationCenter.default.removeObserver(externalObserver)
        }
    }

    var isICloudAccountAvailable: Bool {
        accountAvailable()
    }

    var canUseKeyValueStoreSync: Bool {
        accountAvailable() && keyValueEntitlementAvailable()
    }

    var hasKeyValueStoreEntitlement: Bool {
        keyValueEntitlementAvailable()
    }

    func startObservingExternalChanges(handler: @escaping () -> Void) {
        stopObservingExternalChanges()
        externalObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyChangeHandlers()
            handler()
        }
    }

    func stopObservingExternalChanges() {
        if let externalObserver {
            NotificationCenter.default.removeObserver(externalObserver)
            self.externalObserver = nil
        }
    }

    func addChangeHandler(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        changeHandlers[id] = handler
        lock.unlock()
        return id
    }

    func removeChangeHandler(_ id: UUID) {
        lock.lock()
        changeHandlers.removeValue(forKey: id)
        lock.unlock()
    }

    func loadSnapshot() -> WatchlistCloudSnapshot? {
        guard let data = store.data(forKey: WatchlistCloudSnapshot.snapshotKey) else { return nil }
        do {
            let snap = try decoder.decode(WatchlistCloudSnapshot.self, from: data)
            guard snap.schemaVersion <= WatchlistCloudSnapshot.schemaVersion else {
                Log.db.error("watchlist iCloud snapshot schema too new")
                return nil
            }
            return snap
        } catch {
            Log.db.error("watchlist iCloud decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func saveSnapshot(_ snapshot: WatchlistCloudSnapshot) throws {
        var snap = snapshot
        snap.schemaVersion = WatchlistCloudSnapshot.schemaVersion
        snap.updatedAt = Date()
        let data = try encoder.encode(snap)
        store.set(data, forKey: WatchlistCloudSnapshot.snapshotKey)
        guard store.synchronize() else {
            throw WatchlistCloudSyncError.synchronizeFailed
        }
        notifyChangeHandlers()
    }

    /// 开启同步：有云端数据则用云端；否则把本地快照作为首个云端版本上传。
    @discardableResult
    func activate(preferring localSeed: WatchlistCloudSnapshot) throws -> WatchlistCloudSnapshot {
        let remote = loadSnapshot()
        let resolved = WatchlistCloudSnapshot.chooseDisplaySnapshot(local: localSeed, remote: remote)
        if resolved.seededToCloud {
            try saveSnapshot(resolved.snapshot)
        }
        return resolved.snapshot
    }

    private func notifyChangeHandlers() {
        lock.lock()
        let handlers = changeHandlers.values
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Release builds omit KVS entitlement until Developer ID provisioning is fixed.
    static var hasUbiquityKeyValueStoreEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.ubiquity-kvstore-identifier" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        if let s = value as? String { return !s.isEmpty }
        return true
    }

    enum WatchlistCloudSyncError: LocalizedError {
        case synchronizeFailed
        case iCloudUnavailable

        var errorDescription: String? {
            switch self {
            case .synchronizeFailed:
                return L("icloud.watchlist.error.sync", comment: "")
            case .iCloudUnavailable:
                return L("icloud.watchlist.error.unavailable", comment: "")
            }
        }
    }
}
