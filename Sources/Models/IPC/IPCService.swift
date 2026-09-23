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

        // MARK: - The names the tool bodies use

        // An `extension IPC.Service` declared at file scope does **not** inherit
        // `IPC`'s lexical scope the way this actor's own declaration does — it
        // sits inside `extension IPC { ... }`, so its body resolves `Request`,
        // `ToolArguments` and the rest for free, while a tool moved into
        // `IPCService+Execution.swift` does not. Declaring them as members here
        // is what lets the eight extension files keep their bodies byte for byte
        // rather than requalifying a few hundred references, which would have
        // turned a pure move into a rewrite nobody could review as one.
        //
        // These are aliases, not new types: `IPC.Service.Request` and
        // `IPC.Request` are the same type, and nothing outside has to use them.
        typealias Request = IPC.Request
        typealias Response = IPC.Response
        typealias ToolError = IPC.ToolError
        typealias ToolArguments = IPC.ToolArguments
        typealias Names = IPC.Names
        typealias ProcessAction = IPC.ProcessAction
        typealias ExecutionFailure = IPC.ExecutionFailure
        typealias ExecutionStart = IPC.ExecutionStart
        typealias ProjectTask = IPC.ProjectTask
        typealias TaskInfo = IPC.TaskInfo
        typealias TaskWireState = IPC.TaskWireState
        typealias TaskQueueFailure = IPC.TaskQueueFailure
        typealias TaskSummary = IPC.TaskSummary
        typealias MessageInfo = IPC.MessageInfo
        typealias VerificationFailure = IPC.VerificationFailure
        typealias VerificationStart = IPC.VerificationStart
        typealias VerificationRunInfo = IPC.VerificationRunInfo
        typealias VerificationCheckNotice = IPC.VerificationCheckNotice
        typealias VerificationSummary = IPC.VerificationSummary
        typealias Payload = IPC.Payload
        /// Shadows `Swift.Error` inside this type, exactly as the enclosing
        /// `extension IPC` already did for the actor's own body — every
        /// `Error.unregisteredPeer` here has always meant `IPC.Error`, and the
        /// codebase spells the protocol `Swift.Error` where it means that one.
        typealias Error = IPC.Error

        let store: Store
        let tasks: TaskStore
        var contexts: [UUID: PeerContext] = [:]

        /// The check runner the verification tools act through, once the app has
        /// one. Nil until then, and both tools say so rather than pretending.
        ///
        /// Injected rather than constructed here for the reason
        /// `IPC.VerificationControlling` exists: this actor holds the protocol
        /// and never the runner's type, so the tools are testable against a stub
        /// and the two halves of the feature can land in either order.
        var verification: VerificationControlling?

        /// The run controller the execution tools act through, once the app has
        /// one. Held as the protocol for the reason `verification` is: this actor
        /// knows the seam, never the bridge.
        var execution: ExecutionControlling?

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
        var deliveredNotices: Set<UUID> = []

        /// How `create_shortcut_workstream` reads a story.
        ///
        /// Injected for the reason `WorktreeCreator` is injected on
        /// `Workstream.Launcher.launch`: the handler's whole job is the order it
        /// does things in, and none of that is assertable if reaching the first
        /// guard costs a network round trip. `Shortcut.Client.init(session:token:)`
        /// is already built for this, but a handler that constructs its own
        /// leaves nothing for a test to stand in.
        var fetchStory: StoryFetch = { try await Shortcut.Client().story(id: $0) }

        typealias StoryFetch = @Sendable (Int) async throws -> Shortcut.Story

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

        /// Replaces the Shortcut read. Tests only; production takes the default.
        func setStoryFetch(_ fetch: @escaping StoryFetch) {
            fetchStory = fetch
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
            case .createShortcutWorkstream:
                return await createShortcutWorkstream(for: request)
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
            case .getInitializationState:
                return await getInitializationState(for: request)
            case .getShortcutStory:
                return await getShortcutStory(for: request)
            case .updateSessionCheckpoint:
                return await updateSessionCheckpoint(for: request)
            }
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
        func nudge(_ recipients: [UUID], from senderID: UUID) async {
            let senderName = await store.peerStatus(id: senderID)?.name ?? "another agent"
            await nudge(recipients, senderName: senderName)
        }

        /// The same courtesy for a notice that has no sender peer — a
        /// verification run finishing. The name is only ever logged: the text
        /// typed into a pane deliberately says nothing the sender chose.
        func nudge(_ recipients: [UUID], senderName: String) async {
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
        func isVisible(_ peerID: UUID, to client: ClientIdentity) -> Bool {
            guard let project = client.projectDirectory, !project.isEmpty else { return false }
            return contexts[peerID]?.projectDirectory == project
        }

        /// The caller's own peer id, if it has registered one that is still alive.
        func registeredPeerID(_ request: Request) -> UUID? {
            guard let id = request.client.peerID.flatMap(UUID.init(uuidString:)) else { return nil }
            return contexts[id] == nil ? nil : id
        }

        func context(from client: ClientIdentity) -> PeerContext {
            PeerContext(
                workstreamID: client.workstreamID,
                workstreamName: client.workstreamName,
                projectDirectory: client.projectDirectory,
                surfaceID: client.surfaceID.flatMap(UUID.init(uuidString:))
            )
        }

        /// Contexts outlive their peers otherwise: the store expires peers lazily
        /// and never tells anyone which ones it dropped.
        ///
        /// **Only a context this call already knew about may be dropped.** The
        /// store's answer is read across an `await`, and this actor is reentrant,
        /// so a registration can land *inside* that hop: `registerPeer` writes
        /// `contexts[A]` and then suspends on `store.pin`, and a `list_peers`
        /// resuming with a snapshot taken before A existed would delete A's
        /// context while A's own reply — carrying its peer id — was already on
        /// the way out. The helper then believes itself registered while
        /// `registeredPeerID` answers nil for the rest of the session:
        /// `send_message`, `receive_messages` and `broadcast` all tell it to
        /// register first, `list_peers` cannot see it, `peersBySurface` misses it
        /// so verification and task notices addressed to it are dropped, and
        /// `touch` cannot repair it because its own guard needs a context to
        /// exist. That is reachable from the documented coordinator workflow
        /// verbatim — "poll list_peers until a peer reports that surface id" is a
        /// `list_peers` loop running while a spawned peer registers.
        ///
        /// Scoping to `observed` makes the prune answer only the question it can
        /// answer: of the contexts that existed when the read began, which ones
        /// has the store since expired. Anything younger than the read is not
        /// evidence of anything, and is left for the next call.
        func pruneContexts(observed: Set<UUID>, stillAlive: [UUID]) {
            let expired = Self.expiredContexts(observed: observed, stillAlive: stillAlive)
            guard !expired.isEmpty else { return }
            for id in expired {
                contexts.removeValue(forKey: id)
            }
        }

        /// The decision above, as a pure function so the reentrancy rule is
        /// assertable — a race is not otherwise something a test can stage.
        nonisolated static func expiredContexts(observed: Set<UUID>, stillAlive: [UUID]) -> Set<UUID> {
            observed.subtracting(stillAlive)
        }

        func info(for peer: Peer) async -> PeerInfo {
            await info(for: peer, pending: store.inboxCount(for: peer.id), now: Date())
        }

        /// Synchronous on purpose: `lastUserPromptAt(forSurface:)` is `nonisolated`
        /// precisely so this can stay off the main actor. A `MainActor.run` hop
        /// here once deadlocked a real socket round trip — `IPCServerTests` blocks
        /// its own thread in a raw `recv()` waiting for the reply this function
        /// produces, so if producing it needed the main thread to go idle first,
        /// and the main thread was the one blocked in `recv()`, neither side could
        /// proceed.
        func info(for peer: Peer, pending: Int, now: Date) -> PeerInfo {
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
        func callerWorkstreamID(_ request: Request) -> UUID? {
            request.client.workstreamID.flatMap(UUID.init(uuidString:))
        }

        /// Surface id → the peer registered from it.
        ///
        /// Built from `contexts`, which is the only place the binding lives. This
        /// is what lets `list_tabs` answer "which agent is in that tab" — and so
        /// what lets a caller turn a tab it just created into a `send_message`
        /// address once the agent there has connected.
        func peersBySurface() async -> [UUID: (id: String, name: String)] {
            var result: [UUID: (id: String, name: String)] = [:]
            for peer in await store.listPeers() {
                guard let surfaceID = contexts[peer.id]?.surfaceID else { continue }
                result[surfaceID] = (id: peer.id.uuidString, name: peer.name)
            }
            return result
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
