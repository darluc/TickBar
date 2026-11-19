import Combine
import Foundation

@MainActor
final class HoldingsMonitor: ObservableObject {
    @Published private(set) var snapshots: [ETFShareSnapshot] = []
    @Published private(set) var etfError = false
    @Published private(set) var loading = false
    @Published private(set) var updated: Date?
    private let service = HoldingsService()

    private struct Cache: Codable {
        var snapshots: [ETFShareSnapshot]?
        var updated: Date
    }
    private var cacheURL: URL? {
        (try? Database.defaultDirectory())?.appendingPathComponent("disclosed-holdings.json")
    }

    func load() async {
        if snapshots.isEmpty, let url = cacheURL, let data = try? Data(contentsOf: url),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            snapshots = cache.snapshots ?? []
            updated = cache.updated
        }
        if !snapshots.contains(where: { $0.observedDay == ETFTime.day(Date()) }) || (updated.map({ Date().timeIntervalSince($0) > 86400 }) ?? true) {
            await refresh()
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await service.etfShares(day: ETFTime.day(Date()))
            let keys = Set(fresh.map(\.id))
            snapshots.removeAll { keys.contains($0.id) }
            snapshots.append(contentsOf: fresh)
            etfError = fresh.count < ETFDescriptor.basket.count
            updated = Date()
            if let updated, let url = cacheURL,
               let data = try? JSONEncoder().encode(Cache(snapshots: snapshots, updated: updated)) {
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            etfError = true
        }
    }
}
