// ABOUTME: Tests the runner's refusals, its independence per check, and its completion pass.
// ABOUTME: Surfaces are stubbed; the wrapper's two state files are real, because they are the evidence.

@testable import Atelier
import XCTest

/// Stands in for `TerminalSurfaceCache`. Records what it was asked to start so a
/// test can assert on the command without a Ghostty app, and can refuse — which is
/// the one failure the runner has to report rather than swallow.
@MainActor
private final class StubSurfaceHost: Verification.SurfaceHosting {
    struct Started: Equatable {
        let id: UUID
        let command: String
        let workingDirectory: String
        let environment: [String: String]
    }

    private(set) var started: [Started] = []
    private(set) var disposed: [UUID] = []
    var refuse = false

    func startSurface(
        id: UUID, command: String, workingDirectory: String, environment: [String: String]
    ) -> Bool {
        guard !refuse else { return false }
        started.append(Started(
            id: id, command: command, workingDirectory: workingDirectory, environment: environment
        ))
        return true
    }

    func disposeSurface(id: UUID) {
        disposed.append(id)
    }
}

@MainActor
final class VerificationRunnerTests: XCTestCase {
    private var projectDirectory: URL!
    private var worktree: URL!
    private let workstreamID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-runner-" + UUID().uuidString)
        projectDirectory = base.appendingPathComponent("project")
        worktree = base.appendingPathComponent("project/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Verification.CheckStore.clear(for: workstreamID)
        try? FileManager.default.removeItem(at: projectDirectory.deletingLastPathComponent())
        super.tearDown()
    }

    private func writeConfig(_ yaml: String = """
    rspec:
      command: echo rspec
    rubocop:
      command: echo rubocop
    """) throws {
        try yaml.write(
            toFile: projectDirectory.appendingPathComponent("verification.yaml").path,
            atomically: true, encoding: .utf8
        )
    }

    @discardableResult
    private func start(
        _ runner: Verification.Runner, checks: [String]?
    ) throws -> Verification.Run {
        try runner.start(
            workstreamID: workstreamID,
            projectName: "app",
            workstreamName: "wry-amber-lexer",
            worktreePath: worktree.path,
            projectDirectory: projectDirectory.path,
            defaultBranch: "main",
            checks: checks
        )
    }

    private func makeRunner(_ host: StubSurfaceHost) -> Verification.Runner {
        // A fixed fingerprint rather than four git spawns against a directory that
        // is not a repository.
        let runner = Verification.Runner(
            fingerprint: { _, _ in "head|1|digest" }, pollInterval: .milliseconds(10)
        )
        runner.attach(surfaces: host)
        return runner
    }

    // MARK: - Refusals

    /// The runner performs the same load the tab's empty state is drawn from, so
    /// the two cannot disagree about what can run.
    func test_start_refusesWhenThereIsNoConfig() {
        let runner = makeRunner(StubSurfaceHost())

        XCTAssertThrowsError(try start(runner, checks: nil)) { error in
            guard case Verification.Runner.Failure.unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }

    func test_start_refusesACheckTheConfigDoesNotDeclare() throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())

