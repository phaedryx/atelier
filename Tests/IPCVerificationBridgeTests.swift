// ABOUTME: Tests the adapter between Verification.Runner and the agent tools.
// ABOUTME: Covers the projection and the per-run completion routing.

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
        Verification.CheckStore.clear(for: workstreamID)
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

    /// Finishes every check of a seeded run, which is what drives `onFinish`.
    private func finish(
        _ runner: Verification.Runner,
        runID: String,
        _ results: [(String, Verification.CheckResult.State)]
    ) {
        for (name, state) in results {
            runner.recordCompletion(
                workstreamID: workstreamID, runID: runID, name: name, state: state, duration: 1.0
            )
        }
    }

    func test_finishingARunAnAgentStarted_deliversItsProjection() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        let box = CompletionBox()
        runner.seedRunForTesting(
            workstreamID: workstreamID, runID: "abcd1234", checks: ["rubocop", "rspec", "vitest"]
        )
        bridge.register(runID: "abcd1234") { box.record($0) }

        finish(runner, runID: "abcd1234", [
            ("rubocop", .passed), ("rspec", .failed(1)), ("vitest", .skipped),
        ])

        let info = await waitForCompletion(box)
        let delivered = try? XCTUnwrap(info)
        XCTAssertEqual(delivered?.runID, "abcd1234")
        XCTAssertEqual(delivered?.state, .finished)
        XCTAssertEqual(delivered?.workstreamID, workstreamID.uuidString)
        XCTAssertEqual(delivered?.workstreamName, "wry-amber-lexer")
        XCTAssertEqual(delivered?.checks.map(\.state), [.passed, .failed, .skipped])
        // Only a real failure may report an exit code.
        XCTAssertEqual(delivered?.checks.map(\.exitCode), [nil, 1, nil])
        XCTAssertNotNil(delivered?.durationSeconds, "a finished run knows how long it took")
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

        finish(runner, runID: "abcd1234", [("rubocop", .passed)])

        _ = await waitForCompletion(box, timeout: 0.4)
        XCTAssertEqual(box.deliveries, 0, "the user's own run must not reach an agent's inbox")
    }

    func test_aStoppedRunIsProjectedAsStoppedRatherThanFinished() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        let box = CompletionBox()
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rspec"])
        bridge.register(runID: "abcd1234") { box.record($0) }

        finish(runner, runID: "abcd1234", [("rspec", .stopped)])

        let info = await waitForCompletion(box)
        XCTAssertEqual(info?.state, .stopped)
        XCTAssertEqual(info?.checks.first?.state, .stopped, "a check the user stopped is not a check that failed")
    }

    // MARK: - Reading

    /// The trap this projection exists to avoid. `Runner.isLive` answers "is
    /// anything running in this workstream", which stays true while a sibling
    /// check keeps going — so a state read from it would report this run as still
    /// running in the very notice announcing that it finished.
    func test_aFinishedRunReadsAsFinishedWhileAnotherCheckKeepsTheWorkstreamLive() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rspec"])
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "efgh5678", checks: ["vitest"])

        let running = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(running?.state, .running, "its check has not finished")

        finish(runner, runID: "abcd1234", [("rspec", .passed)])

        let finished = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(
            finished?.state, .finished,
            "read from this run's own rows, not from whether the workstream has anything live"
        )
    }

    /// Every run of this session resolves, not only the newest: runs are small
    /// now — no output rides on them — so there is nothing to bound.
    func test_everyRunOfTheSessionResolves() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "older123", checks: ["rubocop"])
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "newer456", checks: ["rspec"])
        finish(runner, runID: "older123", [("rubocop", .passed)])

        let older = await bridge.verificationRun(id: "older123", in: workstreamID)
        XCTAssertEqual(older?.checks.first?.state, .passed, "an earlier run of this session is still readable")
        let newer = await bridge.verificationRun(id: "newer456", in: workstreamID)
        XCTAssertNotNil(newer)
    }

    /// A run id is the tool's only argument and ids are short, so a read scoped
    /// to another workstream is refused rather than answered with someone else's
    /// results.
    func test_aRunBelongingToAnotherWorkstreamIsNil() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        runner.seedRunForTesting(workstreamID: UUID(), runID: "abcd1234", checks: ["rspec"])

        let foreign = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertNil(foreign)
    }

    func test_aRunIsStaleWhenTheWorktreeNoLongerMatchesItsStamp() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner, stamp: { _, _ in "head|2|changed" })
        runner.seedRunForTesting(
            workstreamID: workstreamID, runID: "abcd1234", checks: ["rubocop"], stamp: "head|1|original"
        )
        finish(runner, runID: "abcd1234", [("rubocop", .passed)])

        let info = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(info?.isStale, true, "a pass from before the last edit is a lie")
    }

    /// An empty stamp is the run's own baseline never having been captured, not a
    /// mismatch — and skipping the comparison also skips four git spawns.
    func test_aRunWhoseStampIsNotCaptured_isNotStaleAndAsksGitNothing() async {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner, stamp: { _, _ in
            XCTFail("the staleness read must not run when there is nothing to compare against")
            return ""
        })
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rspec"])

        let info = await bridge.verificationRun(id: "abcd1234", in: workstreamID)
        XCTAssertEqual(info?.isStale, false)
    }

    func test_anUnknownRunIsNil() async {
        let bridge = makeBridge(runner: Verification.Runner())
        let info = await bridge.verificationRun(id: "nosuchid", in: workstreamID)
        XCTAssertNil(info)
    }

    // MARK: - Per-check notices

    /// A check completing in a run an agent started carries that agent's surface, so the
    /// notice reaches the pane that asked rather than the workstream's main tab.
    func test_bridge_routesACheckNoticeToTheRequestingSurface() {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        let surface = UUID()
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rspec"])

        var notices: [IPC.VerificationCheckNotice] = []
        bridge.observeCheckCompletions { notices.append($0) }
        bridge.register(runID: "abcd1234", requesterSurfaceID: surface.uuidString)

        finish(runner, runID: "abcd1234", [("rspec", .failed(2))])

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.requesterSurfaceID, surface.uuidString)
        XCTAssertEqual(notices.first?.check.name, "rspec")
        XCTAssertEqual(notices.first?.check.state, .failed)
        XCTAssertEqual(notices.first?.check.exitCode, 2)
        XCTAssertEqual(notices.first?.workstreamID, workstreamID.uuidString)
    }

    /// A run the *user* pressed has no requester. It still produces a notice, and
    /// the service resolves the Coding Agent surface from the workstream id.
    func test_bridge_stillEmitsANoticeForARunNobodyAskedFor() {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rubocop"])

        var notices: [IPC.VerificationCheckNotice] = []
        bridge.observeCheckCompletions { notices.append($0) }

        finish(runner, runID: "abcd1234", [("rubocop", .passed)])

        XCTAssertEqual(notices.count, 1)
        XCTAssertNil(notices.first?.requesterSurfaceID)
        XCTAssertEqual(notices.first?.check.state, .passed)
    }

    /// Regression for the ordering `runFinished` must keep: `requesters.removeValue`
    /// has to run *before* the early return that a run with no registered completion
    /// takes, or that run's requester entry is never dropped. A run the user pressed
    /// (only a requester registered, no `onFinish`) takes that early return on every
    /// finish — so if the drop happened after it, the entry would leak forever and a
    /// later check notice for the same run id would still carry the stale surface.
    func test_bridge_dropsTheRequesterEntryEvenWhenTheRunHasNoRegisteredCompletion() {
        let runner = Verification.Runner()
        let bridge = makeBridge(runner: runner)

        var notices: [IPC.VerificationCheckNotice] = []
        bridge.observeCheckCompletions { notices.append($0) }
        // Only the requester is registered — the run-level `onFinish` never is, the
        // same shape a run the user pressed has in production.
        bridge.register(runID: "abcd1234", requesterSurfaceID: "leaked-surface")
        runner.seedRunForTesting(workstreamID: workstreamID, runID: "abcd1234", checks: ["rubocop"])

        // Finishes the run's only check, so `onFinish` fires and takes the early
        // return because no completion was registered for this run id.
        finish(runner, runID: "abcd1234", [("rubocop", .passed)])

        // A check completing under the same run id afterwards must not see the
        // requester the leaked entry would have kept alive. A name the run does not
        // carry, so this is a genuinely fresh completion rather than a repeat.
        finish(runner, runID: "abcd1234", [("vitest", .passed)])

        XCTAssertEqual(notices.map(\.check.name), ["rubocop", "vitest"])
        XCTAssertEqual(notices.first?.requesterSurfaceID, "leaked-surface")
        XCTAssertNil(notices.last?.requesterSurfaceID, "the requester entry must not outlive the run it belonged to")
    }
}
