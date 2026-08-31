// ABOUTME: Tests for KeychainTokenStore, which holds the Shortcut API token.
// ABOUTME: Uses a per-run service name so it never touches the real stored token.

@testable import Atelier
import XCTest

final class KeychainTokenStoreTests: XCTestCase {
    private var store: KeychainTokenStore!

    override func setUp() {
        super.setUp()
        // A unique service keeps these tests off the account's real Shortcut token
        // and keeps parallel runs from clobbering each other.
        store = KeychainTokenStore(service: "com.github.phaedryx.atelier.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        store.delete()
        store = nil
        super.tearDown()
    }

    func testReadReturnsNilWhenNothingStored() {
        XCTAssertNil(store.read())
    }

    func testStoreThenRead() {
        store.write("secret-token")
        XCTAssertEqual(store.read(), "secret-token")
    }

    func testWriteOverwritesExistingToken() {
        store.write("first")
        store.write("second")
        XCTAssertEqual(store.read(), "second", "a second write must replace, not duplicate or fail")
    }

    func testDeleteRemovesToken() {
        store.write("secret-token")
        store.delete()
        XCTAssertNil(store.read())
    }

    func testDeleteIsIdempotent() {
        store.delete()
        store.delete()
        XCTAssertNil(store.read())
    }

    func testWritingEmptyStringClearsToken() {
        // The settings field is a SecureField; clearing it should read as "no token"
        // rather than storing an empty credential the client would send as a header.
        store.write("secret-token")
        store.write("")
        XCTAssertNil(store.read())
    }

    func testWriteReportsSuccess() {
        // The status is the only signal a locked keychain or a denied prompt gives; a
        // discarded one looks exactly like a save that worked.
        XCTAssertEqual(store.write("secret-token"), errSecSuccess)
        XCTAssertEqual(store.write("replacement"), errSecSuccess, "update path must also report success")
    }

    func testDeleteOfAMissingItemReportsSuccess() {
        // Nothing stored is the outcome the caller asked for, so it is not a failure.
        XCTAssertEqual(store.delete(), errSecSuccess)
    }

    func testHasTokenReflectsStoredState() {
        XCTAssertFalse(store.hasToken)
        store.write("secret-token")
        XCTAssertTrue(store.hasToken)
        store.delete()
        XCTAssertFalse(store.hasToken)
    }
}
