import XCTest
import GRDB
@testable import TickBar

@MainActor
final class WatchlistReorderTests: XCTestCase {
    private var tempDir: URL!
    private var database: TickBar.Database!
    private var watchlistRepo: WatchlistRepository!
    private var settingsRepo: SettingsRepository!
    private var refresher: QuoteRefresher!
    private var viewModel: PopoverViewModel!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        database = try TickBar.Database(path: dbPath)
        watchlistRepo = WatchlistRepository(dbPool: database.dbPool)
        settingsRepo = SettingsRepository(dbPool: database.dbPool)

        let clock = MarketClock()
        let tencent = TencentProvider()
        let orchestrator = ProviderOrchestrator(
            providers: [.tencent: tencent],
            preferences: ProviderPreference.defaults
        )
        let quoteCache = QuoteCacheRepository(dbPool: database.dbPool)
        refresher = QuoteRefresher(
            provider: orchestrator,
            watchlistRepo: watchlistRepo,
            clock: clock,
            quoteCacheRepo: quoteCache,
            settingsRepo: settingsRepo
        )
        viewModel = PopoverViewModel(
            refresher: refresher,
            watchlistRepo: watchlistRepo,
            settingsRepo: settingsRepo
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        refresher = nil
        watchlistRepo = nil
        settingsRepo = nil
        database = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testRealTimelineFetcher() async throws {
        let symA = SymbolID(code: "688008", market: .a)
        let histA = await TimelineHistoryFetcher.shared.fetchHistory(for: symA)
        if let h = histA {
            XCTAssertGreaterThanOrEqual(h.points.count, 2)
            print("TEST_TIMELINE_A:", h.points.count, "first:", h.points.first as Any, "last:", h.points.last as Any)
        }

        let symHK = SymbolID(code: "00700", market: .hk)
        let histHK = await TimelineHistoryFetcher.shared.fetchHistory(for: symHK)
        if let h = histHK {
            XCTAssertGreaterThanOrEqual(h.points.count, 2)
            print("TEST_TIMELINE_HK:", h.points.count, "first:", h.points.first as Any, "last:", h.points.last as Any)
        }
    }

    func testXueqiuNightSessionParse() throws {
        let sym = SymbolID(code: "GOOGL", market: .us)
        let jsonStr = """
        {
          "data": {
            "items": [
              {
                "quote": {
                  "symbol": "GOOGL",
                  "name": "谷歌A",
                  "current": 280.03,
                  "last_close": 278.99,
                  "current_ext": 278.43,
                  "chg_ext": -1.6,
                  "percent_ext": -0.57,
                  "current_night_session": 273.58,
                  "timestamp_night_session": 1794189540000,
                  "chg_night_session": -6.45,
                  "percent_night_session": -2.30
                }
              }
            ]
          }
        }
        """
        let xq = XueqiuProvider()
        let now = ISO8601DateFormatter().date(from: "2026-11-09T02:00:00Z")!
        let quotes = try xq.parse(Data(jsonStr.utf8), symbols: [sym], at: now)
        guard let q = quotes[sym] else {
            XCTFail("Xueqiu should parse GOOGL quote")
            return
        }
        XCTAssertEqual(q.price, Decimal(280.03))
        XCTAssertTrue(q.isExtended)
        XCTAssertEqual(q.extendedPrice, Decimal(273.58))
        XCTAssertEqual(q.effectivePrice, Decimal(273.58))
    }

    func testSinaExtendedFetch() async throws {
        let sym = SymbolID(code: "AAPL", market: .us)
        let sina = SinaProvider()
        let result = try await sina.fetch([sym])
        guard let q = result[sym] else {
            XCTFail("Sina should return quote for AAPL")
            return
        }
        XCTAssertGreaterThan(q.price, 0)
        print("SINA_AAPL: price=\(q.price), isExtended=\(q.isExtended), extPrice=\(String(describing: q.extendedPrice)), session=\(String(describing: q.extendedSession))")
    }

    func testTencentParse() throws {
        let sym = SymbolID(code: "AAPL", market: .us)
        let raw = #"v_usAAPL="200~苹果~AAPL.OQ~331.90~338.32~325.58~63160026~0~0~329.80~14280~0~0~0~0~0~0~0~0~329.96~80~0~0~0~0~0~0~0~0~~2026-11-03 16:00:02~-6.42~-1.90~334.50~325.33~USD~63160026~20893976633~0.43~38.06~~44.49~~2.71~48407.97637~48438.08342~Apple Inc.~8.72~351.73~242.76~14200~45.05~0.32~48438.08342~22.42~-4.38~GP~148.75~36.08~-2.24~-0.52~7.67~14594180000~14585108878~1.26~36.18~1.06~330.81~~~~~";"#
        let tencent = TencentProvider()
        let result = tencent.parse(raw, encodedPairs: [("usAAPL", sym)])
        guard let q = result[sym] else {
            XCTFail("Tencent should parse AAPL")
            return
        }
        XCTAssertEqual(q.price, Decimal(string: "331.90"))
        XCTAssertFalse(q.isExtended)
    }

    func testReorderWatchItemMovesItemToTargetPosition() throws {
        let itemA = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", order: 0)
        let itemB = WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "Tesla", order: 1)
        let itemC = WatchItem(symbol: SymbolID(code: "NVDA", market: .us), name: "Nvidia", order: 2)
        try watchlistRepo.upsert(itemA)
        try watchlistRepo.upsert(itemB)
        try watchlistRepo.upsert(itemC)
        viewModel.reload()

        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL", "TSLA", "NVDA"])

        // Move Apple (index 0) to Nvidia's position (index 2)
        viewModel.reorderWatchItem(from: itemA.id, to: itemC.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["TSLA", "NVDA", "AAPL"])

        // Persisted state matches
        let persisted = try watchlistRepo.all()
        XCTAssertEqual(persisted.map(\.symbol.code), ["TSLA", "NVDA", "AAPL"])

        // Move Tesla (index 0) to Nvidia (index 1)
        viewModel.reorderWatchItem(from: itemB.id, to: itemC.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["NVDA", "TSLA", "AAPL"])

        // Moving to same index is no-op
        viewModel.reorderWatchItem(from: itemC.id, to: itemC.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["NVDA", "TSLA", "AAPL"])
    }

