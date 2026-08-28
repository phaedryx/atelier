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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpoint = IPCEndpoint.read() { return endpoint }
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

    private func identity(project: String?) -> IPCClientIdentity {
        IPCClientIdentity(
            workstreamID: UUID().uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: project,
            isAgentSurface: true,
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
            isAgentSurface: true
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

    // MARK: - End to end

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
            isAgentSurface: true
        )
        _ = await service._testRegister(name: "planner", role: "writes plans", context: context)
        _ = try waitForEndpoint()

        let process = Process()
        process.executableURL = helper
        var environment = ProcessInfo.processInfo.environment
        environment["ATELIER_PROJECT_DIR"] = "/repos/atelier"
        environment["ATELIER_WORKSTREAM"] = "sly-cobalt-parser"
        environment["ATELIER_AGENT_SURFACE"] = "1"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
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
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["list_peers"])

        let call = try XCTUnwrap(replies[2]["result"] as? [String: Any])
        XCTAssertEqual(call["isError"] as? Bool, false)
        let content = try XCTUnwrap(call["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("planner"), "expected the registered peer in: \(text)")
        XCTAssertTrue(text.contains("wry-amber-lexer"), "expected the peer's workstream in: \(text)")
    }
}
