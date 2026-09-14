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

    /// A namespace whose every declared name is flag-shaped does declare
    /// checks — they are in the YAML and the user can grep them — so the
    /// refusal has to say what is actually wrong rather than "declares no
    /// verify processes", which is both untrue and unactionable. The filter is
    /// unchanged: nothing flag-shaped is ever started.
    func test_resolveChecks_doesNotCallAnAllFlagShapedNamespaceEmpty() {
        switch Verification.Runner.resolveChecks(requested: [], declared: ["-n", "--help"]) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unrunnableChecks(["-n", "--help"]))
            XCTAssertNotEqual(failure, .nothingDeclared)
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
            XCTAssertEqual(failure, .unrunnableChecks(["-n"]))
        }
    }

    /// And refuses one the project genuinely *declares*, which is the hole the
    /// "not declared" test above could not reach: `-n` is legal YAML, so it
    /// was declared, offered, resolved, and then dropped on the way to the
    /// shell. "No such check" would be a lie here — the user would grep, find
    /// it, and be stuck — so it gets its own refusal.
    func test_resolveChecks_refusesADeclaredFlagShapedName() {
        switch Verification.Runner.resolveChecks(requested: ["-n"], declared: ["-n", "rspec"]) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unrunnableChecks(["-n"]))
            XCTAssertEqual(
                failure.errorDescription,
                "process-compose cannot start a check whose name begins with \"-\": -n. "
                    + "Rename it in process-compose.yaml."
            )
        }
    }

    /// **The inversion.** `-n` as the *only* selection used to reach
    /// `PhaseRunner.command`, be filtered out of the trailing names, leave
    /// `selectedProcesses` empty — and `up -n verify` then runs the entire
    /// namespace, the exact opposite of what was selected, through a guard
    /// that exists for security. The refusal above is what stops it, and
    /// `runnableChecks` is what stops it being offered in the first place.
    func test_resolveChecks_aLoneFlagShapedSelectionNeverResolvesToEverything() {
        let declared = ["-n", "rspec", "rubocop"]
        switch Verification.Runner.resolveChecks(requested: ["-n"], declared: declared) {
        case let .success(names):
            XCTFail("a refusal became a run of \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unrunnableChecks(["-n"]))
        }
        // And through the filter the checklist and `start` both apply, the
        // name is not offered at all — so the selection cannot be made.
        XCTAssertEqual(
            Verification.Runner.runnableChecks(declared), ["rspec", "rubocop"]
        )
    }

    /// One of several: the run must not come back missing a check nobody
    /// declined. Filtering `declared` is what keeps the checklist and the
    /// runner talking about the same set, so nothing is offered that would
    /// seal `.notRun` for no stated reason.
    func test_runnableChecks_dropsFlagShapedNamesAndKeepsTheRest() {
        XCTAssertEqual(
            Verification.Runner.runnableChecks(["rspec", "-n", "rubocop", "--file"]),
            ["rspec", "rubocop"]
        )
        // A run of "everything" then names only what can actually be started.
        let resolved = try? Verification.Runner.resolveChecks(
            requested: [], declared: Verification.Runner.runnableChecks(["-n", "rspec"])
        ).get()
        XCTAssertEqual(resolved, ["rspec"])
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

    /// Reachable without a binary or config: the temp paths below hold no
    /// process-compose config, so a plain start reaches `PhasePolicy.plan`'s
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

    /// "Unique for the app's lifetime" is enforced, not hoped for — pinned
    /// against a forced collision, which is the only way the dedup set is
    /// observable.
    ///
    /// Its predecessor drew 2000 ids and asserted they all differed. Eight hex
    /// characters is 2^32 candidates, so that assertion held whether or not
    /// `issuedRunIDs` existed: it tested `UUID`'s randomness rather than
    /// `makeRunID`'s promise. Deleting the dedup set left it green.
    func test_runID_redrawsWhenACandidateHasAlreadyBeenIssued() {
        let runner = Verification.Runner()
        var candidates = ["aaaaaaaa", "aaaaaaaa", "bbbbbbbb"]
        runner.runIDCandidate = { candidates.removeFirst() }

        XCTAssertEqual(runner.makeRunID(), "aaaaaaaa")
        // The second draw repeats the first id. Without the dedup set this
        // returns "aaaaaaaa" a second time and never reaches "bbbbbbbb".
        XCTAssertEqual(runner.makeRunID(), "bbbbbbbb")
        XCTAssertTrue(candidates.isEmpty, "the colliding candidate was not redrawn")
    }

    /// The dedup set spans the runner's whole life, not one call.
    func test_runID_neverReissuesAnIdIssuedEarlier() {
        let runner = Verification.Runner()
        var candidates = ["aaaaaaaa", "bbbbbbbb", "aaaaaaaa", "cccccccc"]
        runner.runIDCandidate = { candidates.removeFirst() }

        XCTAssertEqual(runner.makeRunID(), "aaaaaaaa")
        XCTAssertEqual(runner.makeRunID(), "bbbbbbbb")
        XCTAssertEqual(runner.makeRunID(), "cccccccc")
        XCTAssertTrue(candidates.isEmpty, "the colliding candidate was not redrawn")
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

    func test_stopAndWait_returnsImmediatelyWhenNothingIsLive() async {
        let runner = Verification.Runner()
        let quiet = await runner.stopAndWait(workstreamID: UUID(), timeout: .milliseconds(50))
        XCTAssertTrue(quiet)
        XCTAssertTrue(runner.runs.isEmpty, "a wait must not invent a run to wait for")
    }

    func test_forget_leavesNoEntryForAWorkstream() {
        let runner = Verification.Runner()
        let id = UUID()
        runner.seedInFlightForTesting(workstreamID: id, runID: "abcd1234")

        runner.forget(workstreamID: id)

        XCTAssertNil(runner.runs[id])
        XCTAssertNil(runner.run(id: "abcd1234"))
        XCTAssertFalse(runner.isLive(id))
    }

    // MARK: - The run loop

    /// A run request the stub spawner never dereferences. `execute` is driven
    /// directly, because `start`'s gate needs a located config and a real
    /// binary — neither of which says anything about the ordering these tests
    /// exist for.
    private func request(workstreamID: UUID, checks: [String]) -> Verification.Runner.SpawnRequest {
        Verification.Runner.SpawnRequest(
            workstreamID: workstreamID,
            config: ProcessCompose.Config(
                path: "/tmp/process-compose.yaml", isRepositoryProvided: false
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

    // MARK: - The live log window

    /// The feature's whole point, and the one thing a stub can prove about it:
    /// while the run is live the tab can read a *running* check's output, which
    /// `captureFailedOutput` never fetches — it only takes failed checks, and
    /// only once, at the end.
    func test_liveLog_readsARunningCheckWhileTheRunIsLive() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero,
            logsByName: ["rspec": ["compiling", "running examples"]]
        )
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        var live: [String]?
        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            // Once the loop has published a row, the client is registered and
            // the server is up — the window this reads through.
            let deadline = Date().addingTimeInterval(2)
            while runner.runs[id]?.checks.first?.state != .running, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            live = await runner.liveLog(workstreamID: id, check: "rspec")
            runner.stop(workstreamID: id)
        }

        XCTAssertEqual(live, ["compiling", "running examples"])
    }

    /// Nil once the run is over, because the server that held the log is gone —
    /// which is what makes a sealed group fall back to what was captured
    /// instead of showing a stale window that will never update again.
    func test_liveLog_isNilOnceTheRunIsOver() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero,
            logsByName: ["rspec": ["all good"]]
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        let after = await runner.liveLog(workstreamID: id, check: "rspec")
        XCTAssertNil(after, "the control server is torn down with the run; there is nothing left to read")
    }

    /// Nil for a workstream with no run at all, rather than a stray read
    /// against whatever happens to be listening on that socket.
    func test_liveLog_isNilWithNoRun() async {
        let runner = Verification.Runner()
        let read = await runner.liveLog(workstreamID: UUID(), check: "rspec")
        XCTAssertNil(read)
    }

    /// Scoped to the run's own checks. A `verify` socket's control server also
    /// answers about processes in other namespaces, so an unscoped read would
    /// hand back output belonging to something this run never started.
    func test_liveLog_refusesACheckThisRunDoesNotOwn() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero,
            logsByName: ["web": ["listening on 3000"]]
        )
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        var read: [String]? = ["not asked"]
        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            let deadline = Date().addingTimeInterval(2)
            while runner.runs[id]?.checks.first?.state != .running, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            read = await runner.liveLog(workstreamID: id, check: "web")
            runner.stop(workstreamID: id)
        }

        XCTAssertNil(read)
        let requested = await client.logRequests
        XCTAssertFalse(requested.contains("web"), "a check the run does not own must never reach the wire")
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
            logsByName: ["rspec": ["1 example, 1 failure", "boom"], "rubocop": ["clean"]]
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
        // Every check keeps output now, pass or fail — the retirement of the old
        // failures-only rule (`recordCompletions` replaces `captureFailedOutput`).
        XCTAssertEqual(sealed?.checks.first { $0.name == "rubocop" }?.output, "clean")
        let requested = await client.logRequests
        XCTAssertEqual(requested, ["rspec", "rubocop"])
    }

    /// The staleness baseline is computed off the main actor.
    ///
    /// `captureStamp` hops to a global queue because `diffFingerprint` is
    /// `git rev-parse`, `git diff --stat`, `git ls-files` and batched
    /// `git hash-object` — four-plus serial spawns — and `Runner` is
    /// `@MainActor`, so a synchronous call would block the actor for all of
    /// them. A stamp computed on the actor and one computed off it are the
    /// same string, so the only way to fail on the difference is to ask the
    /// fingerprint itself which thread it ran on.
    ///
    /// **What this catches**: the hop being dropped, so the fingerprint runs
    /// synchronously on the main actor. **What it does not**: a different
    /// off-actor mechanism, or the hop being kept while something else on the
    /// path blocks the actor anyway.
    func test_execute_computesTheStalenessStampOffTheMainActor() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let witness = ThreadWitness()
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)]),
            ],
            latency: .zero,
            logsByName: [:]
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10))
        let runner = Verification.Runner(
            spawner: spawner,
            pollInterval: .milliseconds(5),
            fingerprint: { _, _ in
                witness.record(isMain: Thread.isMainThread)
                return "stamp-of-the-run"
            }
        )
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        XCTAssertEqual(witness.calls, 1, "the staleness baseline is taken exactly once per run")
        XCTAssertEqual(
            witness.ranOnMainThread, false,
            "the staleness fingerprint ran on the main thread"
        )
        // And it still reaches the sealed run, so the hop is not bought by
        // dropping the answer.
        XCTAssertEqual(runner.run(id: "abcd1234")?.stamp, "stamp-of-the-run")
    }

    /// Live rows are published while the suite runs, not only at the end: the
    /// tab reads `runs` and a result that appeared only at the end would leave
    /// it blank for the length of a suite.
    ///
    /// The spawn is parked, so the check stays `Running` until this test itself
    /// ends the run. The sample below is therefore not racing a state that
    /// moves on — it either appears or the deadline reports that it never did.
    func test_execute_publishesLiveRowsWhileTheSuiteRuns() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: nil)
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
            // Ends the run whether or not the row was seen, so a failure here
            // reports the missing row rather than stalling the loop.
            runner.stop(workstreamID: id)
        }

        XCTAssertTrue(sawRunning.value, "a running check must be visible in `runs` mid-suite")
        XCTAssertEqual(runner.run(id: "abcd1234")?.checks.first?.state, .stopped)
    }

    /// The duration a poll measured survives into the sealed result: it can only
    /// be set by a read that saw the check running and a later one that saw it
    /// end, so it is also second evidence that the loop polls rather than
    /// waiting.
    func test_execute_timesACheckItSawStartAndFinish() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)]),
                .list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)]),
            ],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(30))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        let check = runner.run(id: "abcd1234")?.checks.first
        XCTAssertEqual(check?.state, .passed)
        XCTAssertNotNil(check?.duration, "a check seen running and then finished must be timed")
    }

    /// A Stop can land before the namespace has bound its socket, and acting on
    /// it there would be worse than waiting.
    ///
    /// `PhaseExecutor.shutDown` returns immediately when the socket file is not
    /// there, so sealing then would leave a live server with no owner: `isLive`
    /// false while the suite runs, a second `start` admitted, and that run
    /// publishing the first suite's rows until its own pre-spawn teardown killed
    /// the first suite. So the loop waits for the server to answer — and the
    /// sealed row proves it waited, because a seal against a server that never
    /// answered would have produced `.notRun`.
    func test_execute_aStopBeforeTheServerAnswersWaitsForIt() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .failure(.notRunning),
                .failure(.notRunning),
                .list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)]),
            ],
            latency: .zero
        )
        // Parked, so the namespace really is still running: only the loop's
        // teardown ends it.
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        // Before the loop has polled once — the window where the socket does not
        // exist yet.
        runner.stop(workstreamID: id)

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        XCTAssertEqual(
            runner.run(id: "abcd1234")?.checks.first?.state, .stopped,
            "the loop must wait for the server rather than seal against no answer"
        )
        XCTAssertEqual(runner.run(id: "abcd1234")?.wasStopped, true)
        XCTAssertFalse(runner.isLive(id), "a sealed run whose server this loop tore down")
        let shutDowns = await spawner.shutDowns
        XCTAssertEqual(shutDowns, 1, "still exactly one teardown, and still this loop's")
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

    /// **`isLive` must not go false while the teardown is still in flight.**
    /// `seal` inserts into `sealedRunIDs`, so without `tearingDown` the Run
    /// button re-enables the moment results appear — while `execute` is still
    /// awaiting `shutDown`, which is `down -u <socket>` at `Timeout.local`
    /// followed by unlinking the socket file. A Run pressed in that window
    /// binds the same path, and the old teardown's `removeItem` then deletes
    /// the new run's socket from under its living server: no rows, no logs,
    /// nothing that can end it, and a suite holding the worktree's ports until
    /// `Timeout.suite`. "Press Stop, read the results, press Run again" is an
    /// ordinary sequence, and the stop path is where `down` is slow.
    ///
    /// Sampled from inside `shutDown` because the window is not observable
    /// from outside one, exactly as the sealing order is not.
    func test_execute_staysLiveUntilTheTeardownReturns() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let witness = TeardownWitness(workstreamID: id)
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        // Nil: the namespace is still running when the loop seals — the stop
        // path, which is the one where the teardown has live checks to kill.
        let spawner = StubSpawner(
            client: client, finishAfter: nil, atShutDown: { witness.observe() }
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        witness.runner = runner
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            try? await Task.sleep(for: .milliseconds(30))
            runner.stop(workstreamID: id)
        }

        XCTAssertEqual(witness.storedAtTeardown?.id, "abcd1234", "sealed before the teardown ran")
        XCTAssertEqual(
            witness.isLiveAtTeardown, true,
            "a sealed run still owns <id>-verify.sock until its teardown returns"
        )
        XCTAssertFalse(runner.isLive(id), "and is live no longer once it has")
        // The whole point of doing this with a flag rather than a second call.
        let shutDowns = await spawner.shutDowns
        XCTAssertEqual(shutDowns, 1, "still exactly one teardown, and still the run loop's")
    }

    /// A Stop that arrives *during* the teardown is admitted, because `isLive`
    /// is true there — and must not survive into this workstream's next run,
    /// which would break out of its poll loop on the first pass it sees a
    /// server. That is why both flags clear after `shutDown` returns.
    func test_execute_aStopDuringTeardownDoesNotLeakIntoTheNextRun() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let witness = TeardownWitness(workstreamID: id)
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(10), atShutDown: { witness.requestStop() }
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        witness.runner = runner
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        // The second run must poll normally rather than sealing itself on its
        // first pass, which is what a leaked stop flag would do.
        runner.seedRunForTesting(workstreamID: id, runID: "bcde2345", checks: ["rspec"])
        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "bcde2345")
        XCTAssertEqual(runner.run(id: "bcde2345")?.wasStopped, false)
    }

    /// A spawn that never binds a socket (bad binary path, config the daemon
    /// itself refuses) leaves every check `.notRun` — nothing in any one
    /// check's `output` explains that. `failureDetail` is the only place the
    /// reason is recorded, and it has to reach the *persisted* run, not just
    /// the in-memory one, since `seal` is what calls `Verification.Store.save`.
    func test_execute_recordsFailureDetailWhenTheSpawnFails() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(socketPath: "/nonexistent", replies: [], latency: .zero)
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10), outcome: .failed("binary exited 127"))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.failureDetail, "binary exited 127")
        XCTAssertEqual(sealed?.checks.map(\.state), [.notRun], "no entries ever arrived to report anything else")
        XCTAssertEqual(Verification.Store.latest(for: id)?.failureDetail, "binary exited 127", "must reach the persisted run, not only the in-memory one")
        XCTAssertNil(
            sealed?.unstartedChecksDetail,
            "the headline field owns this case; the mixed-case field must stay empty"
        )
    }

    /// **The mixed case, which used to drop the executor's text entirely.**
    ///
    /// The server reports on `rspec` and never mentions `rubocop` — a config
    /// error in that one process, which `PhaseExecutor` reports as a `.failed`
    /// outcome. `serverReportedAnyCheck` is right to refuse the "the run itself
    /// failed to start its checks" headline here, since a check did report; but
    /// the executor's own message was refused along with it, leaving the
    /// `.notRun` row with no explanation anywhere — the run's log is gone with
    /// its control server, so there is nowhere else to look. It now rides on
    /// `unstartedChecksDetail`, under its own wording.
    func test_execute_keepsTheExecutorsTextWhenSomeChecksNeverStarted() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let detail = "process-compose: process rubocop: working_dir does not exist"
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(30), outcome: .failed(detail)
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "rubocop"])

        await drive(
            runner, request(workstreamID: id, checks: ["rspec", "rubocop"]), runID: "abcd1234"
        )

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.checks.map(\.state), [.passed, .notRun])
        XCTAssertNil(
            sealed?.failureDetail,
            "a run that reported on a check did not fail to start its checks"
        )
        XCTAssertEqual(sealed?.unstartedChecksDetail, detail)
        XCTAssertEqual(
            Verification.Store.latest(for: id)?.unstartedChecksDetail, detail,
            "must reach the persisted run, not only the in-memory one"
        )
    }

    /// The bug this test pins: `PhaseExecutor` reports a `.failed` outcome
    /// whenever *any* process in the namespace exits non-zero, which is
    /// exactly what happens when one check genuinely fails. That check's own
    /// row already explains itself — `.failed(1)` plus its captured
    /// `output` — so the run-level banner must not also fire and duplicate
    /// (and outrank) the same fact with a different, less specific message.
    func test_execute_doesNotRecordFailureDetailWhenACheckExplainsItself() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([
                entry("rspec", status: "Completed", isRunning: false, exitCode: 1),
                entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
            ])],
            latency: .zero
        )
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(10),
            outcome: .failed("rspec exited with code 1.")
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "rubocop"])

        await drive(runner, request(workstreamID: id, checks: ["rspec", "rubocop"]), runID: "abcd1234")

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.checks.map(\.state), [.failed(1), .passed])
        XCTAssertNil(sealed?.failureDetail, "the failed row already explains itself")
    }

    /// process-compose reports a dependency-`Skipped` check with
    /// `exit_code: 1` — a failure it never had — which is enough on its own
    /// to make `PhaseExecutor` call the outcome `.failed`, even though every
    /// row here is `.passed` or `.skipped` and nothing actually broke.
    func test_execute_doesNotRecordFailureDetailForASkippedDependency() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([
                entry("rspec", status: "Completed", isRunning: false, exitCode: 0),
                entry("vitest", status: "Skipped", isRunning: false, exitCode: 1),
            ])],
            latency: .zero
        )
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(10),
            outcome: .failed("vitest exited with code 1.")
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "vitest"])

        await drive(runner, request(workstreamID: id, checks: ["rspec", "vitest"]), runID: "abcd1234")

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.checks.map(\.state), [.passed, .skipped])
        XCTAssertNil(sealed?.failureDetail, "a skipped dependency is not the run breaking")
    }

    /// A run that actually completes must not carry a stale `failureDetail`
    /// from some earlier attempt — there is nothing to explain.
    func test_execute_leavesFailureDetailNilOnSuccess() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        XCTAssertNil(runner.run(id: "abcd1234")?.failureDetail)
    }

    /// **The `exit_on_failure` shape, which is the defect this pins.**
    ///
    /// `PhaseExecutor.PollResult.serverGone`'s own doc records that a project
    /// may shut itself down — `restart: exit_on_failure` does exactly that,
    /// **even with `--keep-project`** — and fail-fast is a plausible thing for
    /// a verify namespace to want. So: the check fails, the live poll publishes
    /// `.failed(1)`, the project self-terminates, and the final read comes back
    /// with nothing. `seal` used to overwrite the failure with `.notRun` and
    /// the banner then claimed the run never started its checks, over a suite
    /// the user had just watched run and fail.
    func test_execute_preservesAFailureWhenTheFinalReadComesBackEmpty() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .list([entry("rspec", status: "Completed", isRunning: false, exitCode: 1)]),
                // The server is gone from here on — the shape a self-terminating
                // project really produces, and `verifyProcesses` turns it into
                // the same empty list an answered-with-nothing poll would give.
                .failure(.notRunning),
            ],
            latency: .zero
        )
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(40),
            outcome: .failed("rspec exited with code 1.")
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(
            sealed?.checks.map(\.state), [.failed(1)],
            "the failure the live rows already established must survive an empty final read"
        )
        XCTAssertEqual(sealed?.failedNames, ["rspec"])
        XCTAssertNil(
            sealed?.failureDetail,
            "a run that self-terminated after a real failure did not fail to start its checks"
        )
        XCTAssertEqual(
            Verification.Store.latest(for: id)?.checks.map(\.state), [.failed(1)],
            "and the persisted run must say the same thing"
        )
    }

    /// The `exit_on_end` shape, which is the same defect one step quieter: a
    /// whole passing suite ends the project, the final read is empty, and the
    /// run persisted as "nothing ran" with no banner to hint at it.
    func test_execute_preservesPassesWhenTheFinalReadComesBackEmpty() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .list([
                    entry("rspec", status: "Completed", isRunning: false, exitCode: 0),
                    entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                ]),
                .failure(.notRunning),
            ],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(40))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "rubocop"])

        await drive(
            runner, request(workstreamID: id, checks: ["rspec", "rubocop"]), runID: "abcd1234"
        )

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.checks.map(\.state), [.passed, .passed])
        XCTAssertEqual(sealed?.wasStopped, false)
        XCTAssertNil(sealed?.failureDetail)
    }

    /// **The executor's own deadline, which is the other way a `.failed`
    /// outcome reaches the gate.** `PhaseExecutor.run` returns `.failed` with
    /// the checks still executing — the run loop's teardown, a line later, is
    /// what kills them — so every row is `.running` at seal time and the final
    /// read is non-empty. A suite that ran for its whole timeout must not be
    /// reported as one that failed to *start* its checks, which is what a gate
    /// keyed on terminal states alone would say.
    func test_execute_doesNotRecordFailureDetailWhenTheDeadlineEndedALiveSuite() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(
            client: client, finishAfter: .milliseconds(30),
            outcome: .failed("verify timed out.")
        )
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        let sealed = runner.run(id: "abcd1234")
        XCTAssertEqual(sealed?.checks.map(\.state), [.stopped], "a live row is relabelled, not kept")
        XCTAssertNil(
            sealed?.failureDetail,
            "a suite that ran to the deadline did not fail to start its checks"
        )
        XCTAssertNil(
            sealed?.unstartedChecksDetail,
            "every row was reported, so nothing here never started either"
        )
    }

    /// A check the server never mentioned at all still seals `.notRun`, which
    /// is what preserving terminal states must not cost: the row is still
    /// `.pending` when sealing starts, and the relabel below the mapping is
    /// what answers it.
    func test_execute_aCheckTheServerNeverReportedStillSealsNotRun() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "gone"])

        await drive(runner, request(workstreamID: id, checks: ["rspec", "gone"]), runID: "abcd1234")

        XCTAssertEqual(runner.run(id: "abcd1234")?.checks.map(\.state), [.passed, .notRun])
    }

    /// The staleness baseline is captured by the **run loop** rather than by
    /// `start`, and it lands before the run is sealed — otherwise the
    /// persisted result could never be called stale.
    ///
    /// Renamed from `…OffTheMainActor`: nothing below could tell an on-actor
    /// capture from an off-actor one, since both produce the same string.
    /// `test_execute_computesTheStalenessStampOffTheMainActor` is the test
    /// that fails on that, and this one keeps the half it really pins.
    func test_execute_fillsTheStalenessStampBeforeSealing() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(10))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        XCTAssertEqual(runner.run(id: "abcd1234")?.stamp, "", "not captured before the loop runs")

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        XCTAssertFalse(
            runner.run(id: "abcd1234")?.stamp.isEmpty ?? true,
            "the loop must fill the stamp before sealing"
        )
        XCTAssertEqual(
            Verification.Store.latest(for: id)?.stamp, runner.run(id: "abcd1234")?.stamp,
            "and the persisted run must carry it too"
        )
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
            // Waited for rather than slept past: the loop now captures the
            // staleness stamp — four git spawns, off the actor — before it
            // spawns anything, so how long it takes to publish its first poll
            // is not a number a test may assume.
            let deadline = Date().addingTimeInterval(2)
            while runner.run(id: "abcd1234")?.isFinished != true, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(runner.run(id: "abcd1234")?.isFinished, true, "rows are terminal")
            runner.stop(workstreamID: id)
        }

        XCTAssertEqual(runner.run(id: "abcd1234")?.wasStopped, true)
    }

    // MARK: - Stopping for a purge

    /// **The binding window, which is the hazard `stopAndWait` exists for.**
    /// `PhaseExecutor.shutDown` returns immediately when the socket file is not
    /// there yet, so `Workstream.Archiver.purge` used to report the verify run
    /// dealt with and go on to `dispose` and `git worktree remove --force` while
    /// the suite was still coming up in that tree.
    ///
    /// The client throws `.notRunning` for its first forty polls — `up` has been
    /// asked for but has not bound — so `shouldStop` correctly withholds the
    /// Stop, and the only right answer to "is it gone" is *no*. The wait then
    /// has to be bounded, because a spawn that never binds is bounded only by
    /// `Timeout.suite`: it reports false, and `purge` proceeds anyway rather
    /// than leaving a workstream half-archived.
    ///
    /// The second call is the other half: once the server answers, the withheld
    /// Stop is acted on, the loop seals and tears down, and the wait returns
    /// true — without ever having torn anything down itself.
    func test_stopAndWait_doesNotReportClearWhileTheSpawnIsStillBinding() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: Array(repeating: .failure(.notRunning), count: 40)
                + [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        // Nil: the namespace is still running when the loop seals, so the
        // teardown is what ends it — the stop path.
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        let stillBinding = Flag()
        let liveWhileBinding = Flag()
        let quietOnceBound = Flag()

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            // Shorter than the ~200ms of `.notRunning` above, so the deadline is
            // reached while the server genuinely has not answered.
            let early = await runner.stopAndWait(workstreamID: id, timeout: .milliseconds(50))
            stillBinding.value = !early
            liveWhileBinding.value = runner.isLive(id)
            quietOnceBound.value = await runner.stopAndWait(workstreamID: id, timeout: .seconds(4))
        }

        XCTAssertTrue(stillBinding.value, "a run that has not bound yet must not be reported gone")
        XCTAssertTrue(liveWhileBinding.value, "and it is still live when the wait gives up")
        XCTAssertTrue(quietOnceBound.value, "once the server answers, the withheld Stop lands")
        XCTAssertFalse(runner.isLive(id))
        let shutDowns = await spawner.shutDowns
        XCTAssertEqual(shutDowns, 1, "stopAndWait must not add a teardown of its own")
    }

    /// **The run-level flag and the row states must agree.** A purge used to
    /// tear the socket down behind the runner's back, so `stopRequested` was
    /// never set: the loop saw its polls start failing, sealed with
    /// `wasStopped: false`, and relabelled the still-`Running` rows `.stopped`.
    /// The stored run then said nobody stopped it over rows saying somebody had.
    /// Going through `stopAndWait` — which goes through `stop` — is what makes
    /// the two the same answer.
    func test_stopAndWait_sealsWasStoppedInStepWithTheStoppedRows() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([
                entry("rspec", status: "Running", isRunning: true, exitCode: 0),
                entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
            ])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "rubocop"])
        let quiet = Flag()

        await drive(runner, request(workstreamID: id, checks: ["rspec", "rubocop"]), runID: "abcd1234") {
            quiet.value = await runner.stopAndWait(workstreamID: id, timeout: .seconds(4))
        }

        XCTAssertTrue(quiet.value)
        let sealed = Verification.Store.latest(for: id)
        XCTAssertEqual(sealed?.wasStopped, true, "the flag must not disagree with the rows")
        XCTAssertEqual(sealed?.checks.first { $0.name == "rspec" }?.state, .stopped)
        XCTAssertEqual(sealed?.checks.first { $0.name == "rubocop" }?.state, .passed)
    }

    /// A purged workstream leaves nothing in `runs`. It held a sealed run for a
    /// workstream that no longer existed for the rest of the session.
    func test_forget_afterAStopAndWaitLeavesNoEntryBehind() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: nil)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            await runner.stopAndWait(workstreamID: id, timeout: .seconds(4))
            runner.forget(workstreamID: id)
        }

        XCTAssertNil(runner.runs[id])
        XCTAssertNil(runner.run(id: "abcd1234"))
        XCTAssertFalse(runner.isLive(id))
    }

    /// The expired-wait path: `purge` forgets the workstream while the loop is
    /// still running, and everything the loop had left to do becomes a no-op.
    ///
    /// That is what `forget` is placed before the destructive work for. A `seal`
    /// landing afterwards would write `atelier.verifyRun.<id>` back for a
    /// workstream being deleted, *and* fire `onFinish` — which is how an agent
    /// gets an `atelier/verification` completion notice about a worktree that no
    /// longer exists.
    func test_forget_stopsALateSealWritingBackAPurgedWorkstream() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        // The namespace ends on its own, so the loop reaches `seal` without any
        // Stop having been acted on — the shape of a wait that expired.
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(80))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        let announced = Flag()
        runner.onFinish = { _ in announced.value = true }

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            try? await Task.sleep(for: .milliseconds(20))
            runner.forget(workstreamID: id)
        }

        XCTAssertNil(runner.runs[id], "the loop must not resurrect a forgotten workstream")
        XCTAssertNil(Verification.Store.latest(for: id), "and must not persist a run for it")
        XCTAssertFalse(announced.value, "nor announce one to an agent")
    }

    /// The non-vacuous sibling of the test above. There the check never leaves
    /// `.running`, so `recordCompletions` never reaches its `client.logs` await and
    /// the guard *after* that await is never exercised — only the guard at the
    /// function's own entry is. Here the check is `.passed` from the very first
    /// poll, so the loop enters the log fetch, and `forget` is timed to land
    /// *during* that fetch's suspension: `client.logRequests` records the name
    /// before the stub's simulated latency, so polling it is a deterministic way
    /// to catch the await mid-flight rather than guessing a sleep duration.
    ///
    /// `recordCompletion` — the writer `recordCompletions` calls — has no
    /// run-existence check of its own by design (Task 3 needs it bare for
    /// `seal`'s post-sealing records), so the only thing standing between a late
    /// completion and a write-back for a purged workstream is the re-check this
    /// test pins.
    func test_forget_stopsALateCompletionDuringTheLogFetchFromWritingBackAPurgedWorkstream() async {
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .milliseconds(150),
            logsByName: ["rspec": ["ok"]]
        )
        // Long enough that the loop is still polling, well past the log fetch,
        // when `drive` gives up waiting on `meanwhile` and moves on.
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(500))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        let runAnnounced = Flag()
        let checkAnnounced = Flag()
        runner.onFinish = { _ in runAnnounced.value = true }
        runner.onCheckFinished = { _, _ in checkAnnounced.value = true }

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234") {
            let deadline = Date().addingTimeInterval(2)
            while await !client.logRequests.contains("rspec"), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            runner.forget(workstreamID: id)
        }

        XCTAssertTrue(
            Verification.CheckStore.records(for: id).isEmpty,
            "no record must be written for a workstream forgotten mid-fetch"
        )
        XCTAssertFalse(checkAnnounced.value, "nor a per-check completion notice")
        XCTAssertFalse(runAnnounced.value, "nor a run-level finish notice")
    }

    // MARK: - Per-check records

    /// The idempotence point. `seal` calls the same writer the poll-loop edge detector
    /// does, and a check reported terminal on several consecutive polls must produce one
    /// record and one notice — not one per poll.
    func test_recordCompletion_firesOncePerCheckPerRun() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.CheckStore.clear(for: id) }
        var notices: [Verification.CheckRecord] = []
        runner.onCheckFinished = { _, record in notices.append(record) }

        for _ in 0 ..< 3 {
            runner.recordCompletion(
                workstreamID: id, runID: "abcd1234", name: "rspec", state: .failed(1),
                duration: 2.0, output: "boom", outputTruncated: false, stamp: "s"
            )
        }

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.state, .failed(1))
        XCTAssertEqual(Verification.CheckStore.records(for: id)["rspec"]?.output, "boom")
    }

    /// A later run overwrites the same name and fires again — the idempotence key is the
    /// pair, not the name. This is the ordinary case every time a row's Re-run is pressed.
    func test_recordCompletion_aSecondRunReplacesTheRecordAndFiresAgain() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.CheckStore.clear(for: id) }
        var notices: [Verification.CheckRecord] = []
        runner.onCheckFinished = { _, record in notices.append(record) }

        runner.recordCompletion(
            workstreamID: id, runID: "aaaaaaaa", name: "rspec", state: .failed(1),
            duration: 2.0, output: "boom", outputTruncated: false, stamp: "s"
        )
        runner.recordCompletion(
            workstreamID: id, runID: "bbbbbbbb", name: "rspec", state: .passed,
            duration: 1.0, output: "ok", outputTruncated: false, stamp: "t"
        )

        XCTAssertEqual(notices.count, 2)
        XCTAssertEqual(Verification.CheckStore.records(for: id)["rspec"]?.state, .passed)
        XCTAssertEqual(Verification.CheckStore.records(for: id)["rspec"]?.runID, "bbbbbbbb")
    }

    /// Records are published for the tab as well as persisted; the tab is not a
    /// subscriber to `onCheckFinished` and reads this instead.
    func test_recordCompletion_publishesForTheTab() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock { Verification.CheckStore.clear(for: id) }

        runner.recordCompletion(
            workstreamID: id, runID: "abcd1234", name: "rspec", state: .passed,
            duration: 1.0, output: nil, outputTruncated: false, stamp: "s"
        )

        XCTAssertEqual(runner.checkRecords[id]?["rspec"]?.state, .passed)
    }

    /// The completion edge fires mid-run, while the server is still up — which is what
    /// makes a per-check notice arrive before the suite ends, and what lets a passing
    /// check's output be captured at all.
    func test_execute_recordsEachCheckAsItCompletesWithItsOutput() async {
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [
                .list([
                    entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                    entry("rspec", status: "Running", isRunning: true, exitCode: 0),
                ]),
                .list([
                    entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                    entry("rspec", status: "Completed", isRunning: false, exitCode: 1),
                ]),
            ],
            latency: .zero,
            logsByName: ["rubocop": ["clean"], "rspec": ["1 failure"]]
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(60))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rubocop", "rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rubocop", "rspec"]), runID: "abcd1234")

        let records = Verification.CheckStore.records(for: id)
        XCTAssertEqual(records["rubocop"]?.state, .passed)
        XCTAssertEqual(records["rubocop"]?.output, "clean", "a passing check's output is kept now")
        XCTAssertEqual(records["rspec"]?.state, .failed(1))
        XCTAssertEqual(records["rspec"]?.output, "1 failure")
    }

    /// The stamp on a record is the run's, and the run loop fills it before the spawn —
    /// so a record written at a completion edge already carries a real fingerprint.
    func test_execute_recordsCarryTheRunsStalenessStamp() async {
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 0)])],
            latency: .zero
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(20))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        let stamp = Verification.CheckStore.records(for: id)["rspec"]?.stamp
        XCTAssertEqual(stamp, runner.run(id: "abcd1234")?.stamp)
        XCTAssertFalse(stamp?.isEmpty ?? true, "an empty stamp would read as 'not captured yet'")
    }

    /// A check the user stopped is terminal only after `seal` relabels it, so no mid-run
    /// edge ever fired for it. It still gets a record — with no output, because Stop is
    /// what ends the server and there was never a completed log to fetch.
    func test_seal_recordsAStoppedCheckWithNoOutput() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        runner.seal(
            runID: "abcd1234",
            from: [entry("rspec", status: "Running", isRunning: true, exitCode: 0)],
            stopped: true
        )

        let record = Verification.CheckStore.records(for: id)["rspec"]
        XCTAssertEqual(record?.state, .stopped)
        XCTAssertNil(record?.output)
    }

    /// A check the server never mentioned seals `.notRun`, and that is **not** a
    /// completion — no record, and no notice. A row with no record renders "Run", which is
    /// the honest offer for a check that never started.
    func test_seal_doesNotRecordACheckThatNeverRan() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        var notices: [Verification.CheckRecord] = []
        runner.onCheckFinished = { _, record in notices.append(record) }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "gone"])

        runner.seal(
            runID: "abcd1234",
            from: [entry("rspec", status: "Completed", isRunning: false, exitCode: 0)],
            stopped: false
        )

        XCTAssertNil(Verification.CheckStore.records(for: id)["gone"])
        XCTAssertEqual(notices.map(\.name), ["rspec"])
    }

    /// Decision 7, now pointed at the record writer: a record written mid-run is what the
    /// row keeps. `seal`'s own view of a check that the server has since stopped reporting
    /// must not replace it — `execute` passes `verifyProcesses(...) ?? []`, so a server
    /// that shut itself down after a failure arrives here as an empty list.
    func test_seal_doesNotOverwriteARecordTheLiveLoopWrote() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        runner.recordCompletion(
            workstreamID: id, runID: "abcd1234", name: "rspec", state: .failed(1),
            duration: 3.0, output: "the failure", outputTruncated: false, stamp: "s"
        )

        runner.seal(runID: "abcd1234", from: [], stopped: false)

        let record = Verification.CheckStore.records(for: id)["rspec"]
        XCTAssertEqual(record?.state, .failed(1), "the live loop's verdict stands")
        XCTAssertEqual(record?.output, "the failure")
    }

    /// **The statement-ordering test.** `recordCompletion` mutates `runs[workstreamID]` to
    /// mirror output onto the row, and `seal` holds a local `var run` copy it later hands
    /// to `Verification.Store.save`. A `seal` that saves its stale local copy persists a
    /// run whose rows have no output while the record does — invisible to every guard in
    /// the file, because `sealedRunIDs` is inserted last and `recordCompletion` has no
    /// `sealedRunIDs` check of its own.
    func test_seal_persistsTheOutputTheRecordWriterAttached() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        runner.seal(
            runID: "abcd1234",
            from: [entry("rspec", status: "Completed", isRunning: false, exitCode: 1)],
            stopped: false
        )

        XCTAssertEqual(
            Verification.Store.latest(for: id)?.checks.first?.state, .failed(1),
            "the persisted run must be the post-record copy, not the pre-record one"
        )
    }

    /// A whole run that completed nothing writes no records at all. Task 8 depends on this
    /// being the discriminator for the surviving run-level notice.
    func test_seal_aRunThatCompletedNothingWritesNoRecords() {
        let runner = Verification.Runner()
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec", "rubocop"])

        let sealed = runner.seal(runID: "abcd1234", from: [], stopped: false)

        XCTAssertEqual(sealed?.checks.map(\.state), [.notRun, .notRun])
        XCTAssertTrue(Verification.CheckStore.records(for: id).isEmpty)
    }

    /// The run's own rows keep carrying output, because `check_verification` projects from
    /// them and `Verification.Store` is what survives a restart.
    func test_execute_theRunsOwnRowsStillCarryOutput() async {
        let id = UUID()
        addTeardownBlock {
            Verification.Store.clear(for: id)
            Verification.CheckStore.clear(for: id)
        }
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: [.list([entry("rspec", status: "Completed", isRunning: false, exitCode: 1)])],
            latency: .zero,
            logsByName: ["rspec": ["1 failure"]]
        )
        let spawner = StubSpawner(client: client, finishAfter: .milliseconds(20))
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])

        await drive(runner, request(workstreamID: id, checks: ["rspec"]), runID: "abcd1234")

        XCTAssertEqual(Verification.Store.latest(for: id)?.checks.first?.output, "1 failure")
    }
}

