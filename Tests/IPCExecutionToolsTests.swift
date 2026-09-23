// ABOUTME: Tests for the seven execution tools against a stub controller.
// ABOUTME: Covers scoping, the four run states, the tail clamp, and every refusal.

@testable import Atelier
import XCTest

/// Stands in for the run controller behind `IPC.ExecutionControlling`.
///
/// The point of declaring the seam on the IPC side: none of these tests need a
/// process-compose binary, a control socket, or a worktree.
private actor StubExecutionController: IPC.ExecutionControlling {
    var listedWorkstreams: [UUID] = []
    var startedWorkstreams: [UUID] = []
    var startedProcesses: [[String]] = []
    var controlled: [(name: String, action: IPC.ProcessAction)] = []
    var loggedTails: [Int] = []
    var stoppedWorkstreams: [UUID] = []
    var refusal: Error?

    var info = IPC.ExecutionInfo(
        state: .idle,
        unavailableReason: nil,
        declaredProcesses: ["web", "api"],
        processes: [],
        command: "execution.process-compose.yaml"
    )
    var start = IPC.ExecutionStart(started: ["web"], isReclaimingSocket: false)
    var stopAnswer = true

    func refuse(with error: Error) {
        refusal = error
    }

    func report(_ info: IPC.ExecutionInfo) {
        self.info = info
    }

    func answerStop(with value: Bool) {
        stopAnswer = value
    }

    func executionState(in workstreamID: UUID) async throws -> IPC.ExecutionInfo {
        listedWorkstreams.append(workstreamID)
        if let refusal {
            throw refusal
        }
        return info
    }

    func processLogs(in _: UUID, name: String, tail: Int) async throws -> IPC.ExecutionLogs {
        loggedTails.append(tail)
        if let refusal {
            throw refusal
        }
        return IPC.ExecutionLogs(process: name, lines: ["boom"], wasTrimmed: false)
    }

    func controlProcess(in _: UUID, name: String, action: IPC.ProcessAction) async throws {
        controlled.append((name, action))
        if let refusal {
            throw refusal
        }
    }

    func startExecution(in workstreamID: UUID, processes: [String]) async throws -> IPC.ExecutionStart {
        startedWorkstreams.append(workstreamID)
        startedProcesses.append(processes)
        if let refusal {
            throw refusal
        }
        return start
    }

    func stopExecution(in workstreamID: UUID) async throws -> Bool {
        stoppedWorkstreams.append(workstreamID)
        if let refusal {
            throw refusal
        }
        return stopAnswer
    }
}

final class IPCExecutionToolsTests: XCTestCase {
    private let workstreamID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let project = "/repos/atelier"
    private var service: IPC.Service!
    private var controller: StubExecutionController!

    override func setUp() {
        super.setUp()
        service = IPC.Service()
        controller = StubExecutionController()
    }

    // MARK: - Helpers

    private func client(workstreamID: UUID? = nil) -> IPC.ClientIdentity {
        IPC.ClientIdentity(
            workstreamID: (workstreamID ?? self.workstreamID).uuidString,
            workstreamName: "wry-amber-lexer",
            projectDirectory: project,
            surfaceID: nil,
            peerID: nil
        )
    }

    /// A client with no workstream at all — an agent Atelier did not launch.
    private var strayClient: IPC.ClientIdentity {
        IPC.ClientIdentity(
            workstreamID: nil,
            workstreamName: nil,
            projectDirectory: project,
            surfaceID: nil,
            peerID: nil
        )
    }

    @discardableResult
    private func call(
        _ tool: IPC.Tool,
        _ arguments: [String: String] = [:],
        as identity: IPC.ClientIdentity? = nil
    ) async -> IPC.Response {
        await service.handle(
            IPC.Request(token: "unused", tool: tool, arguments: arguments, client: identity ?? client())
        )
    }

    private func wire() async {
        await service.setExecutionController(controller)
    }

    // MARK: - Reads

    func test_listProcesses_scopesToTheCallersOwnWorkstream() async {
        await wire()
        await call(.listProcesses)
        let listed = await controller.listedWorkstreams
        XCTAssertEqual(listed, [workstreamID])
    }

    /// The reason must cross verbatim: an agent and `ExecutionTabView` have to
    /// say the same thing about the same file.
    func test_listProcesses_reportsUnavailableWithItsReasonVerbatim() async {
        await wire()
        await controller.report(
            IPC.ExecutionInfo(
                state: .unavailable,
                unavailableReason: "No execution.process-compose.yaml in the project directory.",
                declaredProcesses: [],
                processes: [],
                command: nil
            )
        )
        let response = await call(.listProcesses)
        guard case let .execution(info)? = response.payload else {
            return XCTFail("expected an execution payload, got \(String(describing: response.error))")
        }
        XCTAssertEqual(info.state, .unavailable)
        XCTAssertEqual(info.unavailableReason, "No execution.process-compose.yaml in the project directory.")
    }

