// ABOUTME: HTTP server that receives Claude Code hook events via POST requests.
// ABOUTME: Listens on localhost with an OS-assigned port and writes port to cache file.

import Foundation
import Network
import os

private let logger = Logger(subsystem: "atelier", category: "hook-receiver")

/// Receives Claude Code hook events over HTTP on a local NWListener.
///
/// The listener binds to 127.0.0.1 on an OS-assigned port, writes the port
/// number to `~/Library/Caches/atelier/hook-port`, and routes incoming
/// hook events to the `onEvent` callback.
///
/// Thread safety: all mutable state is accessed on `self.queue`.
final class HookEventReceiver: @unchecked Sendable {
    static let shared = HookEventReceiver()

    /// How long a connection may go without completing a request before it is
    /// closed. A hook posts a small body from a process on this machine; a
    /// client that has not finished by now is not going to, and without a
    /// deadline it pinned an `NWConnection` and a `receiveData` recursion for the
    /// life of the app. Settable so a test can shorten it.
    nonisolated(unsafe) static var connectionTimeout: TimeInterval = 15

    /// `hook_event_name` of the liveness ping. Deliberately not a Claude Code
    /// event name, so a real session can never produce one.
    static let pingEventName = "AtelierPing"

    /// Called on the main queue with (projectDir, event).
    ///
    /// Behind a lock: it is read on the receiver's own queue and assigned from
    /// wherever the app happens to wire it up.
    var onEvent: ((String, AgentEvent) -> Void)? {
        get { onEventLock.withLock { storedOnEvent } }
        set { onEventLock.withLock { storedOnEvent = newValue } }
    }

    private let onEventLock = NSLock()
    private var storedOnEvent: ((String, AgentEvent) -> Void)?

    /// Called on the main queue with (projectDir, surfaceID, reading) when a
    /// status line reports its session's context window.
    ///
    /// Separate from `onEvent` because it is not an event: nothing about an
    /// agent's turn is being reported, and routing it through `AgentEvent` would
    /// put a roster-touching envelope on a channel that fires on a timer's
    /// schedule as well as a turn's.
    var onStatusLine: ((String, String?, StatusLine.Reading) -> Void)? {
        get { onEventLock.withLock { storedOnStatusLine } }
        set { onEventLock.withLock { storedOnStatusLine = newValue } }
    }

    private var storedOnStatusLine: ((String, String?, StatusLine.Reading) -> Void)?

    /// Called on the main queue with (projectDir, request, resolve) when an
    /// agent is blocked on a tool permission.
    ///
    /// The handler **must** call `resolve` exactly once. `nil` means "no
    /// decision", which sends an empty body and leaves Claude Code to ask in the
    /// terminal — the behaviour of no hook at all. Leaving it uncalled leaves a
    /// real agent stopped until Claude Code kills the script.
    ///
    /// Unset is a valid state and is handled: with no handler wired the request
    /// resolves to `nil` immediately, which is what happens for every hook event
    /// that arrives during launch before `ContentView` has hooked things up.
    var onPermissionRequest: ((String, PendingPermission, @escaping @Sendable (PendingPermission.Decision?) -> Void) -> Void)? {
        get { onEventLock.withLock { storedOnPermissionRequest } }
        set { onEventLock.withLock { storedOnPermissionRequest = newValue } }
    }

    private var storedOnPermissionRequest: ((String, PendingPermission, @escaping @Sendable (PendingPermission.Decision?) -> Void) -> Void)?

    /// Called on the main queue with the nonce of an `AtelierPing` envelope.
    ///
    /// `HookChannelProbe` sends one through the real `atelier-hook` script and
    /// waits here for its nonce. That round trip is the only evidence the app
    /// has that the delivery path — port file, curl, this listener, the parser —
    /// is working; every other signal it has is an *absence* of hook events,
    /// which a broken channel and a busy agent produce identically.
    var onPing: ((String) -> Void)? {
        get { onEventLock.withLock { storedOnPing } }
        set { onEventLock.withLock { storedOnPing = newValue } }
    }

    private var storedOnPing: ((String) -> Void)?

    /// How many connections are open right now. Test-facing.
    var connectionCount: Int {
        queue.sync { connections.count }
    }

    private let queue = DispatchQueue(label: "atelier.hook-receiver", qos: .utility)
    private var listener: NWListener?
    /// The port the listener bound to, once ready. Read this rather than the
    /// port file when you need *this* process's port: the file on disk may
    /// still hold a previous run's number.
    var boundPort: UInt16? {
        queue.sync { currentPort }
    }

