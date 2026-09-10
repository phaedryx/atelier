// ABOUTME: Tests for the verification runner: its gate, its refusals, sealing, and the run loop.
// ABOUTME: A stub spawner stands in for process-compose so the loop's ordering is reachable offline.

@testable import Atelier
import XCTest

@MainActor
final class VerificationRunnerTests: XCTestCase {
    /// The same helper `VerificationResultTests` uses. Kept local rather than
    /// shared: it is three lines, and a shared fixture between two test files
    /// that assert on different things is a coupling neither needs.
    private func entry(
        _ name: String, status: String, isRunning: Bool, exitCode: Int
    ) -> ProcessCompose.ProcessEntry {
        ProcessCompose.ProcessEntry(
            name: name, namespace: "verify", status: status, isReady: "",
            hasReadyProbe: false, restarts: 0, exitCode: exitCode,
            pid: 0, isRunning: isRunning
        )
    }

    /// resolveChecks is pure, so every refusal branch is testable without a
    /// config, a binary, or a subprocess.
    func test_resolveChecks_emptyMeansAll() throws {
        let resolved = try Verification.Runner
            .resolveChecks(requested: [], declared: ["rspec", "rubocop"]).get()
        XCTAssertEqual(resolved, ["rspec", "rubocop"])
    }

