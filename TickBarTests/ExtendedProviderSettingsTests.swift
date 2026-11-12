import XCTest
@testable import TickBar

final class ExtendedProviderSettingsTests: XCTestCase {
    func testNormalizationPreservesDisabledProvidersAndCompletesOrder() {
        let preference = ExtendedProviderPreference(order: [.robinhood, .robinhood], enabled: [.robinhood: false]).normalized
        XCTAssertEqual(preference.order, [.robinhood, .yahoo, .xueqiu, .sina, .nasdaq])
        XCTAssertEqual(preference.enabled[.robinhood], false)
        XCTAssertEqual(preference.enabled[.xueqiu], true)
    }

    @MainActor
    func testExtendedPreferencesPersistSeparatelyFromRegularSources() throws {
        try withRepository { repository in
            let preferences = DataSourcePreferences(repo: repository)
            let original = preferences.preferences
            var changed = ExtendedProviderPreference.defaults
            changed.order = [.robinhood, .yahoo, .xueqiu, .nasdaq, .sina]
            changed.enabled[.xueqiu] = false
            var notified: ExtendedProviderPreference?
            preferences.onExtendedPreferenceChange = { notified = $0 }
            preferences.updateExtendedPreference(changed)
            XCTAssertEqual(notified, changed)
            let reloaded = DataSourcePreferences(repo: repository)
            XCTAssertEqual(reloaded.extendedPreference, changed)
            XCTAssertEqual(reloaded.preferences, original)
        }
    }

    func testPriorityDisableAndHotUpdateAffectActualRequests() async throws {
        let instant = ISO8601DateFormatter().date(from: "2026-11-09T02:00:00Z")!
        let symbol = SymbolID(code: "NVDA", market: .us)
        let quote = Quote(symbol: symbol, name: "NVIDIA", price: 186, prevClose: 180,
                          currency: .usd, timestamp: instant, extendedPrice: 190, extendedSession: .overnight)
        let xueqiu = SettingsTestProvider(id: "xueqiu", quotes: [symbol: quote])
        let robinhood = SettingsTestProvider(id: "robinhood", quotes: [symbol: quote])
        let sina = SettingsTestProvider(id: "sina", quotes: [symbol: quote])
        var preference = ExtendedProviderPreference.defaults
        preference.enabled[.xueqiu] = false
        // Even if placed first, Sina must not be queried as a night source.
        preference.order = [.sina, .xueqiu, .robinhood, .nasdaq]
        let orchestrator = ProviderOrchestrator(
            providers: [:], preferences: [:], extendedProviders: [xueqiu, robinhood, sina],
            now: { instant }, extendedPreference: preference
        )
        let first = try await orchestrator.fetch([symbol])
        XCTAssertEqual(first[symbol]?.extendedPrice, 190)
        let xueqiuCount = await xueqiu.count
        let robinhoodCount = await robinhood.count
        let sinaCount = await sina.count
        XCTAssertEqual(xueqiuCount, 0)
        XCTAssertEqual(robinhoodCount, 1)
        XCTAssertEqual(sinaCount, 0)
        let reports = await orchestrator.currentExtendedReports()
        XCTAssertEqual(reports.map(\.providerID), ["robinhood"])
        XCTAssertEqual(reports.first?.tradeTimes[symbol], instant)

        preference.enabled[.xueqiu] = true
        preference.order = [.xueqiu, .robinhood, .sina, .nasdaq]
        await orchestrator.updateExtendedPreference(preference)
        _ = try await orchestrator.fetch([symbol])
        let nextXueqiuCount = await xueqiu.count
        let nextRobinhoodCount = await robinhood.count
        XCTAssertEqual(nextXueqiuCount, 1)
        XCTAssertEqual(nextRobinhoodCount, 1)
    }

    func testClockTransitionsAndWeekendNightRules() {
        let clock = MarketClock()
        let formatter = ISO8601DateFormatter()
        let close = formatter.date(from: "2026-11-09T21:00:00Z")!
        XCTAssertEqual(clock.status(.us, at: close), .closed)
        XCTAssertEqual(clock.usExtendedSession(at: close), .postMarket)
        let sunday = formatter.date(from: "2026-11-09T02:27:00Z")!
        XCTAssertEqual(clock.usExtendedSession(at: sunday), .overnight)
        XCTAssertTrue(clock.anyQuoteActive(markets: [.us], at: sunday))
        let fridayNight = formatter.date(from: "2026-11-07T02:27:00Z")!
        XCTAssertNil(clock.usExtendedSession(at: fridayNight))
        XCTAssertFalse(clock.anyQuoteActive(markets: [.us], at: fridayNight))
    }

    @MainActor
    func testForceClosedAlsoStopsExtendedSession() throws {
        try withRepository { repository in
            let sunday = ISO8601DateFormatter().date(from: "2026-11-09T02:27:00Z")!
            try repository.set(SettingsRepository.Keys.marketOverride(.us), "2026-11-08:closed")
            let clock = MarketClock(settingsRepo: repository)
            XCTAssertEqual(clock.status(.us, at: sunday), .closed)
            XCTAssertNil(clock.usExtendedSession(at: sunday))
            XCTAssertFalse(clock.anyQuoteActive(markets: [.us], at: sunday))
        }
    }

    @MainActor
    private func withRepository(_ body: (SettingsRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try TickBar.Database(path: directory.appendingPathComponent("test.sqlite").path)
        defer {
            try? database.dbPool.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(SettingsRepository(dbPool: database.dbPool))
    }
}

private actor SettingsTestProvider: QuoteProvider {
    nonisolated let id: String
    nonisolated let supportedMarkets: Set<Market> = [.us]
    let quotes: [SymbolID: Quote]
    private(set) var count = 0

    init(id: String, quotes: [SymbolID: Quote]) {
        self.id = id
        self.quotes = quotes
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        count += 1
        return quotes.filter { symbols.contains($0.key) }
    }
}
