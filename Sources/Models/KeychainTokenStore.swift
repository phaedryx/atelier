// ABOUTME: Stores the Shortcut API token as a Keychain generic-password item.
// ABOUTME: The app's first stored credential — everything else in Settings is plaintext UserDefaults.

import Foundation
import Security

/// A single Keychain generic-password item, addressed by service name.
///
/// The rest of Settings lives in `@AppStorage`, which is a plaintext plist. An API
/// token is the one value where that is not good enough, so this is deliberately the
/// only thing in the app that talks to `SecItem`.
struct KeychainTokenStore {
    static let shortcutService = "\(AppConstants.appID).shortcut-api-token"

    /// The generic-password `kSecAttrService`. Injected so tests never touch the real item.
    let service: String

    init(service: String = KeychainTokenStore.shortcutService) {
        self.service = service
    }

    var hasToken: Bool {
        read() != nil
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Writes the token, replacing any existing one. An empty or whitespace-only
    /// value clears the item instead, so a cleared SecureField reads as "no token"
    /// rather than storing a credential the client would send as an empty header.
    ///
    /// Returns `errSecSuccess` or the failing status. The caller must not ignore it: a
    /// locked keychain or a denied access prompt otherwise looks exactly like a save that
    /// worked, and the user is left with a Shortcut button that never appears — or worse,
    /// with an old token still on disk after they believed they had replaced or cleared it.
    @discardableResult
    func write(_ token: String) -> OSStatus {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }

        let data = Data(trimmed.utf8)
        let attributes = [kSecValueData as String: data]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return errSecSuccess
        }
        // Only "no item yet" justifies falling through to add. Treating every failure as
        // not-found turned a locked keychain into a silent no-op, because the subsequent
        // add came back errSecDuplicateItem and changed nothing.
        guard updated == errSecItemNotFound else { return updated }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil)
    }

    @discardableResult
    func delete() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Nothing stored is the outcome the caller wanted.
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}
