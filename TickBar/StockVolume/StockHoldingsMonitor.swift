import Combine
import Foundation

/// Disclosed holdings for the single stock shown in the stock analysis window.
/// Disclosures change at most once a day, so results are cached per stock.
@MainActor
final class StockHoldingsMonitor: ObservableObject {
    static let cacheLifetime: TimeInterval = 86400

    @Published private(set) var result: StockHoldingResult?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    let code: String
    let name: String
    private let cacheURL: URL?
    private let fetch: (String, String) async throws -> StockHoldingResult
    private var loaded = false

    init(code: String, name: String,
         cacheURL: URL? = (try? Database.defaultDirectory())?.appendingPathComponent("disclosed-stock-holdings.json"),
         fetch: @escaping (String, String) async throws -> StockHoldingResult = { code, name in
             try await HoldingsService().stock(code: code, name: name)
         }) {
        self.code = code
        self.name = name
        self.cacheURL = cacheURL
        self.fetch = fetch
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        if result == nil { result = readStore()[code] }
        if let fetchedAt = result?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.cacheLifetime { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var value = try await fetch(code, name)
            value.fetchedAt = Date()
            result = value
            error = nil
            write(value)
        } catch let caught {
            error = (caught as? HTTPError)?.description ?? caught.localizedDescription
        }
    }

    private func readStore() -> [String: StockHoldingResult] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let values = try? JSONDecoder().decode([String: StockHoldingResult].self, from: data) else { return [:] }
        return values
    }

    private func write(_ value: StockHoldingResult) {
        guard let cacheURL else { return }
        var values = readStore()
        values[code] = value
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
