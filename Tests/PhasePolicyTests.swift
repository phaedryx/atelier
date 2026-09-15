// ABOUTME: Tests the decision around the `dispose` phase — its only caller.
// ABOUTME: Branch order only — no actor, no subprocess, no worktree.

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
        let plan = PhasePolicy.plan(phase: .dispose, config: nil, binary: "/bin/pc")

        XCTAssertEqual(note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan))
    }

    /// A missing binary must never look like a broken worktree — the worktree
    /// exists and works, there was just nothing to run dispose with.
    func testMissingBinaryRunsNothing() {
        let plan = PhasePolicy.plan(phase: .dispose, config: config, binary: nil)

        XCTAssertEqual(note(plan)?.contains("was not found"), true, String(describing: plan))
    }

    func testBothPreconditionsMetRuns() {
        let plan = PhasePolicy.plan(phase: .dispose, config: config, binary: "/bin/pc")

        XCTAssertEqual(plan, .run(config: config, binary: "/bin/pc"))
    }

    /// **There is no approval precondition, and this pins that it stays gone.**
    /// It gated a config that could have arrived with a clone; `Config.locate`
    /// reads the project directory and nowhere else, so nothing located here can
    /// have. Putting a gate back without first putting a work-tree tier back in
    /// `locate` would refuse a file the user placed by hand.
    func testNothingIsRefusedForApproval() {
        let plan = PhasePolicy.plan(phase: .dispose, config: config, binary: "/bin/pc")

        XCTAssertNil(note(plan), String(describing: plan))
    }

    /// The note names the phase that did not run. `dispose` is the only caller
    /// left, but the parameter stays because the type does: naming the gate for
    /// its single caller is what invites the next unattended phase to inline a
    /// second copy of it.
    func testNotesNameThePhase() {
        let dispose = PhasePolicy.plan(phase: .dispose, config: nil, binary: nil)
        let prepare = PhasePolicy.plan(phase: .prepare, config: nil, binary: nil)

        XCTAssertEqual(note(dispose)?.contains("dispose"), true, String(describing: dispose))
        XCTAssertEqual(note(prepare)?.contains("prepare"), true, String(describing: prepare))
    }

    /// Guard order. A missing config outranks a missing binary: the config is
    /// what the project controls, and telling a project with neither to install
    /// process-compose would be advice that changes nothing.
    func testMissingConfigOutranksMissingBinary() {
        let plan = PhasePolicy.plan(phase: .dispose, config: nil, binary: nil)

        XCTAssertEqual(note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan))
    }
}
