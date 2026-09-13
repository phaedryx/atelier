// ABOUTME: Tests the decisions around a new worktree's bootstrap phase.
// ABOUTME: Branch order and reporting only — no actor, no subprocess, no worktree.

@testable import Atelier
import XCTest

final class PhasePolicyTests: XCTestCase {
    /// `requiresApproval` is derived from where the loaded file lives, so these
    /// fixtures are the two shapes that differ: one in a worktree (repository
    /// content, gated) and one in the project directory (the user's own, never
    /// gated).
    private let repositoryConfig = ProcessCompose.Config(
        path: "/repo/wt/process-compose.yaml", isRepositoryProvided: true
    )
    private let userConfig = ProcessCompose.Config(
        path: "/repo/process-compose.yaml", isRepositoryProvided: false
    )
    private func note(_ plan: PhasePolicy.Plan) -> String? {
        guard case let .nothingToDo(message) = plan else { return nil }
        return message
    }

    /// Approval stubs. The real check hashes a file on disk; what this suite
    /// covers is which branch the answer is consulted in, not how it is derived.
    private let approved: (ProcessCompose.Config) -> Bool = { _ in true }
    private let unapproved: (ProcessCompose.Config) -> Bool = { _ in false }

    // MARK: - Plan

    /// The first guard, since process-compose became a requirement and the
    /// switch that used to precede it was removed. A project that declares no
    /// config is told that, rather than told an integration is off.
    func testMissingConfigRunsNothing() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: nil, binary: "/bin/pc", isApproved: approved)

        XCTAssertEqual(note(plan)?.contains("no process-compose config"), true, String(describing: plan))
    }

    /// A missing binary must never look like a broken worktree — the worktree
    /// exists and works, there was just nothing to run bootstrap with.
    func testMissingBinaryRunsNothing() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: userConfig, binary: nil, isApproved: approved)

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
    }

    /// Fail closed. `bootstrap` runs repository-provided commands unattended at
    /// worktree creation, which is exactly what `ScriptTrust` gates elsewhere.
    /// Cloning a repository and creating a workstream must not execute its YAML
    /// until the user has read it.
    func testUnapprovedRepositoryProvidedConfigIsRefused() {
        let plan = PhasePolicy.plan(
            phase: .bootstrap, config: repositoryConfig, binary: "/bin/pc", isApproved: unapproved
        )

        XCTAssertEqual(note(plan)?.contains("have not been approved"), true, String(describing: plan))
    }

    /// The other half of the gate. A guard that refuses unconditionally would
    /// pass the test above and make the approval pane do nothing.
    func testApprovedRepositoryProvidedConfigRuns() {
        let plan = PhasePolicy.plan(
            phase: .bootstrap, config: repositoryConfig, binary: "/bin/pc", isApproved: approved
        )

        XCTAssertEqual(plan, .run(config: repositoryConfig, binary: "/bin/pc"))
    }

    /// A config the user placed in the project directory is never asked about,
    /// so the approval check must not even be consulted for it — a store that
    /// answered "false" for everything would otherwise disable it.
    func testUserPlacedConfigIsNotSubjectToApproval() {
        var asked = false
        let plan = PhasePolicy.plan(phase: .bootstrap, config: userConfig, binary: "/bin/pc") { _ in
            asked = true
            return false
        }

        XCTAssertEqual(plan, .run(config: userConfig, binary: "/bin/pc"))
        XCTAssertFalse(asked, "a user-placed config must not be run past the approval store")
    }

    /// `dispose` answers to the same preconditions as `bootstrap` — it is the
    /// same unattended execution of repository-authored processes — and shares
    /// this one implementation of them rather than an untestable copy in
    /// `Workstream.Archiver`. Only the note's wording differs.
    func testDisposeIsGatedByTheSamePolicy() {
        let plan = PhasePolicy.plan(
            phase: .dispose, config: repositoryConfig,
            binary: "/bin/pc", isApproved: unapproved
        )

        XCTAssertEqual(note(plan)?.contains("have not been approved"), true, String(describing: plan))
        XCTAssertEqual(note(plan)?.contains("dispose"), true, String(describing: plan))
    }

    func testApprovedDisposeRuns() {
        let plan = PhasePolicy.plan(
            phase: .dispose, config: repositoryConfig,
            binary: "/bin/pc", isApproved: approved
        )

        XCTAssertEqual(plan, .run(config: repositoryConfig, binary: "/bin/pc"))
    }

    /// The note names the phase that did not run, so a dispose skipped at
    /// archive is not reported as a bootstrap that did not happen.
    func testNotesNameThePhase() {
        let bootstrap = PhasePolicy.plan(
            phase: .bootstrap, config: nil, binary: nil, isApproved: approved
        )
        let dispose = PhasePolicy.plan(
            phase: .dispose, config: nil, binary: nil, isApproved: approved
        )

        XCTAssertEqual(note(bootstrap)?.contains("bootstrap"), true, String(describing: bootstrap))
        XCTAssertEqual(note(dispose)?.contains("dispose"), true, String(describing: dispose))
    }

    /// Guard order. A missing binary outranks a missing approval: nothing can
    /// run without the binary whatever the user approves, and saying so is more
    /// actionable than asking for an approval that would change nothing.
    func testMissingBinaryOutranksMissingApproval() {
        let plan = PhasePolicy.plan(
            phase: .bootstrap, config: repositoryConfig, binary: nil, isApproved: unapproved
        )

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
    }

    /// A config in the project directory sits outside every worktree and outside
    /// git: the user put it there by hand, so there is nothing to approve.
    func testUserPlacedConfigRuns() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: userConfig, binary: "/bin/pc", isApproved: approved)

        XCTAssertEqual(plan, .run(config: userConfig, binary: "/bin/pc"))
    }

    // MARK: - Reporting

    func testSuccessCompletes() {
        XCTAssertEqual(PhasePolicy.state(for: .succeeded), .completed)
    }

    /// "Nothing ran" is neither success nor failure: reporting `.completed`
    /// would claim work that never happened, and `.failed` would claim a broken
    /// worktree.
    func testSkippedIsANoteNotASuccessAndNotAFailure() {
        let state = PhasePolicy.state(for: .skipped)

        guard case let .completedWithNote(message) = state else {
            return XCTFail("expected a note, got \(state)")
        }
        XCTAssertTrue(message.contains("nothing ran"), message)
        XCTAssertNotEqual(state, .completed)
    }

    func testFailureCarriesTheDetail() {
        let state = PhasePolicy.state(for: .failed("installer exited with code 3."))

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
