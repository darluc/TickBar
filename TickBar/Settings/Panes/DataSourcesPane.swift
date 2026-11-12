import SwiftUI

struct DataSourcesPane: View {
    @Environment(\.container) private var container

    var body: some View {
        if let prefs = container?.dataSourcePrefs {
            if let refresher = container?.refresher {
                DataSourcesPaneContent(prefs: prefs, refresher: refresher)
            }
        } else {
            Text(L("loading", comment: ""))
        }
    }
}

private struct DataSourcesPaneContent: View {
    @ObservedObject var prefs: DataSourcePreferences
    @ObservedObject var refresher: QuoteRefresher

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("settings.dataSources", comment: ""))
                    .font(.title3)
                    .padding(.bottom, 4)

                ForEach(Market.allCases, id: \.self) { market in
                    MarketProvidersSection(prefs: prefs, market: market)
                    if market == .us {
                        ExtendedProvidersSection(prefs: prefs, refresher: refresher)
                    }
                }

                Divider().padding(.vertical, 8)

                FinnhubKeySection(prefs: prefs)
            }
            .padding(20)
        }
    }
}

private struct MarketProvidersSection: View {
    @ObservedObject var prefs: DataSourcePreferences
    let market: Market

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(market.displayName)
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(currentOrder, id: \.self) { pid in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                        Toggle("", isOn: enabledBinding(pid))
                            .labelsHidden()
                        Text(pid.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(enabledFor(pid) ? .primary : .secondary)
                        if pid == .finnhub && market != .us {
                            Text(L("dataSource.usOnly", comment: ""))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Spacer()
                        Button { moveUp(pid) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isFirst(pid))
                        Button { moveDown(pid) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLast(pid))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    if pid != currentOrder.last { Divider().opacity(0.4) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var currentOrder: [ProviderID] {
        prefs.preferences[market]?.order ?? ProviderPreference.defaults[market]?.order ?? ProviderID.allCases
    }

    private func enabledFor(_ pid: ProviderID) -> Bool {
        prefs.preferences[market]?.enabled[pid] ?? false
    }

    private func enabledBinding(_ pid: ProviderID) -> Binding<Bool> {
        Binding(
            get: { enabledFor(pid) },
            set: { newValue in
                var pref = prefs.preferences[market] ?? ProviderPreference.defaults[market]!
                pref.enabled[pid] = newValue
                update(pref: pref)
            }
        )
    }

    private func isFirst(_ pid: ProviderID) -> Bool { currentOrder.first == pid }
    private func isLast(_ pid: ProviderID) -> Bool { currentOrder.last == pid }

    private func moveUp(_ pid: ProviderID) {
        var pref = prefs.preferences[market] ?? ProviderPreference.defaults[market]!
        guard let idx = pref.order.firstIndex(of: pid), idx > 0 else { return }
        pref.order.swapAt(idx, idx - 1)
        update(pref: pref)
    }

    private func moveDown(_ pid: ProviderID) {
        var pref = prefs.preferences[market] ?? ProviderPreference.defaults[market]!
        guard let idx = pref.order.firstIndex(of: pid), idx < pref.order.count - 1 else { return }
        pref.order.swapAt(idx, idx + 1)
        update(pref: pref)
    }

    private func update(pref: ProviderPreference) {
        var all = prefs.preferences
        all[market] = pref
        prefs.updatePreferences(all)
    }
}

private struct ExtendedProvidersSection: View {
    @ObservedObject var prefs: DataSourcePreferences
    @ObservedObject var refresher: QuoteRefresher

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("dataSource.extended.title", comment: "")).font(.headline)
            Text(L("dataSource.extended.help", comment: ""))
                .font(.system(size: 11)).foregroundColor(.secondary)
            VStack(spacing: 0) {
                ForEach(prefs.extendedPreference.order, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { prefs.extendedPreference.enabled[id] == true },
                                set: { enabled in
                                    var preference = prefs.extendedPreference
                                    preference.enabled[id] = enabled
                                    prefs.updateExtendedPreference(preference)
                                }
                            )).labelsHidden()
                            Text(id.displayName)
                            Text(L(id.supportsOvernight ? "dataSource.extended.nightCandidate" : "dataSource.extended.prePostOnly", comment: ""))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                            Spacer()
                            Button { move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(prefs.extendedPreference.order.first == id)
                            Button { move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(prefs.extendedPreference.order.last == id)
                        }
                        .buttonStyle(.borderless)
                        Text(reportLabel(id))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    if id != prefs.extendedPreference.order.last { Divider().opacity(0.4) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(L("dataSource.extended.check", comment: "")) { refresher.refreshNow() }
                    .disabled(refresher.isRefreshing)
                if refresher.isRefreshing { ProgressView().controlSize(.small) }
            }
        }
    }

    private func move(_ id: ExtendedProviderID, by offset: Int) {
        var preference = prefs.extendedPreference
        guard let index = preference.order.firstIndex(of: id),
              preference.order.indices.contains(index + offset) else { return }
        preference.order.swapAt(index, index + offset)
        prefs.updateExtendedPreference(preference)
    }

    private func reportLabel(_ id: ExtendedProviderID) -> String {
        guard prefs.extendedPreference.enabled[id] == true else { return L("dataSource.extended.disabled", comment: "") }
        if MarketClock().usExtendedSession() == .overnight && !id.supportsOvernight {
            return L("dataSource.extended.skippedNight", comment: "")
        }
        guard let report = refresher.extendedReports.first(where: { $0.providerID == id.rawValue }) else {
            return L("dataSource.extended.notRequested", comment: "")
        }
        let time = report.timestamp.formatted(date: .omitted, time: .standard)
        if let error = report.error { return "\(time) · \(L("dataSource.extended.failed", comment: "")): \(error)" }
        let accepted = Set(report.accepted)
        let missing = report.requested.filter { !accepted.contains($0) }.map(\.code).joined(separator: ", ")
        var summary = "\(time) · \(L("dataSource.extended.valid", comment: "")): \(report.accepted.count)/\(report.requested.count)"
        let trades = report.accepted.compactMap { symbol -> String? in
            guard let date = report.tradeTimes[symbol] else { return nil }
            return "\(symbol.code) \(date.formatted(date: .omitted, time: .standard))"
        }.joined(separator: ", ")
        if !trades.isEmpty {
            summary += " · \(L("dataSource.extended.tradeTime", comment: "")): \(trades)"
        }
        return missing.isEmpty ? summary : "\(summary) · \(L("dataSource.extended.missing", comment: "")): \(missing)"
    }
}

private struct FinnhubKeySection: View {
    @ObservedObject var prefs: DataSourcePreferences
    @State private var revealed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finnhub")
                .font(.headline)
            Text(L("dataSource.finnhub.help", comment: ""))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack {
                if revealed {
                    TextField(L("dataSource.finnhub.keyPlaceholder", comment: ""), text: $prefs.finnhubKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(L("dataSource.finnhub.keyPlaceholder", comment: ""), text: $prefs.finnhubKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: { revealed.toggle() }) {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                Link(L("dataSource.finnhub.signup", comment: ""), destination: URL(string: "https://finnhub.io/dashboard")!)
                    .font(.system(size: 11))
            }
        }
    }
}
