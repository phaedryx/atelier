// ABOUTME: Answers IPC requests from atelier-mcp helpers against the peer store.
// ABOUTME: Owns the app-side context (workstream, surface, project) the store deliberately lacks.

import Foundation

/// The app-side half of the IPC feature: one request in, one response out.
///
/// Separate from `IPCServer` so the tool behaviour is testable without a socket,
/// and separate from `IPCStore` so the store stays pure peer/inbox logic.
actor IPCService {
    static let shared = IPCService()

    /// What the app knows about a peer that the store does not.
    struct PeerContext: Sendable, Equatable {
        let workstreamID: String?
        let workstreamName: String?
        let projectDirectory: String?
        /// Set only for the Coding Agent surface; see `IPCClientIdentity`.
        let isAgentSurface: Bool
    }

    private let store: IPCStore
    private var contexts: [UUID: PeerContext] = [:]

    init(store: IPCStore = IPCStore()) {
        self.store = store
    }

    // MARK: - Dispatch

    func handle(_ request: IPCRequest) async -> IPCResponse {
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
    private func registerPeer(for request: IPCRequest) async -> IPCResponse {
        let name = request.arguments["name"] ?? request.client.workstreamName ?? "agent"
        let role = request.arguments["role"] ?? ""

        if let existingID = request.client.peerID.flatMap(UUID.init(uuidString:)),
           let renamed = await store.updatePeer(id: existingID, name: name, role: role.isEmpty ? nil : role)
        {
            contexts[renamed.id] = context(from: request.client)
            return .success(id: request.id, .peer(await info(for: renamed)))
        }

        let peer = await store.registerPeer(name: name, role: role)
        contexts[peer.id] = context(from: request.client)
        return .success(id: request.id, .peer(await info(for: peer)))
    }

    private func listPeers(for request: IPCRequest) async -> IPCResponse {
        let peers = await store.listPeers()
        pruneContexts(keeping: peers.map(\.id))

        let visible = peers.filter { isVisible($0.id, to: request.client) && $0.id.uuidString != request.client.peerID }
        let counts = await store.inboxCounts(for: visible.map(\.id))
        let now = Date()
        let infos = visible.map { info(for: $0, pending: counts[$0.id] ?? 0, now: now) }
        return .success(id: request.id, .peers(infos))
    }

    private func sendMessage(for request: IPCRequest) async -> IPCResponse {
        guard let sender = registeredPeerID(request) else {
            return .failure(id: request.id, IPCError.unregisteredPeer.localizedDescription)
        }
        guard let recipient = request.arguments["to"].flatMap(UUID.init(uuidString:)) else {
            return .failure(id: request.id, "send_message needs a `to` peer id. Use list_peers to see who is reachable.")
        }
        guard let content = request.arguments["content"], !content.isEmpty else {
            return .failure(id: request.id, "send_message needs non-empty `content`.")
        }
        guard isVisible(recipient, to: request.client) else {
            return .failure(id: request.id, IPCError.peerNotFound(recipient).localizedDescription)
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

    private func broadcast(for request: IPCRequest) async -> IPCResponse {
        guard let sender = registeredPeerID(request) else {
            return .failure(id: request.id, IPCError.unregisteredPeer.localizedDescription)
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

    private func receiveMessages(for request: IPCRequest) async -> IPCResponse {
        guard let peerID = registeredPeerID(request) else {
            return .failure(id: request.id, IPCError.unregisteredPeer.localizedDescription)
        }

        let messages = await store.receiveMessages(for: peerID)
        var infos: [IPCMessageInfo] = []
        let now = Date()
        for message in messages {
            let senderName = await store.peerStatus(id: message.from)?.name ?? "unknown"
            infos.append(IPCMessageInfo(
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
        let payload = IPCPayload.messages(infos)
        guard (try? JSONEncoder().encode(payload)) != nil else {
            await store.requeue(messages, for: peerID)
            return .failure(id: request.id, "Could not encode the waiting messages; they are still in your inbox.")
        }
        return .success(id: request.id, payload)
    }

    private func getPeerStatus(for request: IPCRequest) async -> IPCResponse {
        guard let peerID = request.arguments["peer_id"].flatMap(UUID.init(uuidString:)) else {
            return .failure(id: request.id, "get_peer_status needs a `peer_id`.")
        }
        guard isVisible(peerID, to: request.client), let peer = await store.peerStatus(id: peerID) else {
            return .failure(id: request.id, IPCError.peerNotFound(peerID).localizedDescription)
        }
        return .success(id: request.id, .peer(await info(for: peer)))
    }

    // MARK: - Nudging

    /// Asks the terminal nudge to tell each recipient a message arrived.
    ///
    /// Strictly best-effort, and separate from delivery: the message is already
    /// in the inbox by the time this runs, so a nudge that is switched off,
    /// aimed at a busy agent, or aimed at a session Atelier didn't launch costs
    /// the sender nothing.
    private func nudge(_ recipients: [UUID], from senderID: UUID) async {
        guard AgentIPCSettings.nudgeEnabled else { return }
        let senderName = await store.peerStatus(id: senderID)?.name ?? "another agent"

        for recipient in recipients {
            guard let context = contexts[recipient],
                  context.isAgentSurface,
                  let workstreamID = context.workstreamID.flatMap(UUID.init(uuidString:))
            else { continue }

            let waiting = await store.inboxCount(for: recipient)
            await MainActor.run {
                AgentNudge.shared.nudge(workstreamID: workstreamID, senderName: senderName, waiting: waiting)
            }
        }
    }

    // MARK: - Scoping

    /// Peers are scoped to the caller's project. Cross-project messaging is a
    /// separate, louder opt-in — an agent that can reach another project's agent
    /// can, once nudging is on, drive a session in a repository the user wasn't
    /// thinking about.
    private func isVisible(_ peerID: UUID, to client: IPCClientIdentity) -> Bool {
        contexts[peerID]?.projectDirectory == client.projectDirectory
    }

    /// The caller's own peer id, if it has registered one that is still alive.
    private func registeredPeerID(_ request: IPCRequest) -> UUID? {
        guard let id = request.client.peerID.flatMap(UUID.init(uuidString:)) else { return nil }
        return contexts[id] == nil ? nil : id
    }

    private func context(from client: IPCClientIdentity) -> PeerContext {
        PeerContext(
            workstreamID: client.workstreamID,
            workstreamName: client.workstreamName,
            projectDirectory: client.projectDirectory,
            isAgentSurface: client.isAgentSurface
        )
    }

    /// Contexts outlive their peers otherwise: the store expires peers lazily
    /// and never tells anyone which ones it dropped.
    private func pruneContexts(keeping aliveIDs: [UUID]) {
        let alive = Set(aliveIDs)
        contexts = contexts.filter { alive.contains($0.key) }
    }

    private func info(for peer: Peer) async -> IPCPeerInfo {
        info(for: peer, pending: await store.inboxCount(for: peer.id), now: Date())
    }

    private func info(for peer: Peer, pending: Int, now: Date) -> IPCPeerInfo {
        IPCPeerInfo(
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

    func _testReset() async {
        await store.cleanup()
        contexts.removeAll()
    }
}
