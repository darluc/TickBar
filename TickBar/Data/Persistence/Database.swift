import Foundation
import GRDB

/// 数据库门面:统一持有 DatabasePool,负责 schema 迁移。
final class Database {
    let dbPool: DatabasePool

    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        self.dbPool = try DatabasePool(path: path, configuration: config)
        try Migrations.register(dbPool)
        Log.db.info("opened db at \(path, privacy: .public)")
    }

    /// 应用支持目录下的默认数据库路径。
    ///
    /// 目录名跟着 `CFBundleName`(Release 是 "TickBar",Debug 是 "TickBar-Dev"),
    /// 这样开发和正式版数据完全隔离,改 dev 的不会污染线上数据库。
    static func defaultPath() throws -> String {
        let base = try defaultDirectory()
        let dbPath = base.appendingPathComponent("tickbar.sqlite").path

        migrateFromLegacyIfNeeded(currentPath: dbPath, folderName: appSupportFolderName())
        return dbPath
    }

    static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        let folderName = appSupportFolderName()
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Release: "TickBar";Debug: "TickBar-Dev"。读 CFBundleName,fallback 到 "TickBar"。
    private static func appSupportFolderName() -> String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return "TickBar"
    }

    /// Legacy 迁移:兼容原 PanBar 数据库
    private static func migrateFromLegacyIfNeeded(currentPath: String, folderName: String) {
        let fm = FileManager.default

        // 当前路径已有数据就跳过
        if fm.fileExists(atPath: currentPath),
           let attrs = try? fm.attributesOfItem(atPath: currentPath),
           let size = attrs[.size] as? UInt64, size > 0 {
            return
        }

        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return }
        let legacyCandidates = [
            "\(home)/Library/Application Support/\(folderName)/panbar.sqlite",
            "\(home)/Library/Application Support/PanBar-Dev/panbar.sqlite",
            "\(home)/Library/Application Support/PanBar/panbar.sqlite"
        ]

        for legacyDB in legacyCandidates where fm.fileExists(atPath: legacyDB) {
            let currentURL = URL(fileURLWithPath: currentPath)
            let currentDir = currentURL.deletingLastPathComponent().path
            try? fm.createDirectory(atPath: currentDir, withIntermediateDirectories: true)
            do {
                for suffix in ["", "-wal", "-shm"] {
                    let src = legacyDB + suffix
                    let dst = currentPath + suffix
                    if fm.fileExists(atPath: src) {
                        try? fm.removeItem(atPath: dst)
                        try? fm.copyItem(atPath: src, toPath: dst)
                    }
                }
                Log.db.info("migrated db from legacy \(legacyDB, privacy: .public)")
                return
            } catch {
                Log.db.warning("legacy db migration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
