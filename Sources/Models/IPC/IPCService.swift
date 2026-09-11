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
        private var contexts: [UUID: PeerContext] = [:]

        /// The check runner the verification tools act through, once the app has
        /// one. Nil until then, and both tools say so rather than pretending.
        ///
        /// Injected rather than constructed here for the reason
        /// `IPC.VerificationControlling` exists: this actor holds the protocol
        /// and never the runner's type, so the tools are testable against a stub
        /// and the two halves of the feature can land in either order.
        private var verification: VerificationControlling?

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

        init(store: Store = Store()) {
            self.store = store
        }

        /// Wires up the check runner. Called once, by whatever builds it.
        func setVerificationRunner(_ runner: VerificationControlling?) {
            verification = runner
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
            case .requestAttention:
                return await requestAttention(for: request)
            case .createWorkstream:
                return await createWorkstream(for: request)
            case .startVerification:
                return await startVerification(for: request)
            case .checkVerification:
                return await checkVerification(for: request)
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
            let name = Names.sanitized(
                request.arguments["name"] ?? request.client.workstreamName ?? "agent",
                limit: 40,
                fallback: "agent"
            )
            let role = Names.sanitized(request.arguments["role"] ?? "", limit: 80, fallback: "")

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
            guard let recipient = request.arguments["to"].flatMap(UUID.init(uuidString:)) else {
                return .failure(id: request.id, "send_message needs a `to` peer id. Use list_peers to see who is reachable.")
            }
            guard let content = request.arguments["content"], !content.isEmpty else {
                return .failure(id: request.id, "send_message needs non-empty `content`.")
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
            guard let content = request.arguments["content"], !content.isEmpty else {
                return .failure(id: request.id, "broadcast needs non-empty `content`.")
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
            guard let peerID = request.arguments["peer_id"].flatMap(UUID.init(uuidString:)) else {
                return .failure(id: request.id, "get_peer_status needs a `peer_id`.")
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
        func release(peerID: UUID) async {
            await store.removePeer(id: peerID)
            let context = contexts.removeValue(forKey: peerID)

            // Its surface state goes with it. Otherwise the tracker keeps reporting
            // whatever that agent last said — usually .idle — and a nudge arriving
            // afterwards would type into a pane whose agent has gone.
            if let surfaceID = context?.surfaceID {
                await MainActor.run {
                    Workstream.AgentStateTracker.shared.clear(surfaceID: surfaceID)
                }
            }
        }

        /// Drops every peer. Called when the listener stops — nothing can reach the
        /// app afterwards, and pinned peers would otherwise outlive their sockets.
        func releaseAll() async {
            await store.cleanup()

            // Same reason `release(peerID:)` clears it: a surface left in the tracker
            // keeps reporting whatever its agent last said — usually .idle — and a
            // later nudge would type into a pane whose agent has gone. Shutdown drops
            // every peer at once, so it has the same exposure for all of them.
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

        private func info(for peer: Peer, pending: Int, now: Date) -> PeerInfo {
            PeerInfo(
                id: peer.id.uuidString,
                name: peer.name,
                role: peer.role,
                workstream: contexts[peer.id]?.workstreamName,
                surfaceID: contexts[peer.id]?.surfaceID?.uuidString,
                lastSeenSecondsAgo: Int(now.timeIntervalSince(peer.lastSeen)),
                pendingMessages: pending
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
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
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
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
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
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
            }
            guard let path = request.arguments["path"], !path.isEmpty else {
                return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("path").localizedDescription)
            }
            // `line` is optional, but a value that is present and unparseable is
            // a mistake worth reporting rather than silently ignoring.
            var line: Int?
            if let raw = request.arguments["line"], !raw.isEmpty {
                guard let parsed = Int(raw) else {
                    return .failure(
                        id: request.id,
                        WorkspaceActions.Failure.invalidArgument(
                            name: "line", reason: "expected a whole number, got \(raw)."
                        ).localizedDescription
                    )
                }
                line = parsed
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
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
            }
            let title = Names.sanitized(request.arguments["title"] ?? "", limit: 40, fallback: "")
            let prompt = request.arguments["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines)

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
            return Workstream.AgentCommand.fresh(
                claudePath: claudePath,
                // The surface's id, never the workstream's: see this method's
                // doc comment.
                sessionID: surfaceID.uuidString.lowercased(),
                sessionName: nil,
                bypassPermissions: plan.bypassPermissions,
                systemPrompt: systemPrompt,
                mcpConfigPath: mcpConfigPath,
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
            let fresh = Workstream.AgentCommand.fresh(
                claudePath: claudePath,
                sessionID: launched.workstreamID.uuidString.lowercased(),
                sessionName: inputs.supportsSessionName ? launched.name : nil,
                bypassPermissions: bypassPermissions,
                systemPrompt: systemPrompt,
                mcpConfigPath: mcpConfigPath,
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

        /// Creates a new workstream — worktree, branch, `bootstrap` — in the
        /// caller's project, and optionally starts an agent in it.
        ///
        /// **Bootstrap's approval gate is inherited, not reimplemented.** The
        /// work happens by posting `.workstreamWorktreeReady`, which
        /// `ContentView` answers by calling
        /// `AsyncSetupService.setupExistingWorktree` — and that is what runs
        /// `bootstrap` through `ProcessCompose.PhasePolicy.plan`. `PhasePolicy`
        /// is deliberately the only copy of those preconditions, so this handler
        /// must never call `setupExistingWorktree` itself.
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
            let name = request.arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = request.arguments["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let callerWorkstreamID = callerWorkstreamID(request)

            let bypass: Bool
            switch Workstream.Launcher.parseBool(request.arguments["bypass_permissions"], name: "bypass_permissions") {
            case let .success(value): bypass = value
            case let .failure(failure): return .failure(id: request.id, failure.localizedDescription)
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
                            + "Its `bootstrap` is running in the background. No agent was started — pass `prompt` to start one."
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
                        + "Coding Agent tab, surface \(launched.workstreamID.uuidString). Its `bootstrap` may still be "
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
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
            }
            let reason = Names.sanitized(request.arguments["reason"] ?? "", limit: 400, fallback: "")
            guard !reason.isEmpty else {
                return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("reason").localizedDescription)
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

        // MARK: - Verification

        /// Starts a verification run in the caller's own workstream and answers
        /// with its run id.
        ///
        /// **The answer is the id, not the result.** A real suite runs for
        /// minutes and an MCP tool call does not, so the result arrives two other
        /// ways: a notice posted into this agent's inbox when the run ends, and
        /// `check_verification` for an agent that never reads its inbox.
        ///
        /// Nothing here decides whether the run is *allowed*. The preconditions —
        /// the integration switch, a located config, a binary, and approval of
        /// every repository-provided file — are `ProcessCompose.PhasePolicy.plan`,
        /// deliberately the only copy, and they live behind the seam. A refusal
        /// arrives as the runner's error and is passed through verbatim.
        private func startVerification(for request: Request) async -> Response {
            guard let workstreamID = callerWorkstreamID(request) else {
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
            }
            guard let runner = verification else {
                return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
            }

            let checks = VerificationSummary.checks(from: request.arguments["checks"])
            // The caller is addressed by surface, never by workstream: two agents
            // in one worktree report the same workstream name, and a notice
            // addressed by workstream would land in the wrong pane's inbox half
            // the time.
            let surfaceID = request.client.surfaceID.flatMap(UUID.init(uuidString:))

            let onFinish: @Sendable (VerificationRunInfo) -> Void
            if let surfaceID {
                let delivery = UUID()
                onFinish = { [weak self] info in
                    Task { await self?.postVerificationNotice(info, to: surfaceID, delivery: delivery) }
                }
            } else {
                // Nothing Atelier launched, so there is no pane to address and no
                // inbox that could be found again. The run is still worth
                // starting — `check_verification` serves it — so this is a
                // deliberate no-op rather than a refusal, and the answer below
                // says as much.
                onFinish = { _ in }
            }

            do {
                let start = try await runner.startVerification(
                    workstreamID: workstreamID,
                    checks: checks,
                    onFinish: onFinish
                )
                return .success(id: request.id, .text(startAnswer(for: start, deliverable: surfaceID != nil)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        /// What an agent is told when a run starts. Says where the result will
        /// appear, because the one thing it must not do is wait here.
        private nonisolated func startAnswer(for start: VerificationStart, deliverable: Bool) -> String {
            let names = start.started.isEmpty ? "the whole verify namespace" : start.started.joined(separator: ", ")
            let delivery = deliverable
                ? "When it finishes, a summary lands in your inbox from \(VerificationSummary.sender) — "
                + "receive_messages to read it, and remember delivery is a pull, so check at your next natural boundary."
                : "Nothing will be posted to your inbox: Atelier does not know which terminal you are running in, "
                + "so poll check_verification instead."
            return "Started verification run \(start.runID): \(names). It runs in the background — do not wait on it. "
                + delivery
                + " check_verification(run_id: \"\(start.runID)\") reads it at any point, including while it is still running."
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
                return .failure(id: request.id, WorkspaceActions.Failure.notInAWorkstream.localizedDescription)
            }
            guard let runner = verification else {
                return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
            }
            guard let runID = request.arguments["run_id"], !runID.isEmpty else {
                return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("run_id").localizedDescription)
            }
            guard let info = await runner.verificationRun(id: runID, in: workstreamID) else {
                return .failure(id: request.id, VerificationFailure.unknownRun(runID).localizedDescription)
            }
            guard info.workstreamID.caseInsensitiveCompare(workstreamID.uuidString) == .orderedSame else {
                return .failure(id: request.id, VerificationFailure.runBelongsElsewhere.localizedDescription)
            }
            return .success(id: request.id, .verificationRun(VerificationSummary.bounded(info)))
        }

        /// Posts a finished run's summary into the inbox of whatever agent now
        /// occupies `surfaceID`.
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
            contexts.removeAll()
            verification = nil
            deliveredNotices.removeAll()
        }
    }
}
