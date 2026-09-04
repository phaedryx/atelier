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

    /// What a read actually found. `errSecInteractionNotAllowed` and
    /// `errSecAuthFailed` are not "no token": the token is there and the keychain
    /// would not hand it over. Collapsing them into the same answer as
    /// `errSecItemNotFound` presented a keychain problem as "your Shortcut token
    /// vanished", which sends the user to re-paste a token they already have.
    enum ReadOutcome: Equatable {
        case token(String)
        case absent
        case failed(OSStatus)
    }

    var hasToken: Bool {
        read() != nil
    }

    /// The token, or nil for both absent and unreadable. Use `readOutcome()`
    /// where the difference is worth telling the user about.
    func read() -> String? {
        if case let .token(token) = readOutcome() {
            return token
        }
        return nil
    }

    func readOutcome() -> ReadOutcome {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .absent
        }
        guard status == errSecSuccess else {
            return .failed(status)
        }
        // A match that comes back as something other than decodable data is a
        // keychain anomaly, not an empty store — which is the distinction this
        // whole type exists to keep, so it goes to `.failed` rather than to
        // `.absent`. Only an item some other tool wrote can reach it: `write`
        // clears rather than storing an empty credential.
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return .failed(errSecDecode)
        }
        return token.isEmpty ? .absent : .token(token)
    }

    /// Writes the token, replacing any existing one. An empty or whitespace-only
    /// value clears the item instead, so a cleared SecureField reads as "no token"
    /// rather than storing a credential the client would send as an empty header.
    ///
    /// Returns `errSecSuccess` or the failing status. The caller must not ignore it: a
    /// locked keychain or a denied access prompt otherwise looks exactly like a save that
    /// worked, and the user is left with a Shortcut button that never appears — or worse,
    /// with an old token still on disk after they believed they had replaced or cleared it.
    ///
    /// Deliberately *not* `@discardableResult`: the attribute said the opposite of
    /// the paragraph above, and one of the two had to go.
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

    /// **No `kSecAttrAccessible`, deliberately.** It is a data-protection-keychain
    /// attribute, and these items land in the macOS *file* keychain, which accepts
    /// it, ignores it, and does not return it — the attributes that come back are
    /// `cdat`, `class`, `labl`, `mdat`, `svce` and nothing else. What governs
    /// access here is the login keychain's own lock state. Setting an inert
    /// attribute would only look like protection.
    ///
    /// Passing `kSecUseDataProtectionKeychain` *would* make it mean something,
    /// but the two keychains are separate stores: switching without a migration
    /// hides every already-saved token, which is exactly the "your Shortcut token
    /// vanished" story `readOutcome` exists to avoid telling.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}
