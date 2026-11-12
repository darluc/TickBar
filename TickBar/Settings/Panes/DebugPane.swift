#if DEBUG
import SwiftUI
import AppKit

/// 仅 Debug 构建出现的工具页:清数据 / 灌示例数据 / 打开 DB 目录。
struct DebugPane: View {
    @Environment(\.container) private var container
    @State private var lastMessage: String = ""

    var body: some View {
        if let container = container {
            content(container: container)
        } else {
            Text(L("loading", comment: "加载中..."))
        }
    }

    @ViewBuilder
    private func content(container: DependencyContainer) -> some View {
        Form {
            Section(header: Text("Debug 工具").font(.title3)) {
                Text("仅 dev 构建可见，用于快速重置与造数据。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("数据").font(.headline)) {
                Button("生成自选示例数据 (中美港主流股票与指数)") {
                    seedSampleData(container: container)
                }
                Button("清空自选标的") { clear(container: container, kinds: [.watchlist]) }
                Button("清空行情缓存") { clear(container: container, kinds: [.quoteCache]) }
                Button(role: .destructive) {
                    clear(container: container, kinds: [.watchlist, .quoteCache])
                } label: {
                    Text("全部清空 (自选 + 行情缓存)")
                }
            }

            Section(header: Text("文件").font(.headline)) {
                Button("在 Finder 打开数据目录") {
                    openDataFolderInFinder()
                }
                Button("打开 updater.log") {
                    openLogFile(name: "updater.log")
                }
            }

            if !lastMessage.isEmpty {
                Section {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    // MARK: - Actions

    private enum ClearKind { case watchlist, quoteCache }

    private func clear(container: DependencyContainer, kinds: Set<ClearKind>) {
        var done: [String] = []
        if kinds.contains(.watchlist) {
            try? container.watchlistRepo.deleteAll()
            done.append("自选")
        }
        if kinds.contains(.quoteCache) {
            container.quoteCacheRepo.deleteAll()
            done.append("行情缓存")
        }
        container.refresher.refreshNow()
        lastMessage = "已清空: " + done.joined(separator: " / ")
    }

    private func seedSampleData(container: DependencyContainer) {
        let watchlist: [WatchItem] = [
            WatchItem(symbol: SymbolID(code: "NVDA", market: .us), name: "英伟达", order: 0),
            WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "苹果", order: 1),
            WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "特斯拉", order: 2),
            WatchItem(symbol: SymbolID(code: "00700", market: .hk), name: "腾讯控股", order: 3),
            WatchItem(symbol: SymbolID(code: "09988", market: .hk), name: "阿里巴巴", order: 4),
            WatchItem(symbol: SymbolID(code: "600519", market: .a), name: "贵州茅台", order: 5),
            WatchItem(symbol: SymbolID(code: "300750", market: .a), name: "宁德时代", order: 6)
        ]

        for w in watchlist {
            try? container.watchlistRepo.upsert(w)
        }

        container.refresher.refreshNow()
        lastMessage = "已生成 \(watchlist.count) 只精选自选股"
    }

    private func openDataFolderInFinder() {
        if let folder = try? Database.defaultDirectory() {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func openLogFile(name: String) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let logFile = appSupport.appendingPathComponent("TickBar").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.open(logFile)
        } else {
            lastMessage = "日志文件尚不存在: \(name)"
        }
    }
}
#endif
