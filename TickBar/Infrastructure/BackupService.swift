import Foundation
import AppKit
import UniformTypeIdentifiers

/// 备份文件载荷:包含所有自选标的与设置。
struct BackupBundle: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let watchlist: [WatchItem]
    var groups: [WatchlistGroup]? = nil
    /// 全量 appSetting 表(包含语言、主题、配色、Provider Key、Hotkey 等所有 key-value)。
    let settings: [String: String]

    static let currentSchemaVersion: Int = 1
}

struct ImportSummary {
    let watchlistCount: Int
    let settingsCount: Int
}

@MainActor
final class BackupService {
    private let container: DependencyContainer

    init(container: DependencyContainer) {
        self.container = container
    }

    // MARK: 导出

    func makeBundle() throws -> BackupBundle {
        let watchlist = (try? container.watchlistRepo.all()) ?? []
        let groups = (try? container.watchlistRepo.allGroups()) ?? []
        let settings = (try? container.settingsRepo.allEntries()) ?? [:]
        let version = AppVersion.short
        return BackupBundle(
            schemaVersion: BackupBundle.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: version,
            watchlist: watchlist,
            groups: groups,
            settings: settings
        )
    }

    func encode(_ bundle: BackupBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }

    // MARK: 导入

    func decode(_ data: Data) throws -> BackupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupBundle.self, from: data)
    }

    /// 全量替换式导入。清空当前 watchlist / settings 再写入。
    @discardableResult
    func applyReplace(_ bundle: BackupBundle) throws -> ImportSummary {
        guard bundle.schemaVersion <= BackupBundle.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(bundle.schemaVersion)
        }

        try container.watchlistRepo.deleteAll()
        try container.settingsRepo.replaceAll(bundle.settings)

        if let groups = bundle.groups, !groups.isEmpty {
            for g in groups { try container.watchlistRepo.upsertGroup(g) }
        }

        for w in bundle.watchlist { try container.watchlistRepo.upsert(w) }

        return ImportSummary(
            watchlistCount: bundle.watchlist.count,
            settingsCount: bundle.settings.count
        )
    }

    // MARK: NSPanel 工具

    func presentExportPanel() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let suggested = "tickbar-backup-\(fmt.string(from: Date())).json"
        let panel = NSSavePanel()
        panel.title = L("backup.exportTitle", comment: "")
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = try makeBundle()
            let data = try encode(bundle)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func presentImportPanel(onSuccess: @escaping (ImportSummary) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L("backup.importTitle", comment: "")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let bundle = try decode(data)

            let alert = NSAlert()
            alert.messageText = L("backup.confirmTitle", comment: "")
            alert.informativeText = String(
                format: L("backup.confirmMessage", comment: ""),
                bundle.watchlist.count,
                bundle.settings.count
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("backup.confirmButton", comment: ""))
            alert.addButton(withTitle: L("action.cancel", comment: ""))

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let summary = try applyReplace(bundle)
            onSuccess(summary)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    enum BackupError: LocalizedError {
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let v):
                return String(format: L("backup.error.schema", comment: ""), v)
            }
        }
    }
}
