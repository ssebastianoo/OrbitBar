import Foundation
import Security

/// The session token lives in the login keychain, one item per server.
enum Keychain {
    private static let service = "dev.orbitbar.session"

    /// False when the keychain refused the item: the session then works until the app quits.
    @discardableResult
    static func save(token: String, server: String) -> Bool {
        delete(server: server)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func token(server: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(server: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Small preferences that survive relaunches.
enum Prefs {
    private static let d = UserDefaults.standard

    static var server: String? {
        get { d.string(forKey: "server") }
        set { d.set(newValue, forKey: "server") }
    }

    static var workspaceID: String? {
        get { d.string(forKey: "workspaceID") }
        set { d.set(newValue, forKey: "workspaceID") }
    }

    static func projectFilter(workspace: String) -> String? { d.string(forKey: "projectFilter.\(workspace)") }
    static func setProjectFilter(_ value: String?, workspace: String) { d.set(value, forKey: "projectFilter.\(workspace)") }

    static var onlyMine: Bool {
        get { d.object(forKey: "onlyMine") as? Bool ?? true }
        set { d.set(newValue, forKey: "onlyMine") }
    }

    static var showDone: Bool {
        get { d.bool(forKey: "showDone") }
        set { d.set(newValue, forKey: "showDone") }
    }

    static var lastProjectForNew: String? {
        get { d.string(forKey: "lastProjectForNew") }
        set { d.set(newValue, forKey: "lastProjectForNew") }
    }
}
