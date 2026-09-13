// ABOUTME: End-to-end test for the Verification tab's live log window.
// ABOUTME: Uses a real process-compose when present; skips cleanly when absent.

@testable import Atelier
import XCTest

/// `Verification.Runner.liveLog` against a real process-compose, because the
/// stub in `VerificationRunnerTests` cannot answer the question this feature
/// turns on: whether a check's output is readable from the control server
/// *while the check is still running*.
///
/// The stub returns whatever fixture it was handed, so it proves the runner's
/// gating — liveness, scope, the client's lifetime — and nothing about the
/// wire. This proves the wire: `up -n verify` binds `<id>-verify.sock`, the
/// server answers `GET /process/logs/<name>/0/<tail>` for a process that has
/// not exited, and the lines grow between reads. All three were assumptions
/// until something ran them.
///
/// Not `@MainActor` at class level: `setUpWithError` and `tearDown` are
/// nonisolated overrides, and isolating the stored properties they write would
/// make every one of those writes a warning. Only the test itself needs the
/// actor, because `Verification.Runner` is `@MainActor`.
final class VerificationLiveLogTests: XCTestCase {
    private var worktree: URL!
    private var projectDir: URL!
    private var binary = ""
    private let workstreamID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let found = ProcessCompose.Settings.searchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("process-compose is not installed")
        }
        binary = found
        worktree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for directory in [worktree!, projectDir!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        // A `verify` run leaves its control server up on purpose — that window
        // is the feature — so a test that spawns one has to end it even when it
        // failed before the run loop's own teardown could.
        ProcessCompose.PhaseExecutor.shutDown(
            binary: binary,
            socketPath: ProcessCompose.PhaseRunner.socketPath(for: workstreamID, phase: .verify),
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        Verification.Store.clear(for: workstreamID)
        try? FileManager.default.removeItem(at: worktree)
        try? FileManager.default.removeItem(at: projectDir)
        super.tearDown()
    }

    /// A check that prints a line a second, read twice while it runs.
    ///
    /// `$$` and not `$`: process-compose runs a command body through envsubst
    /// before the shell sees it, so a single `$` is substituted away at config
    /// load — the trap `PhaseExecutorTests` records, and one that would show up
    /// here as an empty log rather than as a syntax error.
    @MainActor
    func test_liveLog_readsAnUnfinishedCheckFromTheRealControlServer() async throws {
        let path = worktree.appendingPathComponent("process-compose.yaml")
        try """
        version: "0.5"
        processes:
          slow:
            namespace: verify
            command: sh -c 'i=1; while [ $$i -le 6 ]; do echo "line $$i"; i=$$((i+1)); sleep 1; done'
        """.write(to: path, atomically: true, encoding: .utf8)
        let config = ProcessCompose.Config(path: path.path, isRepositoryProvided: false)

        let runner = Verification.Runner()
        let runID = runner.makeRunID()
        runner.seedRunForTesting(workstreamID: workstreamID, runID: runID, checks: ["slow"])
        let request = Verification.Runner.SpawnRequest(
            workstreamID: workstreamID,
            config: config,
            binary: binary,
            projectName: "atelier",
            workstreamName: "verification-processes",
            projectDirectory: projectDir.path,
            worktreePath: worktree.path,
            checks: ["slow"]
        )

        var firstRead: [String]?
        var secondRead: [String]?
        let loop = Task { await runner.execute(request, runID: runID) }

        // Wait for the server to report the check running, which is the moment
        // the window opens. Bounded so a process-compose that never binds fails
        // here rather than hanging the suite.
        let deadline = Date().addingTimeInterval(20)
        while runner.runs[workstreamID]?.checks.first?.state != .running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(
            runner.runs[workstreamID]?.checks.first?.state, .running,
            "the check never reported running, so there was no live window to read"
        )

        // Two reads, a second apart, both while the check is still going: the
        // second must have strictly more than the first, which is the property
        // an expanded group depends on and the one a single read cannot show.
        while firstRead?.isEmpty ?? true, Date() < deadline {
            firstRead = await runner.liveLog(workstreamID: workstreamID, check: "slow")
            if firstRead?.isEmpty ?? true {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        try? await Task.sleep(for: .milliseconds(1500))
        secondRead = await runner.liveLog(workstreamID: workstreamID, check: "slow")

        XCTAssertEqual(firstRead?.first, "line 1")
        XCTAssertGreaterThan(
            secondRead?.count ?? 0, firstRead?.count ?? 0,
            "a live read must pick up lines printed since the last one"
        )

        await loop.value

        // And the same read is nil once the run is over, because the run loop
        // has taken the server down — the fallback every sealed group relies on.
        let afterwards = await runner.liveLog(workstreamID: workstreamID, check: "slow")
        XCTAssertNil(afterwards)
        XCTAssertEqual(runner.runs[workstreamID]?.checks.first?.state, .passed)
    }
}
