// ABOUTME: Tests the gating that decides whether the Shortcut button appears on a project row.
// ABOUTME: Three independent conditions, so each one is covered failing on its own.

@testable import Atelier
import XCTest

final class ShortcutSettingsTests: XCTestCase {
    func testShownWhenRepoAndTokenAndToggleOn() {
        XCTAssertTrue(ShortcutSettings.shouldShowButton(isGitRepo: true, toggleEnabled: true, hasToken: true))
    }

    func testHiddenWhenToggleOffDespiteValidToken() {
        // The toggle exists so someone with a working key can still hide the button.
        XCTAssertFalse(ShortcutSettings.shouldShowButton(isGitRepo: true, toggleEnabled: false, hasToken: true))
    }

    func testHiddenWhenNoTokenDespiteToggleOn() {
        XCTAssertFalse(ShortcutSettings.shouldShowButton(isGitRepo: true, toggleEnabled: true, hasToken: false))
    }

    func testHiddenOutsideAGitRepo() {
        // Matches the existing gate on the "+" button: a non-repo cannot take a worktree.
        XCTAssertFalse(ShortcutSettings.shouldShowButton(isGitRepo: false, toggleEnabled: true, hasToken: true))
    }

    func testKeyNamesAreStable() {
        // Persisted in UserDefaults; renaming silently resets the user's choice.
        XCTAssertEqual(ShortcutSettings.buttonEnabledKey, "atelier.shortcutButtonEnabled")
    }
}
