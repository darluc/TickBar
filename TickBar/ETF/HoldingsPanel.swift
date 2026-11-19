import SwiftUI

/// ETF share snapshots. Per-stock disclosed holdings live in the stock analysis window.
struct HoldingsPanel: View {
    @StateObject private var model = HoldingsMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("holdings.title")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button(L("holdings.refresh")) { Task { await model.refresh() } }
                        .disabled(model.loading)
                }
                Text(L("holdings.disclaimer"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let updated = model.updated {
                    Text(String(format: L("holdings.updated"), updated.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

                Divider()
                Text(L("holdings.etfOwnersUnavailable"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if model.etfError {
                    Text(L("holdings.etfError")).font(.system(size: 10)).foregroundStyle(.orange)
                }
                DisclosureGroup(L("holdings.etfs")) {
                    Text(L("holdings.etfHint")).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(ETFDescriptor.basket) { etf in
                    let values = model.snapshots.filter { $0.code == etf.code }.sorted { $0.observedDay > $1.observedDay }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(etf.name).lineLimit(1)
                            Text(etf.code).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let latest = values.first {
                                Text(String(format: L("holdings.etfShares"), latest.shares / 1e8))
                                Text(latest.observedDay).foregroundStyle(.secondary)
                                if values.count > 1 {
                                    Text(String(format: L("holdings.etfDifference"), values[1].observedDay,
                                                (latest.shares - values[1].shares) / 1e8)).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                    }.font(.system(size: 10)).monospacedDigit().padding(.vertical, 3)
                    }
                }.font(.system(size: 11, weight: .medium))
            }
            .padding(12)
        }
        .task { await model.load() }
    }
}
