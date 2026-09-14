// ABOUTME: Tests for start_verification and check_verification against a stub runner.
// ABOUTME: Covers scoping, the seam's refusals, and the app-originated completion notice.

@testable import Atelier
import XCTest

/// Stands in for the check runner behind `IPC.VerificationControlling`.
///
/// The whole point of declaring the seam on this side: none of these tests need
/// a `verify` namespace, a process-compose binary, or a worktree.
private actor StubVerificationRunner: IPC.VerificationControlling {
    var startedWorkstreams: [UUID] = []
    var startedChecks: [[String]] = []
    var refusal: Error?
    var runs: [String: IPC.VerificationRunInfo] = [:]

    private var start: IPC.VerificationStart
    private var onFinish: (@Sendable (IPC.VerificationRunInfo) -> Void)?

    /// Unsafe on purpose: `observeCheckCompletions` is declared `@MainActor` on the
    /// protocol and satisfied here by a `nonisolated` stub, the same shape the
    /// no-op version already had. Tests only ever set this before, and read it
    /// after, an `await` on the same task, so there is no real race — just no
    /// actor to hop through for a synchronous store.
    private nonisolated(unsafe) var checkHandler: (@MainActor @Sendable (IPC.VerificationCheckNotice) -> Void)?

    init(start: IPC.VerificationStart = IPC.VerificationStart(runID: "v7f3a11", started: ["rspec", "rubocop"])) {
        self.start = start
    }

    func refuse(with error: Error) {
        refusal = error
    }

    func store(_ run: IPC.VerificationRunInfo) {
        runs[run.runID] = run
    }

    /// Fires the completion callback the way a sealed run does.
    func finish(with run: IPC.VerificationRunInfo) {
        onFinish?(run)
    }

    func startVerification(
        workstreamID: UUID,
        checks: [String],
        requesterSurfaceID _: String?,
        onFinish: @escaping @Sendable (IPC.VerificationRunInfo) -> Void
    ) async throws -> IPC.VerificationStart {
        startedWorkstreams.append(workstreamID)
        startedChecks.append(checks)
        if let refusal {
            throw refusal
        }
        self.onFinish = onFinish
        return start
    }

    func verificationRun(id: String, in _: UUID) async -> IPC.VerificationRunInfo? {
        runs[id]
    }

    nonisolated func observeCheckCompletions(_ handler: @escaping @MainActor @Sendable (IPC.VerificationCheckNotice) -> Void) {
        checkHandler = handler
    }

    /// Fires the check-completion callback the way `recordCompletion` does.
    nonisolated func completeCheck(_ notice: IPC.VerificationCheckNotice) async {
        await MainActor.run { checkHandler?(notice) }
    }
}

private struct StubRefusal: Error, LocalizedError {
    let errorDescription: String?
}

final class IPCVerificationToolsTests: XCTestCase {
    private var service: IPC.Service!
    private var runner: StubVerificationRunner!

    private let project = "/repos/atelier"
    private let workstreamID = UUID()

    override func setUp() {
        super.setUp()
        service = IPC.Service()
        runner = StubVerificationRunner()
    }

    // MARK: - Helpers

    private func client(surfaceID: UUID?, peerID: String? = nil, workstreamID: UUID? = nil) -> IPC.ClientIdentity {
        IPC.ClientIdentity(
            workstreamID: (workstreamID ?? self.workstreamID).uuidString,
            workstreamName: "wry-amber-lexer",
            projectDirectory: project,
            surfaceID: surfaceID?.uuidString,
            peerID: peerID
        )
    }

    private func call(
        _ tool: IPC.Tool,
        _ arguments: [String: String] = [:],
        as client: IPC.ClientIdentity
    ) async -> IPC.Response {
        await service.handle(IPC.Request(token: "unused", tool: tool, arguments: arguments, client: client))
    }

    /// Registers a peer on `surfaceID` and returns the identity its helper keeps.
    private func register(surfaceID: UUID, name: String, workstreamID: UUID? = nil) async throws -> IPC.ClientIdentity {
        let response = await call(
            .registerPeer,
            ["name": name],
            as: client(surfaceID: surfaceID, workstreamID: workstreamID)
        )
        guard case let .peer(peer) = response.payload else {
            throw XCTSkip("register_peer failed: \(String(describing: response.error))")
        }
        return client(surfaceID: surfaceID, peerID: peer.id, workstreamID: workstreamID)
    }

