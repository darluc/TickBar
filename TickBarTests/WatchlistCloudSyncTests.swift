import XCTest
import GRDB
@testable import TickBar

final class WatchlistCloudSyncTests: XCTestCase {
    func testChooseDisplaySnapshotPrefersRemoteWhenPresent() {
        let localItem = WatchItem(
            symbol: SymbolID(code: "600519", market: .a),
            name: "Local",
            watchlistId: WatchlistGroup.defaultID
        )
        let remoteItem = WatchItem(
            symbol: SymbolID(code: "AAPL", market: .us),
            name: "Remote",
            watchlistId: WatchlistGroup.defaultID
        )
        let local = WatchlistCloudSnapshot(
            groups: [WatchlistGroup(id: WatchlistGroup.defaultID, name: "Local")],
            items: [localItem]
        )
        let remote = WatchlistCloudSnapshot(
            groups: [WatchlistGroup(id: WatchlistGroup.defaultID, name: "Remote")],
            items: [remoteItem]
        )

        let (snap, seeded) = WatchlistCloudSnapshot.chooseDisplaySnapshot(local: local, remote: remote)
        XCTAssertFalse(seeded)
        XCTAssertEqual(snap.items.first?.symbol.code, "AAPL")
    }

    func testChooseDisplaySnapshotSeedsWhenRemoteEmpty() {
        let localItem = WatchItem(
            symbol: SymbolID(code: "600519", market: .a),
            name: "Moutai",
            watchlistId: WatchlistGroup.defaultID
        )
        let local = WatchlistCloudSnapshot(
            groups: [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName)],
            items: [localItem]
        )
        let emptyRemote = WatchlistCloudSnapshot(
            groups: [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName)],
            items: []
        )

        let (snap, seeded) = WatchlistCloudSnapshot.chooseDisplaySnapshot(local: local, remote: emptyRemote)
        XCTAssertTrue(seeded)
        XCTAssertEqual(snap.items.count, 1)
        XCTAssertEqual(snap.items[0].symbol.code, "600519")
    }

    func testRepositoryCloudModeDoesNotWipeLocalSQLite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TickBar.Database(path: tempDir.appendingPathComponent("t.sqlite").path)
        let settings = SettingsRepository(dbPool: db.dbPool)
        let memoryStore = InMemoryWatchlistCloudKeyValueStore()
        let cloud = WatchlistCloudSyncService(store: memoryStore, iCloudAccountAvailable: { true })
        let repo = WatchlistRepository(dbPool: db.dbPool, settingsRepo: settings, cloudSync: cloud)

        let localOnly = WatchItem(
            symbol: SymbolID(code: "000001", market: .a),
            name: "Ping An",
            watchlistId: WatchlistGroup.defaultID
        )
        try repo.upsert(localOnly)
        XCTAssertEqual(try repo.all().count, 1)

        try settings.setICloudWatchlistSyncEnabled(true)
        try repo.setICloudWatchlistSyncEnabled(true)

        let cloudItem = WatchItem(
            symbol: SymbolID(code: "NVDA", market: .us),
            name: "NVIDIA",
            watchlistId: WatchlistGroup.defaultID
        )
        try repo.upsert(cloudItem)

        XCTAssertEqual(Set(try repo.all().map(\.symbol.code)), Set(["000001", "NVDA"]))

        let rawLocal = try db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watchItem") ?? 0
        }
        XCTAssertEqual(rawLocal, 1)
        XCTAssertEqual(try db.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT code FROM watchItem LIMIT 1")
        }, "000001")
    }

    func testActivateUploadsLocalWhenCloudEmpty() throws {
        let store = InMemoryWatchlistCloudKeyValueStore()
        let service = WatchlistCloudSyncService(store: store)
        let seed = WatchlistCloudSnapshot(
            groups: [WatchlistGroup(id: WatchlistGroup.defaultID, name: WatchlistGroup.defaultName)],
            items: [
                WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "Tesla", watchlistId: WatchlistGroup.defaultID)
            ]
        )
        let activated = try service.activate(preferring: seed)
        XCTAssertEqual(activated.items.first?.symbol.code, "TSLA")
        XCTAssertEqual(service.loadSnapshot()?.items.count, 1)
    }
}
