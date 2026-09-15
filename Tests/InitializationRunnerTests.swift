// ABOUTME: End-to-end tests for the initialization runner against a real worktree.
// ABOUTME: Steps really run, so order, halting and cancellation are asserted on disk.

@testable import Atelier
import XCTest

/// The Info tab's Rerun button and the palette's Rerun Initialization both call
/// `Initialization.Runner.run`, and the row above the button reports whatever
/// state comes back. `initializationRow(for: .completed)` pins the copy for a
/// successful rerun; these pin that the states it renders are ones a run can
/// actually reach.
///
/// It matters because `.completed` is unreachable by any other route a user
/// sees. `Initialization.Runner.states` lives in memory, so every workstream
/// reports `.idle` after a relaunch — pressing Rerun is the only way an existing
/// workstream gets a `.completed` back, and if it did not, the button would run
/// the project's real setup and give no sign that it had worked.
///
/// No `XCTSkipIf` and no binary to find, which is the point of the file this
/// replaced needing one: a step is `$SHELL -lc <command>` and nothing else.
final class InitializationRunnerTests: XCTestCase {
    private var worktree: URL!
    private var projectDir: URL!
    private let workstreamID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        worktree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: worktree)
        try? FileManager.default.removeItem(at: projectDir)
        super.tearDown()
    }

    private func writeConfig(_ body: String) throws {
        try body.write(
            to: projectDir.appendingPathComponent("initialization.yaml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: worktree.appendingPathComponent(name).path)
    }

    private func run(_ runner: Initialization.Runner) async {
        await runner.run(
            workstreamID: workstreamID,
            projectName: "proj",
            workstreamName: "ws",
            projectPath: projectDir.path,
            worktreePath: worktree.path
        )
    }

    func test_run_reportsCompletedAndActuallyRunsTheSteps() async throws {
        try writeConfig("""
        first:
          command: touch marker-one
        second:
          command: touch marker-two
        """)
        let runner = Initialization.Runner()
        let before = await runner.state(for: workstreamID)
        XCTAssertEqual(before, .idle, "A workstream nothing has initialized this session")

        await run(runner)

        let after = await runner.state(for: workstreamID)
        XCTAssertEqual(after, .completed)
        XCTAssertTrue(canRerunInitialization(after), "And the button comes back")
        XCTAssertEqual(initializationRow(for: after).detail, "Ran successfully.")
        XCTAssertTrue(exists("marker-one"), "A step has to actually run, not just be reported")
        XCTAssertTrue(exists("marker-two"))
    }

    /// The worktree is the cwd, which is what makes a relative path in a step's
    /// command mean what the project meant.
    func test_run_runsStepsInTheWorktree() async throws {
        try writeConfig("pwd:\n  command: pwd > where\n")
        await run(Initialization.Runner())
        let where_ = try String(contentsOf: worktree.appendingPathComponent("where"), encoding: .utf8)
        XCTAssertEqual(
            URL(fileURLWithPath: where_.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(),
            worktree.resolvingSymlinksInPath()
        )
    }

    /// The reason the loop is sequential and halting: `second` never runs, so it
    /// never sees the half-built worktree `first` left behind.
    func test_run_stopsAtTheFirstFailingStep() async throws {
        try writeConfig("""
        first:
          command: exit 3
        second:
          command: touch marker-two
        """)
        let runner = Initialization.Runner()
        await run(runner)

        let state = await runner.state(for: workstreamID)
        guard case let .failed(detail) = state else { return XCTFail("Expected .failed, got \(state)") }
        XCTAssertTrue(detail.contains("first"), "The row has to name the step that failed")
        XCTAssertFalse(exists("marker-two"), "Nothing after the failure may run")
    }

    /// A step that fails silently still has to say something a user can act on.
    func test_run_aSilentFailureReportsItsExitCode() async throws {
        try writeConfig("quiet:\n  command: exit 7\n")
        let runner = Initialization.Runner()
        await run(runner)
        guard case let .failed(detail) = await runner.state(for: workstreamID) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertTrue(detail.contains("7"), "\(detail)")
    }

    func test_run_quotesTheFailuresOutput() async throws {
        try writeConfig("loud:\n  command: echo 'the widget is missing' >&2; exit 1\n")
        let runner = Initialization.Runner()
        await run(runner)
        guard case let .failed(detail) = await runner.state(for: workstreamID) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertTrue(detail.contains("the widget is missing"), "\(detail)")
    }

    /// Steps see `ATELIER_*` and everything `ports.yaml` declares, the same set
    /// the worktree's terminals get. Without it a step runs under a different
    /// environment from every other thing the project can run.
    func test_run_stepsSeeTheWorkstreamEnvironment() async throws {
        try writeConfig("env:\n  command: printf '%s' \"$ATELIER_WORKSTREAM\" > ws-name\n")
        await run(Initialization.Runner())
        let name = try String(contentsOf: worktree.appendingPathComponent("ws-name"), encoding: .utf8)
        XCTAssertEqual(name, "ws")
    }

    /// The other half of what the Info row promises: a run that can do nothing
    /// says why, rather than failing or reporting a success it did not have.
    /// This is the shape a user hits by pressing Rerun with no file at all.
    func test_run_withNoConfigReportsANote() async {
        let runner = Initialization.Runner()
        await run(runner)

        let state = await runner.state(for: workstreamID)
        guard case let .completedWithNote(note) = state else {
            return XCTFail("Expected a note, got \(state)")
        }
        XCTAssertEqual(initializationRow(for: state).detail, note)
        XCTAssertTrue(canRerunInitialization(state))
    }

    /// A file Atelier cannot read must not render as "this project declares no
    /// setup" — the same sentence a project with genuinely none gets.
    func test_run_withABrokenConfigSaysSo() async throws {
        try writeConfig("deps:\n  command: [\n")
        let runner = Initialization.Runner()
        await run(runner)
        guard case let .completedWithNote(note) = await runner.state(for: workstreamID) else {
            return XCTFail("Expected a note")
        }
        XCTAssertTrue(note.contains("could not be read"), "\(note)")
    }

    /// A project that never migrated its `bootstrap` namespace now gets no setup
    /// at all, and every other symptom of that is silence.
    func test_run_namesAStrandedBootstrapNamespace() async throws {
        try """
        version: "0.5"
        processes:
          deps:
            namespace: bootstrap
            command: echo hi
        """.write(
            to: projectDir.appendingPathComponent("process-compose.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let runner = Initialization.Runner()
        await run(runner)
        guard case let .completedWithNote(note) = await runner.state(for: workstreamID) else {
            return XCTFail("Expected a note")
        }
        XCTAssertTrue(note.contains("bootstrap"), "\(note)")
        XCTAssertTrue(note.contains("initialization.yaml"), "\(note)")
    }

    /// **Progress must not outlive the run it describes.** Reporting each step
    /// with its own detached `Task` left the last `.inProgress` racing the final
    /// `updateState`, so a run that succeeded could land back on
    /// "Running “second” (2 of 2)" and stay there — the Info row is the only
    /// surface initialization has, so a stuck row is the whole report being
    /// wrong. It also reported to `Runner.shared` rather than to the instance
    /// that was running, which is what this asserts by using neither.
    func test_run_finalStateSurvivesTheLastProgressReport() async throws {
        try writeConfig("""
        first:
          command: true
        second:
          command: true
        """)
        let runner = Initialization.Runner()
        await run(runner)

        // Read immediately and again after a beat: a late progress update would
        // land in the gap between them.
        let immediately = await runner.state(for: workstreamID)
        XCTAssertEqual(immediately, .completed)
        try await Task.sleep(nanoseconds: 200_000_000)
        let later = await runner.state(for: workstreamID)
        XCTAssertEqual(later, .completed, "A progress update must not arrive after the run has finished")
    }

    // MARK: - Cancellation

    func test_cancel_reportsThatNothingWasRunning() async {
        let runner = Initialization.Runner()
        let outcome = await runner.cancel(for: UUID(), worktreePath: "/tmp/does-not-matter")
        XCTAssertEqual(outcome, .notRunning)
    }

    /// The poll used `try? await Task.sleep`, which swallows `CancellationError`:
    /// a cancelled task made every sleep return instantly and the loop spun
    /// through all 300 iterations as fast as the CPU allowed.
    func test_cancel_stopsPollingWhenTheTaskIsCancelled() async {
        let runner = Initialization.Runner()
        let id = UUID()
        await runner._markRunning(id)

        let started = Date()
        let task = Task {
            await runner.cancel(for: id, worktreePath: "/tmp/does-not-matter")
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled, "A cancelled wait must stop, not spin out its 300 iterations")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// What a purge depends on: the running step's command is killed, the run
    /// lets go, and nothing after it starts in a worktree about to be removed.
    /// Reported as a note rather than a failure, because the user asked for it.
    func test_cancel_killsTheRunningStepAndStopsTheRest() async throws {
        try writeConfig("""
        slow:
          command: sleep 120
        after:
          command: touch marker-after
        """)
        let runner = Initialization.Runner()
        // Inlined rather than through `run`, and with the paths copied out: that
        // helper is a method on the test case, so a `Task` calling it would send
        // `self` across an isolation boundary.
        let id = workstreamID
        let project = projectDir.path
        let tree = worktree.path
        let running = Task {
            await runner.run(
                workstreamID: id, projectName: "proj", workstreamName: "ws",
                projectPath: project, worktreePath: tree
            )
        }

        // Wait for the step to be in flight, rather than sleeping a guessed
        // interval: `cancel` answers `.notRunning` before `run` has claimed it.
        var outcome: Initialization.Runner.CancelOutcome = .notRunning
        let started = Date()
        while Date().timeIntervalSince(started) < 10 {
            outcome = await runner.cancel(for: workstreamID, worktreePath: worktree.path)
            if outcome != .notRunning {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await running.value

        XCTAssertEqual(outcome, .stopped)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 30,
            "The step's own deadline is half an hour; cancelling must not wait for it"
        )
        XCTAssertFalse(exists("marker-after"), "Nothing may start after a cancel")
        guard case let .completedWithNote(note) = await runner.state(for: workstreamID) else {
            return XCTFail("A cancelled run is a note, not a failure")
        }
        XCTAssertTrue(note.contains("slow"), "\(note)")
    }

    /// Two concurrent runs would execute the project's setup twice over one
    /// directory. Reachable from `.workstreamWorktreeReady` landing while a
    /// manual rerun is in flight.
    func test_run_ignoresASecondRunForTheSameWorkstream() async throws {
        try writeConfig("count:\n  command: echo x >> counter\n")
        let runner = Initialization.Runner()
        let id = workstreamID
        let project = projectDir.path
        let tree = worktree.path
        func go() async {
            await runner.run(
                workstreamID: id, projectName: "proj", workstreamName: "ws",
                projectPath: project, worktreePath: tree
            )
        }
        async let first: Void = go()
        async let second: Void = go()
        _ = await (first, second)

        let counter = try String(contentsOf: worktree.appendingPathComponent("counter"), encoding: .utf8)
        XCTAssertEqual(
            counter.split(separator: "\n").count, 1,
            "The second run has to be ignored, not queued behind the first"
        )
    }
}