    /// The declarations ride along even with nothing running — they are how an
    /// agent learns the names, and the config is outside its worktree.
    func test_listProcesses_carriesTheDeclarationsWhenNothingIsRunning() async {
        await wire()
        let response = await call(.listProcesses)
        guard case let .execution(info)? = response.payload else { return XCTFail("no payload") }
        XCTAssertEqual(info.state, .idle)
        XCTAssertEqual(info.declaredProcesses, ["web", "api"])
        XCTAssertTrue(info.processes.isEmpty)
    }

    func test_readProcessLogs_defaultsTheTailAndClampsIt() async {
        await wire()
        await call(.readProcessLogs, ["process": "web"])
        await call(.readProcessLogs, ["process": "web", "tail": "99999"])
        await call(.readProcessLogs, ["process": "web", "tail": "0"])
        let tails = await controller.loggedTails
        XCTAssertEqual(tails, [100, 1000, 1])
    }

    func test_readProcessLogs_refusesAMissingProcessName() async {
        await wire()
        let response = await call(.readProcessLogs)
        XCTAssertNil(response.payload)
        XCTAssertNotNil(response.error)
    }

    // MARK: - Per-process control

    func test_eachControlToolPassesItsOwnAction() async {
        await wire()
        await call(.startProcess, ["process": "web"])
        await call(.stopProcess, ["process": "web"])
        await call(.restartProcess, ["process": "api"])
        let controlled = await controller.controlled
        XCTAssertEqual(controlled.map(\.action), [.start, .stop, .restart])
        XCTAssertEqual(controlled.map(\.name), ["web", "web", "api"])
    }

    func test_controlTools_relayTheSeamsRefusalVerbatim() async {
        await wire()
        let failure = IPC.ExecutionFailure.noProcessTable("Nothing is running — start_execution first.")
        await controller.refuse(with: failure)
        let response = await call(.restartProcess, ["process": "web"])
        XCTAssertNil(response.payload)
        XCTAssertEqual(response.error, failure.localizedDescription)
    }

    // MARK: - Starting and stopping

    func test_startExecution_withNoProcesses_passesAnEmptyScope() async {
        await wire()
        await call(.startExecution)
        let scopes = await controller.startedProcesses
        XCTAssertEqual(scopes, [[]], "an omitted list means 'use the stored selection'")
    }

    func test_startExecution_passesTheNamedProcessesThrough() async {
        await wire()
        await call(.startExecution, ["processes": "web,api"])
        let scopes = await controller.startedProcesses
        XCTAssertEqual(scopes, [["web", "api"]])
    }

    /// There are no completion notices on this surface, so the answer has to say
    /// so — an agent that waits for one waits for the session.
    func test_startExecution_answerTellsTheAgentToPoll() async {
        await wire()
        let response = await call(.startExecution)
        guard case let .text(answer)? = response.payload else { return XCTFail("no text payload") }
        XCTAssertTrue(answer.contains("poll list_processes"), answer)
        XCTAssertTrue(answer.contains("Nothing will notify you"), answer)
        XCTAssertTrue(answer.contains("request_attention"), answer)
    }

    func test_startExecution_relaysTheSeamsRefusalVerbatim() async {
        await wire()
        await controller.refuse(with: IPC.ExecutionFailure.alreadyRunning)
        let response = await call(.startExecution)
        XCTAssertNil(response.payload)
        XCTAssertEqual(response.error, IPC.ExecutionFailure.alreadyRunning.localizedDescription)
    }

    /// A start refused mid-reclaim must forbid a retry rather than invite one:
    /// the caller cannot tell a real refusal from one its own retry caused.
    func test_startInFlightRefusal_forbidsARetry() {
        let message = IPC.ExecutionFailure.startInFlight.localizedDescription
        XCTAssertTrue(message.contains("Do not retry"), message)
    }

    func test_stopExecution_withNothingRunning_isSuccessNotARefusal() async {
        await wire()
        await controller.answerStop(with: false)
        let response = await call(.stopExecution)
        XCTAssertNil(response.error)
        guard case let .text(answer)? = response.payload else { return XCTFail("no text payload") }
        XCTAssertEqual(answer, "Nothing was running.")
    }

    func test_stopExecution_scopesToTheCallersOwnWorkstream() async {
        await wire()
        await call(.stopExecution)
        let stopped = await controller.stoppedWorkstreams
        XCTAssertEqual(stopped, [workstreamID])
    }

    // MARK: - Preconditions

    func test_everyExecutionTool_refusesWhenNoControllerIsWiredUp() async {
        for tool in [
            IPC.Tool.listProcesses, .readProcessLogs, .startProcess, .stopProcess,
            .restartProcess, .startExecution, .stopExecution,
        ] {
            let response = await call(tool, ["process": "web"])
            XCTAssertEqual(
                response.error,
                IPC.ExecutionFailure.notAvailable.localizedDescription,
                "\(tool.rawValue)"
            )
        }
    }

