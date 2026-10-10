import Foundation
import Security

/// Small generic-password store for secrets PrepBoard keeps on this device (the Mac ↔ iPhone pairing code).
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.shivvyas.prepboard",
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, _ account: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

enum DeviceBridgeConfig {
    /// The Mac app's port for paired iPhones / iPads (the web bridge script keeps 8787 on localhost).
    static let port: UInt16 = 8788
}
