import Foundation
import AppKit
import UniformTypeIdentifiers

/// 自选股 CSV 导入导出工具。
///
/// 格式: symbol,market,name,order
enum CSVWatchlistIO {
    static func exportWatchlist(_ items: [WatchItem]) -> String {
        var lines = ["symbol,market,name,order"]
        for w in items {
            let row: [String] = [
                w.symbol.code,
                w.symbol.market.rawValue,
                csvField(w.name),
                "\(w.order)"
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func importWatchlist(_ text: String) -> [WatchItem] {
        var out: [WatchItem] = []
        let rows = parseRows(text)
        for row in rows.dropFirst() {
            guard row.count >= 3 else { continue }
            guard let market = Market(rawValue: row[1]) else { continue }
            let order = row.count > 3 ? Int(row[3]) ?? 0 : 0
            out.append(WatchItem(
                symbol: SymbolID(code: row[0], market: market),
                name: row[2],
                order: order
            ))
        }
        return out
    }

    @MainActor
    static func presentExportPanel(suggestedName: String, content: String) {
        let panel = NSSavePanel()
        panel.title = L("csv.exportTitle", comment: "导出 CSV")
        panel.nameFieldStringValue = suggestedName
        if let csv = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csv]
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @MainActor
    static func presentImportPanel(onLoaded: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L("csv.importTitle", comment: "导入 CSV")
        if let csv = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csv]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            onLoaded(nil)
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            onLoaded(text)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            onLoaded(nil)
        }
    }

    private static func csvField(_ str: String) -> String {
        if str.contains(",") || str.contains("\"") || str.contains("\n") {
            let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return str
    }

    private static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if insideQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 1
                    } else {
                        insideQuotes = false
                    }
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" {
                    insideQuotes = true
                } else if ch == "," {
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                } else if ch == "\n" || ch == "\r" {
                    if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 1
                    }
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                    if !currentRow.allSatisfy({ $0.isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                } else {
                    currentField.append(ch)
                }
            }
            i += 1
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
            if !currentRow.allSatisfy({ $0.isEmpty }) {
                rows.append(currentRow)
            }
        }
        return rows
    }
}
