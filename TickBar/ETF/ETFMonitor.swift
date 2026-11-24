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
    private let interval: TimeInterval
    private var surfaces = Set<ETFSurface>()
    private var loop: Task<Void, Never>?
    private var baselineTask: Task<Void, Never>?
    private var baselineDay = ""
    private var baselineFailureDay = ""
    private var refreshing = false
    private var lastSuccess: Date?
    private var problems: [String] = []
    private var fallbackStatus = ""
    /// Grows while the provider keeps rate limiting, so the panel stops retrying every minute.
    private var backoff: TimeInterval = 0
    private var lastMCPRefreshAttempt: Date?

    init(worker: ETFRefreshing = ETFWorker(), clock: MarketClock = MarketClock(),
         interval: TimeInterval = 60, marketStatus: (() -> MarketStatus)? = nil) {
        self.worker = worker
        self.marketStatus = marketStatus ?? { clock.status(.a) }
        self.interval = interval
    }

    var isPolling: Bool { loop != nil }

    /// Delay before the next automatic refresh; tests use it to verify backoff.
    var pollDelay: TimeInterval { max(interval, backoff) }

    /// Called by the popover and pinned-window controllers, mirroring `QuoteRefresher.setPopoverOpen`.
    func setVisible(_ surface: ETFSurface, _ visible: Bool) {
        if visible { surfaces.insert(surface) } else { surfaces.remove(surface) }
        if visible { publishStatus() }
        reconcile()
    }

    func togglePause() {
        paused.toggle()
        if paused {
            baselineTask?.cancel()
            baselineTask = nil
            baselineDay = ""
        }
        publishStatus()
        if !paused, loop != nil { Task { await refresh(automatic: true) } }
    }

    /// Polling exists only while the ETF page is on screen; hiding it cancels in-flight requests.
    private func reconcile() {
        if selectedPage && !surfaces.isEmpty {
            guard loop == nil else { return }
            backoff = 0
            loop = Task { await self.run() }
        } else {
            loop?.cancel()
            loop = nil
            baselineTask?.cancel()
            baselineTask = nil
            baselineDay = ""
        }
    }

    private func run() async {
        // A refresh cancelled by the previous hide may still be unwinding.
        while refreshing && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        if !paused, lastSuccess.map({ Date().timeIntervalSince($0) > 20 }) ?? true {
            await refresh(automatic: true)
        }
        if !paused { resumeBaselineIfNeeded() }
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: UInt64(pollDelay * 1_000_000_000)) } catch { return }
            if !paused && marketStatus() == .open { await refresh(automatic: true) }
            else {
                if !paused { resumeBaselineIfNeeded() }
                publishStatus()
            }
        }
    }

    func refresh() async { await refresh(automatic: false) }

    private func refresh(automatic: Bool) async {
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
        // Repeated throttling or transport failures lengthen polling up to 10 minutes;
        // one healthy round (including a manual refresh) restores the normal interval.
        backoff = outcome.rateLimited ? min(max(backoff * 2, 60), 600) : 0
        let current = board.display
        let next = outcome.display
        // Keep the last complete session visible while a new day's basket is incomplete.
        let incompleteRollover = !current.isEmpty && next.day > current.day &&
            (next.quoteCount < ETFDescriptor.basket.count || next.minuteCount < ETFDescriptor.basket.count)
        if !incompleteRollover && next != current { board.display = next }
        if outcome.reachedServer { lastSuccess = Date() }
        problems = outcome.problems
        if incompleteRollover { problems.append(L("etf.error.rollover", comment: "新交易日数据不完整，保留上一交易日")) }
        if board.display.previous != nil { baselineFailureDay = "" }
        if !baselineFailureDay.isEmpty, baselineFailureDay == board.display.day, board.display.previous == nil {
            problems.append(L("etf.error.baseline", comment: "对比曲线暂不可用"))
        }
        fallbackStatus = outcome.fallbackQuotes || outcome.fallbackMinutes > 0
            ? String(format: L("etf.status.fallback"), outcome.fallbackMinutes) : ""
        publishStatus()
        if !incompleteRollover, outcome.baselineMissing, !next.day.isEmpty,
           !automatic || (!paused && selectedPage && !surfaces.isEmpty) {
            startBaseline(for: next.day)
        }
    }

    private func resumeBaselineIfNeeded() {
        let display = board.display
        guard !display.isEmpty, display.previous == nil else { return }
        startBaseline(for: display.day)
    }

    private func startBaseline(for day: String) {
        if baselineTask != nil && baselineDay == day { return }
        baselineTask?.cancel()
        baselineDay = day
        baselineTask = Task { [weak self, worker] in
            let result = await worker.prepareBaseline(for: day)
            guard let self, !Task.isCancelled, self.baselineDay == day else { return }
            self.baselineTask = nil
            self.baselineDay = ""
            guard self.board.display.day == day else { return }
            if let result {
                var display = self.board.display
                display.applyBaseline(result)
                if display != self.board.display { self.board.display = display }
                self.baselineFailureDay = ""
                self.problems.removeAll { $0 == L("etf.error.baseline", comment: "对比曲线暂不可用") }
            } else {
                // Only report missing curves once an attempt has actually failed; before
                // that the baseline is still loading, not unavailable.
                self.baselineFailureDay = day
                let message = L("etf.error.baseline", comment: "对比曲线暂不可用")
                if !self.problems.contains(message) { self.problems.append(message) }
            }
            self.publishStatus()
        }
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
        if !fallbackStatus.isEmpty { next.text += " · " + fallbackStatus }
        if next != status { status = next }
    }

    // MARK: - MCP

    var mcpPanelVisible: Bool { selectedPage && !surfaces.isEmpty }

    var mcpLastSuccessfulRefresh: Date? { lastSuccess }

    func mcpMarketStatus() -> String {
        switch marketStatus() {
        case .open: return "open"
        case .lunchBreak: return "lunchBreak"
        case .closed: return "closed"
        }
    }

    /// Refresh on demand for MCP when the panel is hidden but a client needs a first snapshot.
    func prepareForMCPSnapshot() async {
        if paused || refreshing { return }
        if mcpPanelVisible { return }
        let needsData = board.display.isEmpty
        let stale = lastSuccess.map { Date().timeIntervalSince($0) > pollDelay } ?? true
        let duringSession = marketStatus() == .open
        guard needsData || (duringSession && stale) else { return }
        guard canAttemptMCPRefresh() else { return }
        lastMCPRefreshAttempt = Date()
        await refresh()
    }

    private func canAttemptMCPRefresh() -> Bool {
        guard let last = lastMCPRefreshAttempt else { return true }
        return Date().timeIntervalSince(last) >= pollDelay
    }
}

extension ETFOutcome {
    /// False only when every request failed, e.g. offline: the old data is simply kept.
    var reachedServer: Bool { !quotesFailed || failedMinutes < ETFDescriptor.basket.count }

    var problems: [String] {
        var list: [String] = []
        if quotesFailed { list.append(L("etf.error.quotes", comment: "行情获取失败，保留已有数据")) }
        if failedMinutes > 0 { list.append(String(format: L("etf.error.minutes", comment: "%d 只分时获取失败"), failedMinutes)) }
        if failedVolumeDetails > 0 {
            list.append(String(format: L("etf.error.volumeDetails"), failedVolumeDetails))
        }
        return list
    }
}
