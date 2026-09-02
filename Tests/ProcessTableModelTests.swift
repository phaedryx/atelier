// ABOUTME: Tests for the Environment process table: selection, port matching, polling, control.
// ABOUTME: A stub client stands in for process-compose so the error branches are reachable.

@testable import Atelier
import XCTest

final class ProcessTableModelTests: XCTestCase {
    /// Random per instance, so these never collide with a real workstream's
    /// selection in the test host's own defaults domain.
    private let workstreamID = UUID()

    override func tearDown() {
        ProcessTableModel.setSelected([], for: workstreamID)
        super.tearDown()
    }

    /// No stored selection means everything runs — a fresh workstream should
    /// start the whole stack, not nothing.
    func testNoSelectionMeansAll() {
        XCTAssertTrue(ProcessTableModel.selected(for: workstreamID).isEmpty)
    }

    func testSelectionRoundTrips() {
        ProcessTableModel.setSelected(["bff", "api"], for: workstreamID)

        XCTAssertEqual(ProcessTableModel.selected(for: workstreamID).sorted(), ["api", "bff"])
    }

    func testSelectionIsPerWorkstream() {
        let other = UUID()
        defer { ProcessTableModel.setSelected([], for: other) }
        ProcessTableModel.setSelected(["bff"], for: workstreamID)
        ProcessTableModel.setSelected(["api"], for: other)

        XCTAssertEqual(ProcessTableModel.selected(for: workstreamID), ["bff"])
        XCTAssertEqual(ProcessTableModel.selected(for: other), ["api"])
    }

    func testClearingSelectionRemovesIt() {
        ProcessTableModel.setSelected(["bff"], for: workstreamID)
        ProcessTableModel.setSelected([], for: workstreamID)

        XCTAssertTrue(ProcessTableModel.selected(for: workstreamID).isEmpty)
    }

    // MARK: - Port matching

    func testPortMatchesTheVariableNamedAfterTheProcess() {
        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ["BFF_PORT": "4001"]), "4001")
    }

    /// Separators differ freely between a process name and a variable name.
    func testPortMatchIgnoresSeparatorsAndCase() {
        let ports = ["HTML_TO_JSON_PORT": "4002"]

        XCTAssertEqual(ProcessTableModel.port(for: "html-to-json", in: ports), "4002")
        XCTAssertEqual(ProcessTableModel.port(for: "HTML_TO_JSON", in: ports), "4002")
        XCTAssertEqual(ProcessTableModel.port(for: "htmltojson", in: ports), "4002")
    }

    /// The `_PORT` suffix is optional on the variable, not required.
    func testPortMatchesAVariableWithoutTheSuffix() {
        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ["BFF": "4001"]), "4001")
    }

    /// An exact name match beats one that only matches after the suffix is
    /// allowed for, so a process actually called `bffport` gets its own value.
    func testExactMatchWinsOverSuffixMatch() {
        let ports = ["BFF_PORT": "4001", "BFF_PORT_PORT": "4002"]

        XCTAssertEqual(ProcessTableModel.port(for: "bff_port", in: ports), "4001")
    }

    func testUnmatchedProcessHasNoPort() {
        XCTAssertNil(ProcessTableModel.port(for: "worker", in: ["BFF_PORT": "4001"]))
    }

    /// A variable named only `PORT` must not become a wildcard that every
    /// process matches once the suffix is stripped.
    func testBarePortVariableMatchesNothing() {
        XCTAssertNil(ProcessTableModel.port(for: "bff", in: ["PORT": "3000"]))
    }

    /// Two variables can normalize to the same key. The lowest variable name
    /// wins, so the column is stable rather than showing whichever way the
    /// dictionary happened to iterate.
    func testCollidingVariablesResolveByLowestName() throws {
        let ports = ["BFF_PORT": "4001", "BFFPORT": "4002"]

        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ports), try ports[XCTUnwrap(ports.keys.min())])
        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ports), "4002")
    }

    // MARK: - Polling and control

    /// A socket file the model can stat. The suppression logic keys on the
    /// socket's existence, so the tests use a real file and really delete it
    /// rather than mocking the filesystem out from under the code.
    private func makeSocketFile() throws -> String {
        let path = NSTemporaryDirectory() + "pt-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func row(_ name: String, running: Bool = true) -> ProcessComposeProcess {
        ProcessComposeProcess(
            name: name, namespace: "execute", status: running ? "Running" : "Stopped",
            isReady: "-", hasReadyProbe: false, restarts: 0, exitCode: 0,
            pid: running ? 42 : 0, isRunning: running
        )
    }

    /// Two refreshes started at once must not put two requests on the wire. The
    /// stub's artificial latency is what makes an overlap observable at all.
    @MainActor
    func testConcurrentRefreshesDoNotOverlap() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(socketPath: path, replies: [.list([row("bff")])])
        let model = ProcessTableModel(socketPath: path, client: stub)

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)

        let calls = await stub.processesCalls
        let peak = await stub.peakConcurrency
        XCTAssertEqual(calls, 2, "both refreshes must actually run")
        XCTAssertEqual(peak, 1, "two process listings were in flight at once")
    }

    /// The path the review caught: pressing Stop while a poll is in flight used
    /// to fire a second listing alongside the first.
    @MainActor
    func testAControlRefreshDoesNotOverlapAPollInFlight() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(socketPath: path, replies: [.list([row("bff")])])
        let model = ProcessTableModel(socketPath: path, client: stub)

        async let poll: Void = model.refresh()
        async let control: Void = model.stop("bff")
        _ = await (poll, control)

        let peak = await stub.peakConcurrency
        XCTAssertEqual(peak, 1, "the control refresh raced the poll")
    }

    /// A reply that lands after the table was cleared must be dropped, or the
    /// next Start briefly shows the previous run's rows.
    @MainActor
    func testAReplyArrivingAfterStopPollingIsDiscarded() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(
            socketPath: path, replies: [.list([row("bff")])], latency: .milliseconds(200)
        )
        let model = ProcessTableModel(socketPath: path, client: stub)

        async let inFlight: Void = model.refresh()
        try await Task.sleep(for: .milliseconds(30))
        model.stopPolling()
        await inFlight

        XCTAssertTrue(model.processes.isEmpty, "a stale reply repopulated the table")
        XCTAssertNil(model.error)
    }

    /// Stopping the last running process ends the whole project. The manager
    /// exits and deletes its socket, so the follow-up listing fails — quietly.
    @MainActor
    func testAStopThatEndsTheProjectIsSilent() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(
            socketPath: path,
            replies: [.list([row("bff")]), .failure(.notRunning)],
            removesSocketOnStop: true
        )
        let model = ProcessTableModel(socketPath: path, client: stub)

        await model.refresh()
        XCTAssertEqual(model.processes.map(\.name), ["bff"])

        await model.stop("bff")

        XCTAssertTrue(model.processes.isEmpty)
        XCTAssertNil(model.error, "a stop that ends the project is not an error")
    }

    /// The same teardown can drop the connection mid-response instead, in which
    /// case the client reports `.malformedResponse`, not `.notRunning` — and it
    /// is thrown by the *refresh* after the stop, not by the stop itself.
    @MainActor
    func testAMalformedReplyAfterAStopThatEndsTheProjectIsSilent() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(
            socketPath: path,
            replies: [.list([row("bff")]), .failure(.malformedResponse)],
            removesSocketOnStop: true
        )
        let model = ProcessTableModel(socketPath: path, client: stub)

        await model.refresh()
        await model.stop("bff")

        XCTAssertTrue(model.processes.isEmpty)
        XCTAssertNil(model.error, "the shutdown race must not flash an error")
    }

    /// A dead manager must not leave its last rows on screen forever under an
    /// orange banner.
    @MainActor
    func testAFailureWithTheSocketGoneClearsTheRows() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(
            socketPath: path,
            replies: [.list([row("bff")]), .failure(.transport("read failed"))]
        )
        let model = ProcessTableModel(socketPath: path, client: stub)

        await model.refresh()
        XCTAssertEqual(model.processes.count, 1)

        try FileManager.default.removeItem(atPath: path)
        await model.refresh()

        XCTAssertTrue(model.processes.isEmpty, "stale rows survived the manager")
        XCTAssertNil(model.error)
    }

    /// A manager that is still there but answering badly is a real fault: keep
    /// what is known and say so.
    @MainActor
    func testAFailureWithTheSocketPresentShowsTheBanner() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(
            socketPath: path,
            replies: [.list([row("bff")]), .failure(.http(500))]
        )
        let model = ProcessTableModel(socketPath: path, client: stub)

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(model.processes.count, 1, "a reachable manager's last state is still useful")
        XCTAssertNotNil(model.error)
    }

    /// Starting a new run must not inherit the previous one's rows.
    @MainActor
    func testStartPollingClearsWhatTheLastRunLeft() async throws {
        let path = try makeSocketFile()
        let stub = StubComposeClient(socketPath: path, replies: [.list([row("bff")])])
        let model = ProcessTableModel(socketPath: path, client: stub)

        await model.refresh()
        XCTAssertEqual(model.processes.count, 1)

        model.startPolling()
        defer { model.stopPolling() }

        XCTAssertTrue(model.processes.isEmpty)
    }
}

