import Foundation
import Security

/// Secrets are stored in macOS Keychain. Legacy file entries are removed only after a successful migration.
enum Keychain {
    enum Key: String { case anthropic, elevenlabs, openai, deepseek, groq, gemini, tokenHarbor, custom, sanctraPersonalToken }
    private static let service = "com.bluey.credentials"
    private static func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly/keys.json")
    }
    private static func legacy() -> [String: String] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
    }
    private static func removeLegacy(_ key: Key) {
        var values = legacy()
        guard values.removeValue(forKey: key.rawValue) != nil,
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    static func get(_ key: Key) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
        // Preserve usability if the Keychain is locked or unavailable; never lose the legacy key.
        guard let old = legacy()[key.rawValue], !old.isEmpty else { return nil }
        if set(key, old) { removeLegacy(key) }
        return old
    }
    @discardableResult static func set(_ key: Key, _ value: String?) -> Bool {
        let q = query(key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { removeLegacy(key); return true }
            return false
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = q
            new[kSecValueData as String] = Data(value.utf8)
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        if status == errSecSuccess { removeLegacy(key); return true }
        return false
    }
}
