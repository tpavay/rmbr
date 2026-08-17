import Foundation
import Security

/// Holds the Geoapify API key in the device keychain.
///
/// The key is never in the repository, never in an `xcconfig`, never in `Info.plist`
/// and never compiled into the binary. It is entered once on the device and lives in
/// the keychain from then on, marked this-device-only so it does not travel to iCloud
/// or to another phone. A key baked into a build ships to every copy of that build and
/// cannot be rotated without a release; a key in the keychain can be replaced in
/// seconds and is readable only by this app.
struct GeoapifyCredentialStore: Sendable {
    private let service: String
    private let account = "geoapify-api-key"

    init(service: String = "com.TylerPavay.rmbr.places") {
        self.service = service
    }

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    func write(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    var hasKey: Bool { read() != nil }
}
