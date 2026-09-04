// ABOUTME: Tests for Git.Operations.isValidBranchName.
// ABOUTME: Validates git check-ref-format rules used by the workstream naming dialog.

@testable import Atelier
import XCTest

final class BranchNameValidationTests: XCTestCase {
    func testValidBranchNames() {
        let valid = [
            "merge-quick-pipe",
            "feat/foo",
            "fix-bug-123",
            "feature.one",
            "main",
            "a/b/c",
            "v1.2.3",
        ]
        for name in valid {
            XCTAssertTrue(Git.Operations.isValidBranchName(name), "expected \(name) to be valid")
        }
    }

    func testEmptyNameIsInvalid() {
        XCTAssertFalse(Git.Operations.isValidBranchName(""))
        XCTAssertFalse(Git.Operations.isValidBranchName("   "))
    }

    func testRejectsForbiddenCharacters() {
        let invalid = [
            "has space",
            "tilde~name",
            "caret^name",
            "colon:name",
            "question?name",
            "star*name",
            "bracket[name",
            "backslash\\name",
        ]
        for name in invalid {
            XCTAssertFalse(Git.Operations.isValidBranchName(name), "expected \(name) to be invalid")
        }
    }

    func testRejectsSequences() {
        let invalid = [
            "dotdot..name",
            "at@{name",
            "double//slash",
        ]
        for name in invalid {
            XCTAssertFalse(Git.Operations.isValidBranchName(name), "expected \(name) to be invalid")
        }
    }

    /// `"double//slash"` above is rejected, but on its own that is also what a rule
    /// banning slashes outright would do — and slashes are how every branch here is
    /// named. The contrast belongs next to the rejection rather than inferred from
    /// `testValidBranchNames` in another test.
    func testRejectsAnEmptyPathComponentWithoutRejectingSlashes() {
        XCTAssertTrue(Git.Operations.isValidBranchName("feature/one"))
        XCTAssertFalse(Git.Operations.isValidBranchName("feature//one"))
    }

    func testRejectsLeadingHyphenAndTrailingPunctuation() {
        XCTAssertFalse(Git.Operations.isValidBranchName("-leading"))
        XCTAssertFalse(Git.Operations.isValidBranchName("trailing."))
        XCTAssertFalse(Git.Operations.isValidBranchName("trailing/"))
        XCTAssertFalse(Git.Operations.isValidBranchName("ends.lock"))
    }

    func testRejectsControlCharacters() {
        XCTAssertFalse(Git.Operations.isValidBranchName("new\nline"))
        XCTAssertFalse(Git.Operations.isValidBranchName("tab\tname"))
    }
}
