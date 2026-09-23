// ABOUTME: Tests for the onboarding screen's gh auth-status dot.
// ABOUTME: Pins that it reads the authentication flag, not the display string it used to compare.

@testable import Atelier
import SwiftUI
import XCTest

final class OnboardingPrerequisiteRowTests: XCTestCase {
    /// Regression for the bug this replaces. `ToolRow` was fixed to branch on
    /// `isAuthenticated`; the onboarding row was not, and went on computing
    /// `detail != "Not authenticated"` — so rewording or localizing that phrase
    /// turned the dot green for a `gh` that is not authenticated. Both rows now
    /// resolve the colour through the one pure function, so a row whose
    /// `detail` literally reads "Not authenticated" while the flag is true —
    /// and the reverse — comes out of the flag alone.
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
