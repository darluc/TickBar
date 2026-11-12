import Combine
import Foundation

/// Where the ETF panel can be on screen. Polling runs only while one of them shows it.
enum ETFSurface: Hashable {
    case popover, pinned
}

/// Footer/header state. Kept apart from the chart data so a status flip never redraws charts.
struct ETFStatus: Equatable {
    var text = ""
    var warning = false
    var updated: Date?
    var refreshing = false
}

/// Holds the prepared display data. Only a refresh that changed something publishes here.
@MainActor
final class ETFBoard: ObservableObject {
    @Published fileprivate(set) var display = ETFDisplay()
}

@MainActor
final class ETFMonitor: ObservableObject {
    @Published var selectedPage = UserDefaults.standard.bool(forKey: "etfPanelSelected") {
        didSet {
            UserDefaults.standard.set(selectedPage, forKey: "etfPanelSelected")
            reconcile()
        }
    }
    @Published private(set) var paused = false
    @Published private(set) var status = ETFStatus()
    let board = ETFBoard()

    private let worker: ETFRefreshing
    private let marketStatus: () -> MarketStatus
    private let interval: UInt64
    private var surfaces = Set<ETFSurface>()
    private var loop: Task<Void, Never>?
    private var refreshing = false
    private var lastSuccess: Date?
    private var problems: [String] = []

    init(worker: ETFRefreshing = ETFWorker(), clock: MarketClock = MarketClock(),
         interval: TimeInterval = 60, marketStatus: (() -> MarketStatus)? = nil) {
        self.worker = worker
        self.marketStatus = marketStatus ?? { clock.status(.a) }
        self.interval = UInt64(interval * 1_000_000_000)
    }

    var isPolling: Bool { loop != nil }

    /// Called by the popover and pinned-window controllers, mirroring `QuoteRefresher.setPopoverOpen`.
    func setVisible(_ surface: ETFSurface, _ visible: Bool) {
        if visible { surfaces.insert(surface) } else { surfaces.remove(surface) }
        if visible { publishStatus() }
        reconcile()
    }

    func togglePause() {
        paused.toggle()
        publishStatus()
        if !paused, loop != nil { Task { await refresh() } }
    }

    /// Polling exists only while the ETF page is on screen; hiding it cancels in-flight requests.
    private func reconcile() {
        if selectedPage && !surfaces.isEmpty {
            guard loop == nil else { return }
            loop = Task { await self.run() }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    private func run() async {
        // A refresh cancelled by the previous hide may still be unwinding.
        while refreshing && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        if !paused, lastSuccess.map({ Date().timeIntervalSince($0) > 20 }) ?? true { await refresh() }
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: interval) } catch { return }
            if !paused && marketStatus() == .open { await refresh() } else { publishStatus() }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        publishStatus()
        let outcome = await worker.refresh()
        refreshing = false
        // A cancelled run (panel closed mid-request) holds partial results; drop them.
        guard !Task.isCancelled else {
            publishStatus()
            return
        }
        if outcome.display != board.display { board.display = outcome.display }
        if outcome.reachedServer { lastSuccess = Date() }
        problems = outcome.problems
        publishStatus()
    }

    private func publishStatus() {
        var next = ETFStatus(updated: lastSuccess, refreshing: refreshing)
        let display = board.display
        if paused {
            next.text = L("etf.status.paused", comment: "已暂停自动刷新")
        } else if refreshing {
            next.text = L("etf.status.loading", comment: "更新中…")
        } else if !problems.isEmpty {
            next.text = problems.joined(separator: "；")
            next.warning = true
        } else if display.isEmpty {
            next.text = L("etf.status.waiting", comment: "等待加载")
        } else if display.day != ETFTime.day(Date()) {
            next.text = String(format: L("etf.status.lastSession", comment: "最近交易日 %@"), display.day)
        } else {
            switch marketStatus() {
            case .open: next.text = L("etf.status.live", comment: "实时 · 每分钟更新")
            case .lunchBreak: next.text = L("etf.status.lunch", comment: "午间休市")
            case .closed: next.text = L("etf.status.closed", comment: "已收盘")
            }
        }
        if next != status { status = next }
    }
}

extension ETFOutcome {
    /// False only when every request failed, e.g. offline: the old data is simply kept.
    var reachedServer: Bool { !quotesFailed || failedMinutes < ETFDescriptor.basket.count }

    var problems: [String] {
        var list: [String] = []
        if quotesFailed { list.append(L("etf.error.quotes", comment: "行情获取失败，保留已有数据")) }
        if failedMinutes > 0 { list.append(String(format: L("etf.error.minutes", comment: "%d 只分时获取失败"), failedMinutes)) }
        if baselineMissing && !display.isEmpty { list.append(L("etf.error.baseline", comment: "对比曲线暂不可用")) }
        return list
    }
}