    func test_resolveChecks_neverReturnsEmptyForAnEmptyRequest() {
        // Empty in, empty declared: a refusal, not a run of nothing.
        // `up -n verify` on a namespace with no processes never exits.
        switch Verification.Runner.resolveChecks(requested: [], declared: []) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure): XCTAssertEqual(failure, .nothingDeclared)
        }
    }

    func test_resolveChecks_refusesUnknownNamesAndListsTheValidOnes() {
        switch Verification.Runner.resolveChecks(
            requested: ["rspec", "typo"], declared: ["rspec", "rubocop"]
        ) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unknownChecks(["typo"], valid: ["rspec", "rubocop"]))
        }
    }

    /// PhaseRunner.command silently drops a trailing name beginning with "-" as
    /// a flag-injection guard. Refusing here is what stops that becoming a run
    /// that quietly omits a check.
    func test_resolveChecks_refusesFlagShapedNames() {
        switch Verification.Runner.resolveChecks(requested: ["-n"], declared: ["rspec"]) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unknownChecks(["-n"], valid: ["rspec"]))
        }
    }

    func test_start_refusesWhileARunIsInFlight() {
        let runner = Verification.Runner()
        let id = UUID()
        runner.seedInFlightForTesting(workstreamID: id, runID: "abcd1234")
        let before = runner.runs
        XCTAssertThrowsError(
            try runner.start(
                workstreamID: id, projectName: "app", workstreamName: "wisp",
                worktreePath: "/tmp", projectDirectory: "/tmp", checks: []
            )
        ) { error in
            XCTAssertEqual(error as? Verification.Runner.Failure, .alreadyRunning("abcd1234"))
        }
        // A refusal must not mutate state — no id issued, no run touched.
        // Task 8 adds mutations later in the same function, so this is what
        // keeps a refusal from leaking partial state ahead of them.
        XCTAssertEqual(runner.runs, before)
    }

    /// Reachable without a binary or config: the process-compose integration
    /// defaults off, so a plain start reaches `PhasePolicy.plan`'s
    /// `.nothingToDo` and must throw before touching `runs`.
    func test_start_leavesRunsUntouchedWhenNothingCanRun() {
        let runner = Verification.Runner()
        XCTAssertThrowsError(
            try runner.start(
                workstreamID: UUID(), projectName: "app", workstreamName: "wisp",
                worktreePath: "/tmp", projectDirectory: "/tmp", checks: []
            )
        )
        XCTAssertTrue(runner.runs.isEmpty)
    }

    func test_runID_isEightLowercaseHexCharacters() {
        let id = Verification.Runner().makeRunID()
        XCTAssertEqual(id.count, 8)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, id)
    }

    /// "Unique for the app's lifetime" is enforced, not hoped for.
    func test_runID_neverReissuesAnId() {
        let runner = Verification.Runner()
        var seen: Set<String> = []
        for _ in 0 ..< 2000 {
            XCTAssertTrue(seen.insert(runner.makeRunID()).inserted)
        }
    }

    // MARK: - Sealing

    /// Sealing is where the measured traps reach a persisted result, so it is
    /// tested directly against entries rather than through a spawn.
    func test_seal_mapsEveryStateAndRecordsFailures() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        runner.seedRunForTesting(
            workstreamID: id, runID: "abcd1234", checks: ["rubocop", "rspec", "vitest"]
        )
        let sealed = runner.seal(
            runID: "abcd1234",
            from: [
                entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                entry("rspec", status: "Completed", isRunning: false, exitCode: 1),
                entry("vitest", status: "Skipped", isRunning: false, exitCode: 1),
            ],
            stopped: false
        )
        XCTAssertEqual(sealed?.checks.map(\.state), [.passed, .failed(1), .skipped])
        XCTAssertEqual(sealed?.failedNames, ["rspec"])
    }

    func test_seal_stoppedRelabelsLiveAndPendingChecks() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        runner.seedRunForTesting(
            workstreamID: id, runID: "abcd1234", checks: ["rspec", "vitest", "rubocop"]
        )
        let sealed = runner.seal(
            runID: "abcd1234",
            from: [
                entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                entry("rspec", status: "Running", isRunning: true, exitCode: 0),
                entry("vitest", status: "Pending", isRunning: false, exitCode: 0),
            ],
            stopped: true
        )
        // A run the user stopped must not report failures they caused on
        // purpose, and must not claim a pending check ran.
        XCTAssertEqual(sealed?.checks.first { $0.name == "rspec" }?.state, .stopped)
        XCTAssertEqual(sealed?.checks.first { $0.name == "vitest" }?.state, .notRun)
        XCTAssertEqual(sealed?.checks.first { $0.name == "rubocop" }?.state, .passed)
        XCTAssertEqual(sealed?.wasStopped, true)
    }

    /// The executor's own deadline reaches this function with `stopped: false`
    /// and the checks still executing — `PhaseExecutor.run` returns `.failed`
    /// while its processes run on, and the run loop's teardown, one line after
    /// this, is what kills them. So the relabel is unconditional: a persisted
    /// `.running` would claim a check is running that was killed a moment
    /// later, and would leave a run whose rows never reach a terminal state.
    func test_seal_relabelsLiveChecksEvenWhenTheRunWasNotStopped() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "vitest"])
        let sealed = runner.seal(
            runID: "abcd1234",
            from: [
                entry("rspec", status: "Running", isRunning: true, exitCode: 0),
                entry("vitest", status: "Pending", isRunning: false, exitCode: 0),
            ],
            stopped: false
        )
        XCTAssertEqual(sealed?.checks.first { $0.name == "rspec" }?.state, .stopped)
        XCTAssertEqual(sealed?.checks.first { $0.name == "vitest" }?.state, .notRun)
        // The run-level flag is still what tells a Stop from a timeout.
        XCTAssertEqual(sealed?.wasStopped, false)
        XCTAssertEqual(sealed?.isFinished, true, "a sealed run must not still look in flight")
    }

    /// `isLive` is the exported answer to "is a run live here", because
    /// `Run.isFinished` is true for the last stretch of a run's life.
    func test_isLive_staysTrueUntilTheRunIsSealed() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        XCTAssertFalse(runner.isLive(id))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rubocop"])
        XCTAssertTrue(runner.isLive(id))
        _ = runner.seal(
            runID: "abcd1234",
            from: [entry("rubocop", status: "Completed", isRunning: false, exitCode: 0)],
            stopped: false
        )
        XCTAssertFalse(runner.isLive(id))
    }

    func test_seal_persistsTheRun() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rubocop"])
        _ = runner.seal(
            runID: "abcd1234",
            from: [entry("rubocop", status: "Completed", isRunning: false, exitCode: 0)],
            stopped: false
        )
        XCTAssertEqual(Verification.Store.latest(for: id)?.id, "abcd1234")
    }

    func test_seal_firesOnFinishExactlyOnce() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        var fired: [String] = []
        runner.onFinish = { fired.append($0.id) }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rubocop"])
        let entries = [entry("rubocop", status: "Completed", isRunning: false, exitCode: 0)]
        _ = runner.seal(runID: "abcd1234", from: entries, stopped: false)
        // A second seal of the same run — a Stop landing just as the poll
        // completes — must not deliver a second completion.
        _ = runner.seal(runID: "abcd1234", from: entries, stopped: false)
        XCTAssertEqual(fired, ["abcd1234"])
    }

    func test_seal_missingEntryLeavesACheckNotRun() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "gone"])
        let sealed = runner.seal(
            runID: "abcd1234",
            from: [entry("rspec", status: "Completed", isRunning: false, exitCode: 0)],
            stopped: false
        )
        XCTAssertEqual(sealed?.checks.first { $0.name == "gone" }?.state, .notRun)
    }

    func test_stop_doesNothingWhenNoRunIsLive() {
        let runner = Verification.Runner()
        runner.stop(workstreamID: UUID()) // must not crash or create a run
        XCTAssertTrue(runner.runs.isEmpty)
    }

    // MARK: - The run loop

    /// A run request the stub spawner never dereferences. `execute` is driven
    /// directly, because `start`'s gate needs the integration switched on, a
    /// located config and a real binary — none of which says anything about the
    /// ordering these tests exist for.
    private func request(workstreamID: UUID, checks: [String]) -> Verification.Runner.SpawnRequest {
        Verification.Runner.SpawnRequest(
            workstreamID: workstreamID,
            config: ProcessCompose.Config(
                path: "/tmp/process-compose.yaml", isRepositoryProvided: false, overridePath: nil
            ),
            binary: "/usr/bin/true",
            projectName: "app",
            workstreamName: "wisp",
            projectDirectory: "/tmp",
            worktreePath: "/tmp",
            checks: checks
        )
    }

    /// Drive one run loop to completion under a deadline, so a loop that never
    /// returns fails here instead of hanging the suite.
    private func drive(
        _ runner: Verification.Runner,
        _ request: Verification.Runner.SpawnRequest,
        runID: String,
        meanwhile: @MainActor () async -> Void = {}
    ) async {
        let done = Flag()
        let loop = Task {
            await runner.execute(request, runID: runID)
            done.value = true
        }
        await meanwhile()
        let deadline = Date().addingTimeInterval(5)
        while !done.value, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        loop.cancel()
        XCTAssertTrue(done.value, "the run loop did not return")
    }

    /// The invariant, in the one place a test can reach it: at the moment
    /// teardown runs, the run must already be sealed **and** the failed check's
    /// output must already be attached.
    ///
    /// The stub's server dies with the teardown, exactly as the real one does,
    /// so a loop that fetched logs afterwards would attach nothing; and only
    /// `seal` persists, so a store that already holds this run proves sealing
    /// came first.
    func test_execute_sealsAndCapturesOutputBeforeTearingDown() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let witness = TeardownWitness(workstreamID: id)
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .list([
                    entry("rspec", status: "Running", isRunning: true, exitCode: 0),
                    entry("rubocop", status: "Pending", isRunning: false, exitCode: 0),
                ]),
                .list([
                    entry("rspec", status: "Completed", isRunning: false, exitCode: 1),
                    entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                ]),
            ],
            latency: .zero,
            logsByName: ["rspec": ["1 example, 1 failure", "boom"]]
        )
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(60), atShutDown: { witness.observe() }
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        witness.runner = runner
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "rubocop"])

        await drive(runner, request(workstreamID: id, checks: ["rspec", "rubocop"]), runID: "abcd1234")

        XCTAssertEqual(witness.storedAtTeardown?.id, "abcd1234", "the run must be sealed before teardown")
        XCTAssertEqual(
            witness.runAtTeardown?.checks.first { $0.name == "rspec" }?.output,
            "1 example, 1 failure\nboom",
            "a failed check's log must be fetched while the server is still up"
        )
        // Exactly one teardown, and it is this loop's.
        let shutDowns = await spawner.shutDowns
        XCTAssertEqual(shutDowns, 1)

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.checks.map(\.state), [.failed(1), .passed])
        // Only failed checks keep output: a 200-line tail per passing check would
        // go into UserDefaults for output nobody asked for.
        XCTAssertNil(sealed?.checks.first { $0.name == "rubocop" }?.output)
        let requested = await client.logRequests
        XCTAssertEqual(requested, ["rspec"])
    }

    /// Live rows are published while the suite runs, not only at the end: the
    /// tab reads `runs` at 1Hz and a result that only appeared at the end would
    /// leave it blank for the length of a suite.
    ///
    /// Asserted twice over — a `.running` row observed while the loop is still
    /// polling, and the duration that survives into the sealed result, which
    /// can only be set by a poll that saw the check running and a later one
    /// that saw it end.
    func test_execute_publishesLiveRowsWhileTheSuiteRuns() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let running = StubComposeClient.Reply.list([
            entry("rspec", status: "Running", isRunning: true, exitCode: 0),
        ])
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                running, running, running,
                .list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)]),
            ],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(80))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        let sawRunning = Flag()

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            let deadline = Date().addingTimeInterval(2)
            while !sawRunning.value, Date() < deadline {
                if runner.run(id: "abcd1234")?.checks.first?.state == .running {
                    sawRunning.value = true
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        XCTAssertTrue(sawRunning.value, "a running check must be visible in `runs` mid-suite")
        let check = runner.run(id: "abcd1234")?.checks.first
        XCTAssertEqual(check?.state, .passed)
        XCTAssertNotNil(check?.duration, "a check seen running and then finished must be timed")
    }

    /// At the line limit the honest answer is "possibly truncated" — a tail
    /// cannot reveal whether anything preceded it.
    func test_execute_marksOutputTruncatedAtTheLineLimit() async {
        let sealed = await sealedRunWithLog(lines: 200)
        XCTAssertEqual(sealed?.checks.first?.outputTruncated, true)
    }

    func test_execute_doesNotMarkAShorterLogTruncated() async {
        let sealed = await sealedRunWithLog(lines: 199)
        XCTAssertEqual(sealed?.checks.first?.outputTruncated, false)
    }

    /// One failing check whose log is `lines` long, run to a sealed result.
    private func sealedRunWithLog(lines: Int) async -> Verification.Run? {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 1)])],
            latency: .zero,
            logsByName: ["rspec": (1 ... lines).map { "line \($0)" }]
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")
        return runner.run(id: "abcd1234")
    }

    /// Stop, end to end: this is what makes `.stopped` a state the app can
    /// actually reach. The namespace is still running when the flag lands, so
    /// the final snapshot still says `Running` — which is precisely why Stop
    /// must not stop the processes itself, and why teardown comes after sealing.
    func test_execute_stopSealsLiveChecksAsStoppedAndTearsDownOnce() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([
                entry("rspec", status: "Running", isRunning: true, exitCode: 0),
                entry("vitest", status: "Pending", isRunning: false, exitCode: 0),
                entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
            ])],
            latency: .zero
        )
        // No completion of its own: the namespace is still running, and the
        // teardown this loop performs is what ends it.
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(
            workstreamID: id, runID: "abcd1234", checks: ["rspec", "vitest", "rubocop"]
        )

        await drive(
            runner, request(workstreamID: id, checks: ["rspec", "vitest", "rubocop"]),
            runID: "abcd1234"
        ) {
            // Let the poll publish at least once, then ask it to stop.
            try? await Task.sleep(for: .milliseconds(30))
            runner.stop(workstreamID: id)
        }

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.wasStopped, true)
        XCTAssertEqual(sealed?.checks.first { $0.name == "rspec" }?.state, .stopped)
        XCTAssertEqual(sealed?.checks.first { $0.name == "vitest" }?.state, .notRun)
        XCTAssertEqual(sealed?.checks.first { $0.name == "rubocop" }?.state, .passed)
        XCTAssertEqual(sealed?.failedNames, [])
        let shutDowns = await spawner.shutDowns
        XCTAssertEqual(shutDowns, 1, "Stop must not add a second teardown of its own")
    }

    /// Liveness is the runner's own bookkeeping, not `Run.isFinished`.
    ///
    /// Every row here reports a terminal state on the first poll, so the run
    /// looks finished long before it is sealed. If `stop` and `seal` keyed on
    /// `isFinished` instead, Stop would be a no-op and this loop would never
    /// return — which is the failure this test would report.
    func test_execute_aRunWhoseRowsAreAllTerminalIsStillStoppable() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(runner.run(id: "abcd1234")?.isFinished, true, "rows are terminal")
            runner.stop(workstreamID: id)
        }

        XCTAssertEqual(runner.run(id: "abcd1234")?.wasStopped, true)
    }
}

