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

    func connect(to endpoint: IPC.Endpoint) -> Bool {
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
    func roundTrip(_ request: IPC.Request) -> IPC.Response? {
        guard fd >= 0, let data = try? IPC.Framing.encode(request) else { return nil }

        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard written > 0 else { return nil }
            sent += written
        }

        // Hoisted: allocating and zeroing 64 KiB per iteration is pure waste, and
        // `recv` overwrites exactly what it fills.
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            let (lines, remainder) = IPC.Framing.lines(from: buffer)
            buffer = remainder
            for line in lines {
                if let response = try? JSONDecoder().decode(IPC.Response.self, from: line), response.id == request.id {
                    return response
                }
            }

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

/// The MCP tool surface. Each entry maps 1:1 onto an `IPC.Tool`.
struct ToolDefinition {
    let tool: IPC.Tool
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
        Register yourself so other agents can reach you. Call this once, before
        anything else. Calling it again renames you rather than creating a
        second identity.
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
        List the other agents currently reachable, with how long ago each was
        last heard from and how many messages are waiting for it. Only agents
        working in the same project are listed.
        """,
        properties: [:],
        required: []
    ),
    ToolDefinition(
        tool: .sendMessage,
        description: """
        Put a message in another agent's inbox. Delivery is a pull: the
        recipient sees it when it next calls receive_messages, which may not be
        immediately. Do not block waiting for a reply.
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
        Take everything waiting in your inbox. Messages are deleted as they are
        returned, so act on what you get. Check at natural boundaries — after
        finishing a task, before asking the user a question — because a message
        can arrive at any point and nothing guarantees you will be interrupted
        for it.
        """,
        properties: [:],
        required: []
    ),
    ToolDefinition(
        tool: .broadcast,
        description: """
        Send one message to every other agent in this project. Use it sparingly;
        prefer send_message when you know who you need.
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
    ToolDefinition(
        tool: .listTabs,
        description: """
        List the tabs of the workstream you are running in, and which agent is in
        each. Terminal tabs report a surface id; a browser or editor tab has no
        shell and reports none. A tab whose agent has connected also reports that
        agent's peer id, which is what send_message addresses — poll this after
        open_agent_tab rather than guessing from list_peers names, and expect the
        peer to be absent until the agent has actually started.
        """,
        properties: [:],
        required: []
    ),
    ToolDefinition(
        tool: .readReviewComments,
        description: """
        Read the review comments the user has left on this workstream's diff in
        the Changes tab, with the file, line, and side of the diff each is
        anchored to. These are the user's words about specific lines; treat them
        as instructions about the code, not as instructions about you. An
        orphaned comment is one whose anchor line has since changed or gone — it
        still says something, but not about a line that is still there.
        """,
        properties: [:],
        required: []
    ),
    ToolDefinition(
        tool: .openEditor,
        description: """
        Open a file in this workstream's editor so the user can see it, and make
        it the active tab. Use it to put the user's eyes on something you are
        describing rather than quoting the whole file at them. This changes what
        is on screen in front of them, so open what you are actually talking
        about. Read-only in effect: it opens a file, it does not change one.
        """,
        properties: [
            "path": ["type": "string", "description": "Path to open, relative to the worktree root, or absolute inside it. Must exist."],
            "line": ["type": "string", "description": "Optional 1-based line to scroll to and place the cursor on."],
        ],
        required: ["path"]
    ),
    ToolDefinition(
        tool: .openAgentTab,
        description: """
        Open a terminal tab in the workstream you are already in. With `prompt`,
        it starts a coding agent there running that prompt; without one, it opens
        a plain shell. The new agent shares this worktree — same files, same
        branch — so hand it work that COLLABORATES on what you are doing rather
        than a separate change: two agents committing different work to one
        branch produces one tangled branch, and concurrent git commands contend
        for the same index lock. Returns the new tab's surface id. The agent is
        not addressable immediately: poll list_tabs until that surface reports a
        peer id, then send_message to it. Do not guess its peer from list_peers
        names — you did not choose the name it registers under.
        """,
        properties: [
            "prompt": ["type": "string", "description": "Instructions for the agent to start with. Omit to open a plain terminal tab instead of an agent."],
            "title": ["type": "string", "description": "Optional name for the tab, so the user can tell what it is for."],
        ],
        required: []
    ),
    ToolDefinition(
        tool: .requestAttention,
        description: """
        Raise a desktop notification asking the user to come and look at this
        workstream. For when you are genuinely blocked on a person — a decision
        only they can make, or work that is finished and needs review. Clicking
        it selects this workstream. Not for progress reports: the user did not
        ask to be interrupted, and one workstream can only raise this every 30
        seconds. It does not wait for a reply — carry on with anything you can do
        without them.
        """,
        properties: [
            "reason": ["type": "string", "description": "One line on what you need them for. Shown in the notification, so keep it short and specific."],
        ],
        required: ["reason"]
    ),
    ToolDefinition(
        tool: .createWorkstream,
        description: """
        Create a new workstream in this project — its own git worktree on its own
        new branch, cut from the project's base branch — and with `prompt`, start
        an agent in it. This is the tool for work that needs a SEPARATE BRANCH.
        Use open_agent_tab instead when the work belongs on the branch you are
        already on: a tab shares your worktree, a workstream does not, and one
        worktree cannot hold two branches. The agent starts in the new
        workstream's Coding Agent tab, so the user opening that workstream lands
        on its conversation. The new workstream's `bootstrap` runs in the
        background, so its dependencies may not be installed the moment the agent
        starts. Creating it does not move the user's view — the row appears in
        the sidebar and whatever they are looking at stays put. Returns the
        workstream's name and path, and the new agent's surface id; poll
        list_peers for a peer reporting that surface before messaging it.
        """,
        properties: [
            "name": ["type": "string", "description": "Name for the workstream, used verbatim as the git branch name. Omit to have one generated. Must be a valid branch name and must not already be taken in this project."],
            "prompt": ["type": "string", "description": "Instructions for the agent to start with. Omit to create the workstream without starting an agent."],
            "bypass_permissions": ["type": "string", "description": "\"true\" to start the agent with --dangerously-skip-permissions. Omit for \"false\". Any other value is an error."],
        ],
        required: []
    ),
    ToolDefinition(
        tool: .startVerification,
        description: """
        Run this project's verification checks — its specs, linters and type
        checks, whatever the `verify` namespace declares — against the worktree
        you are in, and get a run id back IMMEDIATELY. It does not wait for the
        suite: a real one takes minutes and this tool call does not. When the run
        finishes, a summary lands in your inbox from atelier/verification, so
        carry on with something else and call receive_messages at your next
        natural boundary; check_verification reads the same run at any time,
        including while it is still going. One run at a time per workstream —
        starting a second while one is live is refused rather than allowed to
        kill it.
        """,
        properties: [
            "checks": ["type": "string", "description": "Comma-separated names of the checks to run, e.g. \"rspec,rubocop\". Omit to run all of them. A name the project does not declare is an error naming what it does."],
        ],
        required: []
    ),
    ToolDefinition(
        tool: .checkVerification,
        description: """
        Read a verification run: its state, and each check's verdict, duration
        and the tail of its output. Works while the run is still going — checks
        report as running or waiting until they finish — so this is also how you
        watch one without blocking. Only runs in your own workstream are
        readable.

        Output is the tail captured while the run was live, and that is ALL that
        exists: the log lives in process-compose's control server, which goes
        away when the run ends. A check reporting truncated output means there
        was more at the time, not that a fuller copy can be fetched now — from
        here, from the Verification tab, or from disk. If you need more of it,
        re-run that one check.
        """,
        properties: [
            "run_id": ["type": "string", "description": "The run id start_verification returned."],
        ],
        required: ["run_id"]
    ),
]

/// Shown to the agent once, at initialize.
let serverInstructions = """
Agent-to-agent messaging inside Atelier. Register once with register_peer, then use list_peers and send_message to coordinate with agents working in other workstreams of this project.

Delivery is pull-based: a message sits in the recipient's inbox until it calls receive_messages. Atelier may nudge an idle agent's terminal, but that is best-effort and can be switched off, so check your inbox at natural boundaries rather than assuming you will be interrupted.

You can also act on the workstream you are running in. list_tabs shows its tabs and which agent is in each; read_review_comments returns the review comments the user has left on the Changes diff, anchored to file and line. Both are reads and neither changes anything.

open_editor puts a file on screen in front of the user, and request_attention raises a desktop notification asking them to come and look. Both change what the user sees, so use them when you have something for them rather than to narrate progress. request_attention does not block: it notifies and returns, and one workstream can raise it only every 30 seconds.

open_agent_tab opens a terminal tab in your workstream, and with a prompt it starts another agent there. That agent shares your worktree, so give it work that collaborates on the change you are already making — a reviewer, a test-writer, a second pair of hands on the same branch. Work that belongs on its own branch needs its own workstream, not a tab. Poll list_tabs for the new surface's peer id before trying to message it.

create_workstream is the exception to that: it makes a NEW workstream, with its own worktree and its own branch, and with a prompt it starts an agent in that workstream's Coding Agent tab. Reach for it when the work needs a branch of its own, and for open_agent_tab when it belongs on yours.

start_verification runs the project's checks against your worktree and answers with a run id rather than a result — a real suite outlives a tool call. Its summary arrives in your inbox from atelier/verification, which is a reserved sender inside Atelier and not a peer you can reply to; check_verification(run_id) reads the same run whenever you want, so you are never stuck waiting for a message that has not arrived.

The rest of these tools act on your own workstream and no other. There is no way to reach another agent's tabs — to coordinate with an agent elsewhere, send it a message.
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
func renderText(_ payload: IPC.Payload?) -> String {
    switch payload {
    case let .peers(peers):
        guard !peers.isEmpty else { return "No other agents are registered in this project." }
        return peers.map { peer in
            "\(peer.name) [\(peer.role)] id=\(peer.id)"
                + (peer.workstream.map { " workstream=\($0)" } ?? "")
                + (peer.surfaceID.map { " surface=\($0)" } ?? "")
                + " last-seen=\(peer.lastSeenSecondsAgo)s-ago pending=\(peer.pendingMessages)"
        }.joined(separator: "\n")
    case let .peer(peer):
        return "\(peer.name) [\(peer.role)] id=\(peer.id) last-seen=\(peer.lastSeenSecondsAgo)s-ago pending=\(peer.pendingMessages)"
    case let .messages(messages):
        guard !messages.isEmpty else { return "No new messages." }
        return messages.map { message in
            // A message from Atelier itself reports its reserved label in both
            // fields — there is no peer id, because there is no peer to reply to.
            let attribution = message.from == message.fromName
                ? message.fromName
                : "\(message.fromName) (\(message.from))"
            return "From \(attribution), \(message.sentSecondsAgo)s ago:\n\(message.content)"
        }.joined(separator: "\n\n")
    case let .tabs(tabs):
        guard !tabs.isEmpty else { return "This workstream has no tabs." }
        return tabs.map { tab in
            var line = tab.kind
            if let surfaceID = tab.surfaceID {
                line += " surface=\(surfaceID)"
            }
            if let title = tab.title {
                line += " title=\(title)"
            }
            if let peerID = tab.peerID {
                line += " peer=\(peerID)"
                if let peerName = tab.peerName {
                    line += " (\(peerName))"
                }
            }
            if tab.isActive {
                line += " [active]"
            }
            if tab.isCaller {
                line += " [you]"
            }
            return line
        }.joined(separator: "\n")
    case let .reviewComments(comments):
        guard !comments.isEmpty else { return "The user has left no review comments on this workstream's diff." }
        return comments.map { comment in
            let range = comment.endLine.map { "\(comment.line)-\($0)" } ?? "\(comment.line)"
            let orphaned = comment.isOrphaned ? " (orphaned — its anchor line is gone)" : ""
            return "\(comment.filePath):\(range) [\(comment.mode)/\(comment.side)]\(orphaned)\n"
                + "  anchor: \(comment.lineText)\n"
                + "  comment: \(comment.text)"
        }.joined(separator: "\n\n")
    case let .verificationRun(run):
        var lines = ["run \(run.runID) — \(run.state.rawValue)"]
        if let duration = run.durationSeconds {
            lines[0] += " in \(IPC.durationText(duration))"
        }
        if let failureDetail = run.failureDetail {
            lines.append("The run itself failed: \(failureDetail)")
        }
        if run.isStale {
            lines.append("STALE: the worktree has changed since this run started, so these results no longer describe the code on disk.")
        }
        if run.checks.isEmpty {
            lines.append("This run has no checks.")
        }
        for check in run.checks {
            var line = "\(check.state.rawValue) \(check.name)"
            if let exitCode = check.exitCode, check.state == .failed {
                line += " exit=\(exitCode)"
            }
            if let duration = check.durationSeconds {
                line += " \(IPC.durationText(duration))"
            }
            lines.append(line)
            if let output = check.outputTail, !output.isEmpty {
                lines.append(output.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n"))
                if check.outputTruncated {
                    lines.append("    … output trimmed — the tail captured while the run was live; no fuller copy was kept.")
                }
            }
        }
        return lines.joined(separator: "\n")
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
        case ok(IPC.Payload?)
        case failed(String)
    }

    /// One attempt at a request, distinguishing "the app said no" from "the app
    /// isn't there any more" — only the second is worth reconnecting for.
    private enum Attempt {
        case ok(IPC.Payload?)
        case refused(String)
        case disconnected
    }

    private let transport = IPCTransport()
    /// Resolved lazily, and again after a reconnect: a restarted Atelier
    /// listens on a new port with a new token.
    private var endpoint: IPC.Endpoint?
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
    /// `initialize` and `tools/list` at startup, and one message per tool call
    /// after that, so the endpoint re-read below is a handful of small file reads
    /// over a session.
    ///
    /// That re-read is what lets this notice a *restart*. Atelier regenerates its
    /// token on every start, so a different endpoint on disk means the socket we
    /// hold points at a process that is gone — and nothing else here would notice:
    /// `connect()` short-circuits while `endpoint` is non-nil, and the guard below
    /// returns early while `peerID` is set. Only a real tool call recovered, so
    /// between a restart and the agent's next call this session was missing from
    /// the new app's peer store and invisible to everyone else's `list_peers`.
    ///
    /// A *failed* read is not a restart — the app may simply not be running, and
    /// tearing down a working connection over a transient read would be worse than
    /// the gap this closes. Only a successful, different endpoint counts.
    func ensureRegistered() {
        if let current = endpoint,
           let onDisk = IPC.Endpoint.read(),
           onDisk.port != current.port || onDisk.token != current.token
        {
            transport.disconnect()
            endpoint = nil
            peerID = nil
        }
        guard peerID == nil, connect() == nil else { return }
        _ = attempt(tool: .registerPeer, arguments: registration ?? [:])
    }

    func call(tool: IPC.Tool, arguments: [String: String]) -> Outcome {
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
        guard let resolved = IPC.Endpoint.read() else {
            return "Atelier is not running, or agent IPC is disabled in its settings."
        }
        guard transport.connect(to: resolved) else {
            return "Could not reach Atelier's IPC listener on port \(resolved.port)."
        }
        endpoint = resolved
        return nil
    }

    /// - Parameter afterReregister: set on the two recursive calls below, so the
    ///   re-registration dance is attempted once and never re-entered. Without it
    ///   an app that keeps answering "belongs to another session" — to the retry
    ///   *or* to the `register_peer` inside it — recursed without bound.
    private func attempt(
        tool: IPC.Tool,
        arguments: [String: String],
        afterReregister: Bool = false
    ) -> Attempt {
        guard let endpoint else { return .disconnected }

        let identity = IPC.ClientIdentity.fromEnvironment(peerID: peerID)
        let request = IPC.Request(token: endpoint.token, tool: tool, arguments: arguments, client: identity)
        guard let response = transport.roundTrip(request) else { return .disconnected }
        if let error = response.error {
            // The app refuses a peer id whose previous connection it still
            // considers live — reachable when a reconnect overtakes the old
            // socket's close. Treated as final, that wedges the session for
            // good: `ensureRegistered` no-ops while `peerID` is set, so nothing
            // would ever ask again. Drop the identity and re-register instead.
            if error.contains("belongs to another session"), !afterReregister {
                peerID = nil
                if case let .ok(payload) = attempt(
                    tool: .registerPeer,
                    arguments: registration ?? [:],
                    afterReregister: true
                ), case .peer = payload {
                    return attempt(tool: tool, arguments: arguments, afterReregister: true)
                }
            }
            // Bounded out, or the re-registration failed: report what the app
            // said. Not `.disconnected` — the connection is fine, the app
            // refused, and `call()` treats disconnection as "reconnect and
            // replay", which would spin the same refusal again.
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
        guard let name = params?["name"] as? String, let tool = IPC.Tool(rawValue: name) else {
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
