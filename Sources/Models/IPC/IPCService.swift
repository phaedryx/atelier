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
        case .listPeers:
            return await listPeers(for: request)
        }
    }

    // MARK: - Tools

    private func listPeers(for request: IPCRequest) async -> IPCResponse {
        let peers = await store.listPeers()
        let counts = await store.inboxCounts(for: peers.map(\.id))
        let visible = peers.filter { isVisible($0.id, to: request.client) }
        let now = Date()
        let infos = visible.map { peer in
            IPCPeerInfo(
                id: peer.id.uuidString,
                name: peer.name,
                role: peer.role,
                workstream: contexts[peer.id]?.workstreamName,
                lastSeenSecondsAgo: Int(now.timeIntervalSince(peer.lastSeen)),
                pendingMessages: counts[peer.id] ?? 0
            )
        }
        return .success(id: request.id, .peers(infos))
    }

    // MARK: - Scoping

    /// Peers are scoped to the caller's project. Cross-project visibility is a
    /// separate, louder opt-in — an agent that can reach another project's agent
    /// can, once nudging is on, drive a session in a repository the user wasn't
    /// thinking about.
    private func isVisible(_ peerID: UUID, to client: IPCClientIdentity) -> Bool {
        contexts[peerID]?.projectDirectory == client.projectDirectory
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
