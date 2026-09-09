// ABOUTME: Tests what the "New workstream from GitHub" field accepts.
// ABOUTME: A branch name only — pasted pull-request references are turned away by name.

@testable import Atelier
import XCTest

final class GitHubBranchInputTests: XCTestCase {
    // MARK: - Accepted

    func testAcceptsAPlainBranchName() {
        XCTAssertEqual(try? branch(from: "feat-vscicons-file-tree"), "feat-vscicons-file-tree")
    }

    /// `renovate/*` and `dependabot/*` are the common paste for this field.
    func testAcceptsASlashedBranchName() {
        XCTAssertEqual(try? branch(from: "renovate/swift-format"), "renovate/swift-format")
    }

    /// Copying a branch name out of a web page brings whitespace with it, and a trailing
    /// newline is not a reason to make someone retype the name.
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(try? branch(from: "  feature-work\n"), "feature-work")
    }

    /// A branch really named `82` is legal, and refusing it to guess at a pull-request
    /// number would reject a name origin can resolve. An unknown branch is reported by the
    /// remote lookup instead.
    func testAcceptsAnAllDigitsBranchName() {
        XCTAssertEqual(try? branch(from: "82"), "82")
    }

    // MARK: - Rejected

    func testRejectsEmptyInput() {
        XCTAssertEqual(rejection(for: ""), .empty)
        XCTAssertEqual(rejection(for: "   \n"), .empty)
    }

    /// The unambiguous pull-request pastes. Naming them is what lets the dialog say "this
    /// field wants a branch" rather than "origin has no branch named #82".
    func testRejectsAHashPrefixedPullRequestNumber() {
        XCTAssertEqual(rejection(for: "#82"), .pullRequestReference)
    }

    func testRejectsAPullRequestURL() {
        XCTAssertEqual(
            rejection(for: "https://github.com/phaedryx/atelier/pull/82"),
            .pullRequestReference
        )
    }

    /// GitHub's own copy button omits the scheme often enough to matter.
    func testRejectsASchemelessPullRequestURL() {
        XCTAssertEqual(rejection(for: "github.com/phaedryx/atelier/pull/82"), .pullRequestReference)
    }

    /// Any other URL is not a pull request, but it is not a branch either.
    func testRejectsANonPullRequestURL() {
        XCTAssertEqual(rejection(for: "https://example.com/thing"), .notABranchName)
    }

    func testRejectsANameGitWouldRefuse() {
        XCTAssertEqual(rejection(for: "feat thing"), .notABranchName)
        XCTAssertEqual(rejection(for: "feat..thing"), .notABranchName)
        XCTAssertEqual(rejection(for: "-feat"), .notABranchName)
    }

    // MARK: - Messages

    /// Each rejection carries its own message, so the dialog never has to re-derive one
    /// from the input it just handed over.
    func testEveryRejectionHasAMessage() {
        for rejection in [GitHub.BranchInput.Rejection.empty, .pullRequestReference, .notABranchName] {
            XCTAssertFalse(rejection.message.isEmpty, "\(rejection) has no message")
        }
    }

    // MARK: - Helpers

    private func branch(from raw: String) throws -> String {
        try GitHub.BranchInput.branch(from: raw).get()
    }

    private func rejection(for raw: String) -> GitHub.BranchInput.Rejection? {
        guard case let .failure(rejection) = GitHub.BranchInput.branch(from: raw) else { return nil }
        return rejection
    }
}