    /// An agent Atelier did not launch has no workstream for any of this to act
    /// on, and is refused before the controller is even consulted.
    func test_everyExecutionTool_refusesACallerWithNoWorkstream() async {
        await wire()
        for tool in [
            IPC.Tool.listProcesses, .readProcessLogs, .startProcess, .stopProcess,
            .restartProcess, .startExecution, .stopExecution,
        ] {
            let response = await call(tool, ["process": "web"], as: strayClient)
            XCTAssertNil(response.payload, "\(tool.rawValue)")
            XCTAssertNotNil(response.error, "\(tool.rawValue)")
        }
        let listed = await controller.listedWorkstreams
        XCTAssertTrue(listed.isEmpty, "the controller must not be reached at all")
    }

    // MARK: - A named process has to be one the config declares

    private func resolution(
        plan: ProcessCompose.RunCommandPlan,
        declared: [String] = []
    ) -> ProcessCompose.Resolution {
        var resolution = ProcessCompose.Resolution()
        resolution.plan = plan
        resolution.declaredExecuteProcesses = declared
        return resolution
    }

    private var phaseScoped: ProcessCompose.RunCommandPlan {
        .phaseScoped(
            config: ProcessCompose.Config(path: "/repos/atelier/execution.process-compose.yaml"),
            binary: "/opt/homebrew/bin/process-compose"
        )
    }

    /// The bug. `StartContextResolver.selectedProcesses` filters a per-call list
    /// through `runnableProcesses` — a flag-shaped-name check — and never
    /// against what the config declares, so `start_execution(processes: "typo")`
    /// ran `up -n execute typo` and answered "Starting typo… poll
    /// list_processes" for something that was never going to appear.
    func test_undeclared_namesAProcessTheConfigDoesNotDeclare() {
        XCTAssertEqual(
            IPC.ExecutionBridge.undeclared(["web", "typo"], in: resolution(plan: phaseScoped, declared: ["web", "api"])),
            ["typo"]
        )
    }

    func test_undeclared_isEmptyWhenEveryNameIsDeclared() {
        XCTAssertEqual(
            IPC.ExecutionBridge.undeclared(["api"], in: resolution(plan: phaseScoped, declared: ["web", "api"])),
            []
        )
    }

    /// The other half of the same finding, and why one guard covers both.
    /// `declaredExecuteProcesses` is already `runnableProcesses`-filtered, so a
    /// flag-shaped name cannot be in it — it is refused *as undeclared* rather
    /// than silently filtered out and then reported through the `nothingToRun`
    /// fallback, which told the agent "the user's Execution checklist has every
    /// process unticked" about a start no checklist was involved in.
    func test_undeclared_catchesAFlagShapedNameAsUndeclared() {
        XCTAssertEqual(
            IPC.ExecutionBridge.undeclared(["--verbose"], in: resolution(plan: phaseScoped, declared: ["web"])),
            ["--verbose"]
        )
    }

    /// A `.literal` plan is the user's own typed dev command: it has no
    /// namespace and no process names, so there is no set to check against and
    /// nothing to refuse.
    func test_undeclared_declinesToJudgeALiteralPlan() {
        XCTAssertNil(IPC.ExecutionBridge.undeclared(["web"], in: resolution(plan: .literal("bin/dev"))))
    }

    /// `.nothing` has no run at all, and the honest answer is the plan's own
    /// `startUnavailableReason` through the existing `nothingToRun` path — not
    /// "no such process".
    func test_undeclared_declinesToJudgeWhenThereIsNoRun() {
        XCTAssertNil(IPC.ExecutionBridge.undeclared(["web"], in: resolution(plan: .nothing)))
    }

    /// `.phaseScoped` with nothing declared is reachable only for a config Yams
    /// could not decode: `RunCommandPlan` turns a genuinely `.empty` execute
    /// namespace into `.nothing`. Refusing here would report "this project
    /// declares: nothing" as a fact about the user's file when what actually
    /// happened is that Atelier could not read it.
    func test_undeclared_declinesToJudgeAConfigItCouldNotRead() {
        XCTAssertNil(IPC.ExecutionBridge.undeclared(["web"], in: resolution(plan: phaseScoped, declared: [])))
    }

    /// The refusal names the whole legal set and every unknown name, the shape
    /// `Verification.Runner.Failure.unknownChecks` already uses — naming only
    /// the first would leave the caller retrying into the second.
    func test_theRefusal_namesEveryUnknownNameAndTheLegalSet() throws {
        let message = try XCTUnwrap(
            IPC.ExecutionFailure.unknownProcesses(["typo", "othertypo"], declared: ["web", "api"]).errorDescription
        )
        XCTAssertTrue(message.contains("typo, othertypo"), message)
        XCTAssertTrue(message.contains("web, api"), message)
    }
}
