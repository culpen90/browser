import Foundation
import Security

/// Device credentials stay in this Mac's Keychain, never in browser preferences.
enum BrowserAgentSecrets {
    private static let service = "local.browser.foundation.peers"

    static func data(for name: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw KeychainError(result) }
        return data
    }

    static func set(_ data: Data, for name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(added) }
        } else if result != errSecSuccess { throw KeychainError(result) }
    }

    static func remove(_ name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw KeychainError(result) }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var errorDescription: String? { "Couldn’t save device credentials in Keychain (\(status))." }
    }
}
