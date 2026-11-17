import Combine
import Foundation

@MainActor
final class HoldingsMonitor: ObservableObject {
    @Published private(set) var stocks: [StockHoldingResult] = []
    @Published private(set) var snapshots: [ETFShareSnapshot] = []
    @Published private(set) var etfError = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    private let service = HoldingsService()

    private struct Cache: Codable {
        var stocks: [StockHoldingResult]
        var updated: Date
        var snapshots: [ETFShareSnapshot]?
    }
    private var cacheURL: URL? {
        (try? Database.defaultDirectory())?.appendingPathComponent("disclosed-holdings.json")
    }

    func load(items: [WatchItem]) async {
        if stocks.isEmpty && snapshots.isEmpty, let url = cacheURL, let data = try? Data(contentsOf: url),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            stocks = cache.stocks
            snapshots = cache.snapshots ?? []
            updated = cache.updated
        }
        let currentCodes = Set(items.filter { StockVolumeService.supports($0.symbol) }.map { $0.symbol.code })
        if Set(stocks.map(\.code)) != currentCodes || !snapshots.contains(where: { $0.observedDay == ETFTime.day(Date()) }) || (updated.map({ Date().timeIntervalSince($0) > 86400 }) ?? true) {
            await refresh(items: items)
        }
    }

    func refresh(items: [WatchItem]) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var seen = Set<String>()
        let symbols = items.filter { StockVolumeService.supports($0.symbol) && seen.insert($0.symbol.code).inserted }
        var results = Dictionary(uniqueKeysWithValues: stocks.map { ($0.code, $0) })
        do {
            let fresh = try await service.etfShares(day: ETFTime.day(Date()))
            let keys = Set(fresh.map(\.id))
            snapshots.removeAll { keys.contains($0.id) }
            snapshots.append(contentsOf: fresh)
            etfError = fresh.count < ETFDescriptor.basket.count
        } catch {
            etfError = true
        }
        var failed = 0
        for start in stride(from: 0, to: symbols.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = symbols[start..<min(start + 4, symbols.count)]
            let service = self.service
            let values = await withTaskGroup(of: (String, StockHoldingResult?).self) { group in
                for item in batch {
                    group.addTask {
                        var result = try? await service.stock(code: item.symbol.code, name: item.name)
                        result?.fetchedAt = Date()
                        return (item.symbol.code, result)
                    }
                }
                var collected: [(String, StockHoldingResult?)] = []
                for await value in group { collected.append(value) }
                return collected
            }
            for (code, value) in values {
                if let value { results[code] = value } else { failed += 1 }
            }
        }
        guard !Task.isCancelled else { return }
        stocks = symbols.compactMap { results[$0.symbol.code] }
        error = failed > 0 ? String(format: L("holdings.failed"), failed) : nil
        if failed < symbols.count || !snapshots.isEmpty {
            updated = Date()
        }
        if let updated, let url = cacheURL,
           let data = try? JSONEncoder().encode(Cache(stocks: stocks, updated: updated, snapshots: snapshots)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
