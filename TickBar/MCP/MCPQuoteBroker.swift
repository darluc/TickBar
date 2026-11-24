import Foundation

struct MCPStockQuoteRow: Codable, Sendable {
    let symbol: String
    let code: String
    let market: String
    let name: String
    let currency: String
    let price: String
    let change: String
    let changePercent: Double
    let session: String
    let quoteTime: String?
    let retrievedAt: String
    let source: String
    let missing: Bool
    let stale: Bool
}

struct MCPStockQuotesResponse: Codable, Sendable {
    let partial: Bool
    let quotes: [MCPStockQuoteRow]
}

/// On-demand quote fetches for MCP with short-lived reuse to avoid duplicate upstream pressure.
actor MCPQuoteBroker {
    static let reuseInterval: TimeInterval = 15
    static let maxCodes = 20

    private let orchestrator: ProviderOrchestrator
    private var lastBySymbol: [String: (quote: Quote, fetchedAt: Date)] = [:]
    private var lastMarketFetch: [Market: Date] = [:]

    init(orchestrator: ProviderOrchestrator) {
        self.orchestrator = orchestrator
    }

    func ingestLiveQuotes(_ quotes: [SymbolID: Quote], retrievedAt: Date = Date()) {
        for (symbol, quote) in quotes {
            lastBySymbol[symbol.storageKey] = (quote, retrievedAt)
        }
    }

    func fetch(
        market: Market,
        codes: [String],
        seedQuotes: [SymbolID: Quote],
        seedRetrievedAt: Date?
    ) async -> MCPStockQuotesResponse {
        let normalized = Self.normalizeCodes(market: market, codes: codes)
        guard !normalized.isEmpty else {
            return MCPStockQuotesResponse(partial: false, quotes: [])
        }

        if let seedRetrievedAt {
            ingestLiveQuotes(seedQuotes, retrievedAt: seedRetrievedAt)
        } else {
            ingestLiveQuotes(seedQuotes)
        }

        let now = Date()
        var missing: [SymbolID] = []
        for code in normalized {
            let symbol = SymbolID(code: code, market: market)
            if let cached = lastBySymbol[symbol.storageKey], now.timeIntervalSince(cached.fetchedAt) <= Self.reuseInterval {
                continue
            }
            missing.append(symbol)
        }

        if !missing.isEmpty, canFetchMarket(market, at: now) {
            lastMarketFetch[market] = now
            if let fresh = try? await orchestrator.fetch(missing) {
                for (symbol, quote) in fresh {
                    lastBySymbol[symbol.storageKey] = (quote, now)
                }
            }
        }

        var rows: [MCPStockQuoteRow] = []
        var partial = false
        let retrievedAt = ISO8601DateFormatter().string(from: now)

        for code in normalized {
            let symbol = SymbolID(code: code, market: market)
            if let cached = lastBySymbol[symbol.storageKey] {
                let stale = now.timeIntervalSince(cached.fetchedAt) > Self.reuseInterval
                rows.append(Self.row(from: cached.quote, fetchedAt: cached.fetchedAt, stale: stale, missing: false, retrievedAt: retrievedAt))
                if stale { partial = true }
            } else {
                partial = true
                rows.append(MCPStockQuoteRow(
                    symbol: symbol.description,
                    code: code,
                    market: market.rawValue,
                    name: "",
                    currency: market.defaultCurrency.rawValue,
                    price: "",
                    change: "",
                    changePercent: 0,
                    session: "",
                    quoteTime: nil,
                    retrievedAt: retrievedAt,
                    source: "missing",
                    missing: true,
                    stale: false
                ))
            }
        }

        return MCPStockQuotesResponse(partial: partial, quotes: rows)
    }

    private func canFetchMarket(_ market: Market, at date: Date) -> Bool {
        guard let last = lastMarketFetch[market] else { return true }
        return date.timeIntervalSince(last) >= Self.reuseInterval
    }

    private static func normalizeCodes(market: Market, codes: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in codes.prefix(maxCodes) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let symbol = SymbolID(code: trimmed, market: market)
            if seen.insert(symbol.storageKey).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    private static func row(
        from quote: Quote,
        fetchedAt: Date,
        stale: Bool,
        missing: Bool,
        retrievedAt: String
    ) -> MCPStockQuoteRow {
        let quoteTime = ISO8601DateFormatter().string(from: quote.timestamp)
        let session: String
        if let ext = quote.extendedSession, ext != .regular {
            session = ext.rawValue
        } else if quote.isClosed {
            session = "closed"
        } else {
            session = "regular"
        }
        return MCPStockQuoteRow(
            symbol: quote.symbol.description,
            code: quote.symbol.code,
            market: quote.symbol.market.rawValue,
            name: quote.name,
            currency: quote.currency.rawValue,
            price: "\(quote.effectivePrice)",
            change: "\(quote.effectiveChange)",
            changePercent: quote.effectiveChangePct,
            session: session,
            quoteTime: quoteTime,
            retrievedAt: retrievedAt,
            source: stale ? "cached" : "live",
            missing: missing,
            stale: stale
        )
    }
}
