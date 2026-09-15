// ABOUTME: Tests the decisions around a new worktree's bootstrap phase.
// ABOUTME: Branch order and reporting only — no actor, no subprocess, no worktree.

@testable import Atelier
import XCTest

final class PhasePolicyTests: XCTestCase {
    /// One shape now: a config is `execution.process-compose.yaml` in the project
    /// directory, and there is nowhere else for one to come from. The fixture
    /// used to come in two — worktree and project directory — because approval
    /// depended on which, and that question went with the worktree tiers.
    private let config = ProcessCompose.Config(path: "/repo/execution.process-compose.yaml")

    private func note(_ plan: PhasePolicy.Plan) -> String? {
        guard case let .nothingToDo(message) = plan else { return nil }
        return message
    }

    // MARK: - Plan

    /// The first guard, since process-compose became a requirement and the
    /// switch that used to precede it was removed. A project that declares no
    /// config is told that, and told the filename, which is the only pointer an
    /// existing project gets after the lookup stopped searching four places.
    func testMissingConfigRunsNothing() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: nil, binary: "/bin/pc")

        XCTAssertEqual(note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan))
    }

    /// A missing binary must never look like a broken worktree — the worktree
    /// exists and works, there was just nothing to run bootstrap with.
    func testMissingBinaryRunsNothing() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: config, binary: nil)

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
    }

    func testBothPreconditionsMetRuns() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: config, binary: "/bin/pc")

        XCTAssertEqual(plan, .run(config: config, binary: "/bin/pc"))
    }

    /// **There is no approval precondition, and this pins that it stays gone.**
    /// It gated a config that could have arrived with a clone; `Config.locate`
    /// reads the project directory and nowhere else, so nothing located here can
    /// have. Putting a gate back without first putting a work-tree tier back in
    /// `locate` would refuse a file the user placed by hand.
    func testNothingIsRefusedForApproval() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: config, binary: "/bin/pc")

        XCTAssertNil(note(plan), String(describing: plan))
    }

    /// `dispose` answers to the same preconditions as `bootstrap` — it is the
    /// same unattended execution — and shares this one implementation of them
    /// rather than an untestable copy in `Workstream.Archiver`. Only the note's
    /// wording differs.
    func testDisposeIsGatedByTheSamePolicy() {
        let plan = PhasePolicy.plan(phase: .dispose, config: config, binary: nil)

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
        XCTAssertEqual(note(plan)?.contains("dispose"), true, String(describing: plan))
    }

    func testDisposeRuns() {
        let plan = PhasePolicy.plan(phase: .dispose, config: config, binary: "/bin/pc")

        XCTAssertEqual(plan, .run(config: config, binary: "/bin/pc"))
    }

    /// The note names the phase that did not run, so a dispose skipped at
    /// archive is not reported as a bootstrap that did not happen.
    func testNotesNameThePhase() {
        let bootstrap = PhasePolicy.plan(phase: .bootstrap, config: nil, binary: nil)
        let dispose = PhasePolicy.plan(phase: .dispose, config: nil, binary: nil)

        XCTAssertEqual(note(bootstrap)?.contains("bootstrap"), true, String(describing: bootstrap))
        XCTAssertEqual(note(dispose)?.contains("dispose"), true, String(describing: dispose))
    }

    /// Guard order. A missing config outranks a missing binary: the config is
    /// what the project controls, and telling a project with neither to install
    /// process-compose would be advice that changes nothing.
    func testMissingConfigOutranksMissingBinary() {
        let plan = PhasePolicy.plan(phase: .bootstrap, config: nil, binary: nil)

        XCTAssertEqual(note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan))
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
