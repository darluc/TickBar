import GRDB
import XCTest
@testable import TickBar

final class LegacyDataMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeDatabase(_ relativePath: String) throws -> TickBar.Database {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try TickBar.Database(path: url.path)
    }

    private func seed(_ database: TickBar.Database) throws -> (WatchlistGroup, WatchItem) {
        let group = WatchlistGroup(id: UUID(), name: "Legacy custom list", order: 2,
                                   createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let item = WatchItem(symbol: .init(code: "600519", market: .a), name: "Legacy stock", order: 3,
                             inTicker: false, createdAt: group.createdAt, watchlistId: group.id)
        let repo = WatchlistRepository(dbPool: database.dbPool)
        try repo.upsertGroup(group)
        try repo.upsert(item)
        try SettingsRepository(dbPool: database.dbPool).set("legacy_setting", "retained")
        return (group, item)
    }

    private func migrate(folder: String = "TickBar") throws {
        try LegacyDataMigration.migrateDatabase(current: root.appendingPathComponent("\(folder)/tickbar.sqlite"),
                                               applicationSupport: root, folderName: folder)
    }

    func testFreshInstallImportsGroupsSettingsAndCommittedWALWithoutChangingLegacy() throws {
        let old = try makeDatabase("TickerBar/tickerbar.sqlite")
        let (group, item) = try seed(old)
        let wal = root.appendingPathComponent("TickerBar/tickerbar.sqlite-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        try migrate()
        let current = try makeDatabase("TickBar/tickbar.sqlite")
        let repo = WatchlistRepository(dbPool: current.dbPool)
        XCTAssertEqual(try repo.all(), [item])
        XCTAssertEqual(try repo.allGroups().first(where: { $0.id == group.id }), group)
        XCTAssertEqual(SettingsRepository(dbPool: current.dbPool).string("legacy_setting"), "retained")
        XCTAssertEqual(SettingsRepository(dbPool: current.dbPool).string(LegacyDataMigration.databaseMarker), "1")
        XCTAssertNil(SettingsRepository(dbPool: old.dbPool).string(LegacyDataMigration.databaseMarker))
        XCTAssertEqual(try WatchlistRepository(dbPool: old.dbPool).all(), [item])
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("TickBar/MigrationBackups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups[0].appendingPathComponent("legacy.sqlite").path))
    }

    func testExistingDatabaseRecoversMissingListsAndItemsButPreservesCurrentEdits() throws {
        let old = try makeDatabase("TickerBar/tickerbar.sqlite")
        let (group, item) = try seed(old)
        let current = try makeDatabase("TickBar/tickbar.sqlite")
        let repo = WatchlistRepository(dbPool: current.dbPool)
        let newItem = WatchItem(symbol: .init(code: "AAPL", market: .us), name: "New stock",
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try repo.upsert(newItem)
        try SettingsRepository(dbPool: current.dbPool).set("legacy_setting", "new value")
        try migrate()
        XCTAssertEqual(Set(try repo.all().map(\.id)), [item.id, newItem.id])
        XCTAssertTrue(try repo.allGroups().contains(where: { $0.id == group.id }))
        XCTAssertEqual(SettingsRepository(dbPool: current.dbPool).string("legacy_setting"), "new value")
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("TickBar/MigrationBackups"), includingPropertiesForKeys: nil)
        var readonly = Configuration()
        readonly.readonly = true
        let before = try DatabaseQueue(path: backups[0].appendingPathComponent("before-import.sqlite").path, configuration: readonly)
        XCTAssertEqual(try before.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM watchItem") }, 1)
        try before.close()
        try repo.delete(id: item.id)
        try migrate()
        XCTAssertEqual(try repo.all(), [newItem], "deleted legacy records must not reappear on later launches")
    }

    func testSameRecordIDKeepsCurrentNameOrderingAndTickerSetting() throws {
        let old = try makeDatabase("TickerBar/tickerbar.sqlite")
        let (_, item) = try seed(old)
        let current = try makeDatabase("TickBar/tickbar.sqlite")
        var edited = item
        edited.name = "Renamed in TickBar"
        edited.order = 1
        edited.inTicker = true
        let repo = WatchlistRepository(dbPool: current.dbPool)
        try repo.upsert(edited)
        try migrate()
        XCTAssertEqual(try repo.all(), [edited])
    }

    func testOlderSchemaIsUpgradedOnlyOnWorkingCopy() throws {
        let old = try makeDatabase("TickerBar/tickerbar.sqlite")
        try old.dbPool.write { db in
            try db.execute(sql: "ALTER TABLE watchItem DROP COLUMN watchlistId")
            try db.execute(sql: "DROP TABLE watchlistGroup")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7_watchlist_groups'")
            try db.execute(sql: "INSERT INTO watchItem (id, code, market, name, \"order\", createdAt, inTicker) VALUES (?, '600519', 'a', 'Old stock', 0, ?, 1)",
                           arguments: [UUID().uuidString, Date()])
        }
        try migrate()
        let current = try makeDatabase("TickBar/tickbar.sqlite")
        XCTAssertEqual(try WatchlistRepository(dbPool: current.dbPool).all().count, 1)
        XCTAssertTrue(try current.dbPool.read { try $0.tableExists("watchlistGroup") })
        XCTAssertFalse(try old.dbPool.read { try $0.tableExists("watchlistGroup") })
    }

    func testDebugDoesNotImportReleaseDataAndUsesItsOwnLegacyDirectory() throws {
        let release = try makeDatabase("TickerBar/tickerbar.sqlite")
        _ = try seed(release)
        try migrate(folder: "TickBar-Dev")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("TickBar-Dev/tickbar.sqlite").path))
        let debug = try makeDatabase("TickerBar-Dev/tickerbar.sqlite")
        let (_, item) = try seed(debug)
        try migrate(folder: "TickBar-Dev")
        let current = try makeDatabase("TickBar-Dev/tickbar.sqlite")
        XCTAssertEqual(try WatchlistRepository(dbPool: current.dbPool).all(), [item])
    }

    func testTickerBarIsPreferredOverOlderPanBar() throws {
        let ticker = try makeDatabase("TickerBar/tickerbar.sqlite")
        let (_, item) = try seed(ticker)
        try ticker.dbPool.close()
        let panbar = try makeDatabase("PanBar/panbar.sqlite")
        _ = try seed(panbar)
        try migrate()
        let current = try makeDatabase("TickBar/tickbar.sqlite")
        XCTAssertEqual(try WatchlistRepository(dbPool: current.dbPool).all(), [item])
    }

    func testImportFailureRollsBackAllInsertedRowsAndDoesNotSetMarker() throws {
        let old = try makeDatabase("TickerBar/tickerbar.sqlite")
        _ = try seed(old)
        try old.dbPool.write { try $0.execute(sql: "DROP TABLE watchItem") }
        let current = try makeDatabase("TickBar/tickbar.sqlite")
        XCTAssertThrowsError(try migrate())
        XCTAssertEqual(try WatchlistRepository(dbPool: current.dbPool).allGroups().count, 1)
        XCTAssertNil(SettingsRepository(dbPool: current.dbPool).string(LegacyDataMigration.databaseMarker))
    }

    func testPreferencesMigrateOnceAndKeepExistingValuesIncludingFalse() throws {
        let domain = "test.tickbar.\(UUID().uuidString)"
        let legacy = "test.tickerbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: legacy)
        }
        defaults.setPersistentDomain(["tickerbar.language": "en", "etfPanelSelected": true,
                                      "NSStatusItem Preferred Position \(legacy).statusItem": 123], forName: legacy)
        defaults.set(false, forKey: "etfPanelSelected")
        LegacyDataMigration.migratePreferences(defaults: defaults, currentDomain: domain, legacyDomain: legacy)
        XCTAssertEqual(defaults.string(forKey: "tickbar.language"), "en")
        XCTAssertFalse(defaults.bool(forKey: "etfPanelSelected"))
        XCTAssertEqual(defaults.integer(forKey: "NSStatusItem Preferred Position \(domain).statusItem"), 123)
        defaults.set("zh-Hans", forKey: "tickbar.language")
        LegacyDataMigration.migratePreferences(defaults: defaults, currentDomain: domain, legacyDomain: legacy)
        XCTAssertEqual(defaults.string(forKey: "tickbar.language"), "zh-Hans")
    }
}
