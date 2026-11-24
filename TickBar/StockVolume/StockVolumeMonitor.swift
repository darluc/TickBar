import AppKit
import Combine
import SwiftUI

@MainActor
final class StockVolumeMonitor: ObservableObject {
    let symbol: SymbolID
    let name: String
    @Published private(set) var display: StockVolumeDisplay?
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    @Published private(set) var paused = false

    private let worker: StockVolumeFetching
    private let marketStatus: () -> MarketStatus
    private let interval: TimeInterval
    private var visible = false
    private var loop: Task<Void, Never>?
    private var request: Task<Void, Never>?
    /// Grows while rounds keep failing, so automatic polling stops hammering a throttled feed.
    private var backoff: TimeInterval = 0

    init(symbol: SymbolID, name: String, worker: StockVolumeFetching = StockVolumeWorker(),
         interval: TimeInterval = 60, marketStatus: @escaping () -> MarketStatus = { MarketClock().status(.a) }) {
        self.symbol = symbol
        self.name = name
        self.worker = worker
        self.interval = interval
        self.marketStatus = marketStatus
    }

    var pollDelay: TimeInterval { max(interval, backoff) }

    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        if value {
            backoff = 0
            if !paused, updated.map({ Date().timeIntervalSince($0) > 20 }) ?? true { refreshNow(forceDetails: false) }
            loop = Task { [weak self, interval] in
                while !Task.isCancelled {
                    let delay = self?.pollDelay ?? interval
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    guard let self else { return }
                    if !self.paused && self.marketStatus() == .open { self.refreshNow(forceDetails: false) }
                }
            }
        } else {
            loop?.cancel()
            loop = nil
            request?.cancel()
        }
    }

    func togglePause() {
        paused.toggle()
        if paused { request?.cancel() }
        else if visible { refreshNow() }
    }

    /// Manual refresh forces the detail snapshot; automatic rounds reuse it while the minute
    /// series has not advanced.
    func refreshNow(forceDetails: Bool = true) {
        guard visible, request == nil else { return }
        refreshing = true
        request = Task { [weak self] in
            guard let self else { return }
            defer {
                self.request = nil
                self.refreshing = false
                // A rapid hide/reopen may have happened while cancellation was unwinding.
                if Task.isCancelled && self.visible && !self.paused { self.refreshNow(forceDetails: forceDetails) }
            }
            do {
                let value = try await self.worker.fetch(symbol: self.symbol, forceDetails: forceDetails)
                guard !Task.isCancelled, self.visible else { return }
                if self.display != value { self.display = value }
                self.updated = Date()
                self.error = nil
                self.backoff = 0
            } catch {
                guard !Task.isCancelled, self.visible else { return }
                self.error = (error as? HTTPError)?.description ?? error.localizedDescription
                if Self.isTransient(error) {
                    self.backoff = min(max(self.backoff * 2, 60), 600)
                }
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let http = error as? HTTPError else { return false }
        switch http {
        case .transport, .rateLimited: return true
        case .badStatus(let status): return status >= 500
        case .decoding: return false
        }
    }
}

/// Manages independent stock-analysis windows so multiple symbols can be inspected side by side.
@MainActor
final class StockVolumeWindowController: NSObject, NSWindowDelegate {
    static let shared = StockVolumeWindowController()

    private struct Entry {
        let window: NSWindow
        let monitor: StockVolumeMonitor
    }

    private var entries: [SymbolID: Entry] = [:]
    private var windowIndex: [ObjectIdentifier: SymbolID] = [:]
    private var lastOpenedOrigin: NSPoint?
    private let requestGate = ETFRequestGate()
    private let makeMonitor: (SymbolID, String) -> StockVolumeMonitor
    private let defaultSize = NSSize(width: 680, height: 640)
    private let cascadeStep: CGFloat = 28

    override convenience init() {
        let gate = ETFRequestGate()
        self.init(requestGate: gate) { symbol, name in
            StockVolumeMonitor(symbol: symbol, name: name, worker: StockVolumeWorker(service: StockVolumeService(gate: gate)))
        }
    }

    init(requestGate: ETFRequestGate = ETFRequestGate(),
         makeMonitor: @escaping (SymbolID, String) -> StockVolumeMonitor) {
        self.makeMonitor = makeMonitor
        super.init()
        _ = requestGate
    }

    var openSymbols: Set<SymbolID> { Set(entries.keys) }

    func window(for symbol: SymbolID) -> NSWindow? { entries[symbol]?.window }

    func show(symbol: SymbolID, name: String) {
        guard StockVolumeService.supports(symbol) else { return }
        if let existing = entries[symbol] {
            existing.window.deminiaturize(nil)
            existing.window.makeKeyAndOrderFront(nil)
            existing.monitor.setVisible(true)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = makeMonitor(symbol, name)
        let hosting = NSHostingController(rootView: StockVolumePanel(monitor: model, hasTransparentTitlebar: true))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(name) · \(L("stockAnalysis.title"))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.setContentSize(defaultSize)
        window.minSize = NSSize(width: 560, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self

        position(window)

        entries[symbol] = Entry(window: window, monitor: model)
        windowIndex[ObjectIdentifier(window)] = symbol

        window.makeKeyAndOrderFront(nil)
        model.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeAll() {
        for entry in Array(entries.values) {
            entry.window.close()
        }
    }

    private func position(_ window: NSWindow) {
        guard !entries.isEmpty,
              let screen = NSScreen.main ?? window.screen else {
            window.center()
            lastOpenedOrigin = window.frame.origin
            return
        }
        let anchor = lastOpenedOrigin ?? entries.values.first?.window.frame.origin
        guard let origin = anchor else {
            window.center()
            lastOpenedOrigin = window.frame.origin
            return
        }
        let frame = screen.visibleFrame
        let width = window.frame.width
        let height = window.frame.height
        var nextX = origin.x + cascadeStep
        var nextY = origin.y - cascadeStep
        if nextX + width > frame.maxX - 16 || nextY < frame.minY + 16 {
            nextX = frame.minX + 48
            nextY = frame.maxY - height - 48
        }
        let nextOrigin = NSPoint(
            x: max(frame.minX + 16, min(nextX, frame.maxX - width - 16)),
            y: max(frame.minY + 16, min(nextY, frame.maxY - height - 16))
        )
        window.setFrameOrigin(nextOrigin)
        lastOpenedOrigin = nextOrigin
    }

    private func entry(for notification: Notification) -> (SymbolID, Entry)? {
        guard let window = notification.object as? NSWindow,
              let symbol = windowIndex[ObjectIdentifier(window)],
              let entry = entries[symbol] else { return nil }
        return (symbol, entry)
    }

    func windowWillClose(_ notification: Notification) {
        guard let (symbol, entry) = entry(for: notification) else { return }
        entry.monitor.setVisible(false)
        entries.removeValue(forKey: symbol)
        windowIndex.removeValue(forKey: ObjectIdentifier(entry.window))
        if entries.isEmpty { lastOpenedOrigin = nil }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let (_, entry) = entry(for: notification) else { return }
        let window = entry.window
        entry.monitor.setVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    func windowDidMiniaturize(_ notification: Notification) {
        entry(for: notification)?.1.monitor.setVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        entry(for: notification)?.1.monitor.setVisible(true)
    }
}