/// Stands in for process-compose. An actor, so the counters are safe to read
/// from the test, and reentrant across its own `await` — which is what lets it
/// notice two listings in flight at once instead of hiding them.
private actor StubComposeClient: ProcessComposeControlling {
    enum Reply {
        case list([ProcessComposeProcess])
        case failure(ProcessComposeClient.ClientError)
    }

    private var replies: [Reply]
    private let socketPath: String
    private let removesSocketOnStop: Bool
    private let stopFailure: ProcessComposeClient.ClientError?
    private let latency: Duration

    private(set) var processesCalls = 0
    private(set) var peakConcurrency = 0
    private(set) var stopped: [String] = []
    private(set) var started: [String] = []
    private var inFlight = 0

    init(
        socketPath: String,
        replies: [Reply],
        removesSocketOnStop: Bool = false,
        stopFailure: ProcessComposeClient.ClientError? = nil,
        latency: Duration = .milliseconds(40)
    ) {
        self.socketPath = socketPath
        self.replies = replies
        self.removesSocketOnStop = removesSocketOnStop
        self.stopFailure = stopFailure
        self.latency = latency
    }

    func processes() async throws -> [ProcessComposeProcess] {
        processesCalls += 1
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        // A real request takes time. Without a suspension here an overlap could
        // never be observed, and the test would pass for the wrong reason.
        try? await Task.sleep(for: latency)
        inFlight -= 1

        let reply = replies.count > 1 ? replies.removeFirst() : (replies.first ?? .list([]))
        switch reply {
        case let .list(processes): return processes
        case let .failure(error): throw error
        }
    }

    func start(_ name: String) async throws {
        started.append(name)
    }

    func stop(_ name: String) async throws {
        stopped.append(name)
        if removesSocketOnStop {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        if let stopFailure { throw stopFailure }
    }

    func restart(_ name: String) async throws {
        started.append(name)
    }
}
