// ABOUTME: Tests for the initialization step loop: order, halt-on-failure, and what it reports.
// ABOUTME: Pure, so the policy is asserted without spawning anything.

@testable import Atelier
import XCTest

final class InitializationRunTests: XCTestCase {
    private func step(_ name: String) -> Initialization.Config.Step {
        Initialization.Config.Step(name: name, command: "echo \(name)", shell: nil)
    }

    /// Drive the loop with a canned verdict per step name.
    @discardableResult
    private func drive(
        _ names: [String],
        cancelAfter: Int? = nil,
        failing: [String: String] = [:],
        ran: inout [String],
        reported: inout [Initialization.Run.Progress]
    ) -> Initialization.Run.Outcome {
        var completed = 0
        let steps = names.map(step)
        let capturedRan = Box<[String]>([])
        let capturedReported = Box<[Initialization.Run.Progress]>([])
        let outcome = Initialization.Run.drive(
            steps: steps,
            isCancelled: {
                guard let cancelAfter else { return false }
                return completed >= cancelAfter
            },
            report: { capturedReported.value.append($0) },
            execute: { step in
                capturedRan.value.append(step.name)
                completed += 1
                if let detail = failing[step.name] {
                    return .failed(detail: detail)
                }
                return .succeeded
            }
        )
        ran = capturedRan.value
        reported = capturedReported.value
        return outcome
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    // MARK: - Order

    func test_drive_runsStepsInFileOrder() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        let outcome = drive(["zebra", "apple", "middle"], ran: &ran, reported: &reported)
        XCTAssertEqual(ran, ["zebra", "apple", "middle"])
        XCTAssertEqual(outcome, .succeeded(steps: 3))
    }

    func test_drive_withNoSteps_reportsNothingRan() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        let outcome = drive([], ran: &ran, reported: &reported)
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(outcome, .succeeded(steps: 0))
    }

    // MARK: - Halt on failure

    /// The whole reason the loop is sequential rather than independent like
    /// verification's checks: a setup step that fails leaves the ones after it
    /// running against a half-built worktree. `assets` never runs.
    func test_drive_stopsAtTheFirstFailure() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        let outcome = drive(
            ["deps", "migrate", "assets"],
            failing: ["migrate": "bundler exploded"],
            ran: &ran,
            reported: &reported
        )
        XCTAssertEqual(ran, ["deps", "migrate"])
        XCTAssertEqual(outcome, .failed(step: "migrate", detail: "bundler exploded"))
    }

    func test_drive_aFailureNamesTheStepThatFailed() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        let outcome = drive(["only"], failing: ["only": "nope"], ran: &ran, reported: &reported)
        guard case let .failed(step, detail) = outcome else { return XCTFail("expected .failed") }
        XCTAssertEqual(step, "only")
        XCTAssertEqual(detail, "nope")
    }

    // MARK: - Cancellation

    /// A cancelled step's command was killed, so it comes back as a failure.
    /// Only `isCancelled` can tell that from a command that failed on its own,
    /// and reporting a purge as a broken worktree would be a lie about the user's
    /// own action.
    func test_drive_cancellationIsNotReportedAsFailure() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        let outcome = drive(
            ["deps", "migrate", "assets"],
            cancelAfter: 2,
            failing: ["migrate": "killed"],
            ran: &ran,
            reported: &reported
        )
        XCTAssertEqual(ran, ["deps", "migrate"])
        XCTAssertEqual(outcome, .cancelled(step: "migrate"))
    }

    /// Checked before each step too, so a cancel landing between steps does not
    /// start the next command in a worktree that is being removed.
    func test_drive_stopsBeforeStartingTheNextStep() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        let outcome = drive(["deps", "migrate", "assets"], cancelAfter: 1, ran: &ran, reported: &reported)
        XCTAssertEqual(ran, ["deps"])
        XCTAssertEqual(outcome, .cancelled(step: "migrate"))
    }

    // MARK: - Progress

    func test_drive_reportsEveryStepItStarts() {
        var ran: [String] = []
        var reported: [Initialization.Run.Progress] = []
        drive(["deps", "assets"], ran: &ran, reported: &reported)
        XCTAssertEqual(reported.map(\.name), ["deps", "assets"])
        XCTAssertEqual(reported.map(\.position), [1, 2])
        XCTAssertEqual(reported.map(\.total), [2, 2])
    }

    func test_progress_describesItself() {
        let progress = Initialization.Run.Progress(name: "deps", position: 2, total: 4)
        XCTAssertTrue(progress.detail.contains("deps"))
        XCTAssertTrue(progress.detail.contains("2"))
        XCTAssertTrue(progress.detail.contains("4"))
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.001)
    }

    // MARK: - Outcome to state

    func test_state_successIsCompleted() {
        XCTAssertEqual(Initialization.Run.state(for: .succeeded(steps: 3)), .completed)
    }

    /// Neither a success, which would claim work that never happened, nor a
    /// failure, which would claim a broken worktree.
    func test_state_nothingToDoIsANote() {
        XCTAssertEqual(
            Initialization.Run.state(for: .nothingToDo("no file")),
            .completedWithNote("no file")
        )
    }

    func test_state_failureNamesTheStep() {
        guard case let .failed(detail) = Initialization.Run.state(
            for: .failed(step: "migrate", detail: "bundler exploded")
        ) else { return XCTFail("expected .failed") }
        XCTAssertTrue(detail.contains("migrate"))
        XCTAssertTrue(detail.contains("bundler exploded"))
    }

    /// A purge stopped it. The worktree is going away, so this is a note about
    /// what the user did rather than a fault to report.
    func test_state_cancellationIsANoteNotAFailure() {
        guard case let .completedWithNote(note) = Initialization.Run.state(for: .cancelled(step: "deps"))
        else { return XCTFail("expected .completedWithNote") }
        XCTAssertTrue(note.contains("deps"))
    }

    // MARK: - The migration note

    /// A project that still declares a `bootstrap` namespace and has no
    /// initialization.yaml gets nothing at all. Saying so is the difference
    /// between a visible migration and setup that silently stopped happening.
    func test_nothingToDo_namesAStrandedBootstrapNamespace() {
        let note = Initialization.Run.nothingToDoNote(
            load: .missing,
            declaresBootstrapNamespace: true
        )
        XCTAssertTrue(note.contains("bootstrap"))
        XCTAssertTrue(note.contains("initialization.yaml"))
    }

    func test_nothingToDo_withNoStrandedNamespace_usesTheLoadsOwnReason() {
        let note = Initialization.Run.nothingToDoNote(
            load: .missing,
            declaresBootstrapNamespace: false
        )
        XCTAssertEqual(note, Initialization.Config.Load.missing.unavailableReason)
    }

    /// The stranded-namespace note replaces only "there is no file". A file that
    /// is present and broken has its own reason, and that is the one the user
    /// needs — telling them to move their bootstrap steps into a file they have
    /// already written would be advice for the wrong problem.
    func test_nothingToDo_aBrokenFileKeepsItsOwnReason() {
        let note = Initialization.Run.nothingToDoNote(
            load: .invalid(reason: "line 3 is not YAML"),
            declaresBootstrapNamespace: true
        )
        XCTAssertTrue(note.contains("line 3 is not YAML"))
        XCTAssertFalse(note.contains("bootstrap"))
    }
}