/// A main-actor flag, so a test can tell whether a task it started has finished
/// without awaiting it.
@MainActor
private final class Flag {
    var value = false
}

/// What the runner had done by the time teardown ran.
///
/// The teardown ordering is not observable after the loop returns — by then
/// everything has happened — so it is sampled from inside `shutDown`.
@MainActor
private final class TeardownWitness {
    let workstreamID: UUID
    weak var runner: Verification.Runner?
    var runAtTeardown: Verification.Run?
    var storedAtTeardown: Verification.Run?

    init(workstreamID: UUID) {
        self.workstreamID = workstreamID
    }

    func observe() {
        runAtTeardown = runner?.runs[workstreamID]
        storedAtTeardown = Verification.Store.latest(for: workstreamID)
    }
}

/// Stands in for a live process-compose: a spawn whose completion the test
/// controls, one control client, and a teardown that ends the stub's server the
/// way the real one does — which is what makes "the logs were fetched while the
/// server was up" a property a test can fail on.
private actor StubSpawner: Verification.Runner.Spawning {
    nonisolated let client: StubComposeClient
    /// How long the namespace runs. **Nil parks the spawn until `shutDown`
    /// releases it**, which is the Stop path: the namespace is still running
    /// when the loop seals, and the teardown is what ends it.
    private let finishAfter: Duration?
    private let atShutDown: (@MainActor @Sendable () -> Void)?
    private(set) var shutDowns = 0
    private var parked: CheckedContinuation<Void, Never>?

    init(
        client: StubComposeClient,
        finishAfter: Duration?,
        atShutDown: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.client = client
        self.finishAfter = finishAfter
        self.atShutDown = atShutDown
    }

    func run(_: Verification.Runner.SpawnRequest) async -> ProcessCompose.PhaseExecutor.Outcome {
        if let finishAfter {
            try? await Task.sleep(for: finishAfter)
        } else {
            await withCheckedContinuation { parked = $0 }
        }
        return .succeeded
    }

    nonisolated func controlClient(for _: Verification.Runner.SpawnRequest) -> ProcessCompose.Controlling {
        client
    }

    func shutDown(_: Verification.Runner.SpawnRequest) async {
        shutDowns += 1
        if let atShutDown {
            await MainActor.run(body: atShutDown)
        }
        await client.endServer()
        parked?.resume()
        parked = nil
    }
}
