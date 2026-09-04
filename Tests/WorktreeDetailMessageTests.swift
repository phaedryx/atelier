// ABOUTME: Tests the worktree detail sheet's mapping from probe availability to prose.
// ABOUTME: The bug these cover collapsed two independent flags into one with AND.

@testable import Atelier
import SwiftUI
import XCTest

/// `WorktreeDetailSheet` decides what to tell the user from two independent flags:
/// whether the uncommitted-changes probe ran, and whether the unmerged-commits
/// probe ran. Collapsing them made the Force Remove confirmation contradict the
/// sheet it was covering — twelve files listed by name above a dialog saying the
/// contents "could not be read". The mapping lives in two static functions so it
/// can be checked here rather than only by eye.
@MainActor
final class WorktreeDetailMessageTests: XCTestCase {
    private func detail(changesUnavailable: Bool, commitsUnavailable: Bool) -> Worktree.Detail {
        Worktree.Detail(
            changes: [],
            unmergedCommits: [],
            changesUnavailable: changesUnavailable,
            unmergedCommitsUnavailable: commitsUnavailable
        )
    }

    /// The regression. Asserts distinctness rather than exact wording: the defect
    /// was two different states producing one message, and pinning the prose would
    /// make this fail on every copy edit instead.
    func testForceRemoveWarningSaysSomethingDifferentForEachCombinationOfProbes() {
        let messages = [
            WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: false, commitsUnavailable: false)),
            WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: true, commitsUnavailable: false)),
            WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: false, commitsUnavailable: true)),
            WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: true, commitsUnavailable: true)),
        ]

        XCTAssertEqual(Set(messages.map { "\($0)" }).count, 4, "each combination has to say what it actually knows")
    }

    /// The specific contradiction that shipped: readable changes plus an unread
    /// commit log used to produce the same "could not be read" sentence as knowing
    /// nothing at all, while the sheet behind it listed every changed file.
    func testAReadableChangeListDoesNotGetTheKnowsNothingWarning() {
        let partiallyKnown = WorktreeDetailSheet.forceRemoveWarning(
            for: detail(changesUnavailable: false, commitsUnavailable: true)
        )
        let knowsNothing = WorktreeDetailSheet.forceRemoveWarning(
            for: detail(changesUnavailable: true, commitsUnavailable: true)
        )

        XCTAssertNotEqual(
            "\(partiallyKnown)",
            "\(knowsNothing)",
            "the changes were read and are on screen; saying otherwise contradicts the sheet"
        )
    }

    /// A worktree whose probes both ran gets the plain, confident sentence — no
    /// hedging on the overwhelmingly common path.
    func testBothProbesRanGetsADifferentWarningFromEveryFailureCase() {
        let known = "\(WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: false, commitsUnavailable: false)))"

        for (changes, commits) in [(true, false), (false, true), (true, true)] {
            let failed = "\(WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: changes, commitsUnavailable: commits)))"
            XCTAssertNotEqual(known, failed, "a failed probe must not borrow the confident wording")
        }
    }

    /// Nothing loaded yet is not the same as both probes having run and found
    /// nothing — Force Remove is reachable from the sheet's action bar while the
    /// detail is still loading.
    func testAnUnloadedDetailDoesNotGetTheConfidentWarning() {
        let loading = "\(WorktreeDetailSheet.forceRemoveWarning(for: nil))"
        let known = "\(WorktreeDetailSheet.forceRemoveWarning(for: detail(changesUnavailable: false, commitsUnavailable: false)))"

        XCTAssertNotEqual(loading, known, "nothing has been established yet, so nothing can be promised")
    }

    /// The in-sheet banner has the same requirement as the alert.
    func testUnavailableMessageNamesWhichProbeFailed() {
        let messages = [
            WorktreeDetailSheet.unavailableMessage(for: detail(changesUnavailable: true, commitsUnavailable: false)),
            WorktreeDetailSheet.unavailableMessage(for: detail(changesUnavailable: false, commitsUnavailable: true)),
            WorktreeDetailSheet.unavailableMessage(for: detail(changesUnavailable: true, commitsUnavailable: true)),
        ]

        XCTAssertEqual(Set(messages.map { "\($0)" }).count, 3, "each failure names what is actually missing")
    }

    /// `unmergedCommitsUnavailable` is set both by an unresolvable base branch and
    /// by `git log` failing outright, so the message must not name either cause and
    /// send the user to investigate the wrong one.
    func testTheUnmergedCommitsMessageDoesNotAssertACauseItCannotKnow() {
        let message = "\(WorktreeDetailSheet.unavailableMessage(for: detail(changesUnavailable: false, commitsUnavailable: true)))"

        XCTAssertFalse(
            message.contains("base branch"),
            "a failed or timed-out `git log` sets this flag too; naming one cause misdirects"
        )
    }
}
