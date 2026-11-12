import SwiftUI

struct WatchlistTab: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences

    var onRequestAdd: () -> Void = {}

    /// 当前选中的指示器模式:百分比 / 涨跌额
    @State private var metricMode: MetricMode = .percent

    /// Option 键状态与 Cmd+1...9 快捷键监听
    @StateObject private var optionMonitor = OptionKeyMonitor()
    @State private var dropTargetID: UUID? = nil
    @State private var dropTargetGroupID: UUID? = nil

    /// Watchlist 改名与内联编辑焦点
    @FocusState private var isFieldFocused: Bool
    @State private var editingGroupID: UUID? = nil
    @State private var editingName: String = ""

    enum MetricMode {
        case percent
        case amount

        mutating func toggle() {
            self = (self == .percent) ? .amount : .percent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 组标签栏: 干净单一的 Watchlist 胶囊 + 右侧添加按钮
            watchlistGroupBar

            ScrollView {
                LazyVStack(spacing: 1) {
                    if vm.watchlist.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.watchlist) { item in
                            let isTarget = dropTargetID == item.id
                            CleanWatchRow(
                                item: item,
                                quote: refresher.quotes[item.symbol],
                                scheme: prefs.colorScheme,
                                metricMode: metricMode,
                                isReorderActive: optionMonitor.isOptionPressed,
                                isDropTarget: isTarget,
                                onToggleMetric: {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        metricMode.toggle()
                                    }
                                }
                            )
                            .contextMenu {
                                if StockVolumeService.supports(item.symbol) {
                                    Button(L("volume.title")) {
                                        StockVolumeWindowController.shared.show(
                                            symbol: item.symbol,
                                            name: refresher.quotes[item.symbol]?.name ?? item.name
                                        )
                                    }
                                }
                                Button(L("action.openInBrowser", comment: "在浏览器中查看")) {
                                    openInBrowser(item.symbol)
                                }
                                Divider()
                                Button(L("action.delete", comment: "删除"), role: .destructive) {
                                    vm.deleteWatchItem(item.id)
                                }
                            }
                            .onTapGesture(count: 2) {
                                openInBrowser(item.symbol)
                            }
                            .modifier(
                                WatchlistRowDragDropModifier(
                                    item: item,
                                    quote: refresher.quotes[item.symbol],
                                    scheme: prefs.colorScheme,
                                    isOptionPressed: optionMonitor.isOptionPressed,
                                    dropTargetID: $dropTargetID,
                                    onDropReorder: { sourceID, targetID in
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            vm.reorderWatchItem(from: sourceID, to: targetID)
                                        }
                                    }
                                )
                            )
                        }

                        if vm.watchlist.count > 1 {
                            Color.clear
                                .frame(height: 20)
                                .dropDestination(for: String.self) { droppedIDs, _ in
                                    dropTargetID = nil
                                    guard let first = droppedIDs.first,
                                          let sourceID = UUID(uuidString: first),
                                          let lastID = vm.watchlist.last?.id else { return false }
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        vm.reorderWatchItem(from: sourceID, to: lastID)
                                    }
                                    return true
                                } isTargeted: { targeted in
                                    if targeted {
                                        dropTargetID = vm.watchlist.last?.id
                                    } else if dropTargetID == vm.watchlist.last?.id {
                                        dropTargetID = nil
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .background(
                // 隐形快捷键触发按钮: 支持 Cmd+1 到 Cmd+9
                ZStack {
                    ForEach(1...9, id: \.self) { num in
                        Button("") {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                vm.selectGroup(at: num)
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(num)")), modifiers: .command)
                        .opacity(0)
                        .allowsHitTesting(false)
                    }
                }
            )
            .onAppear {
                optionMonitor.onNumberKeyDown = { num in
                    withAnimation(.easeInOut(duration: 0.16)) {
                        vm.selectGroup(at: num)
                    }
                }
                optionMonitor.start()
            }
            .onDisappear {
                optionMonitor.stop()
            }
            .onHover { _ in
                optionMonitor.updateState()
            }
        }
    }

    /// 顶部分组栏: 支持多个 Watchlist 切换、双击改名、以及加号新建
    private var watchlistGroupBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(vm.groups) { group in
                        groupPill(group)
                    }

                    // 旁边的新建 Watchlist 加号按钮
                    Button(action: createNewWatchlist) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(L("watchlist.createGroup", comment: "新建自选列表"))
                }
                .padding(.vertical, 1)
            }

            if optionMonitor.isOptionPressed {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(L("action.dragToReorder", comment: "拖动改顺序"))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(SemanticColors.pulseBrandBlue)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(SemanticColors.pulseBrandBlue.opacity(0.12))
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func groupPill(_ group: WatchlistGroup) -> some View {
        let isSelected = vm.selectedGroupID == group.id
        let isEditing = editingGroupID == group.id
        let isDropTarget = dropTargetGroupID == group.id

        if isEditing {
            TextField("", text: $editingName)
                .focused($isFieldFocused)
                .font(.system(size: 11.5, weight: .semibold))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(SemanticColors.pulseBrandBlue, lineWidth: 1.5)
                )
                .onSubmit {
                    commitRename(group.id)
                }
                .onExitCommand {
                    editingGroupID = nil
                }
        } else {
            Button(action: {
                vm.selectGroup(id: group.id)
            }) {
                HStack(spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isDropTarget ? SemanticColors.pulseBrandBlue : (isSelected ? .primary : .secondary))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isDropTarget
                                ? SemanticColors.pulseBrandBlue.opacity(0.18)
                                : (isSelected ? Color.primary.opacity(0.10) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isDropTarget ? SemanticColors.pulseBrandBlue : Color.clear,
                            lineWidth: 1.5
                        )
                )
                .contentShape(Rectangle())
                .modifier(WatchlistGroupDragModifier(group: group, isOptionPressed: optionMonitor.isOptionPressed))
            }
            .buttonStyle(.plain)
            // 与股票行使用相同的 String 拖放协议，不强制原生拖拽操作为 move。
            .dropDestination(for: String.self) { values, _ in
                dropTargetGroupID = nil
                guard let value = values.first, let payload = WatchlistDragPayload(value) else { return false }
                switch payload {
                case .group(let sourceID):
                    guard sourceID != group.id else { return false }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.reorderGroups(from: sourceID, to: group.id)
                    }
                case .item(let itemID):
                    guard !isSelected else { return false }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.moveWatchItem(itemID, toGroupID: group.id)
                    }
                }
                return true
            } isTargeted: { targeted in
                if targeted {
                    dropTargetGroupID = group.id
                } else if dropTargetGroupID == group.id {
                    dropTargetGroupID = nil
                }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    startEditing(group)
                }
            )
            .contextMenu {
                Button(L("action.rename", comment: "重命名")) {
                    startEditing(group)
                }
                if vm.groups.count > 1 {
                    Divider()
                    Button(L("action.deleteWatchlist", comment: "删除自选列表"), role: .destructive) {
                        vm.deleteGroup(id: group.id)
                    }
                }
            }
        }
    }

    private func startEditing(_ group: WatchlistGroup) {
        editingGroupID = group.id
        editingName = group.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFieldFocused = true
        }
    }

    private func commitRename(_ id: UUID) {
        guard editingGroupID == id else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            vm.renameGroup(id: id, newName: trimmed)
        }
        editingGroupID = nil
    }

    private func createNewWatchlist() {
        let newGroup = vm.createGroup()
        startEditing(newGroup)
    }

    private func openInBrowser(_ symbol: SymbolID) {
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if let url = BrowserURLBuilder.url(template: template, symbol: symbol) {
            NSWorkspace.shared.open(url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PulseWaveform()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                .frame(width: 32, height: 18)
                .padding(.top, 24)
            Text(L("watchlist.empty", comment: "暂无自选标的"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(L("watchlist.quickAdd", comment: "添加标的")) {
                onRequestAdd()
            }
            .controlSize(.small)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

/// 双行报价:常规盘大字着色 + 盘前/盘后小字,对齐常见行情软件。
private struct CleanWatchRow: View {
    let item: WatchItem
    let quote: Quote?
    let scheme: TickerColorScheme
    let metricMode: WatchlistTab.MetricMode
    let isReorderActive: Bool
    let isDropTarget: Bool
    let onToggleMetric: () -> Void

    @State private var isHovered = false

    private var code: String {
        item.symbol.market == .us ? item.symbol.code.uppercased() : item.symbol.code
    }

    var body: some View {
        HStack(spacing: 8) {
            if isReorderActive {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.65))
                    .frame(width: 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    MarketBadge(market: item.symbol.market)
                    Text(item.name.isEmpty ? code : item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Text(code)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.leading, 2)
            }
            .frame(width: 108, alignment: .leading)

            SparklineView(quote: quote, scheme: scheme, height: 28)
                .frame(maxWidth: .infinity)

            Button(action: onToggleMetric) {
                if let q = quote {
                    quotesColumn(q)
                } else {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("--")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("--")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.55))
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L("positions.hint.clickMetric", comment: "点击切换显示指标"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isDropTarget
                        ? SemanticColors.pulseBrandBlue.opacity(0.14)
                        : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isDropTarget ? SemanticColors.pulseBrandBlue : Color.clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private func quotesColumn(_ q: Quote) -> some View {
        let regularUp = q.change >= 0
        let regularColor = regularUp ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
        let showExtended = q.isExtended

        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text(formatPrice(q.price))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(regularColor)
                    .lineLimit(1)
                changePill(
                    text: metricText(pct: q.changePct, amount: q.change),
                    color: regularColor
                )
            }

            if showExtended {
                let extUp = q.effectiveChange >= 0
                let extColor = extUp ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
                HStack(spacing: 5) {
                    Text(formatPrice(q.effectivePrice))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(extColor)
                    Text(metricText(pct: q.effectiveChangePct, amount: q.effectiveChange))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(extColor)
                    if let session = q.extendedSession {
                        Text(session.shortLabel)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.8)
                            )
                    }
                }
                .lineLimit(1)
            } else if q.symbol.market == .us, MarketClock().usExtendedSession() != nil {
                Text(L("quote.extended.unavailable", comment: ""))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .help(L("quote.extended.unavailable.help", comment: ""))
            }
        }
        .frame(minWidth: 118, alignment: .trailing)
    }

    private func changePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
            )
    }

    private func formatPrice(_ value: Decimal) -> String {
        item.symbol.market.defaultCurrency.format(value)
    }

    private func metricText(pct: Double, amount: Decimal) -> String {
        switch metricMode {
        case .percent:
            return String(format: "%+.2f%%", pct * 100)
        case .amount:
            let sign = amount >= 0 ? "+" : ""
            return sign + formatPrice(amount)
        }
    }
}

/// 股票保留原有 UUID 文本；分组加前缀，股票行不会把它误当成股票 ID。
enum WatchlistDragPayload: Equatable {
    case group(UUID)
    case item(UUID)

    private static let groupPrefix = "watchlist-group:"

    init?(_ value: String) {
        if value.hasPrefix(Self.groupPrefix) {
            guard let id = UUID(uuidString: String(value.dropFirst(Self.groupPrefix.count))) else { return nil }
            self = .group(id)
        } else {
            guard let id = UUID(uuidString: value) else { return nil }
            self = .item(id)
        }
    }

    var string: String {
        switch self {
        case .group(let id): return Self.groupPrefix + id.uuidString
        case .item(let id): return id.uuidString
        }
    }
}

private struct WatchlistGroupDragModifier: ViewModifier {
    let group: WatchlistGroup
    let isOptionPressed: Bool

    func body(content: Content) -> some View {
        if isOptionPressed {
            content.onDrag {
                NSItemProvider(object: WatchlistDragPayload.group(group.id).string as NSString)
            } preview: {
                Text(group.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            content
        }
    }
}

/// 拖拽预览悬浮卡片
private struct WatchlistDragPreview: View {
    let item: WatchItem
    let quote: Quote?
    let scheme: TickerColorScheme

    private var code: String {
        item.symbol.market == .us ? item.symbol.code.uppercased() : item.symbol.code
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            MarketBadge(market: item.symbol.market)
            Text(item.name.isEmpty ? code : item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            if let q = quote {
                Text(item.symbol.market.defaultCurrency.format(q.price))
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(q.change >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SemanticColors.pulseBrandBlue.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
    }
}

/// 封装行维度的按需拖拽与放置修饰器
private struct WatchlistRowDragDropModifier: ViewModifier {
    let item: WatchItem
    let quote: Quote?
    let scheme: TickerColorScheme
    let isOptionPressed: Bool
    @Binding var dropTargetID: UUID?
    let onDropReorder: (UUID, UUID) -> Void

    func body(content: Content) -> some View {
        if isOptionPressed {
            content
                .draggable(item.id.uuidString) {
                    WatchlistDragPreview(item: item, quote: quote, scheme: scheme)
                }
                .dropDestination(for: String.self) { droppedIDs, _ in
                    dropTargetID = nil
                    guard let first = droppedIDs.first,
                          let sourceID = UUID(uuidString: first) else { return false }
                    onDropReorder(sourceID, item.id)
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        dropTargetID = item.id
                    } else if dropTargetID == item.id {
                        dropTargetID = nil
                    }
                }
        } else {
            content
                .dropDestination(for: String.self) { droppedIDs, _ in
                    dropTargetID = nil
                    guard let first = droppedIDs.first,
                          let sourceID = UUID(uuidString: first) else { return false }
                    onDropReorder(sourceID, item.id)
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        dropTargetID = item.id
                    } else if dropTargetID == item.id {
                        dropTargetID = nil
                    }
                }
        }
    }
}

/// 全局 / 局部监听 Option 键状态与 Cmd+1...9 数字快捷键
final class OptionKeyMonitor: ObservableObject {
    @Published var isOptionPressed: Bool = false

    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localKeyDownMonitor: Any?

    var onNumberKeyDown: ((Int) -> Void)?

    init() {
        start()
    }

    deinit {
        stop()
    }

    func start() {
        updateState()
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlags(event.modifierFlags)
                return event
            }
        }
        if globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlags(event.modifierFlags)
            }
        }
        if localKeyDownMonitor == nil {
            localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 检查是否按下 Cmd+1 到 Cmd+9
                if event.modifierFlags.contains(.command),
                   let chars = event.charactersIgnoringModifiers,
                   let first = chars.first,
                   let num = Int(String(first)),
                   (1...9).contains(num) {
                    self?.onNumberKeyDown?(num)
                    return nil // 消费该事件
                }
                return event
            }
        }
    }

    func stop() {
        if let m = localFlagsMonitor {
            NSEvent.removeMonitor(m)
            localFlagsMonitor = nil
        }
        if let m = globalFlagsMonitor {
            NSEvent.removeMonitor(m)
            globalFlagsMonitor = nil
        }
        if let m = localKeyDownMonitor {
            NSEvent.removeMonitor(m)
            localKeyDownMonitor = nil
        }
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let isOption = flags.contains(.option)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isOptionPressed != isOption {
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.isOptionPressed = isOption
                }
            }
        }
    }

    func updateState() {
        let isOption = NSEvent.modifierFlags.contains(.option)
        if Thread.isMainThread {
            if isOptionPressed != isOption {
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.isOptionPressed = isOption
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isOptionPressed != isOption {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.isOptionPressed = isOption
                    }
                }
            }
        }
    }
}
