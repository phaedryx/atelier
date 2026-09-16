// ABOUTME: Tests for the Settings pane's gh auth-status dot.
// ABOUTME: Pins the flag-based color decision against the bug where it was re-derived from the reworded-detail string.

@testable import Atelier
import SwiftUI
import XCTest

final class ToolRowAuthenticationTests: XCTestCase {
    func test_authenticated_isGreen() {
        XCTAssertEqual(ToolRow.authenticationDotColor(isAuthenticated: true), .green)
    }

    func test_notAuthenticated_isOrange() {
        XCTAssertEqual(ToolRow.authenticationDotColor(isAuthenticated: false), .orange)
    }

    /// Regression for the bug this replaces: the dot used to derive from
    /// `detail != "Not authenticated"`, so rewording or localizing that string
    /// silently flipped the dot green for a `gh` that was not authenticated.
    /// A row whose `detail` literally reads "Not authenticated" while
    /// `isAuthenticated` is true — and the reverse — pins that the color now
    /// comes from the flag alone.
    func test_dotColor_ignoresDetailWording_followsFlagInstead() {
        let authenticatedButOldSentinelWording = ToolRow(
            name: "gh",
            status: .found("/usr/bin/gh"),
            detail: "Not authenticated",
            isAuthenticated: true
        )
        XCTAssertEqual(
            ToolRow.authenticationDotColor(isAuthenticated: authenticatedButOldSentinelWording.isAuthenticated),
            .green
        )

        let unauthenticatedButUnrelatedWording = ToolRow(
            name: "gh",
            status: .found("/usr/bin/gh"),
            detail: "some reworded or localized status",
            isAuthenticated: false
        )
        XCTAssertEqual(
            ToolRow.authenticationDotColor(isAuthenticated: unauthenticatedButUnrelatedWording.isAuthenticated),
            .orange
        )
    }
}
