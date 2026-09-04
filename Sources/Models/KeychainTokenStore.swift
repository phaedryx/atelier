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
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            // Present but unusable is the same thing to every caller as absent —
            // `write` clears rather than storing an empty credential, so this is
            // only reachable for an item some other tool wrote.
            return .absent
        }
        return .token(token)
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
        // Set on the update path too, so an item written by an earlier build is
        // migrated rather than left on whatever the default was then.
        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ] as [String: Any]
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
        insert[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(insert as CFDictionary, nil)
    }

    @discardableResult
    func delete() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Nothing stored is the outcome the caller wanted.
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    /// Stated rather than inherited, though it does nothing *here*.
    ///
    /// This store lands in the macOS **file** keychain (the login keychain), and
    /// `kSecAttrAccessible` is a data-protection-keychain concept: the file
    /// keychain accepts the attribute, ignores it, and does not return it —
    /// verified by reading the attributes back, which come out as `cdat`, `class`,
    /// `labl`, `mdat`, `svce` and nothing else. What actually governs access is
    /// the login keychain's own lock state.
    ///
    /// It is set anyway so that a move to `kSecUseDataProtectionKeychain` cannot
    /// silently land an unprotected item. That move is *not* made here: the
    /// two keychains are separate stores, so switching without a migration would
    /// hide every already-saved token and read as "your Shortcut token vanished".
    ///
    /// Not on `baseQuery`: that dictionary is also the *search* query, and an
    /// attribute there would stop matching items written before this was set.
    private let accessibility = kSecAttrAccessibleWhenUnlocked

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}