    private func run(
        id: String = "v7f3a11",
        workstreamID: UUID,
        state: IPC.VerificationRunState = .finished,
        checks: [IPC.VerificationCheckInfo]
    ) -> IPC.VerificationRunInfo {
        IPC.VerificationRunInfo(
            runID: id,
            workstreamID: workstreamID.uuidString,
            workstreamName: "wry-amber-lexer",
            state: state,
            startedSecondsAgo: 50,
            durationSeconds: 50,
            checks: checks,
            isStale: false,
            failureDetail: nil,
            unstartedChecksDetail: nil
        )
    }

    private func failingRun(id: String = "v7f3a11", workstreamID: UUID) -> IPC.VerificationRunInfo {
        run(id: id, workstreamID: workstreamID, checks: [
            IPC.VerificationCheckInfo(
                name: "rspec", state: .failed, exitCode: 1, durationSeconds: 48.1,
                outputTail: "3 examples, 1 failure", outputTruncated: false
            ),
        ])
    }

    /// A run that reached a terminal state having reported on nothing — `up -n` on an
    /// empty namespace, or an undecodable config. No check ever reached a terminal edge,
    /// so there are no per-check notices, and this is the one case the run-level notice
    /// still exists for.
    private func nothingRanRun(id: String = "v7f3a11", workstreamID: UUID, state: IPC.VerificationRunState = .finished) -> IPC.VerificationRunInfo {
        run(id: id, workstreamID: workstreamID, state: state, checks: [])
    }

    /// Drains an inbox, waiting for the detached delivery task to land.
    private func waitForInbox(_ identity: IPC.ClientIdentity, timeout: TimeInterval = 3) async -> [IPC.MessageInfo] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = await call(.receiveMessages, [:], as: identity)
            if case let .messages(messages) = response.payload, !messages.isEmpty {
                return messages
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return []
    }

    // MARK: - Starting

