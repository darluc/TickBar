import Foundation
import Combine

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var groups: [WatchlistGroup] = []
    @Published var selectedGroupID: UUID = WatchlistGroup.defaultID
    @Published var watchlist: [WatchItem] = []
    @Published var allItems: [WatchItem] = []

    let refresher: QuoteRefresher
    let watchlistRepo: WatchlistRepository
    let settingsRepo: SettingsRepository

    private var groupsObservationTask: Task<Void, Never>?
    private var itemsObservationTask: Task<Void, Never>?

    init(
        refresher: QuoteRefresher,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository
    ) {
        self.refresher = refresher
        self.watchlistRepo = watchlistRepo
        self.settingsRepo = settingsRepo
        reload()
        startObserving()
    }

    func reload() {
        let loadedGroups = (try? watchlistRepo.allGroups()) ?? []
        self.groups = loadedGroups

        if !loadedGroups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = loadedGroups.first?.id ?? WatchlistGroup.defaultID
        }

        let loadedItems = (try? watchlistRepo.all()) ?? []
        self.allItems = loadedItems
        self.watchlist = loadedItems.filter { $0.watchlistId == selectedGroupID }
    }

    private func startObserving() {
        groupsObservationTask = Task { [weak self] in
            guard let stream = self?.watchlistRepo.observeGroups() else { return }
            for await newGroups in stream {
                await MainActor.run {
                    self?.groups = newGroups
                    if let sel = self?.selectedGroupID, !newGroups.contains(where: { $0.id == sel }) {
                        self?.selectedGroupID = newGroups.first?.id ?? WatchlistGroup.defaultID
                    }
                    self?.updateFilteredWatchlist()
                }
            }
        }

        itemsObservationTask = Task { [weak self] in
            guard let stream = self?.watchlistRepo.observeAll() else { return }
            for await items in stream {
                await MainActor.run {
                    self?.allItems = items
                    self?.updateFilteredWatchlist()
                }
            }
        }
    }

    private func updateFilteredWatchlist() {
        watchlist = allItems.filter { $0.watchlistId == selectedGroupID }
    }

    func selectGroup(id: UUID) {
        guard selectedGroupID != id else { return }
        selectedGroupID = id
        updateFilteredWatchlist()
    }

    /// 根据 1-based index 切换（用于 Cmd+1 ... Cmd+9 快捷键）
    func selectGroup(at index: Int) {
        guard index >= 1 && index <= groups.count else { return }
        selectGroup(id: groups[index - 1].id)
    }

    @discardableResult
    func createGroup(name: String? = nil) -> WatchlistGroup {
        let finalName: String
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            finalName = name
        } else {
            var index = groups.count + 1
            var candidate = "\(WatchlistGroup.defaultName) \(index)"
            while groups.contains(where: { $0.name == candidate }) {
                index += 1
                candidate = "\(WatchlistGroup.defaultName) \(index)"
            }
            finalName = candidate
        }

        let order = (groups.map(\.order).max() ?? -1) + 1
        let newGroup = WatchlistGroup(name: finalName, order: order)
        try? watchlistRepo.upsertGroup(newGroup)
        selectedGroupID = newGroup.id
        reload()
        return newGroup
    }

    func renameGroup(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let group = groups.first(where: { $0.id == id }), group.name != trimmed else { return }

        var updated = group
        updated.name = trimmed
        try? watchlistRepo.upsertGroup(updated)
        reload()
    }

    func deleteGroup(id: UUID) {
        try? watchlistRepo.deleteGroup(id: id)
        reload()
        refresher.refreshNow()
    }

    /// 只调整分组顺序，保留当前选择与各组股票，不触发行情刷新。
    func reorderGroups(from sourceID: UUID, to targetID: UUID) {
        guard let sourceIndex = groups.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = groups.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }
        var reordered = groups
        let group = reordered.remove(at: sourceIndex)
        reordered.insert(group, at: targetIndex)
        do {
            try watchlistRepo.reorderGroups(ids: reordered.map(\.id))
            reload()
        } catch {
            Log.db.error("watchlist group reorder failed: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    func addFromSearch(_ result: SymbolSearchResult) -> Bool {
        if watchlist.contains(where: { $0.symbol == result.symbol }) {
            return false
        }
        let order = (watchlist.map(\.order).max() ?? -1) + 1
        let item = WatchItem(
            symbol: result.symbol,
            name: result.name.isEmpty ? result.symbol.code : result.name,
            order: order,
            inTicker: true,
            watchlistId: selectedGroupID
        )
        do {
            try watchlistRepo.upsert(item)
            reload()
            refresher.refreshNow()
            return true
        } catch {
            return false
        }
    }

    func isOnWatchlist(_ symbol: SymbolID) -> Bool {
        watchlist.contains(where: { $0.symbol == symbol })
    }

    func deleteWatchItem(_ id: UUID) {
        try? watchlistRepo.delete(id: id)
        reload()
        refresher.refreshNow()
    }

    /// 用户按住 Option 键拖动重排自选标的顺序
    func reorderWatchItem(from sourceID: UUID, to targetID: UUID) {
        guard let sourceIndex = watchlist.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = watchlist.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }

        var items = watchlist
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: targetIndex)
        watchlist = items

        let ids = items.map(\.id)
        try? watchlistRepo.reorder(ids: ids)
        refresher.refreshNow()
    }

    /// 用户按住 Option 键拖动个股到另一个 Watchlist 分组
    func moveWatchItem(_ itemID: UUID, toGroupID targetGroupID: UUID) {
        guard let item = allItems.first(where: { $0.id == itemID }),
              item.watchlistId != targetGroupID,
              groups.contains(where: { $0.id == targetGroupID }) else { return }

        // 获取目标分组中当前最大 order
        let targetGroupItems = allItems.filter { $0.watchlistId == targetGroupID }
        let newOrder = (targetGroupItems.map(\.order).max() ?? -1) + 1

        var updated = item
        updated.watchlistId = targetGroupID
        updated.order = newOrder

        try? watchlistRepo.upsert(updated)
        reload()
        refresher.refreshNow()
    }

    deinit {
        groupsObservationTask?.cancel()
        itemsObservationTask?.cancel()
    }
}
