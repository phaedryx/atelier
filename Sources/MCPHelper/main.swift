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

        // Without a send timeout a stuck app can park a write forever. Fixed at
        // connect time and deliberately not per-tool: a request frame is a few
        // hundred bytes, so this never fires against a peer that is reading at
        // all, and varying it per call would be two syscalls of theatre.
        var sendTimeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        fd = socketFD
        return true
    }

    /// What came back, or why nothing did.
    ///
    /// `timedOut` and `closed` were one case — `roundTrip` returning nil — and
    /// merging them is what let a slow handler be read as a dead app. They are
    /// different observations about *this* request: `closed` is the app hanging
    /// up, so the request may never have been seen; `timedOut` is the deadline
    /// passing on a connection that is still open, which says nothing at all
    /// about whether the app has already acted on it.
    enum Reply {
        case response(IPC.Response)
        case timedOut
        case closed
    }

    /// Sends one request and blocks for its reply, for at most `deadline`.
    ///
    /// The receive timeout is recomputed before every `recv`, to whatever is
    /// left until `deadline` rather than to `deadline` itself. `SO_RCVTIMEO`
    /// bounds one call to `recv`, not the socket's whole lifetime, so setting
    /// it once and calling `recv` in a loop bounds only the gap *between*
    /// chunks — a reply (or a stray late frame for an abandoned request, see
    /// `Reply`'s doc comment above) that trickles in under that per-chunk
    /// window keeps re-arming it and can run for chunks × timeout rather than
    /// `deadline`. Recomputing the remaining time on each iteration is what
    /// makes the one clock this function keeps actually bound the total wait.
    func roundTrip(_ request: IPC.Request, deadline: TimeInterval) -> Reply {
        guard fd >= 0, let data = try? IPC.Framing.encode(request) else { return .closed }

        // Started here, before the send, so `deadline` bounds the whole call —
        // "at most `deadline`" above means from entry, not from whenever the
        // last byte of the request happened to land.
        let deadlineTime = DispatchTime.now() + deadline

        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            // A half-written frame poisons the app's read buffer, so this socket
            // is finished whatever the app does next. `closed` rather than
            // `timedOut`: the caller's job here is to reconnect, and a frame that
            // never landed whole was never acted on.
            guard written > 0 else { return .closed }
            sent += written
        }

        // Hoisted: allocating and zeroing 64 KiB per iteration is pure waste, and
        // `recv` overwrites exactly what it fills.
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            let (lines, remainder) = IPC.Framing.lines(from: buffer)
            buffer = remainder
            for line in lines {
                // A reply to a request this one already gave up on can still be
                // sitting in the stream. Matching on the id is what discards it.
                if let response = try? JSONDecoder().decode(IPC.Response.self, from: line), response.id == request.id {
                    return .response(response)
                }
            }

            guard var timeout = Self.remainingTimeval(until: deadlineTime) else {
                return .timedOut
            }
            // Not the "two syscalls of theatre" `connect(to:)` calls out for
            // `SO_SNDTIMEO`: that one is fixed once because a request frame
            // never approaches the send timeout in practice. This one is the
            // fix — recomputed and reset on every iteration, it is the only
            // thing that makes `deadline` bound total elapsed time rather than
            // the gap since the last chunk.
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            let read = recv(fd, &chunk, chunk.count, 0)
            if read == 0 {
                return .closed
            }
            if read < 0 {
                return (errno == EAGAIN || errno == EWOULDBLOCK) ? .timedOut : .closed
            }
            buffer.append(contentsOf: chunk[0 ..< read])
        }
    }

    /// Whatever remains until `deadline`, as the `timeval` `SO_RCVTIMEO`
    /// wants — nil once the deadline has passed, which the caller reads as an
    /// immediate `.timedOut` rather than issuing one more `recv`.
    ///
    /// A `{0, 0}` timeval means "block forever" to `setsockopt`, not "return
    /// immediately", so a remainder too small to round to a whole microsecond
    /// is bumped to one rather than silently disabling the timeout it was
    /// asked for.
    private static func remainingTimeval(until deadline: DispatchTime) -> timeval? {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = deadline.uptimeNanoseconds
        guard end > now else { return nil }
        let remainingNanos = end - now
        let seconds = Int(remainingNanos / 1_000_000_000)
        var microseconds = Int((remainingNanos % 1_000_000_000) / 1_000)
        if seconds == 0, microseconds == 0 {
            microseconds = 1
        }
        return timeval(tv_sec: seconds, tv_usec: suseconds_t(microseconds))
    }
}

