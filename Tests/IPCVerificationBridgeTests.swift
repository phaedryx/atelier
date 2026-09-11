// ABOUTME: Tests the adapter between Verification.Runner and the agent tools.
// ABOUTME: Covers the projection, per-run completion routing, and the persisted-run fallback.

@testable import Atelier
import XCTest

@MainActor
final class IPCVerificationBridgeTests: XCTestCase {
    private let workstreamID = UUID()
    /// `WorkspaceActions.projectList` is weak, so the test has to hold this.
    private var projectList: ProjectList!

    override func setUp() {
        super.setUp()
        let list = ProjectList()
        list.items = [Project(
            name: "app",
            directory: "/repos/app",
            workstreams: [Workstream(name: "wry-amber-lexer", worktreePath: "/repos/app/wry-amber-lexer", id: workstreamID)]
        )]
        projectList = list
        WorkspaceActions.shared.projectList = list
    }

    override func tearDown() {
        Verification.Store.clear(for: workstreamID)
        WorkspaceActions.shared.projectList = nil
        projectList = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// A bridge whose staleness read never shells out to git.
    private func makeBridge(
        runner: Verification.Runner,
        stamp: @escaping @Sendable (String, String) -> String = { _, _ in "head|0|empty" }
    ) -> IPC.VerificationRunnerBridge {
        IPC.VerificationRunnerBridge(runner: runner, currentStamp: stamp)
    }

    private func entry(
        _ name: String,
        status: String,
        isRunning: Bool,
        exitCode: Int
    ) -> ProcessCompose.ProcessEntry {
        ProcessCompose.ProcessEntry(
            name: name, namespace: "verify", status: status, isReady: "", hasReadyProbe: false,
            restarts: 0, exitCode: exitCode, pid: 0, isRunning: isRunning
        )
    }

    /// Waits for a completion the bridge delivers through a `Task`, since the
    /// projection's staleness read is async.
    private func waitForCompletion(_ box: CompletionBox, timeout: TimeInterval = 3) async -> IPC.VerificationRunInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let info = box.value {
                return info
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: IPC.VerificationRunInfo?
        private var count = 0

        var value: IPC.VerificationRunInfo? {
            lock.withLock { stored }
        }

        var deliveries: Int {
            lock.withLock { count }
        }

        func record(_ info: IPC.VerificationRunInfo) {
            lock.withLock {
                stored = info
                count += 1
            }
        }
    }

    // MARK: - Completion routing

    func test_sealingARunAnAgentStarted_deliversItsProjection() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        let box = CompletionBox()
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rubocop", "rspec", "vitest"])
        bridge.register(runID: "abcd1234") { box.record($0) }

        runner.seal(
            runID: "abcd1234",
            from: [
                entry("rubocop", status: "Completed", isRunning: false, exitCode: 0),
                entry("rspec", status: "Completed", isRunning: false, exitCode: 1),
                entry("vitest", status: "Skipped", isRunning: false, exitCode: 1),
            ],
            stopped: false
        )

        let info = await waitForCompletion(box)
        let delivered = try? XCTUnwrap(info)
        XCTAssertEqual(delivered?.runID, "abcd1234")
        XCTAssertEqual(delivered?.state, .finished)
        XCTAssertEqual(delivered?.workstreamID, workstreamID.uuidString)
        XCTAssertEqual(delivered?.workstreamName, "wry-amber-lexer")
        XCTAssertEqual(delivered?.checks.map(\.state), [.passed, .failed, .skipped])
        // A `Skipped` check carries exit 1 from process-compose; only a real
        // failure may report an exit code.
        XCTAssertEqual(delivered?.checks.map(\.exitCode), [nil, 1, nil])
        XCTAssertNotNil(delivered?.durationSeconds, "a sealed run knows how long it took")
    }

    /// `Runner.onFinish` is one slot and fires for every run the app performs,
    /// including the ones the user pressed Run for. Only the agent that asked
    /// may be told.
    func test_aRunNobodyAskedAbout_finishesSilently() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        let box = CompletionBox()
        bridge.register(runID: "someoneelse") { box.record($0) }
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rubocop"])

        runner.seal(
            runID: "abcd1234",
            from: [entry("rubocop", status: "Completed", isRunning: false, exitCode: 0)],
            stopped: false
        )

