// ABOUTME: Tests the decisions around a new worktree's bootstrap phase.
// ABOUTME: Branch order and reporting only — no actor, no subprocess, no worktree.

@testable import Atelier
import XCTest

final class BootstrapPolicyTests: XCTestCase {
    private let repositoryConfig = ProcessComposeConfig(
        path: "/repo/wt/process-compose.yaml", isRepositoryProvided: true, overridePath: nil
    )
    private let userConfig = ProcessComposeConfig(
        path: "/repo/process-compose.yaml", isRepositoryProvided: false, overridePath: nil
    )

    private func note(_ plan: BootstrapPolicy.Plan) -> String? {
        guard case let .nothingToDo(message) = plan else { return nil }
        return message
    }

    /// Approval stubs. The real check hashes a file on disk; what this suite
    /// covers is which branch the answer is consulted in, not how it is derived.
    private let approved: (ProcessComposeConfig) -> Bool = { _ in true }
    private let unapproved: (ProcessComposeConfig) -> Bool = { _ in false }

    // MARK: - Plan

    func testDisabledIntegrationRunsNothing() {
        let plan = BootstrapPolicy.plan(isEnabled: false, config: userConfig, binary: "/bin/pc", isApproved: approved)

        XCTAssertEqual(note(plan)?.contains("turned off"), true, String(describing: plan))
    }

    /// Checked before the config, so a user who has not turned the integration
    /// on is told that rather than being told their project is missing a file.
    func testDisabledIsReportedEvenWithNoConfig() {
        let plan = BootstrapPolicy.plan(isEnabled: false, config: nil, binary: nil, isApproved: approved)

        XCTAssertEqual(note(plan)?.contains("turned off"), true, String(describing: plan))
    }

    func testMissingConfigRunsNothing() {
        let plan = BootstrapPolicy.plan(isEnabled: true, config: nil, binary: "/bin/pc", isApproved: approved)

        XCTAssertEqual(note(plan)?.contains("no process-compose.yaml"), true, String(describing: plan))
    }

    /// A missing binary must never look like a broken worktree — the worktree
    /// exists and works, there was just nothing to run bootstrap with.
    func testMissingBinaryRunsNothing() {
        let plan = BootstrapPolicy.plan(isEnabled: true, config: userConfig, binary: nil, isApproved: approved)

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
    }

    /// Fail closed. `bootstrap` runs repository-provided commands unattended at
    /// worktree creation, which is exactly what `ScriptTrust` gates elsewhere.
    /// Cloning a repository and creating a workstream must not execute its YAML
    /// until the user has read it.
    func testUnapprovedRepositoryProvidedConfigIsRefused() {
        let plan = BootstrapPolicy.plan(
            isEnabled: true, config: repositoryConfig, binary: "/bin/pc", isApproved: unapproved
        )

        XCTAssertEqual(note(plan)?.contains("has not been approved"), true, String(describing: plan))
    }

    /// The other half of the gate. A guard that refuses unconditionally would
    /// pass the test above and make the approval pane do nothing.
    func testApprovedRepositoryProvidedConfigRuns() {
        let plan = BootstrapPolicy.plan(
            isEnabled: true, config: repositoryConfig, binary: "/bin/pc", isApproved: approved
        )

        XCTAssertEqual(plan, .run(config: repositoryConfig, binary: "/bin/pc"))
    }

    /// A config the user placed in the project directory is never asked about,
    /// so the approval check must not even be consulted for it — a store that
    /// answered "false" for everything would otherwise disable it.
    func testUserPlacedConfigIsNotSubjectToApproval() {
        var asked = false
        let plan = BootstrapPolicy.plan(isEnabled: true, config: userConfig, binary: "/bin/pc") { _ in
            asked = true
            return false
        }

        XCTAssertEqual(plan, .run(config: userConfig, binary: "/bin/pc"))
        XCTAssertFalse(asked, "a user-placed config must not be run past the approval store")
    }

    /// Guard order. A missing binary outranks a missing approval: nothing can
    /// run without the binary whatever the user approves, and saying so is more
    /// actionable than asking for an approval that would change nothing.
    func testMissingBinaryOutranksMissingApproval() {
        let plan = BootstrapPolicy.plan(
            isEnabled: true, config: repositoryConfig, binary: nil, isApproved: unapproved
        )

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
    }

    /// A config in the project directory sits outside every worktree and outside
    /// git: the user put it there by hand, so there is nothing to approve.
    func testUserPlacedConfigRuns() {
        let plan = BootstrapPolicy.plan(isEnabled: true, config: userConfig, binary: "/bin/pc", isApproved: approved)

        XCTAssertEqual(plan, .run(config: userConfig, binary: "/bin/pc"))
    }

    // MARK: - Reporting

    func testSuccessCompletes() {
        XCTAssertEqual(BootstrapPolicy.state(for: .succeeded), .completed)
    }

    /// "Nothing ran" is neither success nor failure: reporting `.completed`
    /// would claim work that never happened, and `.failed` would claim a broken
    /// worktree.
    func testSkippedIsANoteNotASuccessAndNotAFailure() {
        let state = BootstrapPolicy.state(for: .skipped)

        guard case let .completedWithNote(message) = state else {
            return XCTFail("expected a note, got \(state)")
        }
        XCTAssertTrue(message.contains("nothing ran"), message)
        XCTAssertNotEqual(state, .completed)
    }

    func testFailureCarriesTheDetail() {
        let state = BootstrapPolicy.state(for: .failed("installer exited with code 3."))

        guard case let .failed(message) = state else {
            return XCTFail("expected a failure, got \(state)")
        }
        XCTAssertTrue(message.contains("installer exited with code 3."), message)
    }

    /// Two notes with different text are different states. The hand-written
    /// `==` on `AsyncSetupState` has a `default: return false` arm, so a missing
    /// case would compile and quietly compare unequal instead.
    func testNotesCompareByTheirText() {
        XCTAssertEqual(AsyncSetupState.completedWithNote("a"), .completedWithNote("a"))
        XCTAssertNotEqual(AsyncSetupState.completedWithNote("a"), .completedWithNote("b"))
    }
}
