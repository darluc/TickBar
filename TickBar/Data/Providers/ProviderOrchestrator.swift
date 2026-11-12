import Foundation

/// Provider 标识。统一 ID 串便于持久化和 UI 显示。
enum ProviderID: String, Codable, CaseIterable, Sendable {
    case tencent
    case eastmoney
    case yahoo
    case finnhub
    case naver
    case binance

    var displayName: String {
        switch self {
        case .tencent:   return "腾讯财经"
        case .eastmoney: return "东方财富"
        case .yahoo:     return "Yahoo Finance"
        case .finnhub:   return "Finnhub"
        case .naver:     return "Naver 财经"
        case .binance:   return "Binance 币安"
        }
    }
}

/// 每市场的 provider 优先级列表 + 启用标志。
struct ProviderPreference: Codable, Equatable, Sendable {
    var order: [ProviderID]
    var enabled: [ProviderID: Bool]

    static let defaults: [Market: ProviderPreference] = [
        .a:  ProviderPreference(order: [.tencent, .eastmoney, .yahoo], enabled: [.tencent: true, .eastmoney: true, .yahoo: false, .finnhub: false, .naver: false, .binance: false]),
        .hk: ProviderPreference(order: [.tencent, .eastmoney, .yahoo], enabled: [.tencent: true, .eastmoney: true, .yahoo: false, .finnhub: false, .naver: false, .binance: false]),
        .us: ProviderPreference(order: [.tencent, .eastmoney, .yahoo, .finnhub], enabled: [.tencent: true, .eastmoney: true, .yahoo: true, .finnhub: false, .naver: false, .binance: false]),
        .kr: ProviderPreference(order: [.naver, .yahoo], enabled: [.naver: true, .yahoo: true, .tencent: false, .eastmoney: false, .finnhub: false, .binance: false]),
        .crypto: ProviderPreference(order: [.binance], enabled: [.binance: true, .yahoo: false, .tencent: false, .eastmoney: false, .finnhub: false, .naver: false])
    ]
}

