// ABOUTME: Tests the IPC transport: token gating, newline framing, and the atelier-mcp round trip.
// ABOUTME: The end-to-end case drives the real helper binary over stdio, as an agent would.

@testable import Atelier
import Darwin
import XCTest

/// A canned verification run, so the stdio test can prove a structured payload
/// survives the wire and the helper's rendering. `Sources/MCPHelper/main.swift`
/// is a separate target that `AtelierTests` cannot import, so driving the real
/// binary is the only way `renderText` ever executes.
private actor StubVerificationRunner: IPC.VerificationControlling {
    private let run: IPC.VerificationRunInfo

    init(run: IPC.VerificationRunInfo) {
        self.run = run
    }

    func startVerification(
        workstreamID _: UUID,
        checks _: [String],
        onFinish _: @escaping @Sendable (IPC.VerificationRunInfo) -> Void
    ) async throws -> IPC.VerificationStart {
        IPC.VerificationStart(runID: run.runID, started: run.checks.map(\.name))
    }

    func verificationRun(id: String, in _: UUID) async -> IPC.VerificationRunInfo? {
        id == run.runID ? run : nil
    }
}

final class IPCServerTests: XCTestCase {
    private var server: IPC.Server!
    private var service: IPC.Service!

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: IPC.Endpoint.fileURL)
        service = IPC.Service()
        server = IPC.Server(service: service)
        server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// The listener binds asynchronously, so every test waits for the endpoint
    /// file the way a helper process would.
    private func waitForEndpoint(timeout: TimeInterval = 5) throws -> IPC.Endpoint {
        // Must match *this* server's port: ipc.json is a shared path, and a
        // previous test's server can still be tearing down and removing it.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpoint = IPC.Endpoint.read(), endpoint.port == server.boundPort {
                return endpoint
            }
            usleep(20_000)
        }
        throw XCTSkip("IPC listener did not come up within \(timeout)s")
    }

    private func connect(to endpoint: IPC.Endpoint) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(result, 0, "could not connect to the IPC listener")
        return fd
    }

    private func roundTrip(_ request: IPC.Request, on fd: Int32) throws -> IPC.Response {
        let data = try IPC.Framing.encode(request)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, data.count, 0) }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 8192)
            let read = recv(fd, &chunk, chunk.count, 0)
            if read > 0 {
                buffer.append(contentsOf: chunk[0 ..< read])
            }
            let (lines, _) = IPC.Framing.lines(from: buffer)
            if let line = lines.first {
                return try JSONDecoder().decode(IPC.Response.self, from: line)
            }
        }
        throw XCTSkip("no IPC response within 5s")
    }

    private func identity(project: String?, surfaceID: UUID = UUID()) -> IPC.ClientIdentity {
        IPC.ClientIdentity(
            workstreamID: UUID().uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: project,
            surfaceID: surfaceID.uuidString,
            peerID: nil
        )
    }

    // MARK: - Transport

    func test_endpointFile_isWrittenPrivately() throws {
        let endpoint = try waitForEndpoint()
        XCTAssertGreaterThan(endpoint.port, 0)
        XCTAssertEqual(endpoint.token.count, 64)

        let attributes = try FileManager.default.attributesOfItem(atPath: IPC.Endpoint.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func test_listPeers_roundTripsOverTheSocket() async throws {
        let context = IPC.Service.PeerContext(
            workstreamID: UUID().uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: "/repos/atelier",
            surfaceID: UUID()
        )
        _ = await service._testRegister(name: "reviewer", role: "reviews diffs", context: context)

        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        let request = IPC.Request(token: endpoint.token, tool: .listPeers, client: identity(project: "/repos/atelier"))
        let response = try roundTrip(request, on: fd)

        XCTAssertNil(response.error)
        XCTAssertEqual(response.id, request.id)
        guard case let .peers(peers) = response.payload else {
            return XCTFail("expected a peers payload, got \(String(describing: response.payload))")
        }
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.name, "reviewer")
        XCTAssertEqual(peers.first?.workstream, "bold-crimson-parser")
    }

    func test_badToken_isRejected() throws {
        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        let request = IPC.Request(token: String(repeating: "0", count: 64), tool: .listPeers, client: identity(project: "/repos/atelier"))
        let response = try roundTrip(request, on: fd)

        XCTAssertEqual(response.error, "Unauthorized.")
        XCTAssertNil(response.payload)
    }

    func test_twoRequests_onOneConnection_bothAnswered() throws {
        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        let first = IPC.Request(token: endpoint.token, tool: .listPeers, client: identity(project: nil))
        XCTAssertNil(try roundTrip(first, on: fd).error)
        let second = IPC.Request(token: endpoint.token, tool: .listPeers, client: identity(project: nil))
        XCTAssertNil(try roundTrip(second, on: fd).error)
    }

    func test_closingAConnection_retiresItsPeer() throws {
        let endpoint = try waitForEndpoint()
        let caller = identity(project: "/repos/atelier")

        let fd = try connect(to: endpoint)
        let registration = try roundTrip(
            IPC.Request(token: endpoint.token, tool: .registerPeer, arguments: ["name": "departing"], client: caller),
            on: fd
        )
        guard case let .peer(peer) = registration.payload else {
            return XCTFail("expected a peer, got \(String(describing: registration.error))")
        }

        // The helper exits; the socket it held for the session goes with it.
        close(fd)

        let observer = try connect(to: endpoint)
        defer { close(observer) }
        let deadline = Date().addingTimeInterval(5)
        var listed: [IPC.PeerInfo] = [IPC.PeerInfo(id: peer.id, name: peer.name, role: "", workstream: nil, surfaceID: nil, lastSeenSecondsAgo: 0, pendingMessages: 0)]
        while Date() < deadline, !listed.isEmpty {
            let response = try roundTrip(
                IPC.Request(token: endpoint.token, tool: .listPeers, client: identity(project: "/repos/atelier")),
                on: observer
            )
            guard case let .peers(peers) = response.payload else { return XCTFail("expected peers") }
            listed = peers
        }
        XCTAssertTrue(listed.isEmpty, "a peer whose helper exited must not linger for the rest of its TTL")
    }

    /// A session becomes reachable because it exists, not because the agent
    /// remembered to announce itself.
    func test_helper_registersItselfWithoutAnyToolCall() throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")
        _ = try waitForEndpoint()

        func environment(workstream: String) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
            environment["ATELIER_WORKSTREAM"] = workstream
            environment["ATELIER_WORKSTREAM_ID"] = UUID().uuidString
            environment["ATELIER_SURFACE_ID"] = UUID().uuidString
            return environment
        }

        // Nothing but the MCP handshake — no tool is ever called on this one.
        let quiet = try MCPProcess(helper: helper, environment: environment(workstream: "quiet-agent"))
        XCTAssertNotNil(quiet.send(method: "initialize", params: ["protocolVersion": "2025-06-18"]))

        let observer = try MCPProcess(helper: helper, environment: environment(workstream: "observer"))
        let listed = try XCTUnwrap(observer.callTool("list_peers"))
        XCTAssertTrue(listed.contains("quiet-agent"), "an agent that never called a tool should still be reachable, got: \(listed)")
    }

    // MARK: - Peer ownership

    /// Reads from `fd` until it closes or the deadline passes; true if the
    /// server hung up.
    private func waitForClose(_ fd: Int32, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let read = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if read == 0 {
                return true
            }
            if read < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                return true
            }
            usleep(20_000)
        }
        return false
    }

    private func sendRaw(_ data: Data, on fd: Int32) {
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard written > 0 else { return }
            sent += written
        }
    }

    func test_aPeerCannotBeClaimedByAnotherLiveConnection() throws {
        let endpoint = try waitForEndpoint()

        let owner = try connect(to: endpoint)
        defer { close(owner) }
        let registration = try roundTrip(
            IPC.Request(token: endpoint.token, tool: .registerPeer, arguments: ["name": "owner"], client: identity(project: "/repos/atelier")),
            on: owner
        )
        guard case let .peer(peer) = registration.payload else { return XCTFail("expected a peer") }

        // A second agent claims the first agent's identity. Allowing it would
        // let anyone speak as anyone, retire a peer by hanging up, or keep a
        // dead one alive.
        let impostor = try connect(to: endpoint)
        defer { close(impostor) }
        var stolen = identity(project: "/repos/atelier")
        stolen = IPC.ClientIdentity(
            workstreamID: stolen.workstreamID,
            workstreamName: stolen.workstreamName,
            projectDirectory: stolen.projectDirectory,
            surfaceID: stolen.surfaceID,
            peerID: peer.id
        )
        let response = try roundTrip(
            IPC.Request(token: endpoint.token, tool: .listPeers, client: stolen),
            on: impostor
        )
        XCTAssertEqual(response.error, "That peer id belongs to another session.")
    }

    func test_aPeerCanBeReclaimedOnceItsConnectionIsGone() throws {
        let endpoint = try waitForEndpoint()

        let first = try connect(to: endpoint)
        let registration = try roundTrip(
            IPC.Request(token: endpoint.token, tool: .registerPeer, arguments: ["name": "reconnector"], client: identity(project: "/repos/atelier")),
            on: first
        )
        guard case let .peer(peer) = registration.payload else { return XCTFail("expected a peer") }
        close(first)

        // The helper's reconnect path: same peer id, new socket. Ownership has
        // to transfer, or the fix for impersonation would lock out the fix for
        // restarts.
        let deadline = Date().addingTimeInterval(5)
        var accepted = false
        while Date() < deadline, !accepted {
            let second = try connect(to: endpoint)
            defer { close(second) }
            var returning = identity(project: "/repos/atelier")
            returning = IPC.ClientIdentity(
                workstreamID: returning.workstreamID,
                workstreamName: returning.workstreamName,
                projectDirectory: returning.projectDirectory,
                surfaceID: returning.surfaceID,
                peerID: peer.id
            )
            let response = try roundTrip(
                IPC.Request(token: endpoint.token, tool: .registerPeer, arguments: ["name": "reconnector"], client: returning),
                on: second
            )
            accepted = response.error == nil
            if !accepted {
                usleep(50_000)
            }
        }
        XCTAssertTrue(accepted, "a returning helper must be able to reclaim its own peer")
    }

    /// The race two reviewers found independently: a peer is created by
    /// `register_peer`, but the connection dies before the reply-side claim can
    /// bind it. `forget` finds nothing bound and returns; the claim then finds
    /// no connection. Nothing released the peer — and a pinned peer no longer
    /// expires, so it would sit in `list_peers` collecting messages until the
    /// app restarted.
    func test_aRegistrationWhoseConnectionDiesImmediately_leavesNoGhost() throws {
        let endpoint = try waitForEndpoint()

        let doomed = try connect(to: endpoint)
        let request = IPC.Request(
            token: endpoint.token,
            tool: .registerPeer,
            arguments: ["name": "ghost"],
            client: identity(project: "/repos/atelier")
        )
        let data = try IPC.Framing.encode(request)
        _ = data.withUnsafeBytes { Darwin.send(doomed, $0.baseAddress!, data.count, 0) }
        // Hang up without waiting for the reply.
        close(doomed)

        let observer = try connect(to: endpoint)
        defer { close(observer) }
        let deadline = Date().addingTimeInterval(5)
        var listed: [IPC.PeerInfo] = []
        repeat {
            let response = try roundTrip(
                IPC.Request(token: endpoint.token, tool: .listPeers, client: identity(project: "/repos/atelier")),
                on: observer
            )
            guard case let .peers(peers) = response.payload else { return XCTFail("expected peers") }
            listed = peers
            if listed.isEmpty {
                break
            }
            usleep(50_000)
        } while Date() < deadline

        XCTAssertTrue(listed.isEmpty, "a peer nobody owns must not outlive the connection that made it")
    }

    // MARK: - Hostile input

    func test_anUnparseableFrame_closesTheConnection() throws {
        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        // Dropping it silently would leave the caller blocked on a reply that
        // never comes — what version skew between helper and app looks like.
        sendRaw(Data("not json at all\n".utf8), on: fd)
        XCTAssertTrue(waitForClose(fd), "the server should hang up rather than leave the caller waiting")
    }

    func test_anEndlessFrame_closesTheConnection() throws {
        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        // No newline, ever: without a cap the app buffers until it dies.
        sendRaw(Data(repeating: UInt8(ascii: "a"), count: 1_200_000), on: fd)
        XCTAssertTrue(waitForClose(fd), "an oversized frame should be cut off")
    }

    // MARK: - End to end

    /// Two helper processes, two registered peers, one message between them —
    /// the whole feature exercised through the real binaries.
    func test_twoHelpers_exchangeAMessage() throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")
        _ = try waitForEndpoint()

        func environment(workstream: String) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
            environment["ATELIER_WORKSTREAM"] = workstream
            environment["ATELIER_WORKSTREAM_ID"] = UUID().uuidString
            environment["ATELIER_SURFACE_ID"] = UUID().uuidString
            return environment
        }

        let planner = try MCPProcess(helper: helper, environment: environment(workstream: "wry-amber-lexer"))
        let builder = try MCPProcess(helper: helper, environment: environment(workstream: "bold-crimson-parser"))

        XCTAssertNotNil(planner.callTool("register_peer", ["name": "planner", "role": "writes plans"]))
        XCTAssertNotNil(builder.callTool("register_peer", ["name": "builder", "role": "writes code"]))

        let listed = try XCTUnwrap(planner.callTool("list_peers"))
        XCTAssertTrue(listed.contains("builder"), "planner should see builder, got: \(listed)")
        let builderID = try XCTUnwrap(listed.split(separator: " ").first { $0.hasPrefix("id=") }?.dropFirst(3))

        let sent = try XCTUnwrap(planner.callTool("send_message", ["to": String(builderID), "content": "plan is ready"]))
        XCTAssertEqual(sent, "Delivered to builder's inbox.")

        let inbox = try XCTUnwrap(builder.callTool("receive_messages"))
        XCTAssertTrue(inbox.contains("plan is ready"), "builder should have the message, got: \(inbox)")
        XCTAssertTrue(inbox.contains("planner"), "the message should name its sender, got: \(inbox)")

        XCTAssertEqual(builder.callTool("receive_messages"), "No new messages.")
    }

    /// Atelier quitting and coming back is the common case in development: new
    /// port, new token, empty store. The helper should recover on its own rather
    /// than failing every call until the agent is restarted.
    func test_helper_reconnectsAndReregistersAfterARestart() throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")
        let first = try waitForEndpoint()

        func environment(workstream: String) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
            environment["ATELIER_WORKSTREAM"] = workstream
            environment["ATELIER_WORKSTREAM_ID"] = UUID().uuidString
            environment["ATELIER_SURFACE_ID"] = UUID().uuidString
            return environment
        }

        let survivor = try MCPProcess(helper: helper, environment: environment(workstream: "wry-amber-lexer"))
        XCTAssertNotNil(survivor.callTool("register_peer", ["name": "survivor", "role": "keeps going"]))

        server.stop()
        let restarted = IPC.Server(service: IPC.Service())
        defer { restarted.stop() }
        restarted.start()

        let deadline = Date().addingTimeInterval(5)
        var second: IPC.Endpoint?
        while Date() < deadline, second == nil {
            let current = IPC.Endpoint.read()
            second = current?.port == restarted.boundPort ? current : nil
            if second == nil {
                usleep(20_000)
            }
        }
        XCTAssertNotNil(second, "the restarted listener did not publish a new endpoint")
        XCTAssertNotEqual(second?.port, first.port)

        // The first call after the restart hits a dead socket, reconnects, and
        // replays the registration before retrying.
        XCTAssertEqual(survivor.callTool("list_peers"), "No other agents are registered in this project.")

        // A fresh helper proves the re-registration actually landed in the new
        // store, rather than the call merely not failing.
        let observer = try MCPProcess(helper: helper, environment: environment(workstream: "bold-crimson-parser"))
        XCTAssertNotNil(observer.callTool("register_peer", ["name": "observer"]))
        let listed = try XCTUnwrap(observer.callTool("list_peers"))
        XCTAssertTrue(listed.contains("survivor"), "expected the re-registered peer, got: \(listed)")
    }

    /// The bug: a lost connection made the helper re-send the call, and a
    /// `create_workstream` sent twice creates two worktrees — or tells the
    /// caller its creation failed, under a name the first copy had just taken.
    ///
    /// Driven against a listener that hangs up rather than a slow one, because
    /// the two reach the same code path and this one finishes in milliseconds:
    /// `create_workstream`'s real deadline is minutes by design.
    func test_helper_doesNotReplayACreateWorkstreamAfterLosingTheConnection() throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")
        let stub = try takeOverTheEndpoint(hangingUpOn: .createWorkstream)
        defer { stub.stop() }

        let agent = try MCPProcess(helper: helper, environment: stubEnvironment())
        let answer = try XCTUnwrap(agent.callTool("create_workstream", ["name": "fix-stale-base-branch"]))

        XCTAssertEqual(stub.count(of: .createWorkstream), 1, "the call must not be sent a second time")
        XCTAssertTrue(
            answer.contains("not retried"),
            "the agent has to be told the call was interrupted, not handed a guess: \(answer)"
        )
        XCTAssertGreaterThanOrEqual(
            stub.count(of: .registerPeer), 2,
            "the session still has to recover its identity, even though the call does not replay"
        )
    }

    /// The other half: refusing to replay an action must not cost the recovery
    /// that replay was added for. A read is still re-sent, and still answers.
    func test_helper_stillReplaysAReadAfterLosingTheConnection() throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")
        let stub = try takeOverTheEndpoint(hangingUpOn: .listPeers)
        defer { stub.stop() }

        let agent = try MCPProcess(helper: helper, environment: stubEnvironment())
        let answer = agent.callTool("list_peers")

        XCTAssertEqual(stub.count(of: .listPeers), 2, "a read is safe to re-send, and the recovery depends on it")
        XCTAssertEqual(answer, "No other agents are registered in this project.")
    }

    // MARK: - Stub listener

    private func stubEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
        environment["ATELIER_WORKSTREAM"] = "wry-amber-lexer"
        environment["ATELIER_WORKSTREAM_ID"] = UUID().uuidString
        environment["ATELIER_SURFACE_ID"] = UUID().uuidString
        return environment
    }

    /// Stops the real server and publishes a stub in its place, so a helper
    /// launched afterwards connects to something whose behaviour this test
    /// chooses. `ipc.json` is one shared path, so the handover has to wait for
    /// the real server to finish removing it.
    private func takeOverTheEndpoint(hangingUpOn tool: IPC.Tool) throws -> HangUpListener {
        // Waited for first, not just stopped: `NWListener` publishes `ipc.json`
        // from its own `.ready` callback, so a listener stopped before it came up
        // writes the file *after* the stub has written its own — leaving the
        // helper pointed at a port that was cancelled a moment later.
        _ = try waitForEndpoint()
        server.stop()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, IPC.Endpoint.read() != nil {
            usleep(20_000)
        }
        guard IPC.Endpoint.read() == nil else {
            throw XCTSkip("the real listener did not release ipc.json")
        }
        let stub = try HangUpListener(hangingUpOn: tool)
        try FilePersistence.writeAtomically(
            JSONEncoder().encode(IPC.Endpoint(port: stub.port, token: stub.token)),
            to: IPC.Endpoint.fileURL
        )
        return stub
    }

    /// Drives the built `atelier-mcp` over stdio exactly as Claude Code would.
    ///
    /// The helper resolves `ipc.json` through `AppConstants.cacheDirectory`,
    /// which redirects to `atelier-tests` under XCTest — the subprocess inherits
    /// `XCTestConfigurationFilePath`, so it lands in the same directory this
    /// test's server wrote to.
    func test_helperBinary_answersToolsCallOverStdio() async throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")

        let context = IPC.Service.PeerContext(
            workstreamID: UUID().uuidString,
            workstreamName: "wry-amber-lexer",
            projectDirectory: "/repos/atelier",
            surfaceID: UUID()
        )
        _ = await service._testRegister(name: "planner", role: "writes plans", context: context)

        // The helper runs as an agent inside this workstream, so a run it reads
        // has to belong to it.
        let callerWorkstreamID = UUID()
        await service.setVerificationRunner(StubVerificationRunner(run: IPC.VerificationRunInfo(
            runID: "v7f3a11c",
            workstreamID: callerWorkstreamID.uuidString,
            workstreamName: "sly-cobalt-parser",
            state: .finished,
            startedSecondsAgo: 50,
            durationSeconds: 48.1,
            checks: [
                IPC.VerificationCheckInfo(
                    name: "rspec", state: .failed, exitCode: 1, durationSeconds: 48.1,
                    outputTail: "3 examples, 1 failure\n./spec/models/contact_spec.rb:42",
                    outputTruncated: true
                ),
            ],
            isStale: false,
            failureDetail: nil
        )))
        _ = try waitForEndpoint()

        let process = Process()
        process.executableURL = helper
        var environment = ProcessInfo.processInfo.environment
        environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
        environment["ATELIER_WORKSTREAM"] = "sly-cobalt-parser"
        environment["ATELIER_WORKSTREAM_ID"] = callerWorkstreamID.uuidString
        environment["ATELIER_SURFACE_ID"] = UUID().uuidString
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate() }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_peers","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"check_verification","arguments":{"run_id":"v7f3a11c"}}}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var replies: [[String: Any]] = []
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while replies.count < 4, Date() < deadline {
            buffer.append(output.fileHandleForReading.availableData)
            let (lines, remainder) = IPC.Framing.lines(from: buffer)
            buffer = remainder
            for line in lines {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    replies.append(object)
                }
            }
        }
        XCTAssertEqual(replies.count, 4, "helper did not answer all four requests")

        let initialize = try XCTUnwrap(replies.first?["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18")

        let tools = try XCTUnwrap((replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let advertised = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            advertised,
            [
                "register_peer", "list_peers", "send_message", "receive_messages", "broadcast", "get_peer_status",
                "list_tabs", "read_review_comments", "open_editor", "open_agent_tab", "request_attention",
                "create_workstream", "start_verification", "check_verification",
            ]
        )
        // Every advertised name must be a real `IPC.Tool`. `toolDefinitions` and
        // the enum are two lists that have to agree, and a typo in a raw value
        // would otherwise surface as a tool the app rejects at dispatch time
        // rather than as a failure here.
        for name in advertised {
            XCTAssertNotNil(IPC.Tool(rawValue: name), "advertised tool \(name) is not an IPC.Tool")
        }
        // A `Tool` case with no definition is deliberate — it is how a case
        // lands ahead of its handler — but it must be *deliberate*, so pin the
        // ones currently unadvertised rather than letting the set drift. Every
        // case now has one; a new tool lands here as a failure until it is
        // either advertised or listed as knowingly hidden.
        let undefined = IPC.Tool.allCases.map(\.rawValue).filter { !advertised.contains($0) }
        XCTAssertEqual(
            undefined.sorted(),
            [],
            "a tool was added to IPC.Tool without a definition, or advertised before its handler landed"
        )

        let call = try XCTUnwrap(replies[2]["result"] as? [String: Any])
        XCTAssertEqual(call["isError"] as? Bool, false)
        let content = try XCTUnwrap(call["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("planner"), "expected the registered peer in: \(text)")
        XCTAssertTrue(text.contains("wry-amber-lexer"), "expected the peer's workstream in: \(text)")
        // Two agents in one workstream report the same workstream name, so the
        // surface id is the only thing that tells them apart — and the only way
        // a caller turns a tab it just created into a peer it can address.
        XCTAssertTrue(
            text.contains("surface=\(context.surfaceID?.uuidString ?? "")"),
            "expected the peer's surface id in: \(text)"
        )

        // The only exercise `renderText`'s verification case ever gets. It lives
        // in the helper target, which `AtelierTests` cannot import, so nothing
        // short of driving the binary proves a structured run survives the wire
        // and comes out as something an agent can read.
        let verification = try XCTUnwrap(replies[3]["result"] as? [String: Any])
        XCTAssertEqual(verification["isError"] as? Bool, false)
        let rendered = try XCTUnwrap(
            (verification["content"] as? [[String: Any]])?.first?["text"] as? String
        )
        XCTAssertTrue(rendered.contains("run v7f3a11c — finished in 48.1s"), rendered)
        XCTAssertTrue(rendered.contains("failed rspec exit=1 48.1s"), rendered)
        XCTAssertTrue(rendered.contains("    3 examples, 1 failure"), rendered)
        XCTAssertTrue(rendered.contains("    ./spec/models/contact_spec.rb:42"), rendered)
        XCTAssertTrue(rendered.contains("output trimmed"), "the runner already trimmed this tail: \(rendered)")
        // The log server is gone by the time an agent reads this, so the copy
        // must not send it looking for a fuller one.
        XCTAssertFalse(
            rendered.contains("Verification tab has all"),
            "there is no fuller copy anywhere after a run: \(rendered)"
        )
    }
}

/// Drives one `atelier-mcp` process over stdio, the way a coding agent does.
private final class MCPProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0

    init(helper: URL, environment: [String: String]) throws {
        process.executableURL = helper
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
    }

    deinit { process.terminate() }

    /// Sends one JSON-RPC request and blocks for the matching reply.
    func send(method: String, params: [String: Any]? = nil, timeout: TimeInterval = 10) -> [String: Any]? {
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params {
            message["params"] = params
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            buffer.append(output.fileHandleForReading.availableData)
            let (lines, remainder) = IPC.Framing.lines(from: buffer)
            buffer = remainder
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if object["id"] as? Int == id {
                    return object
                }
            }
        }
        return nil
    }

    /// Calls a tool and returns the text an agent would read.
    func callTool(_ name: String, _ arguments: [String: String] = [:]) -> String? {
        let reply = send(method: "tools/call", params: ["name": name, "arguments": arguments])
        let result = reply?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }
}

