import SwiftUI

/// Disclosed holdings and fund share changes are separate datasets; neither identifies daily trades.
struct HoldingsPanel: View {
    @EnvironmentObject private var vm: PopoverViewModel
    @StateObject private var model = HoldingsMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("holdings.title")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button(L("holdings.refresh")) { Task { await model.refresh(items: vm.allItems) } }
                        .disabled(model.loading)
                }
                Text(L("holdings.disclaimer"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                }
                if let updated = model.updated {
                    Text(String(format: L("holdings.updated"), updated.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(L("holdings.etfs")).font(.system(size: 12, weight: .semibold))
                Text(L("holdings.etfHint")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.etfError {
                    Text(L("holdings.etfError")).font(.system(size: 10)).foregroundStyle(.orange)
                }
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
                Text(L("holdings.etfOwnersUnavailable"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
                Text(L("holdings.stocks")).font(.system(size: 12, weight: .semibold))
                Text(L("holdings.scope")).font(.system(size: 10)).foregroundStyle(.secondary)
                if model.stocks.isEmpty && !model.loading {
                    Text(L("holdings.empty")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.stocks, id: \.code) { stock in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(stock.name) · \(stock.code)").font(.system(size: 11, weight: .medium))
                        Text("\(L("holdings.latest")) \(stock.latestPeriod.prefix(10))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let fetchedAt = stock.fetchedAt {
                            Text(String(format: L("holdings.updated"), fetchedAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if stock.holdings.isEmpty {
                            Text(L("holdings.none")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(stock.holdings.enumerated()), id: \.offset) { _, record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.holder).lineLimit(2)
                                Text("\(record.period.prefix(10)) · \(Self.shares(record.shares)) · \(Self.percent(record.percent))")
                                    .foregroundStyle(.secondary)
                            }.font(.system(size: 10)).padding(.vertical, 2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(12)
        }
        .task { await model.load(items: vm.allItems) }
    }

    private static func shares(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: L("holdings.shares"), value / 10000)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: L("holdings.percent"), value)
    }
}
