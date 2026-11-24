import Foundation
import Security

/// Bearer token for loopback MCP clients. Stored in Keychain, never in SQLite backups.
enum MCPTokenStore {
    private static let service = "app.tickbar.mcp"
    private static let account = "local-bearer"

    static func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    @discardableResult
    static func ensureToken() -> String {
        if let existing = load() { return existing }
        let token = UUID().uuidString + UUID().uuidString
        save(token)
        return token
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let attrs: [String: Any] = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func rotate() -> String {
        let token = UUID().uuidString + UUID().uuidString
        save(token)
        return token
    }
}