        XCTAssertThrowsError(try start(runner, checks: ["vitest"])) { error in
            guard case let Verification.Runner.Failure.unknownChecks(names, valid) = error else {
                return XCTFail("expected .unknownChecks, got \(error)")
            }
            XCTAssertEqual(names, ["vitest"])
            XCTAssertEqual(valid, ["rspec", "rubocop"], "the refusal names what it could have run")
        }
    }

    /// Per check, never per workstream: two *different* checks starting at once is
    /// the design, and only a second copy of the same one is refused.
    func test_start_refusesACheckThatIsAlreadyRunning() throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())
        try start(runner, checks: ["rspec"])

        XCTAssertThrowsError(try start(runner, checks: ["rspec"])) { error in
            guard case let Verification.Runner.Failure.alreadyRunning(name) = error else {
                return XCTFail("expected .alreadyRunning, got \(error)")
            }
            XCTAssertEqual(name, "rspec")
        }
        XCTAssertNoThrow(try start(runner, checks: ["rubocop"]), "a different check is not blocked")
    }

    /// **A check with no terminal never runs**, so a host that cannot make one is
    /// reported rather than swallowed — a silent no-op reads on the row as a check
    /// that passed instantly.
    func test_start_reportsASurfaceThatCouldNotBeCreated() throws {
        try writeConfig()
        let host = StubSurfaceHost()
        host.refuse = true
        let runner = makeRunner(host)

        XCTAssertThrowsError(try start(runner, checks: ["rspec"])) { error in
            guard case Verification.Runner.Failure.noSurface = error else {
                return XCTFail("expected .noSurface, got \(error)")
            }
        }
        XCTAssertFalse(runner.isRunning(workstreamID, check: "rspec"), "nothing started, so nothing is running")
    }

    // MARK: - Starting

    func test_start_withNoNamesRunsEveryDeclaredCheck() throws {
        try writeConfig()
        let host = StubSurfaceHost()
        let runner = makeRunner(host)

        let run = try start(runner, checks: nil)

        XCTAssertEqual(run.checks.map(\.name), ["rspec", "rubocop"], "in file order")
        XCTAssertEqual(host.started.count, 2)
        XCTAssertTrue(runner.isLive(workstreamID))
    }

    /// Each check gets its own surface, and the id is the derived one — which is
    /// what lets the row find the terminal again on every rebuild.
    func test_start_givesEachCheckItsOwnDerivedSurface() throws {
        try writeConfig()
        let host = StubSurfaceHost()
        let runner = makeRunner(host)

        try start(runner, checks: nil)

        XCTAssertEqual(
            host.started.map(\.id),
            ["rspec", "rubocop"].map {
                Verification.Spawn.surfaceID(for: workstreamID, check: $0)
            }
        )
        XCTAssertEqual(runner.surfaceID(workstreamID, check: "rspec"), host.started.first?.id)
    }

    /// The worktree is cwd, and the workstream's own variables reach the check —
    /// the same set every other phase sees, so one project's commands do not run
    /// under two different environments depending on where they were started.
    func test_start_runsInTheWorktreeWithTheWorkstreamsEnvironment() throws {
        try writeConfig()
        let host = StubSurfaceHost()
        let runner = makeRunner(host)

        try start(runner, checks: ["rspec"])

        let started = try XCTUnwrap(host.started.first)
        XCTAssertEqual(started.workingDirectory, worktree.path)
        XCTAssertEqual(started.environment["ATELIER_DEFAULT_BRANCH"], "main")
        XCTAssertNotNil(started.environment["ATELIER_PROJECT_DIR"])
    }

    /// Two checks at once is the whole point of the redesign: independent
    /// processes, independent surfaces, independent stops.
    func test_start_runsTwoChecksConcurrently() throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())

        try start(runner, checks: ["rspec"])
        try start(runner, checks: ["rubocop"])

        XCTAssertTrue(runner.isRunning(workstreamID, check: "rspec"))
        XCTAssertTrue(runner.isRunning(workstreamID, check: "rubocop"))
    }

    // MARK: - Completion

    /// The wrapper's status file is the verdict, and the completion pass reads the
    /// same evidence production does.
    func test_completionPass_recordsAPassFromTheStatusFile() async throws {
        try writeConfig()
        let host = StubSurfaceHost()
        let runner = makeRunner(host)
        try start(runner, checks: ["rspec"])
        let spawn = Verification.Spawn.build(
            check: Verification.Config.Check(name: "rspec", command: "echo rspec", shell: nil),
            workstreamID: workstreamID
        )
        addTeardownBlock { spawn.clearState() }

        try "0\n".write(toFile: spawn.statusPath, atomically: true, encoding: .utf8)
        await runner.completionPass()

        XCTAssertEqual(runner.state(workstreamID, check: "rspec"), .passed)
        XCTAssertFalse(runner.isRunning(workstreamID, check: "rspec"))
    }

    func test_completionPass_recordsTheExitCodeOfAFailure() async throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())
        try start(runner, checks: ["rspec"])
        let spawn = Verification.Spawn.build(
            check: Verification.Config.Check(name: "rspec", command: "echo rspec", shell: nil),
            workstreamID: workstreamID
        )
        addTeardownBlock { spawn.clearState() }

        try "3\n".write(toFile: spawn.statusPath, atomically: true, encoding: .utf8)
        await runner.completionPass()

        XCTAssertEqual(runner.state(workstreamID, check: "rspec"), .failed(3))
    }

    /// **A check with no pid file yet is starting, never finished.** Reading a
    /// missing pid as "gone" would record every check as finished the instant the
    /// first pass looked at it, before it had run anything — and silently, since
    /// the row would simply show a verdict.
    func test_completionPass_leavesACheckThatHasNotWrittenItsPIDAlone() async throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())
        try start(runner, checks: ["rspec"])

        await runner.completionPass()

        XCTAssertTrue(
            runner.isRunning(workstreamID, check: "rspec"),
            "a check still starting must not be recorded as finished"
        )
        XCTAssertEqual(runner.state(workstreamID, check: "rspec"), .running)
    }

    /// One check finishing says nothing about another.
    func test_completionPass_finishesOneCheckAndLeavesTheOtherRunning() async throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())
        try start(runner, checks: nil)
        let spawn = Verification.Spawn.build(
            check: Verification.Config.Check(name: "rspec", command: "echo rspec", shell: nil),
            workstreamID: workstreamID
        )
        addTeardownBlock { spawn.clearState() }

        try "0\n".write(toFile: spawn.statusPath, atomically: true, encoding: .utf8)
        await runner.completionPass()

        XCTAssertEqual(runner.state(workstreamID, check: "rspec"), .passed)
        XCTAssertTrue(runner.isRunning(workstreamID, check: "rubocop"))
        XCTAssertTrue(runner.isLive(workstreamID), "the workstream is live while any check is")
    }

    /// The record is what survives the process that produced it, and what a row
    /// reads after a relaunch.
    func test_completionPass_persistsTheRecord() async throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())
        try start(runner, checks: ["rspec"])
        let spawn = Verification.Spawn.build(
            check: Verification.Config.Check(name: "rspec", command: "echo rspec", shell: nil),
            workstreamID: workstreamID
        )
        addTeardownBlock { spawn.clearState() }

        try "0\n".write(toFile: spawn.statusPath, atomically: true, encoding: .utf8)
        await runner.completionPass()

        let stored = Verification.CheckStore.records(for: workstreamID)
        XCTAssertEqual(stored["rspec"]?.state, .passed)
        XCTAssertEqual(stored["rspec"]?.stamp, "head|1|digest", "the staleness baseline rides with the record")
        XCTAssertNotNil(stored["rspec"]?.duration)
    }

    /// A re-run must not inherit the last run's verdict: the status file is the
    /// completion signal, so a stale one reads as this run finishing instantly.
    func test_start_clearsAPreviousRunsStatusBeforeStarting() async throws {
        try writeConfig()
        let runner = makeRunner(StubSurfaceHost())
        let spawn = Verification.Spawn.build(
            check: Verification.Config.Check(name: "rspec", command: "echo rspec", shell: nil),
            workstreamID: workstreamID
        )
        addTeardownBlock { spawn.clearState() }
        Verification.Spawn.ensureStateDirectory()
        try "1\n".write(toFile: spawn.statusPath, atomically: true, encoding: .utf8)

        try start(runner, checks: ["rspec"])
        await runner.completionPass()

        XCTAssertTrue(
            runner.isRunning(workstreamID, check: "rspec"),
            "the previous run's verdict must not end this one"
        )
    }

    // MARK: - Forgetting

    /// A check surface is not reachable by `removeWorktreeSurfaces`, so this is the
    /// only thing that drops it — on both archive paths.
    func test_forget_disposesEveryCheckSurface() throws {
        try writeConfig()
        let host = StubSurfaceHost()
        let runner = makeRunner(host)
        try start(runner, checks: nil)

        runner.forget(workstreamID: workstreamID)

        XCTAssertEqual(Set(host.disposed), Set(host.started.map(\.id)))
        XCTAssertFalse(runner.isLive(workstreamID))
        XCTAssertTrue(runner.records(for: workstreamID).isEmpty)
    }
}

