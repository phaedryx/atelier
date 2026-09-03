// ABOUTME: Tests for running a headless process-compose phase to completion.
// ABOUTME: Uses a real process-compose when present; skips cleanly when absent.

@testable import Atelier
import XCTest

final class PhaseExecutorTests: XCTestCase {
    private var dir: URL!
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
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: projectDir)
        try? FileManager.default.removeItem(atPath: ProcessCompose.PhaseRunner.socketPath(for: workstreamID, phase: .bootstrap))
        super.tearDown()
    }

    private func writeConfig(_ body: String) throws -> ProcessCompose.Config {
        let path = dir.appendingPathComponent("process-compose.yaml")
        try body.write(to: path, atomically: true, encoding: .utf8)
        return ProcessCompose.Config(path: path.path, isRepositoryProvided: true, overridePath: nil)
    }

    private func runBootstrap(
        _ config: ProcessCompose.Config,
        environment: [String: String] = [:]
    ) -> ProcessCompose.PhaseExecutor.Outcome {
        ProcessCompose.PhaseExecutor.run(
            phase: .bootstrap,
            config: config,
            binary: binary,
            workstreamID: workstreamID,
            workingDirectory: dir.path,
            environment: environment,
            // Deliberately short. Every config here finishes in seconds, and
            // the production deadline (`Timeout.install`, half an hour) would
            // wedge the suite if one of them ever did not.
            timeout: 60
        )
    }

    /// C1, end to end: the phase's own processes must be able to read the
    /// workstream's variables. They could not — `ProcessCompose.PhaseExecutor` built the child
    /// environment from `ProcessInfo` plus a `PATH` override, so `bootstrap`
    /// and `dispose` saw no `ATELIER_*` and nothing from `ports.yaml`, while
    /// `prepare` and `execute` in a Ghostty surface saw all of it.
    ///
    /// Written with `$$`, not `$`: process-compose runs a command body through
    /// envsubst before the shell sees it, so a single `$` would be substituted
    /// away at config load and the shell would receive an empty string. That is
    /// the failure this test would otherwise have reported as "no environment".
    func testBootstrapProcessesSeeTheWorkstreamEnvironment() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          record:
            namespace: bootstrap
            command: sh -c 'echo "$$ATELIER_WORKTREE_DIR" > seen-dir.txt; echo "$$BFF_PORT" > seen-port.txt'
            availability: { restart: "no" }
        """)

        XCTAssertEqual(
            runBootstrap(config, environment: [
                "ATELIER_WORKTREE_DIR": dir.path,
                "BFF_PORT": "41476",
            ]),
            .succeeded
        )

        let seenDir = try String(contentsOf: dir.appendingPathComponent("seen-dir.txt"), encoding: .utf8)
        let seenPort = try String(contentsOf: dir.appendingPathComponent("seen-port.txt"), encoding: .utf8)
        XCTAssertEqual(seenDir.trimmingCharacters(in: .whitespacesAndNewlines), dir.path)
        XCTAssertEqual(seenPort.trimmingCharacters(in: .whitespacesAndNewlines), "41476")
    }

    /// Succeeding is not just an exit code: the processes must actually have run
    /// in the worktree, so this asserts on the side effect rather than on the
    /// report alone.
    func testSucceedingBootstrapRunsInTheWorktree() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          ok:
            namespace: bootstrap
            command: sh -c 'touch bootstrap-marker'
            availability: { restart: "no" }
        """)

        XCTAssertEqual(runBootstrap(config), .succeeded)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("bootstrap-marker").path),
            "bootstrap must run with the worktree as its working directory"
        )
    }

    /// The only shape that reaches bootstrap in production until config
    /// approval exists: a config the user placed in the project directory,
    /// named with `-f` rather than discovered. It is worth its own test because
    /// it is the one case where the config's directory and the working
    /// directory differ — so the marker landing in the worktree proves the
    /// working directory is inherited rather than taken from the config's
    /// location, which the discovery-style tests cannot distinguish. It also
    /// exercises `-f`, `--keep-project`, and `-n` together.
    func testProjectDirectoryConfigRunsInTheWorktreeNotTheProject() throws {
        let path = projectDir.appendingPathComponent("process-compose.yaml")
        try """
        version: "0.5"
        processes:
          ok:
            namespace: bootstrap
            command: sh -c 'touch bootstrap-marker'
            availability: { restart: "no" }
        """.write(to: path, atomically: true, encoding: .utf8)
        let config = ProcessCompose.Config(path: path.path, isRepositoryProvided: false, overridePath: nil)

        XCTAssertEqual(runBootstrap(config), .succeeded)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("bootstrap-marker").path),
            "bootstrap must run in the worktree"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("bootstrap-marker").path),
            "bootstrap must not run in the project directory"
        )
    }

    /// With `availability.restart: exit_on_failure` the project shuts itself
    /// down and propagates the exit code, so the server is gone before it can
    /// be asked anything — the spawned command's own status is all there is.
    func testFailingBootstrapReportsFailure() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          bad:
            namespace: bootstrap
            command: sh -c 'echo boom >&2; exit 3'
            availability: { restart: "exit_on_failure" }
        """)

        let outcome = runBootstrap(config)
        guard case let .failed(detail) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("boom"), detail)
        // process-compose sets the terminal title even with the TUI off; the
        // escape sequence must not reach a message shown to the user.
        XCTAssertFalse(detail.contains("\u{1B}"), detail)
    }

    /// The case the exit code cannot see. Under the default `restart: "no"`,
    /// `process-compose up` exits 0 even though the process exited 3 — so a
    /// bootstrap whose install failed would look exactly like one that worked.
    /// `--keep-project` holds the control server open past the last process so
    /// the real exit code can be read from the API, which is the only thing
    /// that makes this reportable. If this test ever passes by reporting
    /// success, the failure reporting has silently gone.
    func testFailureWithoutAnExitPolicyIsStillReported() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          installer:
            namespace: bootstrap
            command: sh -c 'exit 3'
            availability: { restart: "no" }
        """)

        let outcome = runBootstrap(config)
        guard case let .failed(detail) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("installer"), detail)
        XCTAssertTrue(detail.contains("3"), detail)
    }

    /// A process whose dependency failed is `Skipped`, which is terminal — the
    /// poll must finish rather than wait out the deadline on it.
    func testFailedDependencyDoesNotStall() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          first:
            namespace: bootstrap
            command: sh -c 'exit 4'
            availability: { restart: "no" }
          second:
            namespace: bootstrap
            command: sh -c 'touch should-not-exist'
            depends_on: { first: { condition: process_completed_successfully } }
            availability: { restart: "no" }
        """)

        let outcome = runBootstrap(config)
        guard case let .failed(detail) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("first"), detail)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("should-not-exist").path)
        )
    }

    /// A config with no processes in the namespace is not an error — most
    /// projects will not use every phase. It must also never be *run*:
    /// `process-compose up -n` on an empty namespace does not exit, it idles
    /// forever, so skipping is what keeps this bounded.
    func testAbsentNamespaceIsSkipped() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          web:
            namespace: execute
            command: sh -c 'exit 0'
        """)

        XCTAssertEqual(runBootstrap(config), .skipped)
    }

    /// A config that predates namespaces entirely declares none, so every phase
    /// is skipped rather than hanging on an empty namespace.
    func testConfigWithNoNamespacesIsSkipped() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          web:
            command: sh -c 'exit 0'
        """)

        XCTAssertEqual(runBootstrap(config), .skipped)
    }

    /// A namespace given as a list is legal process-compose and undecodable by
    /// the Yams shape used to find namespaces, so presence comes back
    /// `.unknown`. The phase runs — refusing would silently skip work a project
    /// may really have declared — and the running project's own answer, zero
    /// processes in the namespace, ends it as a skip. Reporting a timeout here
    /// would blame a project that has no bootstrap at all.
    func testUnparseableConfigWithNoBootstrapIsSkippedNotTimedOut() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          web:
            namespace: [execute, other]
            command: sh -c 'exit 0'
        """)
        XCTAssertEqual(config.namespacePresence("bootstrap"), .unknown)

        let started = Date()
        XCTAssertEqual(runBootstrap(config), .skipped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "must not wait out the deadline")
    }
}