/// 编排多 provider:按市场拆分 symbols → 按用户设定顺序 fallback。
actor ProviderOrchestrator: QuoteProvider {
    let id = "orchestrator"
    let supportedMarkets: Set<Market> = [.a, .hk, .us, .kr, .crypto]

    private let providers: [ProviderID: QuoteProvider]
    private var preferences: [Market: ProviderPreference]
    private var cooldownUntil: [String: Date] = [:]   // key = "providerID|market"
    private let cooldownDuration: TimeInterval = 30
    private let extendedProviders: [QuoteProvider]
    private let now: @Sendable () -> Date
    private var extendedPreference: ExtendedProviderPreference
    private var extendedReports: [ExtendedProviderReport] = []

    init(
        providers: [ProviderID: QuoteProvider],
        preferences: [Market: ProviderPreference],
        extendedProviders: [QuoteProvider] = [RobinhoodProvider(), YahooProvider(), XueqiuProvider(), SinaProvider(), NasdaqProvider()],
        now: @escaping @Sendable () -> Date = { Date() },
        extendedPreference: ExtendedProviderPreference = .defaults
    ) {
        self.providers = providers
        self.preferences = preferences
        self.extendedProviders = extendedProviders
        self.now = now
        self.extendedPreference = extendedPreference.normalized
    }

    func updateExtendedPreference(_ preference: ExtendedProviderPreference) {
        extendedPreference = preference.normalized
        extendedReports = []
    }

    func currentExtendedReports() -> [ExtendedProviderReport] { extendedReports }

    func updatePreferences(_ prefs: [Market: ProviderPreference]) {
        self.preferences = prefs
    }

    func currentPreferences() -> [Market: ProviderPreference] {
        preferences
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        // One security can belong to several watchlists. Fetch it once, including
        // US ticker case aliases, while keeping equal codes in different markets.
        var seen = Set<String>()
        let uniqueSymbols = symbols.filter { seen.insert($0.storageKey).inserted }
        // 按市场分桶
        let byMarket = Dictionary(grouping: uniqueSymbols, by: { $0.market })

        var combined: [SymbolID: Quote] = [:]
        var lastError: Error?

        for (market, marketSymbols) in byMarket {
            do {
                var result: [SymbolID: Quote]
                do {
                    result = try await fetchForMarket(market, symbols: marketSymbols)
                } catch {
                    // 主源失败不应阻止独立的美股扩展报价源。
                    guard market == .us else { throw error }
                    lastError = error
                    result = [:]
                }
                if market == .us {
                    result = await overlayUSExtended(result, symbols: marketSymbols)
                }
                combined.merge(result, uniquingKeysWith: { _, new in new })
            } catch {
                lastError = error
                Log.quote.warning("market \(market.rawValue, privacy: .public) all providers failed: \(String(describing: error), privacy: .public)")
            }
        }

        if combined.isEmpty, let lastError = lastError {
            throw lastError
        }
        return combined
    }

    private func fetchForMarket(_ market: Market, symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let pref = preferences[market] ?? ProviderPreference.defaults[market]!
        let now = Date()
        var lastError: Error?

        let pids = pref.order.filter { pref.enabled[$0] == true }

        for pid in pids {
            guard let provider = providers[pid] else { continue }
            guard provider.supportedMarkets.contains(market) else { continue }

            let cooldownKey = "\(pid.rawValue)|\(market.rawValue)"
            if let until = cooldownUntil[cooldownKey], until > now { continue }

            do {
                let result = try await provider.fetch(symbols)
                if !result.isEmpty {
                    Log.quote.info("market=\(market.rawValue, privacy: .public) provider=\(pid.rawValue, privacy: .public) ok (\(result.count) quotes)")
                    return result
                }
            } catch {
                lastError = error
                cooldownUntil[cooldownKey] = now.addingTimeInterval(cooldownDuration)
                Log.quote.warning("provider \(pid.rawValue, privacy: .public) failed for \(market.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if let lastError = lastError {
            throw lastError
        }
        return [:]
    }

    /// 每个标的独立 fallback，仅接受当前交易时段的真实成交。
    private func overlayUSExtended(_ quotes: [SymbolID: Quote], symbols: [SymbolID]) async -> [SymbolID: Quote] {
        let date = now()
        // 固定本次批次的配置；设置修改在下个批次生效。
        let preference = extendedPreference
        extendedReports = []
        let clock = MarketClock()
        let session = clock.usExtendedSession(at: date)
        var out = quotes

        func isCurrent(_ quote: Quote) -> Bool {
            guard let session, quote.isExtended, quote.extendedSession == session else { return false }
            return clock.isCurrentUSExtendedTrade(quote.timestamp, session: session, at: date)
        }

        // 主源也可能附带过期的盘后价，必须先移除错误的扩展标签。
        for (symbol, quote) in out where !isCurrent(quote) {
            out[symbol] = quote.withoutExtended()
        }
        guard session != nil else { return out }

        let orderedProviders = extendedProviders.sorted { lhs, rhs in
            let left = ExtendedProviderID(rawValue: lhs.id).flatMap { preference.order.firstIndex(of: $0) } ?? Int.max
            let right = ExtendedProviderID(rawValue: rhs.id).flatMap { preference.order.firstIndex(of: $0) } ?? Int.max
            return left < right
        }
        for provider in orderedProviders {
            if let id = ExtendedProviderID(rawValue: provider.id) {
                guard preference.enabled[id] == true else { continue }
                if session == .overnight && !id.supportsOvernight { continue }
            }
            let need = symbols.filter { $0.market == .us && out[$0].map(isCurrent) != true }
            guard !need.isEmpty else { break }
            do {
                let extra = try await provider.fetch(need)
                var accepted: [SymbolID] = []
                for symbol in need {
                    guard let quote = extra[symbol], isCurrent(quote) else { continue }
                    out[symbol] = out[symbol]?.overlayingExtended(from: quote) ?? quote
                    accepted.append(symbol)
                }
                let tradeTimes = Dictionary(uniqueKeysWithValues: accepted.compactMap { symbol in
                    extra[symbol].map { (symbol, $0.timestamp) }
                })
                extendedReports.append(ExtendedProviderReport(providerID: provider.id, requested: need, accepted: accepted, tradeTimes: tradeTimes, timestamp: now(), error: nil))
                Log.quote.info("extended provider=\(provider.id, privacy: .public) accepted=\(accepted.count, privacy: .public) requested=\(need.count, privacy: .public) symbols=\(accepted.map(\.code).joined(separator: ","), privacy: .public)")
            } catch {
                extendedReports.append(ExtendedProviderReport(providerID: provider.id, requested: need, accepted: [], tradeTimes: [:], timestamp: now(), error: String(describing: error)))
                Log.quote.warning("extended provider=\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }
}
