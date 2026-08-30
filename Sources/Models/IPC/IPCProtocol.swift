// ABOUTME: Wire types shared by the app's IPC server and the atelier-mcp helper.
// ABOUTME: Newline-delimited JSON over loopback TCP — deliberately not HTTP.

import Foundation

/// Where the app's IPC listener is, and the token that admits a caller.
///
/// Written to `~/Library/Caches/atelier/ipc.json` at mode 0600 when the server
/// starts, and read by every `atelier-mcp` helper at startup. Keeping the token
/// here rather than in the MCP config means it never lands in `LaunchLogger`'s
/// verbatim record of the launch command.
///
/// Every process involved runs as the user, so the token is not a security
/// boundary against the agent. It stops another app colliding on the port and
/// stops a stray `fetch` from a page in the embedded browser. That is the whole
/// claim.
struct IPCEndpoint: Codable, Sendable {
    let port: UInt16
    let token: String

    static var fileURL: URL {
        AppConstants.cacheDirectory.appendingPathComponent("ipc.json")
    }

    static func read(from url: URL = IPCEndpoint.fileURL) -> IPCEndpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IPCEndpoint.self, from: data)
    }
}

/// The tools the helper exposes over MCP and forwards to the app.
///
/// Six, deliberately. Calix's IPC core is the same six; everything else it
/// grew — pane/tab control, LSP, shell integration — is a different feature
/// with a different trust story.
enum IPCTool: String, Codable, Sendable, CaseIterable {
    case registerPeer = "register_peer"
    case listPeers = "list_peers"
    case sendMessage = "send_message"
    case receiveMessages = "receive_messages"
    case broadcast
    case getPeerStatus = "get_peer_status"
}

/// One request from a helper to the app.
///
/// `arguments` is `[String: String]` rather than arbitrary JSON because every
/// tool in this surface takes only string arguments (peer ids, names, roles,
/// message bodies). That keeps both ends free of a hand-rolled JSON value type.
struct IPCRequest: Codable, Sendable {
    /// Correlates the response; the helper matches replies by this.
    let id: String
    let token: String
    /// The tool being invoked.
    let tool: IPCTool
    let arguments: [String: String]
    /// Identity the helper inherited from its terminal's environment.
    let client: IPCClientIdentity

    init(id: String = UUID().uuidString, token: String, tool: IPCTool, arguments: [String: String] = [:], client: IPCClientIdentity) {
        self.id = id
        self.token = token
        self.tool = tool
        self.arguments = arguments
        self.client = client
    }
}

/// Who is calling, as far as the environment can say.
///
/// The helper is a child of the terminal that launched the agent, so it reads
/// all of this from its own environment — no config interpolation, no headers.
struct IPCClientIdentity: Codable, Sendable {
    /// `ATELIER_WORKSTREAM_ID`, when the helper was launched inside a workstream.
    let workstreamID: String?
    /// `ATELIER_WORKSTREAM`, for display.
    let workstreamName: String?
    /// `ATELIER_PROJECT_DIR`, used for same-project scoping.
    let projectDirectory: String?
    /// `ATELIER_SURFACE_ID`: the terminal surface this agent is running in.
    ///
    /// Every Atelier-launched terminal exports its own — the Coding Agent tab
    /// and each terminal tab alike — so a nudge can be typed into the pane the
    /// recipient actually occupies rather than assumed to be the Agent tab.
    /// Absent for anything Atelier didn't launch, which is then pull-only.
    let surfaceID: String?
    /// The peer this session registered, once it has one.
    let peerID: String?

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment, peerID: String? = nil) -> IPCClientIdentity {
        IPCClientIdentity(
            workstreamID: env["ATELIER_WORKSTREAM_ID"],
            workstreamName: env["ATELIER_WORKSTREAM"],
            projectDirectory: env["ATELIER_PROJECT_DIR"],
            surfaceID: env["ATELIER_SURFACE_ID"],
            peerID: peerID
        )
    }
}

/// A peer as reported to an agent. Distinct from the store's `Peer`: it carries
/// the app-side context (workstream, inbox depth) the store deliberately
/// doesn't know about, and no `Date` values that would need a shared encoding
/// strategy on both ends.
struct IPCPeerInfo: Codable, Sendable {
    let id: String
    let name: String
    let role: String
    let workstream: String?
    /// Seconds since this peer was last heard from.
    let lastSeenSecondsAgo: Int
    let pendingMessages: Int
}

/// A delivered message as reported to an agent.
struct IPCMessageInfo: Codable, Sendable {
    let id: String
    let from: String
    let fromName: String
    let content: String
    /// Seconds since the message was sent.
    let sentSecondsAgo: Int
}

/// The result of a successful call.
enum IPCPayload: Codable, Sendable {
    case peers([IPCPeerInfo])
    case peer(IPCPeerInfo)
    case messages([IPCMessageInfo])
    case text(String)
}

/// One reply from the app to a helper.
struct IPCResponse: Codable, Sendable {
    let id: String
    let payload: IPCPayload?
    let error: String?

    static func success(id: String, _ payload: IPCPayload) -> IPCResponse {
        IPCResponse(id: id, payload: payload, error: nil)
    }

    static func failure(id: String, _ message: String) -> IPCResponse {
        IPCResponse(id: id, payload: nil, error: message)
    }
}

/// Encodes and decodes the newline-delimited framing both ends speak.
///
/// `JSONEncoder` never emits a raw newline inside a value, so a single `\n`
/// terminator is an unambiguous frame boundary.
enum IPCFraming {
    static let terminator: UInt8 = 0x0A

    static func encode(_ value: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(terminator)
        return data
    }

    /// Splits `buffer` into complete lines, returning them along with whatever
    /// partial line is left over.
    static func lines(from buffer: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var remainder = buffer
        while let index = remainder.firstIndex(of: terminator) {
            let line = remainder[remainder.startIndex ..< index]
            if !line.isEmpty { lines.append(Data(line)) }
            remainder = Data(remainder[remainder.index(after: index)...])
        }
        return (lines, remainder)
    }
}
