// ABOUTME: Answers IPC requests from atelier-mcp helpers against the peer store.
// ABOUTME: Owns the app-side context (workstream, surface, project) the store deliberately lacks.

import Foundation

extension IPC {
    /// The app-side half of the IPC feature: one request in, one response out.
    ///
    /// Separate from `IPC.Server` so the tool behaviour is testable without a socket,
    /// and separate from `IPC.Store` so the store stays pure peer/inbox logic.
    actor Service {
        static let shared = Service()

        /// What the app knows about a peer that the store does not.
        struct PeerContext: Equatable {
            let workstreamID: String?
            let workstreamName: String?
            let projectDirectory: String?
            /// The terminal surface this peer runs in, when Atelier launched it.
            /// Nil means pull-only: there is nowhere to type a notice.
            let surfaceID: UUID?
        }

        private let store: Store
        private let tasks: TaskStore
        private var contexts: [UUID: PeerContext] = [:]

        /// The check runner the verification tools act through, once the app has
        /// one. Nil until then, and both tools say so rather than pretending.
        ///
        /// Injected rather than constructed here for the reason
        /// `IPC.VerificationControlling` exists: this actor holds the protocol
        /// and never the runner's type, so the tools are testable against a stub
        /// and the two halves of the feature can land in either order.
        private var verification: VerificationControlling?

        /// The run controller the execution tools act through, once the app has
        /// one. Held as the protocol for the reason `verification` is: this actor
        /// knows the seam, never the bridge.
        private var execution: ExecutionControlling?

        /// Starts whose completion notice has already been posted.
        ///
        /// The seam promises `onFinish` fires once per run, and a second call
        /// would put a duplicate into an inbox with a hundred-message cap. Free
        /// to guard, and unpleasant to diagnose from the agent's end.
        ///
        /// **Keyed per start rather than by run id**, which is the runner's value
        /// and only promised unique for the app's lifetime — and a workstream's
        /// most recent run outlives a restart, so that promise spans a boundary
        /// this set does not. Keyed by id, a legitimate second run that happened
        /// to reuse one would be silently swallowed and deliver nothing. A token
        /// minted here cannot collide with anything.
        private var deliveredNotices: Set<UUID> = []

        init(store: Store = Store(), tasks: TaskStore = TaskStore()) {
            self.store = store
            self.tasks = tasks
        }

        /// Wires up the check runner. Called once, by whatever builds it.
        func setVerificationRunner(_ runner: VerificationControlling?) {
            verification = runner
        }

        func setExecutionController(_ controller: ExecutionControlling?) {
            execution = controller
        }

        // MARK: - Dispatch

        func handle(_ request: Request) async -> Response {
            await touch(request.client)

            switch request.tool {
            case .registerPeer:
                return await registerPeer(for: request)
            case .listPeers:
                return await listPeers(for: request)
            case .sendMessage:
                return await sendMessage(for: request)
            case .receiveMessages:
                return await receiveMessages(for: request)
            case .broadcast:
                return await broadcast(for: request)
            case .getPeerStatus:
                return await getPeerStatus(for: request)
            case .listTabs:
                return await listTabs(for: request)
            case .readReviewComments:
                return await readReviewComments(for: request)
            case .openAgentTab:
                return await openAgentTab(for: request)
            case .openEditor:
                return await openEditor(for: request)
            case .openTab:
                return await openTab(for: request)
            case .closeTab:
                return await closeTab(for: request)
            case .requestAttention:
                return await requestAttention(for: request)
            case .createWorkstream:
                return await createWorkstream(for: request)
            case .startVerification:
                return await startVerification(for: request)
            case .checkVerification:
                return await checkVerification(for: request)
            case .listVerificationChecks:
                return await listVerificationChecks(for: request)
            case .listProcesses:
                return await listProcesses(for: request)
            case .readProcessLogs:
                return await readProcessLogs(for: request)
            case .startProcess:
                return await controlProcess(for: request, action: .start)
            case .stopProcess:
                return await controlProcess(for: request, action: .stop)
            case .restartProcess:
                return await controlProcess(for: request, action: .restart)
            case .startExecution:
                return await startExecution(for: request)
            case .stopExecution:
                return await stopExecution(for: request)
            case .readWhiteboard:
                return readWhiteboard(for: request)
            case .whiteboardAdd:
                return await whiteboardAdd(for: request)
            case .whiteboardUpdate:
                return await whiteboardUpdate(for: request)
            case .whiteboardDelete:
                return await whiteboardDelete(for: request)
            case .addTask:
                return await addTask(for: request)
            case .getPendingTasks:
                return await getPendingTasks(for: request)
            case .listTasks:
                return await listTasks(for: request)
            case .claimTask:
                return await claimTask(for: request)
            case .completeTask:
                return await completeTask(for: request)
            case .failTask:
                return await failTask(for: request)
            case .getSessionCheckpoint:
                return await getSessionCheckpoint(for: request)
            case .updateSessionCheckpoint:
                return await updateSessionCheckpoint(for: request)
            }
        }

        // MARK: - Tools

        /// Registers this session, or renames the peer it already has.
        ///
        /// A helper that reconnects sends the peer id it was given, and gets that
        /// same identity back renamed — otherwise one agent would accumulate a new
        /// peer per registration and its inbox would strand behind the old id.
        private func registerPeer(for request: Request) async -> Response {
            // Both are agent-chosen and both are shown to other agents; the name is
            // additionally typed into their terminals by the nudge.
            let arguments = ToolArguments(request)
            // `optional` reads a present-but-empty `name` as absent, so `name: ""`
            // now falls through to the workstream name rather than to "agent" —
            // which is what this argument's own schema has always promised it
            // defaults to. The behaviour changed with the typed read; the
            // promise did not.
            let name = Names.sanitized(
                arguments.optional("name") ?? request.client.workstreamName ?? "agent",
                limit: 40,
                fallback: "agent"
            )
            let role = Names.sanitized(arguments.optional("role") ?? "", limit: 80, fallback: "")

            if let existingID = request.client.peerID.flatMap(UUID.init(uuidString:)),
               let renamed = await store.updatePeer(id: existingID, name: name, role: role.isEmpty ? nil : role)
            {
                contexts[renamed.id] = context(from: request.client)
                await store.pin(renamed.id)
                return await .success(id: request.id, .peer(info(for: renamed)))
            }

            let peer = await store.registerPeer(name: name, role: role)
            contexts[peer.id] = context(from: request.client)
            // Registration only ever arrives over a live connection, and `release`
            // runs when that connection closes — so the pin's lifetime is the
            // helper's lifetime.
            await store.pin(peer.id)
            return await .success(id: request.id, .peer(info(for: peer)))
        }

        private func listPeers(for request: Request) async -> Response {
            let peers = await store.listPeers()
            pruneContexts(keeping: peers.map(\.id))

            let visible = peers.filter { isVisible($0.id, to: request.client) && $0.id.uuidString != request.client.peerID }
            let counts = await store.inboxCounts(for: visible.map(\.id))
            let now = Date()
            let infos = visible.map { info(for: $0, pending: counts[$0.id] ?? 0, now: now) }
            return .success(id: request.id, .peers(infos))
        }

        private func sendMessage(for request: Request) async -> Response {
            guard let sender = registeredPeerID(request) else {
                return .failure(id: request.id, Error.unregisteredPeer.localizedDescription)
            }
            let arguments = ToolArguments(request)
            // Refused in this tool's own words rather than as a bare
            // `invalidArgument`, because the sentence names the tool that fixes
            // it and agents have been reading it for as long as the tool has
            // existed. `ToolError.refused` is the boundary case for exactly
            // that: one type crossing into `Response`, without renaming a
            // message somebody's agent parses.
            guard let recipient = try? arguments.uuid("to") else {
                return .failure(
                    id: request.id,
                    ToolError.refused("send_message needs a `to` peer id. Use list_peers to see who is reachable.")
                        .localizedDescription
                )
            }
            let content: String
            do {
                content = try arguments.nonEmpty("content")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
            guard isVisible(recipient, to: request.client) else {
                return .failure(id: request.id, Error.peerNotFound(recipient).localizedDescription)
            }

            do {
                _ = try await store.sendMessage(from: sender, to: recipient, content: content)
                let name = await store.peerStatus(id: recipient)?.name ?? recipient.uuidString
                await nudge([recipient], from: sender)
                return .success(id: request.id, .text("Delivered to \(name)'s inbox."))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func broadcast(for request: Request) async -> Response {
            guard let sender = registeredPeerID(request) else {
                return .failure(id: request.id, Error.unregisteredPeer.localizedDescription)
            }
            let content: String
            do {
                content = try ToolArguments(request).nonEmpty("content")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }

            let audience = await store.listPeers()
                .map(\.id)
                .filter { $0 != sender && isVisible($0, to: request.client) }

            do {
                let delivered = try await store.broadcast(from: sender, content: content, to: audience)
                await nudge(delivered.map(\.to), from: sender)
                return .success(id: request.id, .text("Delivered to \(delivered.count) peer\(delivered.count == 1 ? "" : "s")."))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func receiveMessages(for request: Request) async -> Response {
            guard let peerID = registeredPeerID(request) else {
                return .failure(id: request.id, Error.unregisteredPeer.localizedDescription)
            }

            let messages = await store.receiveMessages(for: peerID)
            var infos: [MessageInfo] = []
            let now = Date()
            for message in messages {
                // A `.system` message has no peer to look up and no peer id to
                // report: what an agent sees is the reserved label, which is
                // deliberately not something `send_message` would accept — there
                // is nothing inside Atelier for it to reply to.
                let from: String
                let senderName: String
                switch message.from {
                case let .peer(senderID):
                    from = senderID.uuidString
                    senderName = await store.peerStatus(id: senderID)?.name ?? "unknown"
                case let .system(label):
                    from = label
                    senderName = label
                }
                infos.append(MessageInfo(
                    id: message.id.uuidString,
                    from: from,
                    fromName: senderName,
                    content: message.content,
                    sentSecondsAgo: Int(now.timeIntervalSince(message.timestamp))
                ))
            }

            // receiveMessages is delete-on-read, so a payload that cannot be encoded
            // would take the messages with it. Prove it encodes while the store can
            // still take them back.
            let payload = Payload.messages(infos)
            guard (try? JSONEncoder().encode(payload)) != nil else {
                await store.requeue(messages, for: peerID)
                return .failure(id: request.id, "Could not encode the waiting messages; they are still in your inbox.")
            }
            return .success(id: request.id, payload)
        }

        private func getPeerStatus(for request: Request) async -> Response {
            guard let peerID = try? ToolArguments(request).uuid("peer_id") else {
                return .failure(id: request.id, ToolError.refused("get_peer_status needs a `peer_id`.").localizedDescription)
            }
            guard isVisible(peerID, to: request.client), let peer = await store.peerStatus(id: peerID) else {
                return .failure(id: request.id, Error.peerNotFound(peerID).localizedDescription)
            }
            return await .success(id: request.id, .peer(info(for: peer)))
        }

        /// Treats any request from a registered peer as proof it is alive.
        ///
        /// Without this a well-behaved agent expires: `list_peers` and
        /// `get_peer_status` are pure reads, so an agent that polls politely and
        /// says nothing for ten minutes gets purged by the very call it was making,
        /// and its next `send_message` is told to register first. The TTL is a
        /// backstop for sessions that vanish, not a limit on quiet ones.
        private func touch(_ client: ClientIdentity) async {
            guard let id = client.peerID.flatMap(UUID.init(uuidString:)), contexts[id] != nil else { return }
            if await store.updatePeer(id: id, name: nil, role: nil) == nil {
                contexts.removeValue(forKey: id)
            } else if contexts[id] == nil {
                // A release landed during the await while the store kept the peer.
                // Left alone this is a peer others can see but that cannot send,
                // since its own requests would no longer resolve a context.
                contexts[id] = context(from: client)
            }
        }

        /// Drops a peer whose helper has gone away. Called when its connection
        /// closes — the socket a helper holds open for its whole session is a far
        /// better liveness signal than the TTL, which would otherwise leave a ghost
        /// that `list_peers` advertises and `send_message` reports delivering to.
        ///
        /// **Its surface state goes with it only if no successor has taken the pane
        /// over.** A peer being retired is by definition the older of any two that
        /// name one surface: registration happens on a live connection, and this
        /// runs when a connection closes. So a surviving context for the same
        /// surface belongs to whoever is sitting there now, and clearing it would
        /// reach past them — see `surfaceStillOccupied`.
        func release(peerID: UUID) async {
            await store.removePeer(id: peerID)
            let context = contexts.removeValue(forKey: peerID)

            // Otherwise the tracker keeps reporting whatever that agent last said —
            // usually .idle — and a nudge arriving afterwards would type into a pane
            // whose agent has gone.
            if let surfaceID = context?.surfaceID, !surfaceStillOccupied(surfaceID) {
                await MainActor.run {
                    Workstream.AgentStateTracker.shared.clear(surfaceID: surfaceID)
                }
            }
        }

        /// Whether any peer still registered names `surfaceID`.
        ///
        /// Read **after** the departing peer's own context has been removed, so it
        /// can never match itself — checking first would make every release a no-op
        /// and leave every surface behind forever.
        ///
        /// `contexts` is the whole of the answer, and deliberately not intersected
        /// with the store's live peers. The two failure directions are not
        /// symmetric. Counting a context whose peer has quietly expired costs one
        /// *missed* clear, which is bounded and self-healing: Claude Code's
        /// `agentSessionEnded` clears the surface on its own, `Archiver` clears the
        /// whole workstream, and the successor's own release finds the predecessor's
        /// context already gone and clears it then. Failing to count a live peer is
        /// the defect this guard exists for, and it lasts the session: the nudge
        /// takes an unreported surface as "do not interrupt", so the pane waiting on
        /// a message is exactly the one that stops being told. Erring towards
        /// occupied is therefore the correct direction.
        ///
        /// Nothing can be stranded by a context outliving its peer for good, either:
        /// the store's `pin` exempts a connected helper's peer from the TTL, so a
        /// context and its peer are dropped together by this method, by `touch` when
        /// the store has already expired it, and by `pruneContexts`.
        private func surfaceStillOccupied(_ surfaceID: UUID) -> Bool {
            contexts.values.contains { $0.surfaceID == surfaceID }
        }

        /// Drops every peer. Called when the listener stops — nothing can reach the
        /// app afterwards, and pinned peers would otherwise outlive their sockets.
        func releaseAll() async {
            await store.cleanup()
            await tasks.cleanup()

            // Same reason `release(peerID:)` clears it: a surface left in the tracker
            // keeps reporting whatever its agent last said — usually .idle — and a
            // later nudge would type into a pane whose agent has gone. Shutdown drops
            // every peer at once, so it has the same exposure for all of them — and
            // unconditionally, unlike `release(peerID:)`: there is no successor to
            // reach past when every context is going in the same breath.
            let surfaceIDs = contexts.values.compactMap(\.surfaceID)
            contexts.removeAll()
            if !surfaceIDs.isEmpty {
                await MainActor.run {
                    for surfaceID in surfaceIDs {
                        Workstream.AgentStateTracker.shared.clear(surfaceID: surfaceID)
                    }
                }
            }
        }

        // MARK: - Nudging

        /// Asks the terminal nudge to tell each recipient a message arrived.
        ///
        /// Strictly best-effort, and separate from delivery: the message is already
        /// in the inbox by the time this runs, so a nudge that is switched off,
        /// aimed at a busy agent, or aimed at a session Atelier didn't launch costs
        /// the sender nothing.
        private func nudge(_ recipients: [UUID], from senderID: UUID) async {
            let senderName = await store.peerStatus(id: senderID)?.name ?? "another agent"
            await nudge(recipients, senderName: senderName)
        }

        /// The same courtesy for a notice that has no sender peer — a
        /// verification run finishing. The name is only ever logged: the text
        /// typed into a pane deliberately says nothing the sender chose.
        private func nudge(_ recipients: [UUID], senderName: String) async {
            guard AgentSettings.nudgeEnabled else { return }

            for recipient in recipients {
                guard let context = contexts[recipient], let surfaceID = context.surfaceID else { continue }

                let waiting = await store.inboxCount(for: recipient)

                // Detached, not awaited. The message is already in the inbox; the
                // nudge is a courtesy, and waiting for the main actor here would
                // make delivery to one agent depend on the UI being free — a busy
                // main thread would stall send_message rather than just delaying a
                // notice.
                Task { @MainActor in
                    AgentNudge.shared.nudge(surfaceID: surfaceID, senderName: senderName, waiting: waiting)
                }
            }
        }

        // MARK: - Scoping

        /// Peers are scoped to the caller's project. Cross-project messaging is a
        /// separate, louder opt-in — an agent that can reach another project's agent
        /// can, once nudging is on, drive a session in a repository the user wasn't
        /// thinking about.
        private func isVisible(_ peerID: UUID, to client: ClientIdentity) -> Bool {
            guard let project = client.projectDirectory, !project.isEmpty else { return false }
            return contexts[peerID]?.projectDirectory == project
        }

        /// The caller's own peer id, if it has registered one that is still alive.
        private func registeredPeerID(_ request: Request) -> UUID? {
            guard let id = request.client.peerID.flatMap(UUID.init(uuidString:)) else { return nil }
            return contexts[id] == nil ? nil : id
        }

        private func context(from client: ClientIdentity) -> PeerContext {
            PeerContext(
                workstreamID: client.workstreamID,
                workstreamName: client.workstreamName,
                projectDirectory: client.projectDirectory,
                surfaceID: client.surfaceID.flatMap(UUID.init(uuidString:))
            )
        }

        /// Contexts outlive their peers otherwise: the store expires peers lazily
        /// and never tells anyone which ones it dropped.
        private func pruneContexts(keeping aliveIDs: [UUID]) {
            let alive = Set(aliveIDs)
            contexts = contexts.filter { alive.contains($0.key) }
        }

        private func info(for peer: Peer) async -> PeerInfo {
            await info(for: peer, pending: store.inboxCount(for: peer.id), now: Date())
        }

        /// Synchronous on purpose: `lastUserPromptAt(forSurface:)` is `nonisolated`
        /// precisely so this can stay off the main actor. A `MainActor.run` hop
        /// here once deadlocked a real socket round trip — `IPCServerTests` blocks
        /// its own thread in a raw `recv()` waiting for the reply this function
        /// produces, so if producing it needed the main thread to go idle first,
        /// and the main thread was the one blocked in `recv()`, neither side could
        /// proceed.
        private func info(for peer: Peer, pending: Int, now: Date) -> PeerInfo {
            let surfaceID = contexts[peer.id]?.surfaceID
            let lastUserPromptSecondsAgo = surfaceID
                .flatMap { Workstream.AgentStateTracker.shared.lastUserPromptAt(forSurface: $0) }
                .map { Int(now.timeIntervalSince($0)) }
            return PeerInfo(
                id: peer.id.uuidString,
                name: peer.name,
                role: peer.role,
                workstream: contexts[peer.id]?.workstreamName,
                surfaceID: surfaceID?.uuidString,
                lastSeenSecondsAgo: Int(now.timeIntervalSince(peer.lastSeen)),
                pendingMessages: pending,
                lastUserPromptSecondsAgo: lastUserPromptSecondsAgo
            )
        }

        // MARK: - Workspace tools

        /// The workstream the caller is running in, or the failure to report.
        ///
        /// Every workspace tool starts here. An agent Atelier did not launch has
        /// no `ATELIER_WORKSTREAM_ID`, and there is no sensible default — acting
        /// on "some workstream" would be worse than refusing.
        private func callerWorkstreamID(_ request: Request) -> UUID? {
            request.client.workstreamID.flatMap(UUID.init(uuidString:))
        }

        /// Surface id → the peer registered from it.
        ///
        /// Built from `contexts`, which is the only place the binding lives. This
        /// is what lets `list_tabs` answer "which agent is in that tab" — and so
        /// what lets a caller turn a tab it just created into a `send_message`
        /// address once the agent there has connected.
        private func peersBySurface() async -> [UUID: (id: String, name: String)] {
            var result: [UUID: (id: String, name: String)] = [:]
            for peer in await store.listPeers() {
                guard let surfaceID = contexts[peer.id]?.surfaceID else { continue }
                result[surfaceID] = (id: peer.id.uuidString, name: peer.name)
            }
            return result
        }

        private func listTabs(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            let callerSurfaceID = request.client.surfaceID.flatMap(UUID.init(uuidString:))
            let peers = await peersBySurface()
            do {
                let tabs = try await MainActor.run {
                    try WorkspaceActions.shared.tabs(
                        workstreamID: workstreamID,
                        callerSurfaceID: callerSurfaceID,
                        peers: peers
                    )
                }
                return .success(id: request.id, .tabs(tabs))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func readReviewComments(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            do {
                let comments = try await MainActor.run {
                    try WorkspaceActions.shared.reviewComments(workstreamID: workstreamID)
                }
                return .success(id: request.id, .reviewComments(comments))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func openEditor(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            // `line` is optional, but a value that is present and unparseable is
            // a mistake worth reporting rather than silently ignoring — which is
            // `ToolArguments.integer`'s whole contract, rather than something
            // this handler has to remember to spell out.
            let path: String
            let line: Int?
            do {
                let arguments = ToolArguments(request)
                path = try arguments.required("path")
                line = try arguments.integer("line")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
            do {
                let opened = try await MainActor.run {
                    try WorkspaceActions.shared.openEditor(workstreamID: workstreamID, path: path, line: line)
                }
                return .success(id: request.id, .text("Opened \(opened) in the editor."))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// Opens one of the caller's singleton tabs — Changes, Execution or
        /// Verification — without taking the selection.
        ///
        /// **The answer must never imply the user is now looking at it.** The tab
        /// is opened behind whatever they have in front of them, on purpose, so
        /// an agent that needs their eyes has to ask for them separately with
        /// `request_attention`. Saying "opened" and leaving the rest implied is
        /// how an agent ends up waiting for a reaction to something nobody saw.
        private func openTab(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            let kind: String
            do {
                kind = try ToolArguments(request).required("kind")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
            do {
                let opened = try await MainActor.run {
                    try WorkspaceActions.shared.openTab(workstreamID: workstreamID, kind: kind)
                }
                let what = opened.wasAlreadyOpen
                    ? "The \(opened.kind) tab was already open."
                    : "Opened the \(opened.kind) tab."
                return .success(
                    id: request.id,
                    .text(what + " It did not take the selection, so the user is still looking at whatever they had "
                        + "in front of them — use request_attention if you need them to come and look.")
                )
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// Closes one of the caller's tabs — a singleton pane by `kind`, or a
        /// terminal tab by `surface_id`. See `WorkspaceActions.closeTab` for
        /// the full contract: exactly one of the two arguments, why Execution
        /// is refused rather than closed, and why an id nothing currently
        /// owns is success rather than an error.
        private func closeTab(for request: Request) async -> Response {
            let arguments = ToolArguments(request)
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            do {
                let result = try await MainActor.run {
                    try WorkspaceActions.shared.closeTab(
                        workstreamID: workstreamID,
                        kind: arguments.optional("kind"),
                        surfaceID: arguments.optional("surface_id")
                    )
                }
                let what = switch (result.kind, result.wasOpen) {
                case let (kind?, true):
                    "Closed the \(kind) tab."
                case let (kind?, false):
                    "The \(kind) tab was already closed."
                case (nil, _):
                    "No tab in this workstream has that surface id — it may already be closed."
                }
                return .success(id: request.id, .text(what))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// Opens a terminal tab in the caller's own workstream, optionally
        /// starting an agent in it.
        ///
        /// Three steps in two isolation domains, and the middle one is why this
        /// is not a single `MainActor.run`: building the environment asks git for
        /// the default branch and reads `ports.yaml`, and the main actor has no
        /// business waiting on either.
        ///
        /// The agent is started by *creating the surface already running it*,
        /// never by typing into a shell. There is no paste, no synthetic Return,
        /// and no question of whether the pane was interruptible — the tab does
        /// not exist until it exists running the right thing.
        private func openAgentTab(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            let arguments = ToolArguments(request)
            let title = Names.sanitized(arguments.optional("title") ?? "", limit: 40, fallback: "")
            // An empty `prompt` is not a request for an agent, and is now read as
            // absent. It used to arrive as `Optional("")`, which `startsAgent`
            // already treated as no agent while the `claude`-not-found guard
            // below treated it as one — so a caller sending `prompt: ""` on a
            // machine without `claude` was refused a plain terminal it would
            // otherwise have been given.
            let prompt = arguments.optionalTrimmed("prompt")

            do {
                let plan = try await MainActor.run {
                    try WorkspaceActions.shared.agentTabPlan(workstreamID: workstreamID)
                }

                // An agent was asked for but there is no `claude` to start. Refuse
                // rather than opening a bare shell the caller would believe was an
                // agent — a tab that silently is not what was asked for is worse
                // than no tab.
                if prompt != nil, plan.claudePath == nil {
                    return .failure(
                        id: request.id,
                        "Cannot start an agent: Atelier could not find the `claude` binary. Omit `prompt` to open a plain terminal tab instead."
                    )
                }

                let startsAgent = prompt?.isEmpty == false
                let surfaceID = try await MainActor.run {
                    try WorkspaceActions.shared.spawnTerminalTab(
                        workstreamID: workstreamID,
                        title: title.isEmpty ? nil : title,
                        command: { surfaceID in
                            agentCommand(plan: plan, prompt: prompt, surfaceID: surfaceID)
                        },
                        environment: { surfaceID in
                            WorkspaceActions.environment(for: plan, surfaceID: surfaceID)
                        }
                    )
                }

                let answer = startsAgent
                    ? "Started an agent in a new tab, surface \(surfaceID.uuidString). "
                    + "It is not addressable yet: poll list_tabs until that surface reports a peer id, then send_message to it."
                    : "Opened a terminal tab, surface \(surfaceID.uuidString)."
                return .success(id: request.id, .text(answer))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// The command a spawned tab runs, or nil for a plain shell.
        ///
        /// **The session id is the surface's, never the workstream's.** The
        /// workstream id is the Coding Agent tab's own Claude session; a second
        /// agent handed it would fight that tab over one transcript. The surface
        /// id is unique per tab by construction, so it is the right session
        /// identity — which is also why this is built per surface rather than once.
        ///
        /// The MCP config is the workstream's, shared deliberately: it names the
        /// helper binary and carries no identity, and the agent's identity comes
        /// from `ATELIER_SURFACE_ID` in its environment.
        private nonisolated func agentCommand(
            plan: WorkspaceActions.AgentTabPlan,
            prompt: String?,
            surfaceID: UUID
        ) -> String? {
            guard let prompt, !prompt.isEmpty, let claudePath = plan.claudePath else { return nil }
            let mcpConfigPath = IPC.AgentSettings.isEnabled ? IPC.Config.write(for: plan.workstreamID) : nil
            let systemPrompt = Workstream.AgentCommand.systemPrompt(
                allowOutsideWorktree: UserDefaults.standard.bool(forKey: "atelier.allowOutsideWorktree"),
                autoRenameBranch: UserDefaults.standard.bool(forKey: "atelier.autoRenameBranch"),
                worktreePath: plan.workingDirectory,
                workstreamName: plan.workstreamName,
                mcpConfigWritten: mcpConfigPath != nil
            )
            // Resolved against the worktree, so a project that configures its
            // own status line in `.claude/settings.json` is honoured the same
            // way the Coding Agent tab honours it.
            let settingsPath = StatusLine.Config.write(
                for: plan.workstreamID,
                cwd: plan.workingDirectory
            )
            return Workstream.AgentCommand.fresh(
                claudePath: claudePath,
                // The surface's id, never the workstream's: see this method's
                // doc comment.
                sessionID: surfaceID.uuidString.lowercased(),
                sessionName: nil,
                bypassPermissions: plan.bypassPermissions,
                systemPrompt: systemPrompt,
                mcpConfigPath: mcpConfigPath,
                settingsPath: settingsPath,
                initialPrompt: prompt
            )
        }

        /// Carries the agent-start result out of the launcher's `beforeReady`
        /// closure, which runs in a different isolation domain from the actor
        /// that needs the answer.
        ///
        /// `@unchecked Sendable` and unsynchronised because the access pattern
        /// makes it safe rather than because the checker was in the way: both
        /// fields are written inside one `MainActor.run`, and both are read only
        /// after `launch` has returned, which happens-after that write. Nothing
        /// else holds a reference.
        private final class AgentStartOutcome: @unchecked Sendable {
            var started = false
            var failure: String?
        }

        /// What starting a Coding Agent needs from the live app, gathered in one
        /// hop onto the main actor.
        ///
        /// Read *before* the worktree exists, so every reason an agent cannot
        /// start is a refusal the caller gets instead of a workstream. The
        /// `claude` lookup was already a pre-flight for that reason; the surface
        /// handle is here for the same one — without it the tool would report an
        /// agent started with nothing running it.
        private struct AgentLaunchInputs {
            let claudePath: String?
            let supportsSessionName: Bool
            /// Nil when tmux mode is off *and* when tmux is not installed. Those
            /// are one answer here — do not wrap — which is why the setting is
            /// resolved on this side rather than passed on.
            let tmuxPath: String?
            let canCreateSurfaces: Bool

            @MainActor
            static func read() -> AgentLaunchInputs {
                let environment = WorkspaceActions.shared.appEnvironment
                let tmuxMode = UserDefaults.standard.bool(forKey: "atelier.tmuxMode")
                return AgentLaunchInputs(
                    claudePath: environment?.toolStatus.claude.path,
                    supportsSessionName: environment?.toolStatus.claudeSupportsSessionName ?? false,
                    tmuxPath: tmuxMode ? environment?.toolStatus.tmux.path : nil,
                    canCreateSurfaces: WorkspaceActions.shared.canCreateSurfaces
                )
            }

            /// Why an agent cannot be started, or nil when one can. Both cases
            /// name `prompt` as the way to proceed anyway, because a workstream
            /// without an agent is still worth having.
            var refusal: String? {
                if claudePath == nil {
                    return "Cannot start an agent: Atelier could not find the `claude` binary. "
                        + "Omit `prompt` to create the workstream without one."
                }
                if !canCreateSurfaces {
                    return "Cannot start an agent: Atelier's terminal is not ready yet. "
                        + "Omit `prompt` to create the workstream without one, or try again in a moment."
                }
                return nil
            }
        }

        /// The environment the new workstream's Coding Agent runs in.
        ///
        /// `ProcessCompose.PhaseEnvironment.variables` is the assembler for a
        /// caller with no `ProcessCompose.PortPlan` to hand over — it resolves
        /// `ports.yaml` itself — which is exactly this caller.
        ///
        /// Deliberately **not** `WorkspaceActions.environment(for:surfaceID:)`,
        /// which blanks `TMUX`/`TMUX_PANE`. That is right for a terminal tab and
        /// wrong here: the Coding Agent is the surface tmux mode wraps, and the
        /// view's own `envVars` leaves those inherited. `ensureSurface` does not
        /// compare environments, so a divergence here would never be corrected —
        /// it would just be wrong for the life of the surface.
        private nonisolated func codingAgentEnvironment(
            target: Workstream.Launcher.Target,
            launched: Workstream.Launcher.Launched
        ) -> [String: String] {
            var vars = ProcessCompose.PhaseEnvironment.variables(
                workstreamID: launched.workstreamID,
                projectName: target.projectName,
                workstreamName: launched.name,
                projectDirectory: target.directory,
                worktreePath: launched.worktreePath,
                defaultBranch: Git.Operations.defaultBranch(at: target.directory)
            )
            // The Coding Agent's surface id is the workstream id, so it
            // addresses itself the way every other surface does.
            vars["ATELIER_SURFACE_ID"] = launched.workstreamID.uuidString
            return vars
        }

        /// The command the new workstream's Coding Agent runs.
        ///
        /// **The session id is the workstream's**, which is the opposite of
        /// `agentCommand`'s rule and for the same underlying reason: this *is*
        /// the Coding Agent, and `TerminalContainerView` will later resume that
        /// session on this same surface. `open_agent_tab` must take the surface's
        /// id instead precisely so a second agent does not end up here.
        ///
        /// Fresh rather than the view's resume-then-fresh pair: this workstream
        /// was created moments ago and has no session to resume. The pair is
        /// about recovering the session across a relaunch, a question that only
        /// arises after this one has run.
        private nonisolated func codingAgentCommand(
            target: Workstream.Launcher.Target,
            launched: Workstream.Launcher.Launched,
            prompt: String,
            claudePath: String,
            bypassPermissions: Bool,
            inputs: AgentLaunchInputs,
            environment: [String: String]
        ) -> String {
            let mcpConfigPath = IPC.AgentSettings.isEnabled
                ? IPC.Config.write(for: launched.workstreamID)
                : nil
            let systemPrompt = Workstream.AgentCommand.systemPrompt(
                allowOutsideWorktree: UserDefaults.standard.bool(forKey: "atelier.allowOutsideWorktree"),
                autoRenameBranch: UserDefaults.standard.bool(forKey: "atelier.autoRenameBranch"),
                worktreePath: launched.worktreePath,
                workstreamName: launched.name,
                mcpConfigWritten: mcpConfigPath != nil
            )
            let settingsPath = StatusLine.Config.write(
                for: launched.workstreamID,
                cwd: launched.worktreePath
            )
            let fresh = Workstream.AgentCommand.fresh(
                claudePath: claudePath,
                sessionID: launched.workstreamID.uuidString.lowercased(),
                sessionName: inputs.supportsSessionName ? launched.name : nil,
                bypassPermissions: bypassPermissions,
                systemPrompt: systemPrompt,
                mcpConfigPath: mcpConfigPath,
                settingsPath: settingsPath,
                initialPrompt: prompt
            )
            let command = Workstream.AgentCommand.tmuxWrapped(
                fresh,
                tmuxPath: inputs.tmuxPath,
                projectName: target.projectName,
                workstreamName: launched.name,
                environmentVars: environment
            )

            // The launch log is how an agent that starts and does nothing gets
            // diagnosed, and the Info tab reads it. This path would otherwise be
            // the one agent start that left no entry.
            LaunchLogger.log(LaunchLogEntry(
                workstreamID: launched.workstreamID,
                event: "agent-start",
                finalCommand: command,
                intermediateCommands: command == fresh ? [fresh] : [fresh, command],
                environmentVariables: environment,
                workingDirectory: launched.worktreePath,
                toolPaths: LaunchLogEntry.ToolPaths(
                    claude: claudePath,
                    tmux: inputs.tmuxPath,
                    ffRun: RunLauncher.executableURL()?.path
                ),
                settings: LaunchLogEntry.Settings(
                    tmuxMode: UserDefaults.standard.bool(forKey: "atelier.tmuxMode"),
                    bypassPermissions: bypassPermissions,
                    autoRenameBranch: UserDefaults.standard.bool(forKey: "atelier.autoRenameBranch"),
                    allowOutsideWorktree: UserDefaults.standard.bool(forKey: "atelier.allowOutsideWorktree")
                ),
                shell: CommandBuilder.userShell
            ))

            return command
        }

        /// Creates a new workstream — worktree, branch, initialization — in the
        /// caller's project, and optionally starts an agent in it.
        ///
        /// **Initialization is inherited, not reimplemented.** The work happens
        /// by posting `.workstreamWorktreeReady`, which `ContentView` answers by
        /// calling `Initialization.Runner.run` — and that one path is also what
        /// gets path persistence, the HeadWatcher, the agent-state lookup and the
        /// Shortcut story id, none of which a second creation path would
        /// remember. So this handler must never call `Initialization.Runner.run`
        /// itself.
        ///
        /// **The agent goes in the workstream's Coding Agent tab**, on the
        /// surface whose id *is* the workstream id — so the user opening the
        /// workstream lands on the conversation rather than on an empty agent
        /// beside a terminal tab holding the real one.
        ///
        /// That surface has to exist before `TerminalContainerView` ever renders
        /// this workstream, because nobody is looking at it. The hazard is what
        /// happens when they finally do: `preloadSurfaces` calls `ensureSurface`
        /// with the command `buildClaudeCommand` builds, which carries no initial
        /// prompt, and `ensureSurface` destroys a surface whose stored command
        /// differs. `TerminalSurfaceCache.seedSurface` is what makes that safe —
        /// the view *adopts* the seeded surface once instead of reconciling it.
        /// The invariant lives there, at the consumer, rather than in an
        /// obligation on this handler to produce a byte-identical command.
        private func createWorkstream(for request: Request) async -> Response {
            let arguments = ToolArguments(request)
            let name = arguments.optionalTrimmed("name")
            let prompt = arguments.optionalTrimmed("prompt")
            let callerWorkstreamID = callerWorkstreamID(request)

            let bypass: Bool
            do {
                bypass = try arguments.boolean("bypass_permissions")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }

            do {
                let target = try await MainActor.run {
                    try Workstream.Launcher.shared.target(
                        callerWorkstreamID: callerWorkstreamID,
                        projectDirectory: request.client.projectDirectory
                    )
                }

                // Checked before anything is created. The worktree is a
                // directory on disk and a branch in the repository; refusing
                // after it exists would leave the caller a workstream it was
                // told it did not get.
                let inputs = await MainActor.run { AgentLaunchInputs.read() }
                if prompt?.isEmpty == false, let refusal = inputs.refusal {
                    return .failure(id: request.id, refusal)
                }

                // The agent starts inside `beforeReady`, which the launcher runs
                // after the worktree exists and *before* it posts
                // `.workstreamWorktreeReady`. That notification is what makes the
                // workstream renderable, and the first render creates the Coding
                // Agent's surface with the command the view builds — so seeding
                // after it would be a race against a user clicking the sidebar
                // row that has been sitting there since `.workstreamCreated`, and
                // losing that race would drop the prompt in silence.
                //
                // The outcome comes back in a box because this actor cannot
                // mutate a local from a closure the launcher runs. It is written
                // on the main actor and read only after `launch` has returned.
                let outcome = AgentStartOutcome()
                let launched = try await Workstream.Launcher.shared.launch(
                    in: target,
                    requestedName: name,
                    bypassPermissions: bypass,
                    beforeReady: { launched in
                        guard let prompt, !prompt.isEmpty, let claudePath = inputs.claudePath else { return }
                        // Built from what the launcher hands over rather than by
                        // reading the workstream back out of `ProjectList`: the
                        // append happened on `.workstreamCreated`, but the
                        // notification that sets `worktreePath` has not been
                        // posted yet — that is the point of running here.
                        let environment = self.codingAgentEnvironment(target: target, launched: launched)
                        let command = self.codingAgentCommand(
                            target: target,
                            launched: launched,
                            prompt: prompt,
                            claudePath: claudePath,
                            bypassPermissions: bypass,
                            inputs: inputs,
                            environment: environment
                        )
                        await MainActor.run {
                            do {
                                try WorkspaceActions.shared.seedCodingAgent(
                                    workstreamID: launched.workstreamID,
                                    workingDirectory: launched.worktreePath,
                                    command: command,
                                    environment: environment
                                )
                                outcome.started = true
                            } catch {
                                outcome.failure = error.localizedDescription
                            }
                        }
                    }
                )

                guard prompt?.isEmpty == false else {
                    return .success(id: request.id, .text(
                        "Created workstream \(launched.name) at \(launched.worktreePath). "
                            + "Its initialization is running in the background. No agent was started — pass `prompt` to start one."
                    ))
                }

                // The worktree exists whatever became of the agent, so this is a
                // success carrying bad news rather than a failure — reporting it
                // as an error would tell the caller nothing was created.
                guard outcome.started else {
                    return .success(id: request.id, .text(
                        "Created workstream \(launched.name) at \(launched.worktreePath), but no agent was started. "
                            + (outcome.failure ?? "Atelier gave no reason.")
                    ))
                }

                return .success(id: request.id, .text(
                    "Created workstream \(launched.name) at \(launched.worktreePath) and started an agent in its "
                        + "Coding Agent tab, surface \(launched.workstreamID.uuidString). Its initialization may still be "
                        + "running, so the worktree's dependencies may not be installed yet. The agent is not "
                        + "addressable until it registers: poll list_peers until a peer reports that surface id, then "
                        + "send_message to it."
                ))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func requestAttention(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            // Sanitized *before* the emptiness check, not after: a reason of
            // nothing but control characters is as absent as no reason at all,
            // and this string is rendered into a notification.
            let reason = Names.sanitized(ToolArguments(request).optional("reason") ?? "", limit: 400, fallback: "")
            guard !reason.isEmpty else {
                return .failure(id: request.id, ToolError.missingArgument("reason").localizedDescription)
            }
            let name = request.client.workstreamName ?? "Atelier"
            let outcome = await MainActor.run {
                Workstream.AttentionNotifier.shared.notify(
                    workstreamID: workstreamID,
                    workstreamName: name,
                    reason: reason
                )
            }
            switch outcome {
            case .success:
                return .success(id: request.id, .text("Notified the user. They may not respond immediately — carry on with anything you can do without them."))
            case let .failure(refusal):
                return .failure(id: request.id, refusal.localizedDescription)
            }
        }

        // MARK: - Execution

        /// Default and ceiling for a log tail.
        ///
        /// The ceiling is not tuning: one unbounded line is enough to reach
        /// `IPC.Server.maxFrameBytes`, and `ExecutionLogs.trimmed`'s byte budget
        /// is the second bound. Clamped rather than refused — a caller asking for
        /// more lines than exist is not making a mistake, and the cap is
        /// Atelier's bound rather than the project's.
        private static let defaultLogTail = 100
        private static let maxLogTail = 1000

        private func listProcesses(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let controller = execution else {
                return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
            }
            do {
                return try await .success(id: request.id, .execution(controller.executionState(in: workstreamID)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func readProcessLogs(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let controller = execution else {
                return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
            }
            let arguments = ToolArguments(request)
            do {
                let name = try arguments.nonEmpty("process")
                let asked = try arguments.integer("tail") ?? Self.defaultLogTail
                let tail = min(max(asked, 1), Self.maxLogTail)
                return try await .success(
                    id: request.id,
                    .executionLogs(controller.processLogs(in: workstreamID, name: name, tail: tail))
                )
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func controlProcess(for request: Request, action: ProcessAction) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let controller = execution else {
                return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
            }
            do {
                let name = try ToolArguments(request).nonEmpty("process")
                try await controller.controlProcess(in: workstreamID, name: name, action: action)
                return .success(id: request.id, .text("\(action.rawValue) \(name): done."))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func startExecution(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let controller = execution else {
                return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
            }
            let processes = ToolArguments(request).list("processes")
            do {
                let start = try await controller.startExecution(in: workstreamID, processes: processes)
                return .success(id: request.id, .text(Self.startAnswer(for: start)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// The answer a start gets.
        ///
        /// It says "poll" in as many words, because there are no completion
        /// notices on this surface and an agent that waits for one waits for the
        /// rest of the session. It also says the tab was opened but not selected,
        /// the same thing `open_tab`'s answer says and for the same reason: an
        /// agent that reads "opened" as "they are looking at it" waits for a
        /// reaction nobody had.
        nonisolated static func startAnswer(for start: ExecutionStart) -> String {
            let scope = start.started.isEmpty
                ? "the processes the user's checklist selects"
                : start.started.joined(separator: ", ")
            let reclaim = start.isReclaimingSocket
                ? " Atelier is reclaiming the previous run's control socket first, so it comes up a moment late."
                : ""
            return "Starting \(scope).\(reclaim) This does not wait: poll list_processes to watch it come up, "
                + "and read_process_logs when something fails. Nothing will notify you. "
                + "The Execution tab is open but the user's view has not been switched to it — "
                + "use request_attention if you need their eyes."
        }

        private func stopExecution(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let controller = execution else {
                return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
            }
            do {
                let wasRunning = try await controller.stopExecution(in: workstreamID)
                return .success(
                    id: request.id,
                    .text(wasRunning ? "Stopped this workstream's dev stack." : "Nothing was running.")
                )
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        // MARK: - Verification

        /// Answers what the project declares in `verification.yaml`, running
        /// nothing.
        ///
        /// **This is the only way an agent can learn a check's name.** The file
        /// lives in the project directory, outside every work tree, and the
        /// "Restrict to worktree" system prompt is on by default — so before this
        /// existed a name could only be found by guessing one and reading
        /// `start_verification`'s refusal.
        private func listVerificationChecks(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let runner = verification else {
                return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
            }
            do {
                return try await .success(id: request.id, .verificationChecks(runner.verificationChecks(in: workstreamID)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        // MARK: - Whiteboard

        /// The caller's own board, as text plus a path to its picture.
        ///
        /// **Nothing here can fail with an error, and that is the point.** Every
        /// state a board can be in — never drawn on, drawn on and rendered,
        /// drawn on with a render that is behind, a scene file that will not
        /// parse — is a sentence rather than a refusal. An empty board is the
        /// first state every workstream is in, and answering it with an error
        /// would send an agent looking for a fault that is not there; the one
        /// state that *is* a fault says so in different words, the distinction
        /// `Verification.Config.Load` draws and for the same reason.
        ///
        /// Generated fresh rather than read back from `board.md`: the age and
        /// the staleness verdict are both answers to "right now", and a file
        /// cannot hold either.
        ///
        /// **No main-actor hop and no webview.** `Whiteboard.Store` is plain
        /// file IO, so a board whose tab has never been opened in this launch
        /// still reads, from whatever the last one saved.
        private func readWhiteboard(for request: Request) -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            return .success(
                id: request.id,
                .text(Whiteboard.Store.digestText(for: workstreamID, now: Date()))
            )
        }

        /// The sentence every write ends with.
        ///
        /// An agent that reads "opened" as "they are looking at it" waits for a
        /// reaction nobody had — the same thing `open_tab` says, for the same
        /// reason, and the reason `request_attention` is named in it.
        private static let whiteboardTabNote =
            " The Whiteboard tab is open, but this did not take the selection, so the user is "
                + "still looking at whatever they had in front of them — use request_attention if "
                + "you need them to come and look."

        private func whiteboardAdd(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            let elements: String
            do {
                elements = try ToolArguments(request).required("elements")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
            do {
                let result = try await WorkspaceActions.shared.whiteboardAdd(
                    workstreamID: workstreamID,
                    elementsJSON: elements
                )
                let count = result.ids.count
                return .success(id: request.id, .text(
                    "Added \(count) element\(count == 1 ? "" : "s"): "
                        + result.ids.joined(separator: ", ") + "."
                        + Self.whiteboardTabNote
                ))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func whiteboardUpdate(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            let arguments = ToolArguments(request)
            let id: String
            do {
                id = try arguments.required("id")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
            do {
                let result = try await WorkspaceActions.shared.whiteboardUpdate(
                    workstreamID: workstreamID,
                    id: id,
                    at: arguments.optional("at"),
                    // `raw`, not `optional`: an empty string is how a label is
                    // cleared, and `optional` reads empty as absent.
                    text: arguments.raw["text"],
                    color: arguments.optional("color")
                )
                return .success(
                    id: request.id,
                    .text("Updated \(result.id)." + Self.whiteboardTabNote)
                )
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func whiteboardDelete(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            let ids = ToolArguments(request).list("ids")
            do {
                let result = try await WorkspaceActions.shared.whiteboardDelete(
                    workstreamID: workstreamID,
                    ids: ids
                )
                // What was really there. An id already gone is success and is
                // simply not listed, which is what makes this replayable.
                let count = result.removed.count
                let what = result.removed.isEmpty
                    ? "Nothing to remove — none of those ids are on the board."
                    : "Removed \(count) element\(count == 1 ? "" : "s"): "
                    + result.removed.joined(separator: ", ") + "."
                return .success(id: request.id, .text(what + Self.whiteboardTabNote))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// Starts a verification run in the caller's own workstream and answers
        /// with its run id.
        ///
        /// **The answer is the id, not the result.** A real suite runs for
        /// minutes and an MCP tool call does not, so the result arrives two other
        /// ways: a notice posted into this agent's inbox as each check finishes
        /// (`postCheckNotice`, fired from `observeVerificationChecks`), and
        /// `check_verification` for an agent that never reads its inbox. A run
        /// that finishes having completed nothing gets one notice instead, since
        /// there is no per-check completion to have announced it.
        ///
        /// Nothing here decides whether the run is *allowed*. The preconditions
        /// are `Verification.Config.Load`'s own three cases — no file, a file that
        /// will not parse, a file declaring nothing — and `Verification.Runner.start`
        /// asks them behind the seam, deliberately the only copy. There is no
        /// approval gate to re-check: `verification.yaml` lives in the project
        /// directory, outside every work tree, so it cannot have arrived with the
        /// repository. A refusal arrives as the runner's error and is passed through
        /// verbatim.
        private func startVerification(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let runner = verification else {
                return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
            }

            let checks = ToolArguments(request).list("checks")
            // The caller is addressed by surface, never by workstream: two agents
            // in one worktree report the same workstream name, and a notice
            // addressed by workstream would land in the wrong pane's inbox half
            // the time.
            //
            // Parsed once and threaded through as its own string, rather than handing the
            // runner `request.client.surfaceID` raw: a non-UUID surface id would otherwise
            // be routed on the parsed (nil-safe) value here while the runner stored the raw
            // string as `requesterSurfaceID`, so the two disagreed about whether a requester
            // was known at all.
            let surfaceID = request.client.surfaceID.flatMap(UUID.init(uuidString:))

            let delivery = UUID()
            let target = surfaceID ?? workstreamID
            let onFinish: @Sendable (VerificationRunInfo) -> Void = { [weak self] info in
                // **Only for a run that completed nothing.** Every check that reaches a
                // terminal state posts its own notice, so a normal run's result has already
                // arrived check by check and a summary on top would be a second telling.
                //
                // A run that completed nothing is the case that would otherwise be silent,
                // and it must never read as a pass: `up -n` on an empty namespace never
                // exits so `PhaseExecutor` returns `.skipped` without spawning; an
                // undecodable config declares no processes at all; and a spawn that dies
                // before binding leaves every row `.notRun`. In all three, "0 of 0 failed"
                // is both true and a green suite.
                //
                // **A stopped run is excluded**, and it is not the same case. Stopping
                // before any check started also seals every row `.notRun`, but the user
                // caused that deliberately and knows it happened — the notice exists to
                // break a silence, not to report an action back to the person who took it.
                guard info.state != .stopped,
                      info.checks.allSatisfy({ $0.state == .notRun })
                else { return }
                Task { await self?.postVerificationNotice(info, to: target, delivery: delivery) }
            }

            do {
                let start = try await runner.startVerification(
                    workstreamID: workstreamID,
                    checks: checks,
                    requesterSurfaceID: surfaceID?.uuidString,
                    onFinish: onFinish
                )
                return .success(id: request.id, .text(startAnswer(for: start, deliverable: surfaceID != nil)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// What an agent is told when a run starts. Says where the results will appear,
        /// because the one thing it must not do is wait here.
        ///
        /// **`deliverable` distinguishes whose inbox, not whether anything is posted.**
        /// `onFinish` and `postCheckNotice` both fall back to the workstream's Coding Agent
        /// surface when the caller's own surface id is unknown, so a notice always has a
        /// target — but for a caller Atelier did not launch, that target is not this
        /// caller's own pane. Telling such a caller to check its inbox would be a claim
        /// about a pane it may not be sitting in, so the honest answer names the fallback
        /// instead and points at `check_verification`.
        private nonisolated func startAnswer(for start: VerificationStart, deliverable: Bool) -> String {
            // `started` is the *resolved* list and is never empty — an agent that
            // omitted `checks` still needs to see what it set running, and a start
            // that would resolve to nothing is refused rather than minted. That
            // still holds now a start is partial: a call with every name already
            // running throws `alreadyRunning` and never reaches this.
            let names = start.started.joined(separator: ", ")
            let delivery = deliverable
                ? "Each check posts its own verdict to your inbox from \(VerificationSummary.sender) as it finishes — "
                + "receive_messages to read them, and remember delivery is a pull, so check at your next natural boundary."
                : "Nothing will be posted to your inbox: Atelier does not know which terminal you are running in. "
                + "check_verification is how you read this run."
            // **Said, not implied.** A refused check's verdict is posted under the
            // run that started it, so it will never arrive under this run id and
            // `check_verification` on this run will never list it. An agent told
            // only "refused: rspec" would sit waiting for a notice that cannot
            // come — the same silence the run-level notice exists to break.
            let refusals = start.refused.isEmpty
                ? ""
                : " Already running, so not part of this run: \(start.refused.joined(separator: ", ")). "
                + "Those belong to the run that started them: their verdicts arrive under that run id, "
                + "not this one, and check_verification on this run will not list them."
            return "Started verification run \(start.runID): \(names). It runs in the background — do not wait on it."
                + refusals
                + " " + delivery
                + " check_verification(run_id: \"\(start.runID)\") reads the whole run at any point, "
                + "including while it is still running."
        }

        /// Reads one run, scoped to the caller's own workstream.
        ///
        /// Not a security boundary — every process in this feature runs as the
        /// user, and `agent-ipc.md` says as much about the IPC token itself. The
        /// scope check is there because a run id is the tool's only argument and
        /// ids are short: an agent holding a stale or mistyped one should be told
        /// it is not its run rather than handed somebody else's results. Which is
        /// also what every other tool in this group does.
        private func checkVerification(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let runner = verification else {
                return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
            }
            let runID: String
            do {
                runID = try ToolArguments(request).required("run_id")
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
            guard let info = await runner.verificationRun(id: runID, in: workstreamID) else {
                return .failure(id: request.id, VerificationFailure.unknownRun(runID).localizedDescription)
            }
            guard info.workstreamID.caseInsensitiveCompare(workstreamID.uuidString) == .orderedSame else {
                return .failure(id: request.id, VerificationFailure.runBelongsElsewhere.localizedDescription)
            }
            return .success(id: request.id, .verificationRun(info))
        }

        /// Posts a finished run's summary into the inbox of whatever agent now
        /// occupies `surfaceID`.
        ///
        /// **Called only for a run that completed nothing**, per `startVerification`'s
        /// `onFinish` guard. Every check that reaches a terminal state posts its own notice
        /// through `postCheckNotice`, so a run that reported on at least one check has
        /// already told the agent everything this would say a second time; the run-level
        /// notice survives only for the case that has no per-check notices to be silent
        /// through — nothing ran, so nothing completed.
        ///
        /// **Resolved at delivery time, not when the run started.** A helper that
        /// reconnects normally keeps its peer id, but one whose old socket has not
        /// closed yet is told the id belongs to another session and re-registers
        /// under a new one — so a peer id captured ten minutes ago can be dead
        /// while the pane it belonged to has an agent sitting in it. The surface
        /// is the stable address; the peer is looked up through it.
        private func postVerificationNotice(_ info: VerificationRunInfo, to surfaceID: UUID, delivery: UUID) async {
            guard deliveredNotices.insert(delivery).inserted else { return }
            guard let peerID = await peersBySurface()[surfaceID].flatMap({ UUID(uuidString: $0.id) }) else { return }

            do {
                // Nil means the agent has gone. Ordinary, and not worth
                // reporting anywhere: the run's results stay readable through
                // check_verification, and there is nobody left to tell.
                guard try await store.deliverSystemMessage(
                    from: VerificationSummary.sender,
                    to: peerID,
                    content: VerificationSummary.message(for: info)
                ) != nil else { return }
            } catch {
                // The only throw is the store's content cap, and
                // `VerificationSummary.message` is bounded an order of magnitude
                // below it. Reaching here means that bound was broken, which is a
                // bug in the formatter rather than something an agent can act on.
                return
            }

            await nudge([peerID], senderName: VerificationSummary.sender)
        }

        /// Posts one check's completion into the inbox of whatever agent now occupies the
        /// addressed surface.
        ///
        /// **The address falls back to the workstream's Coding Agent tab**, whose surface
        /// id *is* the workstream id. That fallback is what makes a run the *user* pressed
        /// reach the agent — previously such a run finished silently, because only a run an
        /// agent had started carried a surface to deliver to. A run an agent did start is
        /// still addressed to the pane that asked, since two agents in one worktree report
        /// the same workstream name and the surface is the only discriminator.
        ///
        /// Resolved at delivery time, never when the run started: a helper whose old socket
        /// has not closed is told its id belongs to another session and re-registers under
        /// a new one, so an id captured minutes ago can be dead while its pane has an agent
        /// sitting in it.
        private func postCheckNotice(_ notice: VerificationCheckNotice) async {
            let surfaceID = notice.requesterSurfaceID.flatMap(UUID.init(uuidString:))
                ?? UUID(uuidString: notice.workstreamID)
            guard let surfaceID,
                  let peerID = await peersBySurface()[surfaceID].flatMap({ UUID(uuidString: $0.id) })
            else { return }

            do {
                // Nil means the agent has gone. Ordinary, and not worth reporting anywhere:
                // the results stay readable through check_verification, and there is nobody
                // left to tell.
                guard try await store.deliverSystemMessage(
                    from: VerificationSummary.sender,
                    to: peerID,
                    content: VerificationSummary.checkMessage(for: notice)
                ) != nil else { return }
            } catch {
                // The only throw is the store's content cap, and `checkMessage` is bounded
                // an order of magnitude below it. Reaching here is a bug in the formatter.
                return
            }

            await nudge([peerID], senderName: VerificationSummary.sender)
        }

        /// Installs the per-check observer. Called exactly once, beside the one bridge.
        func observeVerificationChecks() async {
            await verification?.observeCheckCompletions { [weak self] notice in
                Task { await self?.postCheckNotice(notice) }
            }
        }

        // MARK: - Task queue

        /// Every task-queue tool starts here — scoped to the project, not the
        /// workstream, the same scope peers and messages already have.
        private func projectDirectory(_ request: Request) throws -> String {
            guard let project = request.client.projectDirectory, !project.isEmpty else {
                throw TaskQueueFailure.noProject
            }
            return project
        }

        /// `claim_task`/`complete_task`/`fail_task` key ownership on the
        /// caller's surface id — see `IPC.TaskStore`'s doc comment for why —
        /// and on its workstream id, so a torn-down workstream's claims can be
        /// found and reverted without resolving individual surfaces back to
        /// it. Both are set together by every Atelier-launched terminal, so
        /// one guard covers both.
        private func surfaceAndWorkstream(_ request: Request) throws -> (surfaceID: String, workstreamID: String) {
            guard let surfaceID = request.client.surfaceID, let workstreamID = request.client.workstreamID else {
                throw TaskQueueFailure.noSurface
            }
            return (surfaceID, workstreamID)
        }

        private func addTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let arguments = ToolArguments(request)
                let path = try arguments.requiredTrimmed("path")
                let name = try arguments.requiredTrimmed("name")
                let content = try arguments.required("content")
                let tags = arguments.list("tags")
                let task = try await tasks.add(
                    projectDirectory: project, path: path, name: name, content: content,
                    tags: tags, createdBySurfaceID: request.client.surfaceID
                )
                return await .success(id: request.id, .task(info(for: task)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func getPendingTasks(for request: Request) async -> Response {
            await listing(for: request) { [tasks] project, prefix, tagList in
                await tasks.pending(projectDirectory: project, pathPrefix: prefix, tags: tagList)
            }
        }

        private func listTasks(for request: Request) async -> Response {
            await listing(for: request) { [tasks] project, prefix, tagList in
                await tasks.all(projectDirectory: project, pathPrefix: prefix, tags: tagList)
            }
        }

        private func listing(
            for request: Request,
            fetch: (String, String?, [String]) async -> [ProjectTask]
        ) async -> Response {
            do {
                let project = try projectDirectory(request)
                let arguments = ToolArguments(request)
                let prefix = arguments.optional("path_prefix")
                let tagList = arguments.list("tags")
                let found = await fetch(project, prefix, tagList)
                var infos: [TaskInfo] = []
                for task in found {
                    await infos.append(info(for: task))
                }
                return .success(id: request.id, .tasks(infos))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func claimTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let (surfaceID, workstreamID) = try surfaceAndWorkstream(request)
                let path = try ToolArguments(request).required("path")
                let task = try await tasks.claim(projectDirectory: project, path: path, surfaceID: surfaceID, workstreamID: workstreamID)
                return await .success(id: request.id, .task(info(for: task)))
            } catch let failure as TaskQueueFailure {
                return await .failure(id: request.id, message(for: failure))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func completeTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let (surfaceID, _) = try surfaceAndWorkstream(request)
                let path = try ToolArguments(request).required("path")
                let (task, transitioned) = try await tasks.complete(projectDirectory: project, path: path, surfaceID: surfaceID)
                if transitioned {
                    await notifyCreator(of: task)
                }
                return await .success(id: request.id, .task(info(for: task)))
            } catch let failure as TaskQueueFailure {
                return await .failure(id: request.id, message(for: failure))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func failTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let (surfaceID, _) = try surfaceAndWorkstream(request)
                let arguments = ToolArguments(request)
                let path = try arguments.required("path")
                let reason = try arguments.requiredTrimmed("reason")
                let (task, transitioned) = try await tasks.fail(projectDirectory: project, path: path, surfaceID: surfaceID, reason: reason)
                if transitioned {
                    await notifyCreator(of: task)
                }
                return await .success(id: request.id, .task(info(for: task)))
            } catch let failure as TaskQueueFailure {
                return await .failure(id: request.id, message(for: failure))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// Enriches `wrongClaimer` with the current claimant's display name,
        /// resolved live via `peersBySurface()` — the same "resolved at
        /// delivery time, not creation time" rule the verification notices
        /// already follow. Every other failure's stored description is
        /// already complete.
        private func message(for failure: TaskQueueFailure) async -> String {
            guard case let .wrongClaimer(surfaceIDString) = failure else {
                return failure.errorDescription ?? "Task queue error."
            }
            guard let surfaceIDString, let surfaceID = UUID(uuidString: surfaceIDString),
                  let peer = await peersBySurface()[surfaceID]
            else {
                return failure.errorDescription ?? "That task is not claimed by you."
            }
            return "That task is claimed by \(peer.name), not you."
        }

        /// Projects an app-side `ProjectTask` into the wire `TaskInfo`,
        /// resolving display names live — never storing them — the same
        /// pattern `MessageInfo.fromName` and the verification notices use.
        private func info(for task: ProjectTask) async -> TaskInfo {
            let peers = await peersBySurface()
            func resolved(_ surfaceID: String?) -> (id: String?, name: String?) {
                guard let surfaceID, let uuid = UUID(uuidString: surfaceID), let peer = peers[uuid] else { return (nil, nil) }
                return (peer.id, peer.name)
            }
            let now = Date()
            let created = resolved(task.createdBySurfaceID)

            let wireState: TaskWireState
            var claimedBy: String?
            var claimedByName: String?
            var claimedSecondsAgo: Int?
            var failureReason: String?

            switch task.state {
            case .pending:
                wireState = .pending
            case let .claimed(surfaceID, _, at):
                wireState = .claimed
                let claimant = resolved(surfaceID)
                claimedBy = claimant.id
                claimedByName = claimant.name
                claimedSecondsAgo = Int(now.timeIntervalSince(at))
            case let .completed(surfaceID, at):
                wireState = .completed
                let claimant = resolved(surfaceID)
                claimedBy = claimant.id
                claimedByName = claimant.name
                claimedSecondsAgo = Int(now.timeIntervalSince(at))
            case let .failed(surfaceID, at, reason):
                wireState = .failed
                let claimant = resolved(surfaceID)
                claimedBy = claimant.id
                claimedByName = claimant.name
                claimedSecondsAgo = Int(now.timeIntervalSince(at))
                failureReason = reason
            }

            return TaskInfo(
                path: task.path, name: task.name, content: task.content, tags: task.tags,
                state: wireState, createdSecondsAgo: Int(now.timeIntervalSince(task.createdAt)),
                createdBy: created.id, createdByName: created.name,
                claimedBy: claimedBy, claimedByName: claimedByName, claimedSecondsAgo: claimedSecondsAgo,
                failureReason: failureReason
            )
        }

        /// Posts a notice to a completed/failed task's creator, resolved from
        /// `createdBySurfaceID` **at delivery time** — the same rule
        /// `postVerificationNotice` states, and for the identical reason: the
        /// surface's current occupant can be a different peer than the one
        /// that created the task.
        ///
        /// Best-effort, like the verification notices: no surface recorded,
        /// or no peer currently resolvable there, is an ordinary silent
        /// no-op — the task's result stays readable through
        /// `list_tasks`/`get_pending_tasks` either way.
        private func notifyCreator(of task: ProjectTask) async {
            guard let surfaceIDString = task.createdBySurfaceID, let surfaceID = UUID(uuidString: surfaceIDString) else { return }
            guard let peerID = await peersBySurface()[surfaceID].flatMap({ UUID(uuidString: $0.id) }) else { return }

            let content = TaskSummary.notice(for: task)
            do {
                guard try await store.deliverSystemMessage(from: TaskSummary.sender, to: peerID, content: content) != nil else { return }
            } catch {
                return
            }
            await nudge([peerID], senderName: TaskSummary.sender)
        }

        /// Reverts every task claimed by a surface in `workstreamID` back to
        /// pending. Called from `Workstream.Archiver.remove`/`.purge` when
        /// that workstream's surfaces are torn down for good — never from
        /// `release(peerID:)`, which also fires on an ordinary reconnect race
        /// that must not disturb a live claim. See `IPC.TaskStore
        /// .releaseClaims(inWorkstreamID:)`'s doc comment.
        func releaseTaskClaims(inWorkstream workstreamID: UUID) async {
            _ = await tasks.releaseClaims(inWorkstreamID: workstreamID.uuidString)
        }

        // MARK: - Session checkpoint

        /// Reads the caller's workstream's saved checkpoint.
        ///
        /// **No `MainActor` hop.** Unlike `listTabs`/`readReviewComments`, which
        /// route through `WorkspaceActions` because they need the live app
        /// environment, this is a plain `UserDefaults` read reachable directly
        /// from this actor.
        ///
        /// **"Never saved" and "saved" are different sentences**, not the same
        /// empty answer dressed up two ways — the same three-case discipline
        /// `Verification.Config.Load` applies to its own file: a state an agent
        /// could mistake for "nothing to report" must say plainly that nothing
        /// has been recorded yet, so it knows to write one rather than assume
        /// there was never anything worth saving.
        private func getSessionCheckpoint(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            guard let checkpoint = IPC.CheckpointStore.read(for: workstreamID) else {
                return .success(id: request.id, .text(
                    "No checkpoint saved yet for this workstream. Call update_session_checkpoint "
                        + "before finishing a task, or at any milestone worth resuming from."
                ))
            }
            let secondsAgo = Int(Date().timeIntervalSince(checkpoint.updatedAt))
            return .success(id: request.id, .text("Checkpoint from \(secondsAgo)s ago:\n\n\(checkpoint.content)"))
        }

        /// Overwrites the caller's workstream's checkpoint.
        ///
        /// **Shared per workstream, not per agent** — see `IPC.CheckpointStore`'s
        /// doc comment. Two agents in one workstream read and write the same
        /// blob, and the tool's own description says so.
        private func updateSessionCheckpoint(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
            }
            do {
                let content = try ToolArguments(request).nonEmpty("content")
                try IPC.CheckpointStore.save(content, for: workstreamID)
                return .success(id: request.id, .text("Checkpoint saved."))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        // MARK: - Test Support

        func _testRegister(name: String, role: String, context: PeerContext) async -> Peer {
            let peer = await store.registerPeer(name: name, role: role)
            contexts[peer.id] = context
            return peer
        }

        func _testContext(for peerID: UUID) -> PeerContext? {
            contexts[peerID]
        }

        func _testBackdate(peerID: UUID, to date: Date) async {
            await store._testSetPeerLastSeen(peerId: peerID, date: date)
        }

        func _testReset() async {
            await store.cleanup()
            await tasks.cleanup()
            contexts.removeAll()
            verification = nil
            deliveredNotices.removeAll()
        }
    }
}