    func test_startVerification_answersWithTheRunIDAndTheChecksItStarted() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.startVerification, ["checks": "rspec, rubocop"], as: caller)

        guard case let .text(text) = response.payload else {
            return XCTFail("expected text, got \(String(describing: response.error))")
        }
        XCTAssertTrue(text.contains("v7f3a11"), text)
        XCTAssertTrue(text.contains("rspec, rubocop"), text)
        XCTAssertTrue(text.contains("check_verification"), "the poll read is the answer to a message that never arrives: \(text)")
        let startedChecks = await runner.startedChecks
        let startedWorkstreams = await runner.startedWorkstreams
        XCTAssertEqual(startedChecks, [["rspec", "rubocop"]])
        XCTAssertEqual(startedWorkstreams, [workstreamID], "a run belongs to the caller's own workstream")
    }

    func test_startVerification_withNoChecks_startsTheWholeNamespace() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")

        _ = await call(.startVerification, [:], as: caller)

        let startedChecks = await runner.startedChecks
        XCTAssertEqual(startedChecks, [[]], "empty means all — the codebase's own convention for a process selection")
    }

    func test_startVerification_outsideAWorkstream_refuses() async {
        await service.setVerificationRunner(runner)
        let stranger = IPC.ClientIdentity(
            workstreamID: nil, workstreamName: nil, projectDirectory: project, surfaceID: nil, peerID: nil
        )

        let response = await call(.startVerification, [:], as: stranger)

        XCTAssertNotNil(response.error)
        let startedWorkstreams = await runner.startedWorkstreams
        XCTAssertEqual(startedWorkstreams, [])
    }

    func test_startVerification_withNoRunnerWiredUp_saysSoRatherThanFailingObscurely() async throws {
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.startVerification, [:], as: caller)

        XCTAssertTrue(
            response.error?.contains("no check runner") == true,
            "got: \(String(describing: response.error))"
        )
    }

    /// The runner owns every precondition — `PhasePolicy.plan`, an absent
    /// namespace, an unknown check name, a run already in flight. This side must
    /// pass its refusal through rather than paraphrasing it.
    func test_startVerification_passesTheRunnersRefusalThrough() async throws {
        await service.setVerificationRunner(runner)
        await runner.refuse(with: StubRefusal(errorDescription: "run v7f3a11 is still going in this workstream."))
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.startVerification, [:], as: caller)

        XCTAssertEqual(response.error, "run v7f3a11 is still going in this workstream.")
        XCTAssertNil(response.payload)
    }

    // MARK: - The run-level notice (only for a run that completed nothing)

    /// Every check that reaches a terminal state posts its own notice — see the
    /// "per-check notice" section below — so a normal run's `onFinish` must stay
    /// silent, or the agent would be told twice.
    func test_aNormalFinishedRun_postsNoRunLevelNotice() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")
        _ = await call(.startVerification, [:], as: caller)

        await runner.finish(with: failingRun(workstreamID: workstreamID))

        let messages = await waitForInbox(caller, timeout: 0.3)
        XCTAssertTrue(messages.isEmpty, "each check posts its own notice; a run-level one would be a second telling")
    }

    /// The one case with no per-check notices to be silent through: nothing ran, so
    /// nothing completed. `up -n` on an empty namespace never exits, so `PhaseExecutor`
    /// returns `.skipped` without spawning — reachable here.
    func test_aRunThatCompletedNothing_postsARunLevelNotice() async throws {
        await service.setVerificationRunner(runner)
        let surfaceID = UUID()
        let caller = try await register(surfaceID: surfaceID, name: "builder")
        _ = await call(.startVerification, [:], as: caller)

        await runner.finish(with: nothingRanRun(workstreamID: workstreamID))

        let messages = await waitForInbox(caller)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.fromName, "atelier/verification")
        XCTAssertEqual(
            messages.first?.from,
            "atelier/verification",
            "the sender is a reserved label, not a peer id an agent could try to reply to"
        )
        XCTAssertTrue(messages.first?.content.contains("no checks ran") == true, messages.first?.content ?? "")
    }

    /// The other shape of "completed nothing": a spawn that died before binding leaves
    /// every *declared* check present as a row, sealed `.notRun` (`VerificationRunner.swift`,
    /// `case .pending: sealed.state = .notRun`) — rather than an empty `checks` array. With
    /// `total == 3` and `failed == 0`, "all 3 checks passed" is both true and a lie: nothing
    /// ran. This is the case the run-level notice exists to catch and the empty-array case
    /// does not exercise.
    func test_aRunThatCompletedNothingButLeftRowsBehind_isNotReportedAsAPass() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")
        _ = await call(.startVerification, [:], as: caller)

        await runner.finish(with: run(workstreamID: workstreamID, checks: [
            IPC.VerificationCheckInfo(name: "rspec", state: .notRun, exitCode: nil, durationSeconds: nil, outputTail: nil, outputTruncated: false),
            IPC.VerificationCheckInfo(name: "rubocop", state: .notRun, exitCode: nil, durationSeconds: nil, outputTail: nil, outputTruncated: false),
            IPC.VerificationCheckInfo(name: "tsc", state: .notRun, exitCode: nil, durationSeconds: nil, outputTail: nil, outputTruncated: false),
        ]))

        let messages = await waitForInbox(caller)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(
            messages.first?.content.lowercased().contains("passed") == true,
            "a run that ran nothing must never read as a green suite: \(messages.first?.content ?? "")"
        )
    }

    /// A run the user stopped before any check started also seals every row
    /// `.notRun`, but the user caused that deliberately and knows it happened — the
    /// notice exists to break a silence, not to report an action back to the person
    /// who took it.
    func test_aStoppedRunThatCompletedNothing_postsNoNotice() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")
        _ = await call(.startVerification, [:], as: caller)

        await runner.finish(with: nothingRanRun(workstreamID: workstreamID, state: .stopped))

        let messages = await waitForInbox(caller, timeout: 0.3)
        XCTAssertTrue(messages.isEmpty, "the user already knows they stopped it")
    }

    /// Two agents in one worktree is a supported shape and they report the same
    /// workstream name, so the surface id is the only discriminator. Addressed by
    /// workstream, this notice would land in the wrong pane's inbox half the time.
    func test_theNoticeGoesToTheCallersSurfaceAndNotItsSibling() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")
        let sibling = try await register(surfaceID: UUID(), name: "reviewer")
        _ = await call(.startVerification, [:], as: caller)

        await runner.finish(with: nothingRanRun(workstreamID: workstreamID))

        let delivered = await waitForInbox(caller)
        XCTAssertEqual(delivered.count, 1)
        let siblingInbox = await waitForInbox(sibling, timeout: 0.3)
        XCTAssertTrue(siblingInbox.isEmpty, "the sibling agent did not ask for this run")
    }

    /// The seam promises `onFinish` fires once. A second call would put a
    /// duplicate into an inbox with a hundred-message cap, and be unpleasant to
    /// diagnose from the agent's end.
    func test_aRunThatReportsFinishingTwice_postsOneNotice() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")
        _ = await call(.startVerification, [:], as: caller)

        await runner.finish(with: nothingRanRun(workstreamID: workstreamID))
        _ = await waitForInbox(caller)
        await runner.finish(with: nothingRanRun(workstreamID: workstreamID))

        let second = await waitForInbox(caller, timeout: 0.3)
        XCTAssertTrue(second.isEmpty, "the second completion must not post again")
    }

    /// A helper whose old socket has not closed yet is told its peer id belongs
    /// to another session and re-registers under a new one — so the peer that
    /// asked for the run can be dead while its pane has an agent sitting in it.
    /// The surface is the stable address, which is why the peer is resolved when
    /// the notice is posted rather than when the run started.
    func test_theNoticeReachesWhicheverPeerNowHoldsThatSurface() async throws {
        await service.setVerificationRunner(runner)
        let surfaceID = UUID()
        let first = try await register(surfaceID: surfaceID, name: "builder")
        _ = await call(.startVerification, [:], as: first)

        guard let oldPeerID = first.peerID.flatMap(UUID.init(uuidString:)) else {
            return XCTFail("the registration did not yield a peer id")
        }
        await service.release(peerID: oldPeerID)
        let second = try await register(surfaceID: surfaceID, name: "builder")
        XCTAssertNotEqual(second.peerID, first.peerID, "precondition: this is a new identity on the same surface")

        await runner.finish(with: nothingRanRun(workstreamID: workstreamID))

        let messages = await waitForInbox(second)
        XCTAssertEqual(messages.count, 1, "the notice must follow the surface, not the peer id captured at start")
    }

    func test_aCallerWithNoSurface_isToldToPollInstead() async {
        await service.setVerificationRunner(runner)
        // No `ATELIER_SURFACE_ID`: nothing Atelier launched, so there is no pane
        // to address and no inbox that can be found again.
        let response = await call(.startVerification, [:], as: client(surfaceID: nil))

        guard case let .text(text) = response.payload else {
            return XCTFail("expected text, got \(String(describing: response.error))")
        }
        XCTAssertTrue(text.contains("check_verification"), text)
        XCTAssertTrue(text.lowercased().contains("nothing will be posted"), text)
    }

    // MARK: - The per-check notice

    private func checkNotice(
        requesterSurfaceID: String?,
        state: IPC.VerificationCheckState = .passed,
        workstreamID: UUID
    ) -> IPC.VerificationCheckNotice {
        IPC.VerificationCheckNotice(
            runID: "v7f3a11", workstreamID: workstreamID.uuidString, requesterSurfaceID: requesterSurfaceID,
            check: IPC.VerificationCheckInfo(
                name: "rspec", state: state, exitCode: nil, durationSeconds: 12, outputTail: nil, outputTruncated: false
            )
        )
    }

    /// Nil means the user pressed Run, not an agent — so there is no requester's own
    /// pane to address. The fallback is the workstream's Coding Agent tab, whose
    /// surface id *is* the workstream id: this is the change the whole task is for,
    /// since such a run finished silently before it.
    func test_checkCompletion_withNoRequester_reachesTheWorkstreamsCodingAgentSurface() async throws {
        await service.setVerificationRunner(runner)
        let codingAgent = try await register(surfaceID: workstreamID, name: "coding-agent")
        await service.observeVerificationChecks()

        await runner.completeCheck(checkNotice(requesterSurfaceID: nil, workstreamID: workstreamID))

        let messages = await waitForInbox(codingAgent)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.from, "atelier/verification")
        XCTAssertTrue(messages.first?.content.contains("rspec") == true, messages.first?.content ?? "")
    }

    /// An agent that called `start_verification` gets its own run's checks back on
    /// its own pane — two agents in one worktree report the same workstream name, so
    /// the surface is the only discriminator between them.
    func test_checkCompletion_withARequester_reachesThatSurfaceNotASibling() async throws {
        await service.setVerificationRunner(runner)
        let requesterSurfaceID = UUID()
        let requester = try await register(surfaceID: requesterSurfaceID, name: "builder")
        let sibling = try await register(surfaceID: UUID(), name: "reviewer")
        await service.observeVerificationChecks()

        await runner.completeCheck(
            checkNotice(requesterSurfaceID: requesterSurfaceID.uuidString, workstreamID: workstreamID)
        )

        let delivered = await waitForInbox(requester)
        XCTAssertEqual(delivered.count, 1)
        let siblingInbox = await waitForInbox(sibling, timeout: 0.3)
        XCTAssertTrue(siblingInbox.isEmpty, "the sibling agent did not ask for this run")
    }

    // MARK: - Reading

    func test_checkVerification_returnsTheRun() async throws {
        await service.setVerificationRunner(runner)
        await runner.store(failingRun(workstreamID: workstreamID))
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.checkVerification, ["run_id": "v7f3a11"], as: caller)

        guard case let .verificationRun(info) = response.payload else {
            return XCTFail("expected a run, got \(String(describing: response.error))")
        }
        XCTAssertEqual(info.runID, "v7f3a11")
        XCTAssertEqual(info.state, .finished)
        XCTAssertEqual(info.checks.map(\.name), ["rspec"])
        XCTAssertEqual(info.checks.first?.state, .failed)
    }

    func test_checkVerification_boundsTheOutputItAnswersWith() async throws {
        await service.setVerificationRunner(runner)
        await runner.store(run(workstreamID: workstreamID, checks: [
            IPC.VerificationCheckInfo(
                name: "rspec", state: .failed, exitCode: 1, durationSeconds: 48,
                outputTail: String(repeating: "chatter\n", count: 100_000), outputTruncated: false
            ),
        ]))
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.checkVerification, ["run_id": "v7f3a11"], as: caller)

        guard case let .verificationRun(info) = response.payload else {
            return XCTFail("expected a run, got \(String(describing: response.error))")
        }
        let tail = try XCTUnwrap(info.checks.first?.outputTail)
        XCTAssertLessThanOrEqual(tail.utf8.count, IPC.VerificationSummary.maxReadTailBytesPerCheck)
        XCTAssertEqual(info.checks.first?.outputTruncated, true)
    }

    func test_checkVerification_withoutARunID_saysWhichArgumentIsMissing() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.checkVerification, [:], as: caller)

        XCTAssertTrue(response.error?.contains("run_id") == true, String(describing: response.error))
    }

    func test_checkVerification_forAnUnknownRun_saysRunIDsDoNotSurviveARestart() async throws {
        await service.setVerificationRunner(runner)
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.checkVerification, ["run_id": "v0000ff"], as: caller)

        XCTAssertTrue(response.error?.contains("restart") == true, String(describing: response.error))
    }

    /// A run id is the tool's only argument and ids are short, so a stale or
    /// mistyped one must be told it is not this caller's run rather than handed
    /// another workstream's results. Not a security boundary; every process here
    /// runs as the user.
    func test_checkVerification_refusesARunFromAnotherWorkstream() async throws {
        await service.setVerificationRunner(runner)
        await runner.store(failingRun(workstreamID: UUID()))
        let caller = try await register(surfaceID: UUID(), name: "builder")

        let response = await call(.checkVerification, ["run_id": "v7f3a11"], as: caller)

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("different workstream") == true, String(describing: response.error))
    }
}
