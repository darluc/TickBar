import Foundation
import GRDB

/// Imports the renamed app's data once, without changing the legacy database.
enum LegacyDataMigration {
    static let databaseMarker = "tickbar.legacy_data_import_v1"
    static let preferencesMarker = "tickbar.legacy_preferences_import_v1"

    static func candidates(applicationSupport: URL, folderName: String) -> [URL] {
        let dev = folderName.hasSuffix("-Dev")
        let suffix = dev ? "-Dev" : ""
        return [
            applicationSupport.appendingPathComponent("TickerBar\(suffix)/tickerbar.sqlite"),
            applicationSupport.appendingPathComponent("\(folderName)/tickerbar.sqlite"),
            applicationSupport.appendingPathComponent("\(folderName)/panbar.sqlite"),
            applicationSupport.appendingPathComponent("PanBar\(suffix)/panbar.sqlite")
        ]
    }

    /// SQLite's backup API includes committed WAL content and produces a consistent snapshot.
    private static func snapshot(from source: URL, to destination: URL) throws {
        // Allow SQLite to create WAL sidecars when a closed legacy database has none.
        // No statements write to the source database.
        let reader = try DatabaseQueue(path: source.path)
        defer { try? reader.close() }
        let writer = try DatabaseQueue(path: destination.path)
        defer { try? writer.close() }
        try reader.backup(to: writer)
        // Keep snapshots self-contained and readable without WAL sidecars.
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
    }

    static func migrateDatabase(current: URL, applicationSupport: URL, folderName: String) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: current.path)
        if exists {
            let reader = try DatabaseQueue(path: current.path)
            let imported = try reader.read { db in
                try db.tableExists("appSetting") && String.fetchOne(db,
                    sql: "SELECT value FROM appSetting WHERE key = ?", arguments: [databaseMarker]) == "1"
            }
            try reader.close()
            if imported { return }
        }
        guard let source = candidates(applicationSupport: applicationSupport, folderName: folderName)
            .first(where: { fm.fileExists(atPath: $0.path) }) else { return }

        let backupDirectory = current.deletingLastPathComponent()
            .appendingPathComponent("MigrationBackups/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let legacyBackup = backupDirectory.appendingPathComponent("legacy.sqlite")
        try snapshot(from: source, to: legacyBackup)
        if exists {
            try snapshot(from: current, to: backupDirectory.appendingPathComponent("before-import.sqlite"))
        }

        // Upgrade a working copy, never the user's old database or its backup.
        let working = backupDirectory.appendingPathComponent("working.sqlite")
        try snapshot(from: legacyBackup, to: working)
        let legacy = try Database(path: working.path)
        try legacy.dbPool.close()

        if !exists {
            try snapshot(from: working, to: current)
        }
        let destination = try Database(path: current.path)
        defer { try? destination.dbPool.close() }
        try destination.dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS legacyImport", arguments: [working.path])
            defer { try? db.execute(sql: "DETACH DATABASE legacyImport") }
            try db.inTransaction {
                if exists {
                    // Existing records and preferences win; missing groups/items/settings are restored.
                    // Named columns avoid depending on historical column order.
                    for table in ["watchlistGroup", "watchItem", "holding", "alert", "appSetting", "fxCache", "quoteCache"] {
                        let columns = try db.columns(in: table).map { column in
                            "\"" + column.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                        }.joined(separator: ",")
                        try db.execute(sql: "INSERT OR IGNORE INTO \(table) (\(columns)) SELECT \(columns) FROM legacyImport.\(table)")
                    }
                }
                try db.execute(sql: "INSERT OR REPLACE INTO appSetting (key, value) VALUES (?, '1')",
                               arguments: [databaseMarker])
                return .commit
            }
        }
        // Backups remain available for manual recovery; the working copy is no longer needed.
        for suffix in ["", "-wal", "-shm"] {
            let path = working.path + suffix
            if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
        }
        Log.db.info("imported legacy data; backups at \(backupDirectory.path, privacy: .public)")
    }

    static func migratePreferences(defaults: UserDefaults = .standard,
                                   currentDomain: String? = Bundle.main.bundleIdentifier,
                                   legacyDomain: String? = nil) {
        guard let currentDomain else { return }
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard current[preferencesMarker] == nil else { return }
        let dev = currentDomain.hasSuffix(".debug")
        let oldDomain = legacyDomain ?? ("app.tickerbar.TickerBar" + (dev ? ".debug" : ""))
        guard let legacy = defaults.persistentDomain(forName: oldDomain), !legacy.isEmpty else { return }
        for (key, value) in legacy {
            var target = key.replacingOccurrences(of: oldDomain, with: currentDomain)
            if target.hasPrefix("tickerbar.") {
                target = "tickbar." + target.dropFirst("tickerbar.".count)
            }
            if current[target] == nil { defaults.set(value, forKey: target) }
        }
        defaults.set(true, forKey: preferencesMarker)
    }
}