/// How a finished phase is turned into a report. No binary needed, so these run
/// everywhere — including the branch where the poll and the spawned command
/// disagree, which is the one that has been got wrong.
final class PhaseOutcomeReportingTests: XCTestCase {
    private func output(_ status: Int32, _ stdout: String = "") -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data())
    }

    private func outcome(
        _ poll: ProcessCompose.PhaseExecutor.PollResult,
        _ output: ProcessRunner.Output?
    ) -> ProcessCompose.PhaseExecutor.Outcome {
        ProcessCompose.PhaseExecutor.outcome(for: .bootstrap, poll: poll, output: output)
    }

    /// The regression guard. A nil status means `down` did not land inside the
    /// shutdown grace — nothing about the work. The poll watched every process
    /// exit zero, so reporting "did not finish in time" here would call a
    /// bootstrap that demonstrably succeeded a failure.
    func testSlowShutdownDoesNotTurnASuccessIntoATimeout() {
        XCTAssertEqual(outcome(.finished([]), nil), .succeeded)
    }

    func testCleanPollAndCleanCommandSucceeds() {
        XCTAssertEqual(outcome(.finished([]), output(0)), .succeeded)
    }

    /// Every process clean but the command itself refused — an unparseable
    /// config, say. That is still a real failure.
    func testCleanPollWithAFailingCommandIsAFailure() {
        guard case let .failed(detail) = outcome(.finished([]), output(1, "invalid config")) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(detail.contains("invalid config"), detail)
    }

    func testFailedProcessesAreNamedWithTheirCodes() {
        guard case let .failed(detail) = outcome(.finished([("installer", 3)]), nil) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(detail.contains("installer"), detail)
        XCTAssertTrue(detail.contains("3"), detail)
    }

    /// The server went away without answering, so the command's status is the
    /// only evidence there is — and its absence really does mean it was killed.
    func testServerGoneWithNoStatusIsATimeout() {
        guard case let .failed(detail) = outcome(.serverGone, nil) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(detail.contains("did not finish in time"), detail)
    }

    func testServerGoneAfterANonZeroExitIsAFailure() {
        guard case let .failed(detail) = outcome(.serverGone, output(3, "boom")) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(detail.contains("boom"), detail)
    }

    func testServerGoneAfterACleanExitSucceeds() {
        XCTAssertEqual(outcome(.serverGone, output(0)), .succeeded)
    }

    func testEmptyNamespaceIsSkipped() {
        XCTAssertEqual(outcome(.namespaceEmpty, output(0)), .skipped)
    }

    func testTimeoutIsReportedAsOne() {
        guard case let .failed(detail) = outcome(.timedOut, nil) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(detail.contains("did not finish in time"), detail)
    }

    // MARK: - Quit-time server sweep

    /// `shutDown` deletes the socket path whether or not the `down` succeeded,
    /// so the files disappearing is the observable proof that the sweep visited
    /// every one. `/usr/bin/true` stands in for the binary: this asserts the
    /// iteration, not process-compose's behaviour.
    func testStopAllServersVisitsEverySocket() throws {
        ProcessCompose.PhaseRunner.ensureSocketDirectory()
        let directory = ProcessCompose.PhaseRunner.socketDirectory
        let sockets = (0 ..< 3).map { directory.appendingPathComponent("sweep-\($0).sock") }
        let ignored = directory.appendingPathComponent("not-a-socket.txt")
        for url in sockets + [ignored] {
            try Data("x".utf8).write(to: url)
        }
        defer { for url in sockets + [ignored] {
            try? FileManager.default.removeItem(at: url)
        } }

        ProcessCompose.PhaseExecutor.stopAllServers(binary: "/usr/bin/true", timeout: 10)

        for url in sockets {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) should have been swept"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ignored.path),
            "only .sock paths are servers; other files must be left alone"
        )
    }

    func testStopAllServersDoesNothingWithNoSockets() {
        ProcessCompose.PhaseRunner.ensureSocketDirectory()
        let stray = ProcessCompose.PhaseRunner.socketDirectory.appendingPathComponent("keep.txt")
        try? Data("x".utf8).write(to: stray)
        defer { try? FileManager.default.removeItem(at: stray) }

        ProcessCompose.PhaseExecutor.stopAllServers(binary: "/usr/bin/true", timeout: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: - Which stream explains a failure

    private func output(stdout: String, stderr: String) -> ProcessRunner.Output {
        ProcessRunner.Output(
            status: 1,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8)
        )
    }

    /// process-compose relays process output on its own stdout and keeps stderr
    /// for its own diagnostics, so stdout is what explains a failure. This
    /// preferred stderr whenever it was non-empty, which CI caught: a runner
    /// with no process-compose config home logs a debug line to stderr, and the
    /// reported detail became that line instead of the failing command's
    /// output.
    func testTheFailureDetailComesFromStdoutWhenBothStreamsHaveText() {
        let detail = ProcessCompose.PhaseExecutor.detail(from: output(
            stdout: "boom",
            stderr: #"{"level":"debug","message":"Path not found for process compose config home"}"#
        ))

        XCTAssertEqual(detail, "boom")
    }

    /// The fallback still matters: if process-compose itself could not run,
    /// there is no process output and stderr is all there is.
    func testTheFailureDetailFallsBackToStderrWhenStdoutIsEmpty() {
        let detail = ProcessCompose.PhaseExecutor.detail(from: output(stdout: "", stderr: "unknown flag: --nope"))

        XCTAssertEqual(detail, "unknown flag: --nope")
    }
}
