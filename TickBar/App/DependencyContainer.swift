import Foundation
import Combine

/// 应用全局依赖。AppDelegate 启动时构造一次,然后通过 `shared` 提供。
@MainActor
final class DependencyContainer {
    static private(set) var shared: DependencyContainer?

    let database: Database
    let watchlistRepo: WatchlistRepository
    let settingsRepo: SettingsRepository
    let quoteCacheRepo: QuoteCacheRepository
    let orchestrator: ProviderOrchestrator
    let finnhub: FinnhubProvider
    let provider: QuoteProvider
    let symbolSearch: SymbolSearch
    let clock: MarketClock
    let refresher: QuoteRefresher
    let networkMonitor: NetworkMonitor
    let tickerPrefs: TickerPreferences
    let dataSourcePrefs: DataSourcePreferences
    let appearancePrefs: AppearancePreferences
    let etfMonitor: ETFMonitor

    init() throws {
        let dbPath = try Database.defaultPath()
        let database = try Database(path: dbPath)
        self.database = database
        self.watchlistRepo = WatchlistRepository(dbPool: database.dbPool)
        self.settingsRepo = SettingsRepository(dbPool: database.dbPool)
        self.quoteCacheRepo = QuoteCacheRepository(dbPool: database.dbPool)

        NetworkConfig.apply(
            mode: settingsRepo.proxyMode,
            host: settingsRepo.proxyHost,
            port: settingsRepo.proxyPort
        )

        let tencent = TencentProvider()
        let eastMoney = EastMoneyProvider()
        let yahoo = YahooProvider()
        let finnhub = FinnhubProvider()
        let naver = NaverProvider()
        let binance = BinanceProvider()
        self.finnhub = finnhub
        self.dataSourcePrefs = DataSourcePreferences(repo: settingsRepo)
        finnhub.setApiKey(dataSourcePrefs.finnhubKey)
        let registry: [ProviderID: QuoteProvider] = [
            .tencent: tencent,
            .eastmoney: eastMoney,
            .yahoo: yahoo,
            .finnhub: finnhub,
            .naver: naver,
            .binance: binance
        ]
        let orchestrator = ProviderOrchestrator(
            providers: registry,
            preferences: dataSourcePrefs.preferences,
            extendedProviders: [RobinhoodProvider(), yahoo, XueqiuProvider(), SinaProvider(), NasdaqProvider()],
            extendedPreference: dataSourcePrefs.extendedPreference
        )
        self.orchestrator = orchestrator
        self.provider = orchestrator
        self.symbolSearch = SymbolSearch()
        self.clock = MarketClock(settingsRepo: settingsRepo)
        self.etfMonitor = ETFMonitor(clock: clock)

        self.refresher = QuoteRefresher(
            provider: orchestrator,
            watchlistRepo: watchlistRepo,
            clock: clock,
            quoteCacheRepo: quoteCacheRepo,
            settingsRepo: settingsRepo
        )
        self.networkMonitor = NetworkMonitor()
        self.tickerPrefs = TickerPreferences(repo: settingsRepo)
        self.appearancePrefs = AppearancePreferences(repo: settingsRepo)

        self.tickerPrefs.$pauseWhenClosed
            .sink { [weak refresher] val in
                refresher?.pauseWhenClosed = val
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    static func bootstrap() throws -> DependencyContainer {
        let container = try DependencyContainer()
        shared = container
        return container
    }

    func warmup() async {
        refresher.tickerInterval = TimeInterval(settingsRepo.quoteRefreshInterval)
        refresher.pauseWhenClosed = tickerPrefs.pauseWhenClosed
        refresher.start()
    }
}
