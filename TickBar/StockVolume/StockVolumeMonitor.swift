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
    private let interval: UInt64
    private var visible = false
    private var loop: Task<Void, Never>?
    private var request: Task<Void, Never>?

    init(symbol: SymbolID, name: String, worker: StockVolumeFetching = StockVolumeWorker(),
         interval: TimeInterval = 60, marketStatus: @escaping () -> MarketStatus = { MarketClock().status(.a) }) {
        self.symbol = symbol
        self.name = name
        self.worker = worker
        self.interval = UInt64(interval * 1_000_000_000)
        self.marketStatus = marketStatus
    }

    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        if value {
            if !paused, updated.map({ Date().timeIntervalSince($0) > 20 }) ?? true { refreshNow() }
            loop = Task { [weak self, interval] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: interval) } catch { return }
                    guard let self else { return }
                    if !self.paused && self.marketStatus() == .open { self.refreshNow() }
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

    func refreshNow() {
        guard visible, request == nil else { return }
        refreshing = true
        request = Task { [weak self] in
            guard let self else { return }
            defer {
                self.request = nil
                self.refreshing = false
                // A rapid hide/reopen may have happened while cancellation was unwinding.
                if Task.isCancelled && self.visible && !self.paused { self.refreshNow() }
            }
            do {
                let value = try await self.worker.fetch(symbol: self.symbol)
                guard !Task.isCancelled, self.visible else { return }
                if self.display != value { self.display = value }
                self.updated = Date()
                self.error = nil
            } catch {
                guard !Task.isCancelled, self.visible else { return }
                self.error = (error as? HTTPError)?.description ?? error.localizedDescription
            }
        }
    }
}

/// One analysis window. Selecting another symbol cancels the previous symbol's requests.
@MainActor
final class StockVolumeWindowController: NSObject, NSWindowDelegate {
    static let shared = StockVolumeWindowController()
    private var window: NSWindow?
    private var monitor: StockVolumeMonitor?

    func show(symbol: SymbolID, name: String) {
        guard StockVolumeService.supports(symbol) else { return }
        if monitor?.symbol == symbol, let window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            monitor?.setVisible(true)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window?.close()
        let model = StockVolumeMonitor(symbol: symbol, name: name)
        let hosting = NSHostingController(rootView: StockVolumePanel(monitor: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(name) · \(L("volume.title"))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 720))
        window.minSize = NSSize(width: 680, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        monitor = model
        window.center()
        window.makeKeyAndOrderFront(nil)
        model.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        monitor?.setVisible(false)
        monitor = nil
        window = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        monitor?.setVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    func windowDidMiniaturize(_ notification: Notification) { monitor?.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { monitor?.setVisible(true) }
}