    func testGroupAndStockDragStringsStayCompatibleAndDistinct() {
        let id = UUID()
        let group = WatchlistDragPayload.group(id).string
        let item = WatchlistDragPayload.item(id).string
        XCTAssertEqual(WatchlistDragPayload(group), .group(id))
        XCTAssertEqual(WatchlistDragPayload(item), .item(id))
        XCTAssertEqual(item, id.uuidString)
        XCTAssertNil(UUID(uuidString: group)) // 股票行必须拒绝分组拖拽。
        XCTAssertNil(WatchlistDragPayload("watchlist-group:invalid"))
        XCTAssertNil(WatchlistDragPayload("invalid"))
    }

    func testGroupReorderPersistsBothDirectionsWithoutMovingStocksOrSelection() throws {
        let original = viewModel.groups[0]
        let tech = viewModel.createGroup(name: "Tech")
        let crypto = viewModel.createGroup(name: "Crypto")
        let apple = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", watchlistId: original.id)
        let tesla = WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "Tesla", watchlistId: tech.id)
        try watchlistRepo.upsert(apple)
        try watchlistRepo.upsert(tesla)
        viewModel.reload()
        viewModel.selectGroup(id: tech.id)

        viewModel.reorderGroups(from: original.id, to: crypto.id)
        XCTAssertEqual(viewModel.groups.map(\.id), [tech.id, crypto.id, original.id])
        XCTAssertEqual(try watchlistRepo.allGroups().map(\.id), [tech.id, crypto.id, original.id])
        XCTAssertEqual(viewModel.selectedGroupID, tech.id)
        XCTAssertEqual(viewModel.watchlist.map(\.id), [tesla.id])

        viewModel.reorderGroups(from: original.id, to: tech.id)
        viewModel.reload()
        XCTAssertEqual(viewModel.groups.map(\.id), [original.id, tech.id, crypto.id])
        XCTAssertEqual(viewModel.groups.map(\.order), [0, 1, 2])
        XCTAssertEqual(viewModel.selectedGroupID, tech.id)
        XCTAssertEqual(try watchlistRepo.all().first(where: { $0.id == apple.id })?.watchlistId, original.id)
        XCTAssertEqual(try watchlistRepo.all().first(where: { $0.id == tesla.id })?.watchlistId, tech.id)