/// Shown to the agent once, at initialize.
let serverInstructions = """
Agent-to-agent messaging inside Atelier. Register once with register_peer, then use list_peers and send_message to coordinate with agents working in other workstreams of this project.

Delivery is pull-based: a message sits in the recipient's inbox until it calls receive_messages. Atelier may nudge an idle agent's terminal, but that is best-effort and can be switched off, so check your inbox at natural boundaries rather than assuming you will be interrupted.

You can also act on the workstream you are running in. list_tabs shows its tabs and which agent is in each; read_review_comments returns the review comments the user has left on the Changes diff, anchored to file and line. Both are reads and neither changes anything.

open_editor puts a file on screen in front of the user, and request_attention raises a desktop notification asking them to come and look. Both change what the user sees, so use them when you have something for them rather than to narrate progress. request_attention does not block: it notifies and returns, and one workstream can raise it only every \(IPC.Vocabulary.attentionCooldownSeconds) seconds.

open_tab opens this workstream's Changes, Execution, Verification or Whiteboard pane, which all start closed. It does not switch the user's view — pair it with request_attention when you need their eyes, rather than assuming a tab you opened is a tab they saw.

open_agent_tab opens a terminal tab in your workstream, and with a prompt it starts another agent there. That agent shares your worktree, so give it work that collaborates on the change you are already making — a reviewer, a test-writer, a second pair of hands on the same branch. Work that belongs on its own branch needs its own workstream, not a tab. Poll list_tabs for the new surface's peer id before trying to message it.

close_tab is open_agent_tab's counterpart: once a peer you spawned has finished a bounded job, close its tab by the surface_id you got back rather than leaving it for the user to close by hand. It also closes a singleton pane by kind — Changes, Verification, or Execution, and closing Execution STOPS the running dev stack, so reach for it only when you mean to. Info and Agent are permanent and cannot be closed this way.

create_workstream is the exception to that: it makes a NEW workstream, with its own worktree and its own branch, and with a prompt it starts an agent in that workstream's Coding Agent tab. Reach for it when the work needs a branch of its own, and for open_agent_tab when it belongs on yours.

create_shortcut_workstream is the same thing for work that has a Shortcut story: the branch is named by the user's own Branch Name Pattern rather than by you, and the workstream carries the story, so its Info tab shows it and "Open in Shortcut" works. If the work has a story, use this rather than create_workstream and a name of your own.

add_task/get_pending_tasks/list_tasks/claim_task/complete_task/fail_task are a shared, project-scoped work queue — add several units of work once, and any peer in the project can claim, complete, or fail them, instead of you dispatching each by hand. Claiming is exclusive: only one peer wins, and it needs a surface to attach to, so this only works from an agent Atelier launched. Completing or failing a task notifies whoever created it.

list_verification_checks names the checks this project declares and the command each one runs, without running anything — the declarations live outside your worktree, so this is how you find out what is there. start_verification then runs the project's checks against your worktree and answers with a run id rather than a result — a real suite outlives a tool call. Each check's verdict arrives in your inbox from \(IPC.Vocabulary.verificationSender) as that check finishes; that is a reserved sender inside Atelier and not a peer you can reply to. If you are this workstream's Coding Agent, you will also get these for runs the user starts in the Verification tab. check_verification(run_id) reads the whole run whenever you want, so you are never stuck waiting for a message that has not arrived.

Call get_session_checkpoint early in a session, before starting new work — it is where an agent records what it was doing and how far it got, for itself or for whoever picks up this workstream next. update_session_checkpoint overwrites it with free text; call that before finishing a task, or at any milestone worth resuming from. There is one checkpoint per workstream and no history — it is shared with any other agent in this workstream, and each save replaces the last.

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

/// "never" is deliberately not "0s-ago": a value of 0 means a prompt just
/// landed, which is a very different fact from "none has ever been observed
/// on this surface, or it has no surface at all."
func lastUserPromptText(_ secondsAgo: Int?) -> String {
    secondsAgo.map { "\($0)s-ago" } ?? "never"
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
                + " last-user-prompt=\(lastUserPromptText(peer.lastUserPromptSecondsAgo))"
        }.joined(separator: "\n")
    case let .peer(peer):
        return "\(peer.name) [\(peer.role)] id=\(peer.id) last-seen=\(peer.lastSeenSecondsAgo)s-ago pending=\(peer.pendingMessages)"
            + " last-user-prompt=\(lastUserPromptText(peer.lastUserPromptSecondsAgo))"
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
        }
        // No output: a check runs in its own terminal surface in the Verification
        // tab, and Atelier keeps no copy of what it printed.
        return lines.joined(separator: "\n")
    case let .verificationChecks(declared):
        // The three load cases stay three answers. A file that is present and
        // broken must never render as "this project declares no checks" — that
        // is the same sentence a project with genuinely none gets, and it sends
        // an agent looking for a file that is right there.
        if let reason = declared.unavailableReason {
            return reason
        }
        var lines: [String] = []
        if let path = declared.configPath {
            lines.append("Declared in \(path), in file order:")
        }
        lines += declared.checks.map { check in
            var line = "\(check.name): \(check.command)"
            if let shell = check.shell {
                line += " [shell: \(shell)]"
            }
            return line
        }
        lines.append(
            "Run them with start_verification — all of them by omitting `checks`, "
                + "or any subset by naming them."
        )
        return lines.joined(separator: "\n")
    case let .execution(info):
        // The state is rendered first and always, because three of its four
        // cases are reasons rather than results — an agent that reads only the
        // process list would see an empty one and conclude the stack is idle.
        var lines = ["state=\(info.state.rawValue)"]
        if let reason = info.unavailableReason {
            lines.append(reason)
        }
        if let command = info.command {
            lines.append("runs=\(command)")
        }
        lines.append(
            info.declaredProcesses.isEmpty
                ? "declared: none"
                : "declared: \(info.declaredProcesses.joined(separator: ", "))"
        )
        if info.processes.isEmpty {
            lines.append("No processes are running.")
        } else {
            lines += info.processes.map { process in
                "\(process.name) [\(process.namespace)] status=\(process.status)"
                    + " ready=\(process.isReady) running=\(process.isRunning)"
                    + " restarts=\(process.restarts) exit=\(process.exitCode) pid=\(process.pid)"
                    + (process.port.map { " port=\($0)" } ?? "")
            }
        }
        return lines.joined(separator: "\n")
    case let .executionLogs(logs):
        guard !logs.lines.isEmpty else { return "\(logs.process) has logged nothing." }
        let header = logs.wasTrimmed
            ? "\(logs.process) (older lines dropped to fit):"
            : "\(logs.process):"
        return ([header] + logs.lines).joined(separator: "\n")
    case let .task(task):
        return renderTask(task)
    case let .tasks(list):
        guard !list.isEmpty else { return "No tasks match." }
        return list.map { renderTask($0, contentPreviewLimit: 200) }.joined(separator: "\n\n")
    case let .text(text):
        return text
    case nil:
        return ""
    }
}

/// Renders one task for the plain text an agent reads.
///
/// `contentPreviewLimit` is `nil` for the singular `.task` payload (add/claim/
/// complete/fail responses) — full content, since a caller acting on one task
/// needs its whole brief. `get_pending_tasks`/`list_tasks` pass a fixed limit
/// instead: a list can hold several tasks near the 64KB cap each, and dumping
/// all of them in full would flood the agent's context.
///
/// `createdBy`/`claimedBy` are rendered alongside their display-name
/// counterparts — id in parens after the name, the same shape `.peer`/`.peers`
/// use (`[peer.role] id=\(peer.id)`) — because a peer id, not a display name,
/// is what `send_message` addresses.
func renderTask(_ task: IPC.TaskInfo, contentPreviewLimit: Int? = nil) -> String {
    var lines = ["\(task.path) [\(task.state.rawValue)] \(task.name)"]

    var createdLine = "created \(task.createdSecondsAgo)s ago"
    if let createdByName = task.createdByName {
        createdLine += " by \(createdByName)" + (task.createdBy.map { " (\($0))" } ?? "")
    }
    lines.append(createdLine)

    if let claimedByName = task.claimedByName, let claimedSecondsAgo = task.claimedSecondsAgo {
        lines.append("claimed by \(claimedByName)" + (task.claimedBy.map { " (\($0))" } ?? "") + " \(claimedSecondsAgo)s ago")
    }
    if !task.tags.isEmpty {
        lines.append("tags: \(task.tags.joined(separator: ", "))")
    }

    if let limit = contentPreviewLimit, task.content.count > limit {
        lines.append("content: \(task.content.prefix(limit))…")
    } else {
        lines.append("content: \(task.content)")
    }

    if let reason = task.failureReason {
        lines.append("failure reason: \(reason)")
    }
    return lines.joined(separator: "\n")
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
        /// The app hung up, or the frame never landed whole. Recoverable by
        /// reconnecting.
        case disconnected
        /// The tool's deadline passed on a connection that is still open. The
        /// app may be wedged, or it may simply still be working — and nothing
        /// here can tell those apart, which is why this is never replayed.
        case timedOut
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

    /// Forwards one tool call, recovering the session — but never the call —
    /// from an interruption.
    ///
    /// **A replay is a second execution.** The reconnect below exists so a
    /// restarted Atelier does not fail every later call, and for a read that is
    /// free. For anything that creates something it is a silent duplicate, and
    /// `IPC.Tool.isSafeToReplay` is where that line is drawn.
    ///
    /// A *timeout* is never replayed, whatever the tool. It is not evidence that
    /// the app is gone — only that it has not answered yet — so re-sending would
    /// race the call's own first copy. That is what produced two worktrees for
    /// one `create_workstream`, and a `nameInUse` refusal reported to a caller
    /// whose workstream had in fact been created.
    func call(tool: IPC.Tool, arguments: [String: String]) -> Outcome {
        if let failure = connect() {
            return .failed(failure)
        }

        switch attempt(tool: tool, arguments: arguments) {
        case let .ok(payload):
            return .ok(payload)
        case let .refused(message):
            return .failed(message)
        case .timedOut:
            // Deliberately without disconnecting: the socket is still open, the
            // peer id still valid, and a late reply arriving on it is discarded
            // by id in `roundTrip`. Tearing it down here would strand this
            // session's inbox behind a dead id for no gain.
            return .failed(Self.timedOutMessage(tool: tool))
        case .disconnected:
            break
        }

        // Atelier went away mid-session — almost always a restart during
        // development. Reconnect so the rest of the session works, whether or
        // not this particular call can be retried.
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

        guard tool.isSafeToReplay else {
            return .failed(Self.notReplayedMessage(tool: tool))
        }

        switch attempt(tool: tool, arguments: arguments) {
        case let .ok(payload):
            return .ok(payload)
        case let .refused(message):
            return .failed(message)
        case .timedOut:
            return .failed(Self.timedOutMessage(tool: tool))
        case .disconnected:
            return .failed("Atelier closed the IPC connection.")
        }
    }

    /// What the agent is told when a call outlived its deadline.
    ///
    /// It has to forbid a retry rather than invite one. The caller cannot tell a
    /// genuine refusal from one its own second attempt caused, so "try again
    /// under another name" risks exactly the duplicate this no-replay rule
    /// exists to prevent. The honest instruction is to go and look, by the same
    /// route `create_workstream`'s success string already documents.
    ///
    /// Unlocalized, like every other string this surface returns: these are
    /// answers to an agent, written to tell it what to do differently.
    private static func timedOutMessage(tool: IPC.Tool) -> String {
        let opening = "Atelier did not answer \(tool.rawValue) within \(Int(tool.replyDeadline))s."

        // Keyed on the replay policy rather than on `surface`, because that is
        // exactly the question being answered: "may this be run twice?" A read
        // that timed out is worth retrying and saying otherwise would be wrong.
        guard !tool.isSafeToReplay else {
            return opening + " Atelier may be busy rather than stuck, and this call changes nothing by "
                + "running twice, so it is safe to try again."
        }

        var message = opening + " This is not a failure: the call may still be running, and may already "
            + "have succeeded. Do not call it again — a second copy would race the first."
        if tool.surface == .workspaceAction {
            message += " Check what actually happened before doing anything else: list_peers shows an agent "
                + "once it registers, and the sidebar shows a workstream as soon as it exists."
        }
        return message
    }

    /// What the agent is told when the connection dropped mid-call and the tool
    /// is one a second execution would change something.
    private static func notReplayedMessage(tool: IPC.Tool) -> String {
        "Atelier closed the IPC connection while \(tool.rawValue) was in flight, and it was not retried: "
            + "running it twice is not the same as running it once. The connection is back, so later calls will "
            + "work. Check whether the first one took effect before repeating it."
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
    ///   an app that keeps answering `peerOwnedByAnotherSession` — to the retry
    ///   *or* to the `register_peer` inside it — recursed without bound.
    private func attempt(
        tool: IPC.Tool,
        arguments: [String: String],
        afterReregister: Bool = false
    ) -> Attempt {
        guard let endpoint else { return .disconnected }

        let identity = IPC.ClientIdentity.fromEnvironment(peerID: peerID)
        let request = IPC.Request(token: endpoint.token, tool: tool, arguments: arguments, client: identity)
        let response: IPC.Response
        switch transport.roundTrip(request, deadline: tool.replyDeadline) {
        case let .response(received): response = received
        case .timedOut: return .timedOut
        case .closed: return .disconnected
        }
        if let error = response.error {
            // The app refuses a peer id whose previous connection it still
            // considers live — reachable when a reconnect overtakes the old
            // socket's close. Treated as final, that wedges the session for
            // good: `ensureRegistered` no-ops while `peerID` is set, so nothing
            // would ever ask again. Drop the identity and re-register instead.
            //
            // Recognised by `Response.code`, never by the sentence. This was
            // `error.contains("belongs to another session")` — a substring match
            // across a process boundary against a string assembled in
            // `IPC.Server`, so rewording the message for a human would have
            // silently disabled this recovery.
            if response.code == .peerOwnedByAnotherSession, !afterReregister {
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
        // The registry is the only list. `IPC.ToolSpec.advertised` decides the
        // order; `IPC.Tool.spec` decides everything else, and is an exhaustive
        // switch, so a tool cannot reach an agent with no schema or reach this
        // loop without being a real `IPC.Tool`.
        let tools = IPC.ToolSpec.advertised.map { spec -> [String: Any] in
            [
                "name": spec.tool.rawValue,
                "description": spec.description,
                "inputSchema": spec.inputSchema,
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
