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

    /// Drops the socket and any half-read frame with it. A leftover partial
    /// line would corrupt framing on the next connection.
    func disconnect() {
        if fd >= 0 {
            close(fd)
        }
        fd = -1
        buffer.removeAll()
    }

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

        // Without a receive timeout a stuck app hangs the agent's tool call
        // forever: no reply, no close, and a blocking recv. Generous, since
        // every handler here is sub-millisecond — this is a liveness backstop,
        // not a latency budget.
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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
            // 0 is a closed socket; -1 with EAGAIN is the timeout above. Both
            // mean "no answer is coming", which the caller turns into a
            // reconnect rather than a hang.
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
        tool: .registerPeer,
        description: """
        Register yourself so other agents can reach you. Call this once, before         anything else. Calling it again renames you rather than creating a         second identity.
        """,
        properties: [
            "name": ["type": "string", "description": "Short handle other agents will address you by. Defaults to your workstream name."],
            "role": ["type": "string", "description": "One line on what you are working on, so others know what to send you."],
        ],
        required: []
    ),
    ToolDefinition(
        tool: .listPeers,
        description: """
        List the other agents currently reachable, with how long ago each was         last heard from and how many messages are waiting for it. Only agents         working in the same project are listed.
        """,
        properties: [:],
        required: []
    ),
    ToolDefinition(
        tool: .sendMessage,
        description: """
        Put a message in another agent's inbox. Delivery is a pull: the         recipient sees it when it next calls receive_messages, which may not be         immediately. Do not block waiting for a reply.
        """,
        properties: [
            "to": ["type": "string", "description": "Peer id from list_peers."],
            "content": ["type": "string", "description": "The message. Say who you are and what you need."],
        ],
        required: ["to", "content"]
    ),
    ToolDefinition(
        tool: .receiveMessages,
        description: """
        Take everything waiting in your inbox. Messages are deleted as they are         returned, so act on what you get. Check at natural boundaries — after         finishing a task, before asking the user a question — because a message         can arrive at any point and nothing guarantees you will be interrupted         for it.
        """,
        properties: [:],
        required: []
    ),
    ToolDefinition(
        tool: .broadcast,
        description: """
        Send one message to every other agent in this project. Use it sparingly;         prefer send_message when you know who you need.
        """,
        properties: [
            "content": ["type": "string", "description": "The message."],
        ],
        required: ["content"]
    ),
    ToolDefinition(
        tool: .getPeerStatus,
        description: "Check one agent: whether it is still registered, and how many messages are waiting for it.",
        properties: [
            "peer_id": ["type": "string", "description": "Peer id from list_peers."],
        ],
        required: ["peer_id"]
    ),
]

/// Shown to the agent once, at initialize.
let serverInstructions = """
Agent-to-agent messaging inside Atelier. Register once with register_peer, then use list_peers and send_message to coordinate with agents working in other workstreams of this project.

Delivery is pull-based: a message sits in the recipient's inbox until it calls receive_messages. Atelier may nudge an idle agent's terminal, but that is best-effort and can be switched off, so check your inbox at natural boundaries rather than assuming you will be interrupted.
"""

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

    /// One attempt at a request, distinguishing "the app said no" from "the app
    /// isn't there any more" — only the second is worth reconnecting for.
    private enum Attempt {
        case ok(IPCPayload?)
        case refused(String)
        case disconnected
    }

    private let transport = IPCTransport()
    /// Resolved lazily, and again after a reconnect: a restarted Atelier
    /// listens on a new port with a new token.
    private var endpoint: IPCEndpoint?
    /// The identity `register_peer` handed this session. Sent with every later
    /// request, so a reconnect renames the same peer instead of stranding its
    /// inbox behind a dead id.
    private var peerID: String?
    /// What this session registered as, replayed after a reconnect so the agent
    /// does not have to notice that Atelier restarted.
    private var registration: [String: String]?

    /// Registers this session the moment the helper can reach the app, without
    /// waiting for the agent to ask.
    ///
    /// Registration used to be the agent's job, which made discovery depend on a
    /// model remembering an instruction it had no immediate use for — measured,
    /// and it does not happen. An agent's existence is what makes it reachable,
    /// so the helper claims an identity as soon as it has a connection: name
    /// defaults to the workstream, and `register_peer` from the agent becomes a
    /// rename rather than a prerequisite.
    ///
    /// Called on every incoming MCP message, so a session that starts before
    /// Atelier is listening still lands as soon as it is. Claude Code sends
    /// `initialize` and `tools/list` at startup, so this costs nothing extra.
    func ensureRegistered() {
        guard peerID == nil, connect() == nil else { return }
        _ = attempt(tool: .registerPeer, arguments: registration ?? [:])
    }

    func call(tool: IPCTool, arguments: [String: String]) -> Outcome {
        if let failure = connect() {
            return .failed(failure)
        }

        switch attempt(tool: tool, arguments: arguments) {
        case let .ok(payload):
            return .ok(payload)
        case let .refused(message):
            return .failed(message)
        case .disconnected:
            break
        }

        // Atelier went away mid-session — almost always a restart during
        // development. Reconnect once and replay, rather than making every
        // later tool call fail until the agent itself is restarted.
        transport.disconnect()
        endpoint = nil
        if let failure = connect() {
            return .failed("Atelier closed the IPC connection. \(failure)")
        }

        // A restarted app has an empty store, so the peer id from before is
        // meaningless. Re-register under the same name before retrying.
        if tool != .registerPeer, let registration {
            peerID = nil
            _ = attempt(tool: .registerPeer, arguments: registration)
        }

        switch attempt(tool: tool, arguments: arguments) {
        case let .ok(payload):
            return .ok(payload)
        case let .refused(message):
            return .failed(message)
        case .disconnected:
            return .failed("Atelier closed the IPC connection.")
        }
    }

    /// Opens the connection if it isn't already up. Returns a message on
    /// failure, nil on success.
    private func connect() -> String? {
        if endpoint != nil {
            return nil
        }
        guard let resolved = IPCEndpoint.read() else {
            return "Atelier is not running, or agent IPC is disabled in its settings."
        }
        guard transport.connect(to: resolved) else {
            return "Could not reach Atelier's IPC listener on port \(resolved.port)."
        }
        endpoint = resolved
        return nil
    }

    private func attempt(tool: IPCTool, arguments: [String: String]) -> Attempt {
        guard let endpoint else { return .disconnected }

        let identity = IPCClientIdentity.fromEnvironment(peerID: peerID)
        let request = IPCRequest(token: endpoint.token, tool: tool, arguments: arguments, client: identity)
        guard let response = transport.roundTrip(request) else { return .disconnected }
        if let error = response.error {
            // The app refuses a peer id whose previous connection it still
            // considers live — reachable when a reconnect overtakes the old
            // socket's close. Treated as final, that wedges the session for
            // good: `ensureRegistered` no-ops while `peerID` is set, so nothing
            // would ever ask again. Drop the identity and re-register instead.
            if error.contains("belongs to another session") {
                peerID = nil
                if case let .ok(payload) = attempt(tool: .registerPeer, arguments: registration ?? [:]),
                   case .peer = payload
                {
                    return attempt(tool: tool, arguments: arguments)
                }
            }
            return .refused(error)
        }

        if tool == .registerPeer, case let .peer(peer) = response.payload {
            peerID = peer.id
            registration = arguments
        }
        return .ok(response.payload)
    }
}

let bridge = IPCBridge()

while let line = readLine(strippingNewline: true) {
    bridge.ensureRegistered()

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
            "instructions": serverInstructions,
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