        _ = await waitForCompletion(box, timeout: 0.4)
        XCTAssertEqual(box.deliveries, 0, "the user's own run must not reach an agent's inbox")
    }

    func test_aStoppedRunIsProjectedAsStoppedRatherThanFinished() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        let box = CompletionBox()
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rspec", "vitest"])
        bridge.register(runID: "abcd1234") { box.record($0) }

        runner.seal(
            runID: "abcd1234",
            from: [entry("rspec", status: "Running", isRunning: true, exitCode: 0)],
            stopped: true
        )

        let info = await waitForCompletion(box)
        XCTAssertEqual(info?.state, .stopped)
        XCTAssertEqual(info?.checks.first?.state, .stopped, "a check the user stopped is not a check that failed")
    }

    // MARK: - Reading

    /// The trap this projection exists to avoid. `Runner.isLive` means "may a
    /// new run start on this socket" and stays true through sealing and
    /// teardown — a state read from it would report a run as still running in
    /// the very notice announcing that it finished.
    func test_aRunWhoseRowsAreAllTerminalReadsAsFinishedWhileTheRunnerStillCallsItLive() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        runner.seedInFlightForTesting(workstreamID: workstreamID, runID: "abcd1234")
        XCTAssertTrue(runner.isLive(workstreamID), "precondition: unsealed, so the socket is still taken")

        let running = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(running?.state, .running, "its one check is still running")

        runner.seal(
            runID: "abcd1234",
            from: [entry("x", status: "Completed", isRunning: false, exitCode: 0)],
            stopped: false
        )
        let sealed = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(sealed?.state, .finished)
    }

    func test_readingARunCarriesOutputAndItsTruncationFlag() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        var run = Verification.Run(
            id: "abcd1234", workstreamID: workstreamID, startedAt: Date(), stamp: "",
            checks: [.init(
                name: "rspec", state: .failed(1), duration: 48.1,
                output: "3 examples, 1 failure", outputTruncated: true
            )],
            wasStopped: false
        )
        run.stamp = ""
        Verification.Store.save(run)

        let info = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(info?.checks.first?.outputTail, "3 examples, 1 failure")
        XCTAssertEqual(
            info?.checks.first?.outputTruncated,
            true,
            "the fetch hit its line limit; the answer must not claim to be whole"
        )
    }

    /// A workstream's most recent run outlives a restart because the staleness
    /// stamp needs it. Nothing else does, and an older id is simply gone.
    func test_aPersistedRunResolvesWhenNothingIsInMemory() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        Verification.Store.save(Verification.Run(
            id: "abcd1234", workstreamID: workstreamID, startedAt: Date(), stamp: "",
            checks: [.init(name: "rubocop", state: .passed, duration: 1.9, output: nil)],
            wasStopped: false
        ))

        let found = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(found?.runID, "abcd1234")
        XCTAssertEqual(found?.checks.first?.state, .passed)
        XCTAssertNil(
            found?.durationSeconds,
            "a run restored from the store has no finish time, and must not invent one that grows as it is read"
        )

        let older = await bridge.verificationRun(id: "00000000", in: workstreamID)
        XCTAssertNil(older, "only the most recent run is kept")
    }

    func test_aRunIsStaleWhenTheWorktreeNoLongerMatchesItsStamp() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner, stamp: { _, _ in "head|2|changed" })
        Verification.Store.save(Verification.Run(
            id: "abcd1234", workstreamID: workstreamID, startedAt: Date(), stamp: "head|1|original",
            checks: [.init(name: "rubocop", state: .passed, duration: 1.9, output: nil)],
            wasStopped: false
        ))

        let info = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(info?.isStale, true, "a pass from before the last edit is a lie")
    }

    /// An empty stamp is the run's own baseline not being captured yet, not a
    /// mismatch — and skipping the comparison also skips four git spawns.
    func test_aRunWhoseStampIsNotYetCaptured_isNotStaleAndAsksGitNothing() async {
        let runner = Verification.Runner()
        let asked = CompletionBox()
        let bridge = makeBridge(runner: runner, stamp: { _, _ in
            XCTFail("the staleness read must not run when there is nothing to compare against")
            return ""
        })
        _ = asked
        runner.seedInFlightForTesting(workstreamID: workstreamID, runID: "abcd1234")

        let info = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(info?.isStale, false)
    }

    func test_anUnknownRunIsNil() async {
        let bridge = makeBridge(runner: Verification.Runner())
        let info = await bridge.verificationRun(id: "nosuchid", in: workstreamID)
        XCTAssertNil(info)
    }
}
