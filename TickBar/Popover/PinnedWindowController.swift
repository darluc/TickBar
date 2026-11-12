import AppKit
import SwiftUI

/// 悬浮置顶独立窗口 (对齐 Pulse 的 PinnedWindow / action.pinWindow)
@MainActor
final class PinnedWindowController: NSWindowController {
    static let shared = PinnedWindowController()

    private let windowWidth: CGFloat = 510
    private let windowHeight: CGFloat = 520

    var isPinned: Bool {
        window?.isVisible ?? false
    }

    var onUnpin: (() -> Void)?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 300, height: 380)

        super.init(window: panel)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowClosed()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        near view: NSView?,
        viewModel: PopoverViewModel,
        refresher: QuoteRefresher,
        appearancePrefs: AppearancePreferences,
        tickerPrefs: TickerPreferences,
        container: DependencyContainer
    ) {
        guard let window = window else { return }

        let rootView = PinnedRootView(onUnpin: { [weak self] in
            self?.unpin()
        })
        .environmentObject(viewModel)
        .environmentObject(refresher)
        .environmentObject(appearancePrefs)
        .environmentObject(tickerPrefs)
        .environmentObject(container.etfMonitor)
        .environment(\.container, container)

        window.contentViewController = NSHostingController(rootView: rootView)

        // 首次打开或根据按钮位置计算居中展示
        if let view = view, let screen = view.window?.screen ?? NSScreen.main {
            let viewRectOnScreen = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
            let x = max(screen.visibleFrame.minX + 20, min(screen.visibleFrame.maxX - windowWidth - 20, viewRectOnScreen.midX - windowWidth / 2))
            let y = viewRectOnScreen.minY - windowHeight - 8
            window.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 20, y)))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresher.setPopoverOpen(true)
        container.etfMonitor.setVisible(.pinned, true)
    }

    func unpin() {
        close()
        onUnpin?()
    }

    private func handleWindowClosed() {
        if let container = DependencyContainer.shared {
            container.refresher.setPopoverOpen(false)
            container.etfMonitor.setVisible(.pinned, false)
        }
        onUnpin?()
    }
}

/// 钉住窗口的根容器视图: 带有磨砂毛玻璃背景与圆角边框
struct PinnedRootView: View {
    let onUnpin: () -> Void

    var body: some View {
        ZStack {
            // 背景毛玻璃
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
                )

            PopoverRoot(isPinned: true, onTogglePin: onUnpin)
        }
        .padding(4)
        .ignoresSafeArea()
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
