// ABOUTME: Pins the execution bridge's four states and the two guards RunSession lacks.
// ABOUTME: Every seam is injected, so none of this needs a control socket or a binary.

@testable import Atelier
import XCTest

/// Stands in for process-compose's control API.
private final class StubProcessClient: ProcessCompose.Controlling, @unchecked Sendable {
    var entries: [ProcessCompose.ProcessEntry] = []
    var failure: Error?
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []
    private(set) var restarted: [String] = []
    private(set) var loggedTails: [Int] = []
    var lines: [String] = ["boom"]

    func processes() async throws -> [ProcessCompose.ProcessEntry] {
        if let failure {
            throw failure
        }
        return entries
    }

    func start(_ name: String) async throws {
        started.append(name)
        if let failure {
            throw failure
        }
    }

    func stop(_ name: String) async throws {
        stopped.append(name)
        if let failure {
            throw failure
        }
    }

    func restart(_ name: String) async throws {
        restarted.append(name)
        if let failure {
            throw failure
        }
    }

    func logs(name _: String, tail: Int) async throws -> [String] {
        loggedTails.append(tail)
        if let failure {
            throw failure
        }
        return lines
    }
}

@MainActor
final class ExecutionBridgeTests: XCTestCase {
    private let workstreamID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!

    // MARK: - Fixtures

    /// A run session with every seam inert, so a start records nothing on disk
    /// and nothing is spawned.
    private func session(socketBusy: Bool = false) -> ProcessCompose.RunSession {
        ProcessCompose.RunSession(
            workstreamID: workstreamID,
            ensureExecutionTab: {},
            removeSurface: { _ in },
            createSurface: { _, _, _, _ in },
            isSocketBusy: { _ in socketBusy },
            resolveBinary: { "/usr/local/bin/process-compose" },
            reclaimSocket: { _, _, _ in },
            tmuxSessionExists: { _, _ in false },
            killTmuxSession: { _, _ in },
            logLaunch: { _ in },
            loadPortsConfig: { _ in nil },
            observesSurfaceExits: false
        )
    }

    private func target() -> WorkspaceActions.ExecutionTarget {
        WorkspaceActions.ExecutionTarget(
            workstreamID: workstreamID,
            workstreamName: "wry-amber-lexer",
            projectName: "atelier",
            projectDirectory: NSTemporaryDirectory(),
            worktreePath: NSTemporaryDirectory(),
            defaultBranch: "main",
            devCommandOverride: nil,
            tmuxPath: nil,
            launcherPath: nil,
            shell: "/bin/zsh"
        )
    }

    private func resolution(
        plan: ProcessCompose.RunCommandPlan,
        declared: [String] = [],
        reason: String? = nil,
        usesProcessCompose: Bool? = nil
    ) -> ProcessCompose.Resolution {
        var resolution = ProcessCompose.Resolution()
        resolution.plan = plan
        resolution.declaredExecuteProcesses = declared
        resolution.startUnavailableReason = reason
        resolution.usesProcessCompose = usesProcessCompose ?? {
            if case .phaseScoped = plan {
                true
            } else {
                false
            }
        }()
        return resolution
    }

    private func bridge(
        session: ProcessCompose.RunSession,
        resolution: ProcessCompose.Resolution,
        client: StubProcessClient = StubProcessClient()
    ) -> IPC.ExecutionBridge {
        let target = target()
        return IPC.ExecutionBridge(
            runSession: { _ in session },
            target: { _ in target },
            client: { _ in client },
            resolution: { _ in resolution }
        )
    }

    // MARK: - The four states

    /// The pure read, every branch, with no socket in sight.
    func test_state_coversAllFourCases() {
        XCTAssertEqual(
            IPC.ExecutionBridge.state(plan: .nothing, usesProcessCompose: false, runStarted: false),
            .unavailable
        )
        XCTAssertEqual(
            IPC.ExecutionBridge.state(plan: .nothing, usesProcessCompose: true, runStarted: true),
            .unavailable,
            "a plan that cannot run is unavailable whatever else is true"
        )
        XCTAssertEqual(
            IPC.ExecutionBridge.state(plan: .literal("bin/dev"), usesProcessCompose: false, runStarted: false),
            .idle
        )
        XCTAssertEqual(
            IPC.ExecutionBridge.state(plan: .literal("bin/dev"), usesProcessCompose: true, runStarted: true),
            .running
        )
        XCTAssertEqual(
            IPC.ExecutionBridge.state(plan: .literal("bin/dev"), usesProcessCompose: false, runStarted: true),
            .runningWithoutProcessTable,
            "the user's own dev command has no control socket and never will"
        )
    }

    func test_executionState_isUnavailableWithItsReasonVerbatim() async throws {
        let bridge = bridge(
            session: session(),
            resolution: resolution(plan: .nothing, reason: "No execution.process-compose.yaml.")
        )
        let info = try await bridge.executionState(in: workstreamID)
        XCTAssertEqual(info.state, .unavailable)
        XCTAssertEqual(info.unavailableReason, "No execution.process-compose.yaml.")
        XCTAssertTrue(info.processes.isEmpty)
    }

