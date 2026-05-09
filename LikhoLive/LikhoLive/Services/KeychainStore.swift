import Foundation
import Security

/// Persists the Sarvam API key securely in the macOS Keychain.
/// On first run, bootstraps from the reference project's .env file.
final class KeychainStore {

    static let shared = KeychainStore()

    private let service = "com.shaugupt.LikhoLive"
    private let account = "SarvamAPIKey"

    private init() {}

    // MARK: - Public API

    /// Returns the stored API key, or nil if not set.
    func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key.isEmpty ? nil : key
    }

    /// Saves or updates the API key in the Keychain.
    @discardableResult
    func save(apiKey: String) -> Bool {
        let data = apiKey.data(using: .utf8)!

        // Update if exists
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            // Add new
            var newItem = query
            newItem[kSecValueData as String] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Deletes the stored key.
    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

}
