import SwiftUI

struct PopoverRoot: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var etfMonitor: ETFMonitor
    @Environment(\.container) private var container

    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil

    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if etfMonitor.selectedPage {
                ETFPanel(board: etfMonitor.board).equatable()
            } else {
                if isSearching {
                    PopoverSearch(onClose: closeSearch)
                }
                WatchlistTab(onRequestAdd: openSearch)
            }
            Divider().opacity(0.35)
            footer
        }
    }

    /// 极简清爽的 Header
    private var header: some View {
        HStack(spacing: 8) {
            PopoverPagePicker(selectedPage: etfMonitor.selectedPage) {
                etfMonitor.selectedPage = $0
            }
            .equatable()
            .onChange(of: etfMonitor.selectedPage) { _ in closeSearch() }
            Spacer()

            // 右侧工具按钮: Pin / 刷新 / 搜索 / 设置
            HStack(spacing: 4) {
                if let onTogglePin = onTogglePin {
                    toolButton(
                        systemName: isPinned ? "pin.fill" : "pin",
                        active: isPinned,
                        help: isPinned ? L("action.unpinWindow", comment: "取消钉住") : L("action.pinWindow", comment: "钉为独立窗口")
                    ) {
                        onTogglePin()
                    }
                }

                toolButton(
                    systemName: "arrow.clockwise",
                    active: false,
                    help: L("menu.refresh", comment: "立即刷新"),
                    disabled: etfMonitor.selectedPage ? etfMonitor.status.refreshing : refresher.isRefreshing
                ) {
                    if etfMonitor.selectedPage { Task { await etfMonitor.refresh() } }
                    else { refresher.refreshNow() }
                }

                if !etfMonitor.selectedPage {
                    toolButton(
                        systemName: "magnifyingglass",
                        active: isSearching,
                        help: L("action.search", comment: "搜索标的")
                    ) {
                        if isSearching {
                            closeSearch()
                        } else {
                            openSearch()
                        }
                    }
                }

                toolButton(systemName: "gearshape", active: false, help: L("menu.settings", comment: "设置")) {
                    openSettings()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    private func toolButton(
        systemName: String,
        active: Bool,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? SemanticColors.pulseBrandBlue : .secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    /// 极简纯净的 Footer
    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(footerStatusColor)
                .frame(width: 5, height: 5)

            Text(footerStatus)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(footerStatus)

            Spacer()

            if etfMonitor.selectedPage ? etfMonitor.status.refreshing : refresher.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else if let updated = etfMonitor.selectedPage ? etfMonitor.status.updated : refresher.lastUpdated {
                Text(timeString(from: updated))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var footerStatusColor: Color {
        if etfMonitor.selectedPage {
            return etfMonitor.status.warning ? .orange : .secondary
        }
        if refresher.isOffline { return .secondary }
        if refresher.lastError != nil { return .orange }
        return Color(red: 0.04, green: 0.66, blue: 0.35)
    }

    private var footerStatus: String {
        if etfMonitor.selectedPage { return etfMonitor.status.text }
        if refresher.isOffline {
            return L("footer.offline", comment: "离线")
        }
        if refresher.lastError != nil {
            return L("footer.quoteFailed", comment: "部分行情延迟")
        }
        return "Streaming live"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func openSearch() {
        withAnimation(.easeInOut(duration: 0.14)) {
            isSearching = true
        }
    }

    private func closeSearch() {
        withAnimation(.easeInOut(duration: 0.14)) {
            isSearching = false
        }
    }
}

/// 行情刷新不应反复更新原生分段控件；只在页面选择改变时重绘。
private struct PopoverPagePicker: View, Equatable {
    let selectedPage: Bool
    let onSelect: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedPage == rhs.selectedPage
    }

    var body: some View {
        Picker("面板", selection: Binding(get: { selectedPage }, set: onSelect)) {
            Text(L("tab.watchlist", comment: "自选")).tag(false)
            Text(L("tab.etf", comment: "ETF 资金")).tag(true)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        // 140pt 小于英文标签的原生理想宽度，会触发压缩与重新布局。
        .fixedSize()
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
