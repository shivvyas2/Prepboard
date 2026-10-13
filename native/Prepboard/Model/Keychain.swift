import Foundation
import Security

/// Small generic-password store for secrets PrepBoard keeps on this device (the Mac ↔ iPhone pairing code, the LinkedIn sign-in).
/// Items go to the data-protection keychain, where they are scoped to this app and `ThisDeviceOnly` holds. A build without an
/// application identifier (the ad-hoc signed Debug build) cannot use it, so it falls back to the legacy login keychain; reads
/// look in both, which also carries items saved by earlier versions over.
enum Keychain {
    private static let service = "com.shivvyas.prepboard"

    private static func query(_ account: String, legacy: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecAttrSynchronizable as String: false]
        if !legacy { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    static func save(_ value: String, _ account: String) {
        delete(account)
        var q = query(account, legacy: false)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(q as CFDictionary, nil) == errSecMissingEntitlement {
            q[kSecUseDataProtectionKeychain as String] = nil
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func read(_ account: String) -> String? {
        for legacy in [false, true] {
            var q = query(account, legacy: legacy)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return String(decoding: d, as: UTF8.self) }
        }
        return nil
    }

    /// True when an item exists; reads attributes only, so the secret itself is never pulled out just to check.
    static func exists(_ account: String) -> Bool {
        [false, true].contains { legacy in
            var q = query(account, legacy: legacy)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account, legacy: false) as CFDictionary)
        SecItemDelete(query(account, legacy: true) as CFDictionary)
    }
}

enum DeviceBridgeConfig {
    /// The Mac app's port for paired iPhones / iPads (the web bridge script keeps 8787 on localhost).
    static let port: UInt16 = 8788
}
