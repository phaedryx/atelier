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

        init(store: Store = Store()) {
            self.store = store
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
                let senderName = await store.peerStatus(id: message.from)?.name ?? "unknown"
                infos.append(MessageInfo(
                    id: message.id.uuidString,
                    from: message.from.uuidString,
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
            guard AgentSettings.nudgeEnabled else { return }
            let senderName = await store.peerStatus(id: senderID)?.name ?? "another agent"

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
                lastSeenSecondsAgo: Int(now.timeIntervalSince(peer.lastSeen)),
                pendingMessages: pending
            )
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
        }
    }
}
