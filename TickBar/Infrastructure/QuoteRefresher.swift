import Foundation
import Combine
import AppKit

/// 全局自选股行情刷新泵。
/// 根据可见性 / 系统休眠 / 市场开休市状态自动切换刷新节奏。
@MainActor
final class QuoteRefresher: ObservableObject {
    enum Pace {
        case popoverOpen   // 3s, 用户正在查看
        case tickerOnly    // 用户配置的菜单栏刷新间隔(默认 5s)
        case sleeping      // 暂停(全市场休市 / 系统休眠 / 离线)
    }

    @Published var tickerInterval: TimeInterval = 5
    @Published var pauseWhenClosed: Bool = true

    private func interval(for pace: Pace) -> TimeInterval {
        switch pace {
        case .popoverOpen: return min(tickerInterval, 3)
        case .tickerOnly:  return tickerInterval
        case .sleeping:    return .infinity
        }
    }

    @Published private(set) var quotes: [SymbolID: Quote] = [:]
    @Published private(set) var extendedReports: [ExtendedProviderReport] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var snapshotIsFromCache: Bool = false

    private let provider: QuoteProvider
    private let watchlistRepo: WatchlistRepository
    private let clock: MarketClock
    private let quoteCacheRepo: QuoteCacheRepository?
    private let settingsRepo: SettingsRepository?

    private var task: Task<Void, Never>?
    private var pace: Pace = .tickerOnly
    private var popoverOpen = false
    private var sleeping = false
    private var offline = false
    private var observers: [NSObjectProtocol] = []

    init(
        provider: QuoteProvider,
        watchlistRepo: WatchlistRepository,
        clock: MarketClock,
        quoteCacheRepo: QuoteCacheRepository? = nil,
        settingsRepo: SettingsRepository? = nil
    ) {
        self.provider = provider
        self.watchlistRepo = watchlistRepo
        self.clock = clock
        self.quoteCacheRepo = quoteCacheRepo
        self.settingsRepo = settingsRepo

        // 从磁盘预加载上次缓存的 quotes，秒开秒显
        let cached = quoteCacheRepo?.loadAll() ?? [:]
        if !cached.isEmpty {
            self.quotes = cached
            self.snapshotIsFromCache = true
            Log.quote.info("seeded \(cached.count, privacy: .public) quotes from disk")
        }

        observeSystem()
    }

    func setOffline(_ value: Bool) {
        offline = value
        recomputePace()
    }

    var isOffline: Bool { offline }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        task?.cancel()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 立即触发刷新一次
    func refreshNow() {
        Task { await tick() }
    }

    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
        recomputePace()
    }

    private func observeSystem() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.recomputePace()
            }
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.recomputePace()
            }
        })
    }

    private func recomputePace() {
        let next: Pace
        let markets = Set(((try? watchlistRepo.all()) ?? []).map(\.symbol.market))
        if sleeping || offline {
            next = .sleeping
        } else if pauseWhenClosed && !clock.anyQuoteActive(markets: markets) {
            next = .sleeping
        } else if popoverOpen {
            next = .popoverOpen
        } else {
            next = .tickerOnly
        }
        pace = next
    }

    private func runLoop() async {
        await tick()
        while !Task.isCancelled {
            recomputePace()
            let nextInterval = await MainActor.run { self.interval(for: self.pace) }
            if nextInterval.isInfinite {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            try? await Task.sleep(nanoseconds: UInt64(nextInterval * 1_000_000_000))
            if Task.isCancelled { break }
            await tick()
        }
    }

    private func tick() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            // 缺失标的或请求失败时也不能一直保留上一交易时段的 24h 标签。
            let now = Date()
            for (symbol, quote) in quotes where symbol.market == .us && quote.isExtended {
                if let session = quote.extendedSession,
                   !clock.isCurrentUSExtendedTrade(quote.timestamp, session: session, at: now) {
                    quotes[symbol] = quote.withoutExtended()
                }
            }
            isRefreshing = false
        }

        do {
            let items = (try? watchlistRepo.all()) ?? []
            let symbols = items.map { $0.symbol }

            guard !symbols.isEmpty else {
                quotes = [:]
                snapshotIsFromCache = false
                lastUpdated = Date()
                lastError = nil
                return
            }

            let freshQuotes = try await provider.fetch(symbols)
            if let orchestrator = provider as? ProviderOrchestrator {
                extendedReports = await orchestrator.currentExtendedReports()
            }
            quotes.merge(freshQuotes) { _, new in new }
            snapshotIsFromCache = false
            lastUpdated = Date()
            lastError = nil

            if !freshQuotes.isEmpty {
                quoteCacheRepo?.upsertMany(freshQuotes)
            }
        } catch {
            if let orchestrator = provider as? ProviderOrchestrator {
                extendedReports = await orchestrator.currentExtendedReports()
            }
            lastError = String(describing: error)
            Log.quote.error("quote refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}