/// `verificationRowAction` is a pure function, so the whole state table is
/// assertable without a view. The table is the spec: never-run → Run, running →
/// Stop, completed → Re-run, stopped → back to Run.
final class VerificationRowActionTests: XCTestCase {
    func test_aCheckThatHasNeverRunOffersRun() {
        XCTAssertEqual(verificationRowAction(isRunning: false, recordedState: nil), .run)
        XCTAssertEqual(verificationRowAction(isRunning: false, recordedState: .notRun), .run)
    }

    func test_aRunningCheckOffersStop() {
        XCTAssertEqual(verificationRowAction(isRunning: true, recordedState: nil), .stop)
        // Running wins over whatever the last run recorded: a re-run in flight is
        // stoppable, not re-runnable.
        XCTAssertEqual(verificationRowAction(isRunning: true, recordedState: .passed), .stop)
        XCTAssertEqual(verificationRowAction(isRunning: true, recordedState: .failed(1)), .stop)
    }

    func test_aCheckThatProducedAVerdictOffersRerun() {
        XCTAssertEqual(verificationRowAction(isRunning: false, recordedState: .passed), .rerun)
        XCTAssertEqual(verificationRowAction(isRunning: false, recordedState: .failed(2)), .rerun)
        XCTAssertEqual(verificationRowAction(isRunning: false, recordedState: .skipped), .rerun)
    }

    /// **The branch a reader would get wrong.** A stop *does* record a result, so
    /// "has a record" alone would say Re-run — but a stop is the user deciding this
    /// check should not have run, so the honest next offer is the one an untouched
    /// check gets.
    func test_aStoppedCheckGoesBackToRunRatherThanRerun() {
        XCTAssertEqual(verificationRowAction(isRunning: false, recordedState: .stopped), .run)
    }
}
