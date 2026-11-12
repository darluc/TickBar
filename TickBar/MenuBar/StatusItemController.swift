import AppKit
import Carbon
import Combine

/// 持有 NSStatusItem 与自绘的 TickerView。
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var tickerView: MenuBarTickerView
    private let popoverController: PopoverController
    private let refresher: QuoteRefresher
    private let prefs: TickerPreferences
    private let clock: MarketClock
    private let settingsRepo: SettingsRepository
    private var renderer: TickerRenderer
    private var cancellables = Set<AnyCancellable>()
    private var contextMenu: NSMenu
    private var screenSharingMonitor: ScreenSharingMonitor?
    private var privacyHidden: Bool = false
    private var currentMode: TickerDisplayMode = .carousel
    private var lockedPopoverLength: CGFloat?

    init(
        refresher: QuoteRefresher,
        popoverController: PopoverController,
        prefs: TickerPreferences,
        clock: MarketClock,
        settingsRepo: SettingsRepository
    ) {
        self.refresher = refresher
        self.popoverController = popoverController
        self.prefs = prefs
        self.clock = clock
        self.settingsRepo = settingsRepo
        self.renderer = TickerRenderer(scheme: prefs.colorScheme)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "app.tickbar.TickBar.statusItem"
        self.currentMode = prefs.displayMode
        self.tickerView = Self.makeView(for: prefs.displayMode, scheme: prefs.colorScheme)
        self.contextMenu = NSMenu()

        privacyHidden = settingsRepo.string(SettingsRepository.Keys.privacyManualHide) == "1"
        let autoEnabled = settingsRepo.string(SettingsRepository.Keys.hideOnScreenShare) != "0"
        if autoEnabled {
            let monitor = ScreenSharingMonitor()
            monitor.onChange = { [weak self] sharing in
                self?.updateTickerVisibility(autoSharing: sharing)
            }
            monitor.start()
            screenSharingMonitor = monitor
        }

        configure()
        popoverController.onClose = { [weak self] in
            self?.unlockPopoverLength()
        }
        applyPrefs()
        bind()
    }

    private func applyPrefs() {
        renderer = TickerRenderer(
            scheme: prefs.colorScheme,
            showsQuoteCode: prefs.showQuoteCode,
            showsQuoteName: prefs.showQuoteName
        )
        if prefs.displayMode != currentMode {
            swapTickerView(to: prefs.displayMode)
        }
        switch prefs.displayMode {
        case .scroll, .scrollNoCode:
            tickerView.preferredTotalWidth = prefs.scrollAutoWidth ? nil : CGFloat(prefs.scrollMenuBarWidth)
        case .carousel:
            tickerView.preferredTotalWidth = prefs.carouselAutoWidth ? nil : CGFloat(prefs.carouselMenuBarWidth)
        default:
            tickerView.preferredTotalWidth = prefs.carouselAutoWidth ? nil : CGFloat(prefs.carouselMenuBarWidth)
        }
        tickerView.showsIcon = false
        if let scroll = tickerView as? TickerView {
            scroll.pixelsPerSecond = prefs.scrollSpeed.pixelsPerSecond
            scroll.pauseOnHover = prefs.pauseOnHover
        }
        if let carousel = tickerView as? CarouselTickerView {
            carousel.pauseOnHover = prefs.pauseOnHover
            carousel.dwell = CFTimeInterval(prefs.carouselDwell)
        }
        applyQuotes(refresher.quotes)
    }

    private static func makeView(for mode: TickerDisplayMode, scheme: TickerColorScheme) -> MenuBarTickerView {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        switch mode {
        case .scroll, .scrollNoCode:
            return TickerView(frame: frame)
        default:
            return CarouselTickerView(frame: frame)
        }
    }

    private func swapTickerView(to mode: TickerDisplayMode) {
        tickerView.onContentChanged = nil
        tickerView.invalidateAnimation()
        tickerView = Self.makeView(for: mode, scheme: prefs.colorScheme)
        wireUpTickerView()
        currentMode = mode
    }

    private var mouseMovedMonitors: [Any] = []

    private func configure() {
        guard let button = statusItem.button else { return }
        button.frame = NSRect(x: 0, y: 0, width: tickerView.totalWidth, height: 22)
        button.target = self
        button.action = #selector(onClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        startHoverTracking()
        wireUpTickerView()
        buildContextMenu()
    }

    private func startHoverTracking() {
        let onMove: (NSEvent) -> Void = { [weak self] _ in self?.updateHoverState() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: onMove) {
            mouseMovedMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.updateHoverState()
            return event
        }) {
            mouseMovedMonitors.append(local)
        }
    }

    private func updateHoverState() {
        guard let button = statusItem.button, let window = button.window else { return }
        let rectOnScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let isHovering = rectOnScreen.contains(NSEvent.mouseLocation)
        if tickerView.hovered != isHovering {
            tickerView.hovered = isHovering
        }
    }

    deinit {
        mouseMovedMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    private func wireUpTickerView() {
        tickerView.onContentChanged = { [weak self] in
            self?.refreshButtonImage()
        }
        refreshButtonImage()
    }

    private func refreshButtonImage() {
        guard let button = statusItem.button else { return }
        let image = tickerView.renderImage()
        button.image = image
        button.imagePosition = .imageOnly
        statusItem.length = lockedPopoverLength ?? tickerView.totalWidth
    }

    private func lockPopoverLength() {
        guard lockedPopoverLength == nil else { return }
        lockedPopoverLength = max(40, statusItem.length, tickerView.totalWidth)
        statusItem.length = lockedPopoverLength ?? tickerView.totalWidth
    }

    private func unlockPopoverLength() {
        guard lockedPopoverLength != nil else { return }
        lockedPopoverLength = nil
        refreshButtonImage()
    }

    private func render(quotes: [SymbolID: Quote]) {
        let items = buildTickerItems(quotes: quotes)
        switch currentMode {
        case .scroll, .scrollNoCode:
            guard let view = tickerView as? TickerView else { return }
            view.update(attributed: renderer.render(items: items))
        default:
            guard let view = tickerView as? CarouselTickerView else { return }
            var slots: [NSAttributedString] = []
            for it in items {
                slots.append(renderer.render(items: [it]))
            }
            view.update(items: slots)
        }
        statusItem.length = lockedPopoverLength ?? tickerView.totalWidth
    }

    private func buildContextMenu() {
        contextMenu.removeAllItems()
        contextMenu.addItem(withTitle: L("menu.refresh", comment: ""), action: #selector(refresh), keyEquivalent: "r").target = self
        contextMenu.addItem(withTitle: L("menu.showPopover", comment: ""), action: #selector(showPopover), keyEquivalent: "p").target = self
        contextMenu.addItem(.separator())
        let privacyItem = NSMenuItem(
            title: privacyHidden ? L("menu.privacy.show", comment: "") : L("menu.privacy.hideNow", comment: ""),
            action: #selector(togglePrivacy),
            keyEquivalent: ""
        )
        privacyItem.target = self
        contextMenu.addItem(privacyItem)
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: L("menu.settings", comment: ""), action: #selector(openSettings), keyEquivalent: ",").target = self
        contextMenu.addItem(withTitle: L("menu.checkForUpdates", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: L("menu.quit", comment: ""), action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func bind() {
        refresher.$quotes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] quotes in
                self?.applyQuotes(quotes)
            }
            .store(in: &cancellables)

        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyPrefs() }
            }
            .store(in: &cancellables)
    }

    private func applyQuotes(_ quotes: [SymbolID: Quote]) {
        updatePauseState()
        render(quotes: quotes)
    }

    private func updatePauseState() {
        let watchlist = (try? DependencyContainer.shared?.watchlistRepo.all()) ?? []
        let markets = Set(watchlist.map(\.symbol.market))
        let shouldPause = prefs.pauseWhenClosed && !clock.anyQuoteActive(markets: markets)
        tickerView.setPaused(shouldPause)
    }

    private func buildTickerItems(quotes: [SymbolID: Quote]) -> [TickerItem] {
        var items: [TickerItem] = []
        let watchlist = (try? DependencyContainer.shared?.watchlistRepo.all()) ?? []
        for w in watchlist where w.inTicker {
            if let q = quotes[w.symbol] {
                items.append(.quote(q))
            }
        }
        let cap = max(1, prefs.maxItems)
        return Array(items.prefix(cap))
    }

    @objc private func onClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = contextMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popoverController.isShown {
            popoverController.close()
        } else {
            lockPopoverLength()
            popoverController.show(relativeTo: button)
        }
    }

    func toggleViaHotkey() {
        togglePopover()
    }

    func togglePrivacyViaHotkey() {
        togglePrivacy()
    }

    @objc private func refresh() {
        refresher.refreshNow()
    }

    @objc private func showPopover() {
        guard let button = statusItem.button else { return }
        lockPopoverLength()
        popoverController.show(relativeTo: button)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    @objc private func togglePrivacy() {
        privacyHidden.toggle()
        try? settingsRepo.set(SettingsRepository.Keys.privacyManualHide, privacyHidden ? "1" : "0")
        buildContextMenu()
        updateTickerVisibility(autoSharing: screenSharingMonitor?.isSharing ?? false)
    }

    private func updateTickerVisibility(autoSharing: Bool) {
        let shouldHide = privacyHidden || autoSharing
        tickerView.privacyHidden = shouldHide
        refreshButtonImage()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
