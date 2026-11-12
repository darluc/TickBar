import AppKit
import SwiftUI

@MainActor
final class PopoverController {
    private let popover: NSPopover
    private let refresher: QuoteRefresher
    private let viewModel: PopoverViewModel
    private let appearancePrefs: AppearancePreferences
    private let tickerPrefs: TickerPreferences
    private let container: DependencyContainer
    private let popoverWidth: CGFloat = 510
    private let popoverHeight: CGFloat = 520

    private var anchorView: NSView?

    /// 监听 popover 之外的点击
    private var eventMonitor: Any?
    private var didCloseObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    var isShown: Bool { popover.isShown }
    var isPinned: Bool { PinnedWindowController.shared.isPinned }

    init(
        refresher: QuoteRefresher,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository,
        appearancePrefs: AppearancePreferences,
        tickerPrefs: TickerPreferences,
        container: DependencyContainer
    ) {
        self.refresher = refresher
        self.viewModel = PopoverViewModel(
            refresher: refresher,
            watchlistRepo: watchlistRepo,
            settingsRepo: settingsRepo
        )
        self.appearancePrefs = appearancePrefs
        self.tickerPrefs = tickerPrefs
        self.container = container

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        self.popover = popover

        updatePopoverContent()

        didCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePopoverClosed()
            }
        }

        PinnedWindowController.shared.onUnpin = { [weak self] in
            // 取消 pin 时，如果菜单栏有 anchorView，可以优雅收回到菜单栏
            self?.handleUnpin()
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        if let observer = didCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updatePopoverContent() {
        popover.contentViewController = NSHostingController(rootView:
            PopoverRoot(
                isPinned: false,
                onTogglePin: { [weak self] in
                    self?.pinToWindow()
                }
            )
            .environmentObject(viewModel)
            .environmentObject(refresher)
            .environmentObject(appearancePrefs)
            .environmentObject(tickerPrefs)
            .environmentObject(container.etfMonitor)
            .environment(\.container, container)
            .frame(width: popoverWidth, height: popoverHeight)
        )
    }

    /// 把当前面板 pin 成独立常驻浮窗
    func pinToWindow() {
        close()
        PinnedWindowController.shared.show(
            near: anchorView,
            viewModel: viewModel,
            refresher: refresher,
            appearancePrefs: appearancePrefs,
            tickerPrefs: tickerPrefs,
            container: container
        )
    }

    private func handleUnpin() {
        if let anchor = anchorView {
            show(relativeTo: anchor)
        }
    }

    private func handlePopoverClosed() {
        stopOutsideClickMonitor()
        container.etfMonitor.setVisible(.popover, false)
        if !PinnedWindowController.shared.isPinned {
            refresher.setPopoverOpen(false)
        }
        onClose?()
    }

    func show(relativeTo view: NSView, anchorWidth: CGFloat? = nil) {
        self.anchorView = view

        // 如果当前已经钉成浮窗，再次点击菜单栏图标时置顶并激活该浮窗
        if PinnedWindowController.shared.isPinned {
            PinnedWindowController.shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        refresher.setPopoverOpen(true)
        refresher.refreshNow()
        container.etfMonitor.setVisible(.popover, true)
        popover.show(relativeTo: positioningRect(relativeTo: view, anchorWidth: anchorWidth), of: view, preferredEdge: .minY)
        startOutsideClickMonitor()
    }

    private func positioningRect(relativeTo view: NSView, anchorWidth: CGFloat?) -> NSRect {
        let rect: NSRect
        if let anchorWidth {
            let width = max(view.bounds.width, anchorWidth)
            rect = NSRect(
                x: view.bounds.maxX - width,
                y: view.bounds.minY,
                width: width,
                height: view.bounds.height
            )
        } else {
            rect = view.bounds
        }
        return rect
    }

    func close() {
        stopOutsideClickMonitor()
        popover.performClose(nil)
        container.etfMonitor.setVisible(.popover, false)
        if !PinnedWindowController.shared.isPinned {
            refresher.setPopoverOpen(false)
        }
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.popover.isShown else { return }
                self.close()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
