// ABOUTME: atelier-mcp — a stdio MCP server that forwards tool calls to the running app.
// ABOUTME: Does MCP framing and nothing else; the app owns the peer store.

import Darwin
import Foundation

// MARK: - Transport

/// A blocking line-protocol client for the app's IPC listener.
///
/// A plain POSIX socket rather than `NWConnection`: this process is a strictly
/// synchronous request/response loop driven by stdin, so a run loop and async
/// callbacks would be pure overhead.
final class IPCTransport {
    private var fd: Int32 = -1
    private var buffer = Data()

    func connect(to endpoint: IPCEndpoint) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(socketFD)
            return false
        }

        fd = socketFD
        return true
    }

    /// Sends one request and blocks for its reply.
    func roundTrip(_ request: IPCRequest) -> IPCResponse? {
        guard fd >= 0, let data = try? IPCFraming.encode(request) else { return nil }

        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard written > 0 else { return nil }
            sent += written
        }

        while true {
            let (lines, remainder) = IPCFraming.lines(from: buffer)
            buffer = remainder
            for line in lines {
                if let response = try? JSONDecoder().decode(IPCResponse.self, from: line), response.id == request.id {
                    return response
                }
            }

            var chunk = [UInt8](repeating: 0, count: 65_536)
            let read = recv(fd, &chunk, chunk.count, 0)
            guard read > 0 else { return nil }
            buffer.append(contentsOf: chunk[0 ..< read])
        }
    }
}

// MARK: - Tool definitions

/// The MCP tool surface. Each entry maps 1:1 onto an `IPCTool`.
struct ToolDefinition {
    let tool: IPCTool
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]

    var schema: [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
    }
}

let toolDefinitions: [ToolDefinition] = [
    ToolDefinition(
        tool: .listPeers,
        description: """
        List the other agents currently reachable over Atelier's IPC, with how \
        long ago each was last heard from and how many messages are waiting for \
        it. Only agents working in the same project are listed.
        """,
        properties: [:],
        required: []
    ),
]

// MARK: - JSON-RPC plumbing

func writeLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func reply(id: Any, result: [String: Any]) {
    writeLine(["jsonrpc": "2.0", "id": id, "result": result])
}

func reply(id: Any, code: Int, message: String) {
    writeLine(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// Renders a payload as the plain text an agent reads.
func renderText(_ payload: IPCPayload?) -> String {
    switch payload {
    case let .peers(peers):
        guard !peers.isEmpty else { return "No other agents are registered in this project." }
        return peers.map { peer in
            "\(peer.name) [\(peer.role)] id=\(peer.id)"
                + (peer.workstream.map { " workstream=\($0)" } ?? "")
                + " last-seen=\(peer.lastSeenSecondsAgo)s-ago pending=\(peer.pendingMessages)"
        }.joined(separator: "\n")
    case let .peer(peer):
        return "\(peer.name) [\(peer.role)] id=\(peer.id) last-seen=\(peer.lastSeenSecondsAgo)s-ago pending=\(peer.pendingMessages)"
    case let .messages(messages):
        guard !messages.isEmpty else { return "No new messages." }
        return messages.map { "From \($0.fromName) (\($0.from)), \($0.sentSecondsAgo)s ago:\n\($0.content)" }
            .joined(separator: "\n\n")
    case let .text(text):
        return text
    case nil:
        return ""
    }
}

func toolResult(id: Any, text: String, isError: Bool = false) {
    reply(id: id, result: [
        "content": [["type": "text", "text": text]],
        "isError": isError,
    ])
}

// MARK: - Main loop

/// Holds the connection to the app for the life of the session.
///
/// State lives here rather than in top-level `var`s so it isn't main-actor
/// isolated: the loop below is a plain synchronous read/dispatch cycle and has
/// no business being tangled up in actor isolation.
final class IPCBridge {
    /// The result of one forwarded tool call. A failure here reaches the agent
    /// as an error-flagged tool result, never as a JSON-RPC error: the server
    /// itself is fine, the call is what didn't work.
    enum Outcome {
        case ok(IPCPayload?)
        case failed(String)
    }

    private let identity = IPCClientIdentity.fromEnvironment()
    private let transport = IPCTransport()
    /// Resolved lazily and once: the app may not be listening when the agent
    /// starts, and exiting here would look like a broken MCP server rather than
    /// a recoverable tool error.
    private var endpoint: IPCEndpoint?

    func call(tool: IPCTool, arguments: [String: String]) -> Outcome {
        if endpoint == nil {
            guard let resolved = IPCEndpoint.read() else {
                return .failed("Atelier is not running, or agent IPC is disabled in its settings.")
            }
            guard transport.connect(to: resolved) else {
                return .failed("Could not reach Atelier's IPC listener on port \(resolved.port).")
            }
            endpoint = resolved
        }
        guard let endpoint else { return .failed("Not connected.") }

        let request = IPCRequest(token: endpoint.token, tool: tool, arguments: arguments, client: identity)
        guard let response = transport.roundTrip(request) else {
            return .failed("Atelier closed the IPC connection.")
        }
        if let error = response.error { return .failed(error) }
        return .ok(response.payload)
    }
}

let bridge = IPCBridge()

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String
    else { continue }

    let id = message["id"]

    switch method {
    case "initialize":
        let params = message["params"] as? [String: Any]
        let requested = params?["protocolVersion"] as? String
        reply(id: id ?? NSNull(), result: [
            "protocolVersion": requested ?? "2025-06-18",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "atelier-ipc", "version": "1"],
        ])

    case "notifications/initialized", "notifications/cancelled":
        continue

    case "ping":
        reply(id: id ?? NSNull(), result: [:])

    case "tools/list":
        let tools = toolDefinitions.map { definition -> [String: Any] in
            [
                "name": definition.tool.rawValue,
                "description": definition.description,
                "inputSchema": definition.schema,
            ]
        }
        reply(id: id ?? NSNull(), result: ["tools": tools])

    case "tools/call":
        guard let id else { continue }
        let params = message["params"] as? [String: Any]
        guard let name = params?["name"] as? String, let tool = IPCTool(rawValue: name) else {
            reply(id: id, code: -32602, message: "Unknown tool: \(params?["name"] as? String ?? "")")
            continue
        }
        // Every tool in this surface takes string arguments only; anything else
        // is rendered rather than rejected, so a stray number still reaches the app.
        var arguments: [String: String] = [:]
        for (key, value) in params?["arguments"] as? [String: Any] ?? [:] {
            arguments[key] = value as? String ?? String(describing: value)
        }

        switch bridge.call(tool: tool, arguments: arguments) {
        case let .ok(payload):
            toolResult(id: id, text: renderText(payload))
        case let .failed(message):
            toolResult(id: id, text: message, isError: true)
        }

    default:
        if let id {
            reply(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }
}
