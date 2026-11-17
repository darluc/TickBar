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

                Text(L("holdings.stocks")).font(.system(size: 12, weight: .semibold))
                Text(L("holdings.scope")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.stocks.isEmpty && !model.loading {
                    Text(L("holdings.noStockData")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.stocks.filter { !$0.holdings.isEmpty }, id: \.code) { stock in
                    stockCard(stock)
                }
                ForEach(model.stocks.filter { $0.holdings.isEmpty }, id: \.code) { stock in
                    stockCard(stock)
                }

                Divider()
                Text(L("holdings.profitUnavailable"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .task { await model.load(items: vm.allItems) }
    }

    private func stockCard(_ stock: StockHoldingResult) -> some View {
        let groups = Dictionary(grouping: stock.holdings, by: \.holder)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(stock.name) · \(stock.code)").font(.system(size: 11, weight: .medium))
            Text("\(L("holdings.latest")) \(stock.latestPeriod.prefix(10))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let fetchedAt = stock.fetchedAt {
                Text(String(format: L("holdings.updated"), fetchedAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if groups.isEmpty {
                Text(L("holdings.none")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted(), id: \.self) { holder in
                let records = (groups[holder] ?? []).sorted { $0.period > $1.period }
                if let latest = records.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(holder).font(.system(size: 10, weight: .medium))
                        Text("\(latest.period.prefix(10)) · \(Self.shares(latest.shares)) · \(Self.percent(latest.percent))")
                            .foregroundStyle(.secondary)
                        if let previous = records.dropFirst().first(where: { $0.period != latest.period }),
                           let currentShares = latest.shares, let previousShares = previous.shares {
                            Text(String(format: L("holdings.changeSince"), String(previous.period.prefix(10)),
                                        (currentShares - previousShares) / 10000))
                        } else {
                            Text(L("holdings.changeUnavailable")).foregroundStyle(.secondary)
                        }
                        let history = Array(records.filter { ($0.shares ?? -1) >= 0 }.prefix(4).reversed())
                        if history.count >= 2 {
                            historyChart(history)
                        }
                    }.font(.system(size: 10)).monospacedDigit().padding(.vertical, 2)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private func historyChart(_ records: [DisclosedHolding]) -> some View {
        let maximum = max(records.compactMap(\.shares).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("holdings.historyChart")).foregroundStyle(.secondary)
            ForEach(records) { record in
                HStack(spacing: 6) {
                    Text(String(record.period.prefix(10))).frame(width: 65, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(SemanticColors.pulseBrandBlue)
                            .frame(width: geometry.size.width * CGFloat((record.shares ?? 0) / maximum), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }.frame(height: 16)
                    Text(Self.shares(record.shares)).frame(width: 80, alignment: .trailing)
                }
                .help("\(record.period.prefix(10)) · \(Self.shares(record.shares))")
            }
        }.padding(.top, 3)
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
