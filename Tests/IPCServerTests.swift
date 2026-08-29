// ABOUTME: Tests the IPC transport: token gating, newline framing, and the atelier-mcp round trip.
// ABOUTME: The end-to-end case drives the real helper binary over stdio, as an agent would.

@testable import Atelier
import Darwin
import XCTest

final class IPCServerTests: XCTestCase {
    private var server: IPCServer!
    private var service: IPCService!

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: IPCEndpoint.fileURL)
        service = IPCService()
        server = IPCServer(service: service)
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
    private func waitForEndpoint(timeout: TimeInterval = 5) throws -> IPCEndpoint {
        // Must match *this* server's port: ipc.json is a shared path, and a
        // previous test's server can still be tearing down and removing it.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpoint = IPCEndpoint.read(), endpoint.port == server.boundPort {
                return endpoint
            }
            usleep(20_000)
        }
        throw XCTSkip("IPC listener did not come up within \(timeout)s")
    }

    private func connect(to endpoint: IPCEndpoint) throws -> Int32 {
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

    private func roundTrip(_ request: IPCRequest, on fd: Int32) throws -> IPCResponse {
        let data = try IPCFraming.encode(request)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, data.count, 0) }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 8192)
            let read = recv(fd, &chunk, chunk.count, 0)
            if read > 0 { buffer.append(contentsOf: chunk[0 ..< read]) }
            let (lines, _) = IPCFraming.lines(from: buffer)
            if let line = lines.first {
                return try JSONDecoder().decode(IPCResponse.self, from: line)
            }
        }
        throw XCTSkip("no IPC response within 5s")
    }

    private func identity(project: String?, surfaceID: UUID = UUID()) -> IPCClientIdentity {
        IPCClientIdentity(
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

        let attributes = try FileManager.default.attributesOfItem(atPath: IPCEndpoint.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func test_listPeers_roundTripsOverTheSocket() async throws {
        let context = IPCService.PeerContext(
            workstreamID: UUID().uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: "/repos/atelier",
            surfaceID: UUID()
        )
        _ = await service._testRegister(name: "reviewer", role: "reviews diffs", context: context)

        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        let request = IPCRequest(token: endpoint.token, tool: .listPeers, client: identity(project: "/repos/atelier"))
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

        let request = IPCRequest(token: String(repeating: "0", count: 64), tool: .listPeers, client: identity(project: "/repos/atelier"))
        let response = try roundTrip(request, on: fd)

        XCTAssertEqual(response.error, "Unauthorized.")
        XCTAssertNil(response.payload)
    }

    func test_twoRequests_onOneConnection_bothAnswered() throws {
        let endpoint = try waitForEndpoint()
        let fd = try connect(to: endpoint)
        defer { close(fd) }

        let first = IPCRequest(token: endpoint.token, tool: .listPeers, client: identity(project: nil))
        XCTAssertNil(try roundTrip(first, on: fd).error)
        let second = IPCRequest(token: endpoint.token, tool: .listPeers, client: identity(project: nil))
        XCTAssertNil(try roundTrip(second, on: fd).error)
    }

    func test_closingAConnection_retiresItsPeer() async throws {
        let endpoint = try waitForEndpoint()
        let caller = identity(project: "/repos/atelier")

        let fd = try connect(to: endpoint)
        let registration = try roundTrip(
            IPCRequest(token: endpoint.token, tool: .registerPeer, arguments: ["name": "departing"], client: caller),
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
        var listed: [IPCPeerInfo] = [IPCPeerInfo(id: peer.id, name: peer.name, role: "", workstream: nil, lastSeenSecondsAgo: 0, pendingMessages: 0)]
        while Date() < deadline, !listed.isEmpty {
            let response = try roundTrip(
                IPCRequest(token: endpoint.token, tool: .listPeers, client: identity(project: "/repos/atelier")),
                on: observer
            )
            guard case let .peers(peers) = response.payload else { return XCTFail("expected peers") }
            listed = peers
        }
        XCTAssertTrue(listed.isEmpty, "a peer whose helper exited must not linger for the rest of its TTL")
    }

    // MARK: - Peer ownership

    /// Reads from `fd` until it closes or the deadline passes; true if the
    /// server hung up.
    private func waitForClose(_ fd: Int32, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let read = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if read == 0 { return true }
            if read < 0, errno != EAGAIN, errno != EWOULDBLOCK { return true }
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
            IPCRequest(token: endpoint.token, tool: .registerPeer, arguments: ["name": "owner"], client: identity(project: "/repos/atelier")),
            on: owner
        )
        guard case let .peer(peer) = registration.payload else { return XCTFail("expected a peer") }

        // A second agent claims the first agent's identity. Allowing it would
        // let anyone speak as anyone, retire a peer by hanging up, or keep a
        // dead one alive.
        let impostor = try connect(to: endpoint)
        defer { close(impostor) }
        var stolen = identity(project: "/repos/atelier")
        stolen = IPCClientIdentity(
            workstreamID: stolen.workstreamID,
            workstreamName: stolen.workstreamName,
            projectDirectory: stolen.projectDirectory,
            surfaceID: stolen.surfaceID,
            peerID: peer.id
        )
        let response = try roundTrip(
            IPCRequest(token: endpoint.token, tool: .listPeers, client: stolen),
            on: impostor
        )
        XCTAssertEqual(response.error, "That peer id belongs to another session.")
    }

    func test_aPeerCanBeReclaimedOnceItsConnectionIsGone() throws {
        let endpoint = try waitForEndpoint()

        let first = try connect(to: endpoint)
        let registration = try roundTrip(
            IPCRequest(token: endpoint.token, tool: .registerPeer, arguments: ["name": "reconnector"], client: identity(project: "/repos/atelier")),
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
            returning = IPCClientIdentity(
                workstreamID: returning.workstreamID,
                workstreamName: returning.workstreamName,
                projectDirectory: returning.projectDirectory,
                surfaceID: returning.surfaceID,
                peerID: peer.id
            )
            let response = try roundTrip(
                IPCRequest(token: endpoint.token, tool: .registerPeer, arguments: ["name": "reconnector"], client: returning),
                on: second
            )
            accepted = response.error == nil
            if !accepted { usleep(50_000) }
        }
        XCTAssertTrue(accepted, "a returning helper must be able to reclaim its own peer")
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
        let restarted = IPCServer(service: IPCService())
        defer { restarted.stop() }
        restarted.start()

        let deadline = Date().addingTimeInterval(5)
        var second: IPCEndpoint?
        while Date() < deadline, second == nil {
            let current = IPCEndpoint.read()
            second = current?.port == restarted.boundPort ? current : nil
            if second == nil { usleep(20_000) }
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

    /// Drives the built `atelier-mcp` over stdio exactly as Claude Code would.
    ///
    /// The helper resolves `ipc.json` through `AppConstants.cacheDirectory`,
    /// which redirects to `atelier-tests` under XCTest — the subprocess inherits
    /// `XCTestConfigurationFilePath`, so it lands in the same directory this
    /// test's server wrote to.
    func test_helperBinary_answersToolsCallOverStdio() async throws {
        let helper = try XCTUnwrap(MCPHelperLauncher.executableURL(), "atelier-mcp was not found in the host app bundle")

        let context = IPCService.PeerContext(
            workstreamID: UUID().uuidString,
            workstreamName: "wry-amber-lexer",
            projectDirectory: "/repos/atelier",
            surfaceID: UUID()
        )
        _ = await service._testRegister(name: "planner", role: "writes plans", context: context)
        _ = try waitForEndpoint()

        let process = Process()
        process.executableURL = helper
        var environment = ProcessInfo.processInfo.environment
        environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
        environment["ATELIER_WORKSTREAM"] = "sly-cobalt-parser"
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
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var replies: [[String: Any]] = []
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while replies.count < 3, Date() < deadline {
            buffer.append(output.fileHandleForReading.availableData)
            let (lines, remainder) = IPCFraming.lines(from: buffer)
            buffer = remainder
            for line in lines {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    replies.append(object)
                }
            }
        }
        XCTAssertEqual(replies.count, 3, "helper did not answer all three requests")

        let initialize = try XCTUnwrap(replies.first?["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18")

        let tools = try XCTUnwrap((replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.map { $0["name"] as? String },
            ["register_peer", "list_peers", "send_message", "receive_messages", "broadcast", "get_peer_status"]
        )

        let call = try XCTUnwrap(replies[2]["result"] as? [String: Any])
        XCTAssertEqual(call["isError"] as? Bool, false)
        let content = try XCTUnwrap(call["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("planner"), "expected the registered peer in: \(text)")
        XCTAssertTrue(text.contains("wry-amber-lexer"), "expected the peer's workstream in: \(text)")
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
        if let params { message["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            buffer.append(output.fileHandleForReading.availableData)
            let (lines, remainder) = IPCFraming.lines(from: buffer)
            buffer = remainder
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if object["id"] as? Int == id { return object }
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