/// A loopback listener that answers every request, except that the first time
/// one chosen tool arrives it hangs up without replying.
///
/// That is the `.disconnected` branch of `IPCBridge.call` — the one that
/// reconnects, re-registers, and used to re-send whatever it was carrying. A
/// real app that is merely *slow* reaches the same branch through a deadline
/// instead, which is why this stands in for it: same code path, milliseconds
/// rather than the minutes `create_workstream` is allowed.
private final class HangUpListener {
    let port: UInt16
    let token = "stub-token-for-the-replay-tests"

    private let listenFD: Int32
    private let hangUpOn: IPC.Tool
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var hungUp = false
    private var running = true

    init(hangingUpOn tool: IPC.Tool) throws {
        hangUpOn = tool

        // Bound through a local rather than the stored property: a closure in an
        // initializer may not read `self` before every member has a value.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("could not open a stub listener socket") }
        listenFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw XCTSkip("could not bind a stub listener")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw XCTSkip("could not read the stub listener's port")
        }
        port = assigned.sin_port.bigEndian

        Thread.detachNewThread { [weak self] in
            while let self, isRunning {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                serve(connection)
                close(connection)
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        close(listenFD)
        try? FileManager.default.removeItem(at: IPC.Endpoint.fileURL)
    }

    func count(of tool: IPC.Tool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[tool.rawValue] ?? 0
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Reads frames until the peer goes away, or until the chosen tool arrives
    /// for the first time — at which point the caller closes this connection.
    private func serve(_ connection: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while isRunning {
            let read = recv(connection, &chunk, chunk.count, 0)
            guard read > 0 else { return }
            buffer.append(contentsOf: chunk[0 ..< read])

            let (lines, remainder) = IPC.Framing.lines(from: buffer)
            buffer = remainder
            for line in lines {
                guard let request = try? JSONDecoder().decode(IPC.Request.self, from: line) else { continue }

                lock.lock()
                counts[request.tool.rawValue, default: 0] += 1
                let shouldHangUp = request.tool == hangUpOn && !hungUp
                if shouldHangUp {
                    hungUp = true
                }
                lock.unlock()

                if shouldHangUp {
                    return
                }
                send(reply(to: request), on: connection)
            }
        }
    }

    private func reply(to request: IPC.Request) -> IPC.Response {
        switch request.tool {
        case .registerPeer:
            .success(id: request.id, .peer(IPC.PeerInfo(
                id: UUID().uuidString,
                name: "wry-amber-lexer",
                role: "",
                workstream: "wry-amber-lexer",
                surfaceID: nil,
                lastSeenSecondsAgo: 0,
                pendingMessages: 0
            )))
        case .listPeers:
            .success(id: request.id, .peers([]))
        default:
            .success(id: request.id, .text("the stub answered \(request.tool.rawValue)"))
        }
    }

    private func send(_ response: IPC.Response, on connection: Int32) {
        guard let data = try? IPC.Framing.encode(response) else { return }
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                Darwin.send(connection, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard written > 0 else { return }
            sent += written
        }
    }
}
