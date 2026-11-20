import Foundation

/// Keeps the comparison curves for the current trading day across launches, so a restart
/// does not refetch 20 history series that were already loaded successfully.
struct ETFBaselineCache: Sendable {
    let url: URL?

    init(url: URL? = (try? Database.defaultDirectory())?.appendingPathComponent("etf-baseline.json")) {
        self.url = url
    }

    /// Only a baseline built for `day` is usable; anything older is refetched.
    func load(day: String) -> ETFBaseline? {
        guard let url, let data = try? Data(contentsOf: url),
              let baseline = try? JSONDecoder().decode(ETFBaseline.self, from: data),
              baseline.liveDay == day else { return nil }
        return baseline
    }

    func save(_ baseline: ETFBaseline) {
        guard let url, let data = try? JSONEncoder().encode(baseline) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