    /// The reason is carried only where it is true — a reason beside `.idle`
    /// would read as a refusal of a run that is perfectly startable.
    func test_executionState_whenIdle_carriesNoReasonAndDoesNotTouchTheSocket() async throws {
        let client = StubProcessClient()
        client.entries = [
            ProcessCompose.ProcessEntry(
                name: "web", namespace: "execute", status: "Running", isReady: "Ready",
                hasReadyProbe: true, restarts: 0, exitCode: 0, pid: 1, isRunning: true
            ),
        ]
        let bridge = bridge(
            session: session(),
            resolution: resolution(plan: .literal("bin/dev"), declared: ["web"], reason: "ignored"),
            client: client
        )
        let info = try await bridge.executionState(in: workstreamID)
        XCTAssertEqual(info.state, .idle)
        XCTAssertNil(info.unavailableReason)
        XCTAssertTrue(info.processes.isEmpty, "nothing is running, so the table must not be read")
        XCTAssertEqual(info.declaredProcesses, ["web"], "declarations ride along in every state")
    }

    // MARK: - The guards

    /// `RunSession.stop()` has no guard of its own, and calling it with nothing
    /// running sets `runStoppedManually`, which suppresses the next launch's
    /// tmux restore. This is the bridge carrying that guard.
    func test_stop_withNothingRunning_answersFalseAndLeavesTheSessionAlone() async throws {
        let session = session()
        let generationBefore = session.runGeneration
        let bridge = bridge(session: session, resolution: resolution(plan: .literal("bin/dev")))

        let wasRunning = try await bridge.stopExecution(in: workstreamID)

        XCTAssertFalse(wasRunning)
        XCTAssertEqual(session.runGeneration, generationBefore, "stop() must not have been called")
        XCTAssertFalse(session.runStoppedManually, "a no-op stop must not suppress the tmux restore")
    }

    func test_stop_withARunUp_stopsItAndAnswersTrue() async throws {
        let session = session()
        let bridge = bridge(session: session, resolution: resolution(plan: .literal("bin/dev")))
        _ = try await bridge.startExecution(in: workstreamID, processes: [])
        XCTAssertTrue(session.runStarted)

        let wasRunning = try await bridge.stopExecution(in: workstreamID)

        XCTAssertTrue(wasRunning)
        XCTAssertFalse(session.runStarted)
    }

    func test_start_refusesARunThatIsAlreadyUp() async throws {
        let session = session()
        let bridge = bridge(session: session, resolution: resolution(plan: .literal("bin/dev")))
        _ = try await bridge.startExecution(in: workstreamID, processes: [])

        do {
            _ = try await bridge.startExecution(in: workstreamID, processes: [])
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, IPC.ExecutionFailure.alreadyRunning.localizedDescription)
        }
    }

    func test_start_refusesWhenThereIsNothingToRun() async {
        let bridge = bridge(
            session: session(),
            resolution: resolution(plan: .nothing, reason: "Nothing declares an execute namespace.")
        )
        do {
            _ = try await bridge.startExecution(in: workstreamID, processes: [])
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Nothing declares an execute namespace.")
        }
    }

    func test_start_reportsTheProcessesItWasScopedTo() async throws {
        let bridge = bridge(session: session(), resolution: resolution(plan: .literal("bin/dev")))
        let start = try await bridge.startExecution(in: workstreamID, processes: ["web"])
        XCTAssertEqual(start.started, ["web"])
        XCTAssertFalse(start.isReclaimingSocket)
    }

    /// An unscoped start reports an empty list — "whatever the user's checklist
    /// selects" — rather than inventing names it did not resolve.
    func test_start_withNoScope_reportsAnEmptyList() async throws {
        let bridge = bridge(session: session(), resolution: resolution(plan: .literal("bin/dev")))
        let start = try await bridge.startExecution(in: workstreamID, processes: [])
        XCTAssertTrue(start.started.isEmpty)
    }

    // MARK: - The socket-backed refusals

    func test_perProcessControl_refusesWhenNothingIsRunning() async {
        let client = StubProcessClient()
        let bridge = bridge(
            session: session(), resolution: resolution(plan: .literal("bin/dev")), client: client
        )
        do {
            try await bridge.controlProcess(in: workstreamID, name: "web", action: .restart)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("no process manager"),
                "got: \(error.localizedDescription)"
            )
            XCTAssertTrue(error.localizedDescription.contains("start_execution first"))
        }
        XCTAssertTrue(client.restarted.isEmpty, "the manager must not be driven at all")
    }

    /// The user's own dev command has no manager, and saying "nothing is
    /// running" there would send an agent to start a run that is already up.
    func test_perProcessControl_refusesAnOverrideRunByName() async throws {
        let session = session()
        let bridge = bridge(
            session: session,
            resolution: resolution(plan: .literal("bin/dev"), usesProcessCompose: false)
        )
        _ = try await bridge.startExecution(in: workstreamID, processes: [])

        do {
            try await bridge.controlProcess(in: workstreamID, name: "web", action: .stop)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("user's own dev command"),
                "got: \(error.localizedDescription)"
            )
        }
    }

    func test_logs_refuseWhenThereIsNoProcessTable() async {
        let client = StubProcessClient()
        let bridge = bridge(
            session: session(), resolution: resolution(plan: .nothing, reason: "No config."), client: client
        )
        do {
            _ = try await bridge.processLogs(in: workstreamID, name: "web", tail: 10)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No config."), error.localizedDescription)
        }
        XCTAssertTrue(client.loggedTails.isEmpty)
    }
}