/// Which thread the injected fingerprint ran on.
///
/// Locked rather than main-actor isolated, unlike `Flag` and
/// `TeardownWitness`: the whole point is that it is written from a thread
/// that is not the main one.
private final class ThreadWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [Bool] = []

    func record(isMain: Bool) {
        lock.lock()
        observed.append(isMain)
        lock.unlock()
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed.count
    }

    /// Nil when it was never called, which must not read the same as "it ran
    /// off the main thread".
    var ranOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard !observed.isEmpty else { return nil }
        return observed.contains(true)
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
    var isLiveAtTeardown: Bool?

    init(workstreamID: UUID) {
        self.workstreamID = workstreamID
    }

    func observe() {
        runAtTeardown = runner?.runs[workstreamID]
        storedAtTeardown = Verification.Store.latest(for: workstreamID)
        isLiveAtTeardown = runner?.isLive(workstreamID)
    }

    /// A Stop asked for from inside the teardown. `tearingDown` keeps `isLive`
    /// true there, so `stop` is admitted — the flag it sets must not outlive
    /// this run.
    func requestStop() {
        runner?.stop(workstreamID: workstreamID)
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
    /// What `run` reports once it finishes. Defaults to `.succeeded`;
    /// `.failed` is what a real spawn failure looks like to the run loop.
    private let outcome: ProcessCompose.PhaseExecutor.Outcome
    private(set) var shutDowns = 0
    private var parked: CheckedContinuation<Void, Never>?

    init(
        client: StubComposeClient,
        finishAfter: Duration?,
        outcome: ProcessCompose.PhaseExecutor.Outcome = .succeeded,
        atShutDown: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.client = client
        self.finishAfter = finishAfter
        self.outcome = outcome
        self.atShutDown = atShutDown
    }

    func run(_: Verification.Runner.SpawnRequest) async -> ProcessCompose.PhaseExecutor.Outcome {
        if let finishAfter {
            try? await Task.sleep(for: finishAfter)
        } else {
            await withCheckedContinuation { parked = $0 }
        }
        return outcome
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
