// ABOUTME: Tests for the onboarding screen's gh auth-status dot.
// ABOUTME: Pins that it reads the authentication flag, not the display string it used to compare.

@testable import Atelier
import SwiftUI
import XCTest

final class OnboardingPrerequisiteRowTests: XCTestCase {
    /// Regression for the bug this replaces. `ToolRow` was fixed to branch on
    /// `isAuthenticated`; the onboarding row was not, and went on computing
    /// `detail != "Not authenticated"` — so rewording or localizing that phrase
    /// turned the dot green for a `gh` that is not authenticated.
    ///
    /// What this pins is narrow, and worth stating rather than overclaiming:
    /// that the row *carries* the flag independently of the wording of
    /// `detail`. What actually keeps the two rows from diverging again is
    /// structural — the body resolves the colour through the one shared
    /// `ToolRow.authenticationDotColor` instead of deciding for itself — and a
    /// body that went back to comparing the string would still pass here.
    /// Pinning that would need to inspect the rendered view, which this suite
    /// has no way to do.
    func test_dotColor_ignoresDetailWording_followsFlagInstead() {
        let authenticatedButOldSentinelWording = PrerequisiteRow(
            name: "gh",
            status: .found("/usr/bin/gh"),
            detail: "Not authenticated",
            isAuthenticated: true
        )
        XCTAssertEqual(
            ToolRow.authenticationDotColor(
                isAuthenticated: authenticatedButOldSentinelWording.isAuthenticated
            ),
            .green
        )

        let unauthenticatedButUnrelatedWording = PrerequisiteRow(
            name: "gh",
            status: .found("/usr/bin/gh"),
            detail: "some reworded or localized status",
            isAuthenticated: false
        )
        XCTAssertEqual(
            ToolRow.authenticationDotColor(
                isAuthenticated: unauthenticatedButUnrelatedWording.isAuthenticated
            ),
            .orange
        )
    }

    /// A row that was never handed the flag must not read as authenticated.
    func test_isAuthenticated_defaultsToFalse() {
        let row = PrerequisiteRow(name: "gh", status: .found("/usr/bin/gh"), detail: "whatever")
        XCTAssertFalse(row.isAuthenticated)
        XCTAssertEqual(ToolRow.authenticationDotColor(isAuthenticated: row.isAuthenticated), .orange)
    }
}