        viewModel.reorderGroups(from: tech.id, to: tech.id)
        viewModel.reorderGroups(from: UUID(), to: tech.id)
        XCTAssertEqual(viewModel.groups.map(\.id), [original.id, tech.id, crypto.id])
        viewModel.selectGroup(at: 3)
        XCTAssertEqual(viewModel.selectedGroupID, crypto.id)
    }

    func testMultipleWatchlistsCreateRenameDelete() throws {
        // Initially has default group
        XCTAssertEqual(viewModel.groups.count, 1)
        let defaultGroup = viewModel.groups[0]
        XCTAssertEqual(defaultGroup.name, "Watchlist")

        // Add an item to default group
        let apple = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", watchlistId: defaultGroup.id)
        try watchlistRepo.upsert(apple)
        viewModel.reload()
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Create a new group
        let newGroup = viewModel.createGroup(name: "US Tech")
        XCTAssertEqual(viewModel.groups.count, 2)
        XCTAssertEqual(viewModel.selectedGroupID, newGroup.id)
        XCTAssertEqual(viewModel.watchlist.count, 0) // New group is empty

        // Add Tesla to new group
        let tesla = WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "Tesla", watchlistId: newGroup.id)
        try watchlistRepo.upsert(tesla)
        viewModel.reload()
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["TSLA"])

        // Switch back to default group
        viewModel.selectGroup(id: defaultGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Rename new group
        viewModel.renameGroup(id: newGroup.id, newName: "Magnificent")
        let updatedGroups = try watchlistRepo.allGroups()
        XCTAssertEqual(updatedGroups.first(where: { $0.id == newGroup.id })?.name, "Magnificent")

        // Delete the new group
        viewModel.deleteGroup(id: newGroup.id)
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.selectedGroupID, defaultGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Tesla was cascade deleted
        let remaining = try watchlistRepo.all()
        XCTAssertEqual(remaining.map(\.symbol.code), ["AAPL"])
    }

    func testMoveWatchItemToAnotherGroup() throws {
        let defaultGroup = viewModel.groups[0]
        let techGroup = viewModel.createGroup(name: "Tech")
        let cryptoGroup = viewModel.createGroup(name: "Crypto")

        let apple = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", watchlistId: defaultGroup.id)
        let btc = WatchItem(symbol: SymbolID(code: "BTCUSDT", market: .crypto), name: "Bitcoin", watchlistId: defaultGroup.id)
        try watchlistRepo.upsert(apple)
        try watchlistRepo.upsert(btc)
        viewModel.reload()

        viewModel.selectGroup(id: defaultGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL", "BTCUSDT"])

        // Move Apple from default to Tech group
        viewModel.moveWatchItem(apple.id, toGroupID: techGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["BTCUSDT"])

        // Switch to Tech group and verify Apple is there
        viewModel.selectGroup(id: techGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Move Bitcoin to Crypto group
        viewModel.moveWatchItem(btc.id, toGroupID: cryptoGroup.id)
        viewModel.selectGroup(id: cryptoGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["BTCUSDT"])

        // Moving to same group is no-op
        viewModel.moveWatchItem(btc.id, toGroupID: cryptoGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["BTCUSDT"])
    }

    func testSelectGroupByIndexWithShortcuts() throws {
        _ = viewModel.createGroup(name: "List2")
        _ = viewModel.createGroup(name: "List3")

        XCTAssertEqual(viewModel.groups.count, 3)

        // Switch to List 2 (Cmd+2)
        viewModel.selectGroup(at: 2)
        XCTAssertEqual(viewModel.selectedGroupID, viewModel.groups[1].id)

        // Switch to List 3 (Cmd+3)
        viewModel.selectGroup(at: 3)
        XCTAssertEqual(viewModel.selectedGroupID, viewModel.groups[2].id)

        // Switch back to List 1 (Cmd+1)
        viewModel.selectGroup(at: 1)
        XCTAssertEqual(viewModel.selectedGroupID, viewModel.groups[0].id)

        // Out of bounds index does not crash and keeps selection
        viewModel.selectGroup(at: 9)
        XCTAssertEqual(viewModel.selectedGroupID, viewModel.groups[0].id)
    }
}