    private var currentPort: UInt16?
    private var connections: [NWConnection] = []

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.setupListener()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            // Read before the teardown clears it: the port is what decides
            // whether this instance is the one allowed to remove the rendezvous
            // file, and `removePortFile` runs last.
            let ownPort = currentPort
            listener?.cancel()
            listener = nil
            currentPort = nil
            for conn in connections {
                conn.cancel()
            }
            connections.removeAll()
            removePortFile(ownPort: ownPort)
        }
    }

    // MARK: - Listener Setup

    private func setupListener() {
        // Idempotent: a second start() must not leave an orphaned listener
        // racing the first to rewrite the port file.
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let newListener = try NWListener(using: params)

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = newListener.port {
                        logger.info("Hook receiver listening on port \(port.rawValue)")
                        self?.currentPort = port.rawValue
                        self?.writePortFile(port: port.rawValue)
                    }
                case let .failed(error):
                    logger.error("Hook receiver failed: \(error.localizedDescription)")
                    newListener.cancel()
                case .cancelled:
                    logger.info("Hook receiver cancelled")
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.handleConnection(connection)
                }
            }

            listener = newListener
            newListener.start(queue: queue)
        } catch {
            logger.error("Failed to create hook listener: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            // `.cancelled` as well as `.failed`: every request ends by cancelling
            // the connection in `sendResponse`, and only `.failed` was being
            // taken off `connections` — so a healthy request leaked an entry too.
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak self] in
            guard let self, connections.contains(where: { $0 === connection }) else { return }
            logger.warning("Closing a hook connection that never completed a request")
            connection.cancel()
            removeConnection(connection)
        }

        connection.start(queue: queue)
        receiveData(on: connection, buffer: Data())
    }

    private func receiveData(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if isComplete || error != nil {
                // We have all the data — process it
                processHTTPRequest(accumulated, on: connection)
                return
            }

            // Check if we have the full HTTP body yet
            if let headerEnd = findHeaderEnd(in: accumulated) {
                let headerData = accumulated[..<headerEnd]
                let bodyStart = headerEnd
                if let contentLength = parseContentLength(from: headerData),
                   accumulated.count >= bodyStart + contentLength
                {
                    // Full request received
                    processHTTPRequest(accumulated, on: connection)
                    return
                }
            }

            // Need more data
            receiveData(on: connection, buffer: accumulated)
        }
    }

    private func findHeaderEnd(in data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        for i in 0 ... (bytes.count - 4) {
            if bytes[i] == separator[0], bytes[i + 1] == separator[1],
               bytes[i + 2] == separator[2], bytes[i + 3] == separator[3]
            {
                return i + 4
            }
        }
        return nil
    }

    private func parseContentLength(from headerData: Data) -> Int? {
        guard let headerString = String(data: headerData, encoding: .utf8)?.lowercased() else { return nil }
        for line in headerString.components(separatedBy: "\r\n") {
            if line.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    // MARK: - HTTP Request Processing

    private func processHTTPRequest(_ data: Data, on connection: NWConnection) {
        /// Not `defer`: the permission path below keeps its connection open past
        /// the end of this function, and unhooking it from `connections` is that
        /// path's own first act. Every other exit removes it here.
        func done() {
            removeConnection(connection)
        }

        // Extract JSON body after \r\n\r\n
        guard let headerEnd = findHeaderEnd(in: data) else {
            sendResponse(on: connection, status: "400 Bad Request", body: "{\"error\":\"no headers\"}")
            done()
            return
        }

        let target = requestTarget(in: data[..<headerEnd])
        let bodyData = data[headerEnd...]
        guard !bodyData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            sendResponse(on: connection, status: "400 Bad Request", body: "{\"error\":\"invalid json\"}")
            done()
            return
        }

        // The atelier-statusline script wraps Claude Code's status line payload
        // as: { "payload": { ... }, "surface_id": "..." }. A different envelope
        // from the hook one because the payload carries its own launch
        // directory and no event name — there is nothing to map and no roster to
        // touch, only two numbers to hand over.
        if target == "/statusline" {
            handleStatusLine(json: json)
            sendResponse(on: connection, status: "200 OK", body: "{\"ok\":true}")
            done()
            return
        }

        // The atelier-hook script wraps the Claude Code input as:
        //   { "event_input": { ... }, "project_dir": "..." }
        guard let projectDir = json["project_dir"] as? String else {
            logger.warning("Hook event missing project_dir")
            sendResponse(on: connection, status: "200 OK", body: "{\"ok\":true}")
            done()
            return
        }

        guard let eventInput = json["event_input"] as? [String: Any] else {
            logger.warning("Hook event missing event_input")
            sendResponse(on: connection, status: "200 OK", body: "{\"ok\":true}")
            done()
            return
        }

        // Present only for an agent Atelier launched: the hook process inherits
        // ATELIER_SURFACE_ID from the terminal it runs in. Empty for a Claude
        // session started anywhere else, which the hook installs globally for.
        let surfaceID = (json["surface_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let hookEventName = eventInput["hook_event_name"] as? String ?? ""

        // Atelier's own liveness ping, not a Claude Code event. Answered here
        // rather than through `mapHookEvent` so it produces no `AgentEvent` at
        // all: an envelope that touched a workstream's roster would reset the
        // very stall clock the probe was sent to explain, making the probe's own
        // traffic the reason the channel looked healthy.
        if hookEventName == Self.pingEventName {
            if let nonce = eventInput["nonce"] as? String, !nonce.isEmpty {
                logger.info("Hook channel ping returned")
                DispatchQueue.main.async { [weak self] in
                    self?.onPing?(nonce)
                }
            }
            sendResponse(on: connection, status: "200 OK", body: "{\"ok\":true}")
            done()
            return
        }

        logger.info("Hook event received: \(hookEventName, privacy: .public) for project: \(projectDir, privacy: .public) surface: \(surfaceID ?? "none", privacy: .public)")
        var events = mapHookEvent(hookEventName: hookEventName, eventInput: eventInput, projectDir: projectDir)
        if let surfaceID {
            events = events.map { event in
                var stamped = event
                stamped.surfaceID = surfaceID
                return stamped
            }
        }

        if !events.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for event in events {
                    onEvent?(projectDir, event)
                }
            }
        }

        // The one request that is not answered on the spot: the reply *is* the
        // decision, and the agent is stopped until it arrives.
        if target == "/permission", hookEventName == "PermissionRequest" {
            hold(
                connection,
                eventInput: eventInput,
                projectDir: projectDir,
                surfaceID: surfaceID
            )
            return
        }

        sendResponse(on: connection, status: "200 OK", body: "{\"ok\":true}")
        done()
    }

    /// Hands one status line payload to `onStatusLine`, or drops it.
    ///
    /// Deliberately silent about a payload it cannot use: the status line runs
    /// on every assistant message, and `context_window` is absent until the
    /// session's first API response, so "nothing to report" is an ordinary
    /// state rather than a fault. Nothing here touches a roster or a stall
    /// clock — a rendered status line is not evidence an agent is alive, and
    /// the row's status word and the channel banner both depend on that
    /// distinction being kept.
    private func handleStatusLine(json: [String: Any]) {
        guard let payload = json["payload"] as? [String: Any],
              let projectDir = StatusLine.projectDir(payload: payload),
              let reading = StatusLine.reading(payload: payload)
        else { return }

        let surfaceID = (json["surface_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        DispatchQueue.main.async { [weak self] in
            self?.onStatusLine?(projectDir, surfaceID, reading)
        }
    }

    // MARK: - Permission Requests

    /// Keeps a connection open until the app decides, then replies with the
    /// decision document Claude Code reads off the hook's stdout.
    ///
    /// The connection is unhooked from `connections` first, and deliberately.
    /// The read deadline that reaps half-open requests cancels anything still in
    /// that list after `connectionTimeout` — it would otherwise kill this
    /// connection 15 seconds in, mid-hold, with the banner still on screen. What
    /// bounds this one instead is the app's own hold, which always resolves;
    /// `PermissionApprovalStore` exists to guarantee that.
    private func hold(
        _ connection: NWConnection,
        eventInput: [String: Any],
        projectDir: String,
        surfaceID: String?
    ) {
        removeConnection(connection)

        let toolName = eventInput["tool_name"] as? String ?? "unknown"
        let request = PendingPermission(
            id: UUID(),
            toolName: toolName,
            detail: PendingPermission.detail(
                toolName: toolName,
                toolInput: eventInput["tool_input"] as? [String: Any]
            ),
            surfaceID: surfaceID.flatMap(UUID.init(uuidString:)),
            receivedAt: Date(),
            expiresAt: Date().addingTimeInterval(PermissionApprovalSettings.hold)
        )

        // Resolvable exactly once. Two callers can race here — a click landing at
        // the moment the hold expires — and answering twice would write a second
        // response onto a cancelled connection.
        let resolved = OSAllocatedUnfairLock(initialState: false)
        let respond: @Sendable (PendingPermission.Decision?) -> Void = { [weak self] decision in
            let first = resolved.withLock { alreadyResolved -> Bool in
                defer { alreadyResolved = true }
                return !alreadyResolved
            }
            guard first, let self else { return }
            queue.async {
                self.sendResponse(on: connection, status: "200 OK", body: Self.decisionBody(decision))
            }
        }

        logger.info("Permission requested for \(toolName, privacy: .public) in \(projectDir, privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onPermissionRequest else {
                // Nothing is wired up yet — the app is still launching, or this
                // build has no approval UI. Hand it straight back rather than
                // queueing against a handler that may never appear.
                respond(nil)
                return
            }
            handler(projectDir, request, respond)
        }
    }

    /// The body Claude Code's `PermissionRequest` hook expects on stdout.
    ///
    /// An empty body for "no decision" is load-bearing: the hook script only
    /// echoes a body containing `hookSpecificOutput`, so this prints nothing and
    /// Claude Code asks in the terminal exactly as it would with no hook at all.
    static func decisionBody(_ decision: PendingPermission.Decision?) -> String {
        switch decision {
        case .allow:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in Atelier."}}}"#
        case nil:
            ""
        }
    }

    /// The request target from an HTTP request line, e.g. "/permission".
    /// Defaults to "/hook", which is what every caller before this one sent.
    private func requestTarget(in headerData: Data) -> String {
        guard let header = String(data: headerData, encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first
        else { return "/hook" }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return "/hook" }
        return String(fields[1])
    }

    // MARK: - Event Mapping

    /// Determines the agent ID from the event input JSON.
    /// Uses "main" if no `agent_id` field is present.
    private func agentId(from eventInput: [String: Any]) -> String {
        (eventInput["agent_id"] as? String) ?? "main"
    }

    /// Returns true if the given agent ID represents a subagent (not the main agent).
    private func isSubagent(_ agentId: String) -> Bool {
        !agentId.isEmpty && agentId != "main"
    }

    /// Whether a tool is Atelier's business to report at all.
    ///
    /// Consulted by **both** `PreToolUse` and `PostToolUse`, which is the point:
    /// the two hooks bracket a running tool, and a bracket that opens without
    /// closing — or closes without opening — is worse than no bracket at all.
    /// `mcp__*` used to be filtered here on one side only, so an MCP call
    /// reported nothing on the way in and a stray `toolDone` on the way out; the
    /// stall sweep therefore saw a silent agent with no tool in flight and had
    /// nothing to exempt. MCP calls are ordinary tool calls, frequently the
    /// slowest ones, and belong inside a bracket.
    static func isMetaTool(_ toolName: String) -> Bool {
        toolName == "Skill" || toolName == "ToolSearch"
    }

    /// Maps a tool name (and, when available, its input) to a short human-readable
    /// activity description for the sidebar roster, e.g. "Editing Foo.swift".
    static func activityDescription(toolName: String, toolInput: [String: Any]?) -> String? {
        // `mcp__scenius__read` -> "scenius/read". The raw name is what the
        // harness reports, and it does not fit the status line's one truncating
        // slot; server and tool are the two parts that identify the call.
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst("mcp__".count).components(separatedBy: "__")
            let named = parts.filter { !$0.isEmpty }
            return named.isEmpty ? nil : named.joined(separator: "/")
        }
        let filePath = (toolInput?["file_path"] as? String) ?? (toolInput?["notebook_path"] as? String)
        let baseName = filePath.map { URL(fileURLWithPath: $0).lastPathComponent }

        // Claude Code tool names are PascalCase ("Edit"); match case-
        // insensitively so a differently-cased payload still resolves.
        switch toolName.lowercased() {
        case "edit", "write", "multiedit", "notebookedit", "patch":
            if let baseName {
                return String(format: NSLocalizedString("Editing %@", comment: "Agent is modifying a file"), baseName)
            }
            return NSLocalizedString("Editing", comment: "Agent is modifying a file")
        case "read":
            if let baseName {
                return String(format: NSLocalizedString("Reading %@", comment: "Agent is reading a file"), baseName)
            }
            return NSLocalizedString("Reading", comment: "Agent is reading a file")
        case "grep", "glob":
            return NSLocalizedString("Searching", comment: "Agent is searching the codebase")
        case "bash":
            return NSLocalizedString("Running command", comment: "Agent is running a shell command")
        case "webfetch", "websearch":
            return NSLocalizedString("Browsing", comment: "Agent is fetching web content")
        case "todowrite", "todoread":
            return NSLocalizedString("Planning", comment: "Agent is updating its task plan")
        case "task":
            return NSLocalizedString("Delegating", comment: "Agent is delegating to a subagent")
        default:
            // Custom/MCP tools surface verbatim so the row always says
            // something specific about what's running.
            return toolName.isEmpty ? nil : toolName
        }
    }

    /// Maps a Claude Code hook event to zero or more `AgentEvent` values.
    /// Must be called on `self.queue`.
    private func mapHookEvent(hookEventName: String, eventInput: [String: Any], projectDir: String) -> [AgentEvent] {
        // Every Claude Code hook payload carries the session transcript path;
        // attach it so the tracker can read context-window usage from its tail.
        let transcriptPath = eventInput["transcript_path"] as? String
        let events = baseHookEvents(hookEventName: hookEventName, eventInput: eventInput, projectDir: projectDir)
        guard let transcriptPath else { return events }
        return events.map { event in
            var event = event
            event.transcriptPath = transcriptPath
            return event
        }
    }

    private func baseHookEvents(hookEventName: String, eventInput: [String: Any], projectDir _: String) -> [AgentEvent] {
        switch hookEventName {
        case "PreToolUse":
            let toolName = eventInput["tool_name"] as? String ?? "unknown"
            guard !Self.isMetaTool(toolName) else { return [] }
            let aid = agentId(from: eventInput)
            let activity = Self.activityDescription(toolName: toolName, toolInput: eventInput["tool_input"] as? [String: Any])
            logger.info("Hook PreToolUse: \(toolName, privacy: .public) agent=\(aid, privacy: .public)")
            return [AgentEvent.toolStart(agentId: aid, tool: toolName, activity: activity)]

        case "PostToolUse":
            let toolName = eventInput["tool_name"] as? String ?? "unknown"
            guard !Self.isMetaTool(toolName) else { return [] }
            let aid = agentId(from: eventInput)
            logger.info("Hook PostToolUse: \(toolName, privacy: .public) agent=\(aid, privacy: .public)")
            return [AgentEvent.toolDone(agentId: aid)]

        case "Stop":
            logger.info("Hook Stop: main agent goes idle")
            return [AgentEvent.idle(agentId: "main")]

        case "UserPromptSubmit":
            logger.info("Hook UserPromptSubmit: main agent waiting")
            return [AgentEvent.waiting(agentId: "main")]

        case "SubagentStart":
            let aid = agentId(from: eventInput)
            guard isSubagent(aid) else { return [] }
            let agentType = eventInput["agent_type"] as? String ?? "Sub-agent"
            let name = String(agentType.prefix(20))
            logger.info("Hook SubagentStart: \(aid, privacy: .public) name=\(name, privacy: .public)")
            return [AgentEvent.created(agentId: aid, name: name, parentAgentId: "main")]

        case "SubagentStop":
            let aid = agentId(from: eventInput)
            guard isSubagent(aid) else { return [] }
            logger.info("Hook SubagentStop: \(aid, privacy: .public)")
            return [AgentEvent.removed(agentId: aid)]

        case "SessionStart":
            // `source` says why the session started: "startup" and "clear" are
            // genuinely new sessions, while "resume" and "compact" continue one
            // that is already running — and compaction in particular fires
            // mid-turn, where wiping the roster would erase live subagents and
            // reset a working row to idle. Only the first two clear.
            let source = eventInput["source"] as? String ?? ""
            guard source == "startup" || source == "clear" else {
                logger.info("Hook SessionStart: continuing session (source=\(source, privacy: .public)), roster kept")
                return []
            }
            logger.info("Hook SessionStart: new session (source=\(source, privacy: .public))")
            return [AgentEvent.sessionStarted()]

        case "SessionEnd":
            logger.info("Hook SessionEnd: session over, roster cleared")
            return [AgentEvent.sessionEnded()]

        case "PreCompact":
            logger.info("Hook PreCompact: main agent compacting")
            return [AgentEvent.compacting()]

        case "PostCompact":
            logger.info("Hook PostCompact: compaction finished")
            return [AgentEvent.compacted()]

        case "PermissionRequest":
            // Emitted whether or not the app is allowed to *answer*: the row has
            // to show that something is waiting on the user either way, and this
            // payload says so with a tool name instead of a phrase to grep.
            let toolName = eventInput["tool_name"] as? String ?? "unknown"
            logger.info("Hook PermissionRequest: \(toolName, privacy: .public)")
            return [AgentEvent.status(agentId: "main", status: "permissionRequired")]

        case "Notification":
            // Claude Code emits Notification for permission prompts and idle
            // reminders. The message field is the only signal we have; over-
            // reporting permission is preferable to under-reporting.
            //
            // Kept now that `PermissionRequest` reports the same thing properly,
            // because the two do not cover the same ground: a prompt Claude Code
            // resolves from its own allowlist, or raises while Atelier is down,
            // reaches us here and nowhere else. This is the lossy fallback and
            // `PermissionRequest` is the authoritative path; they set the same
            // state, so arriving by both routes is harmless.
            let message = (eventInput["message"] as? String) ?? ""
            let lower = message.lowercased()
            let isPermission = lower.contains("permission") || lower.contains("approval")
            let status = isPermission ? "permissionRequired" : "idleNotification"
            logger.info("Hook Notification: status=\(status, privacy: .public)")
            return [AgentEvent.status(agentId: "main", status: status)]

        default:
            logger.debug("Unhandled hook event: \(hookEventName, privacy: .public)")
            return []
        }
    }

    private func sendResponse(on connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let responseData = Data(response.utf8)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    // MARK: - Port File

    private var portFilePath: String {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/atelier")
        return cacheDir.appendingPathComponent("hook-port").path
    }

    /// Publishing is skipped under XCTest. There is exactly one port file, and
    /// `Resources/Scripts/atelier-hook` is installed globally in
    /// `~/.claude/settings.json`, so it cannot know which process wrote it: a
    /// test process that advertises its own listener here collects the hook
    /// traffic of every Claude Code session on the machine. That is what made
    /// `HookEventReceiverTests`'s inverted expectations fail at random — real
    /// `agentToolStart` events landing inside a window that asserts silence —
    /// and the permission cases in that suite answer `.allow`/`.deny`, so a real
    /// prompt could have been decided by a test. Nothing in the suite reads the
    /// file; tests take the port from `boundPort`.
    ///
    /// The path is deliberately *not* `AppConstants.cacheDirectory`, which
    /// separates debug from release. One global hook script means one rendezvous,
    /// so whichever build is running owns it. Taking ownership on launch is
    /// unconditional; *giving it up* is not — see `removePortFile`.
    private func writePortFile(port: UInt16) {
        guard !isRunningXCTest() else { return }
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/atelier")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let portString = String(port)
        try? portString.write(toFile: portFilePath, atomically: true, encoding: .utf8)
        logger.info("Wrote port \(port) to \(self.portFilePath)")
    }

    /// Removes the rendezvous file, but **only when it still names this
    /// instance's port**.
    ///
    /// One file, several Atelier processes — the condition `writePortFile`
    /// describes — and a later launch overwrites it. Quitting is therefore the
    /// one moment an instance can hold a number the file no longer carries, and
    /// an unconditional delete there took the *running* instance's rendezvous
    /// with it. `atelier-hook` exits 0 without posting when the file is missing,
    /// so the result was silence for every Claude Code session on the machine,
    /// reported as nothing at all: the remaining app's `HookChannelProbe` said
    /// "No Signal" and was right, with no way to say why. One release app plus
    /// one `./scripts/dev.sh br` from a worktree was enough to reach it.
    ///
    /// Still skipped under XCTest, for `writePortFile`'s reason: a suite that
    /// never published the port must not delete the running app's. The ownership
    /// check does not make that guard redundant — a suite that *did* bind and
    /// publish would pass it.
    private func removePortFile(ownPort: UInt16?) {
        guard !isRunningXCTest() else { return }
        let contents = try? String(contentsOfFile: portFilePath, encoding: .utf8)
        guard Self.ownsPortFile(contents: contents, ownPort: ownPort) else {
            logger.info("Leaving the hook port file: it no longer names this instance")
            return
        }
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    /// Whether the rendezvous file as read belongs to an instance on `ownPort`.
    ///
    /// Split out and `static` so the rule is testable: the file itself is the
    /// one thing the suite must not touch, so the decision has to be checkable
    /// without one. Exact match on the trimmed contents — a prefix comparison
    /// would read `607980` as `60798` and delete a sibling's file.
    static func ownsPortFile(contents: String?, ownPort: UInt16?) -> Bool {
        guard let ownPort, let contents else { return false }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines) == String(ownPort)
    }
}
