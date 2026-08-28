// ABOUTME: In-memory actor holding IPC peers and their message inboxes.
// ABOUTME: Pure logic — peer registration, liveness/TTL, send, broadcast, delete-on-read receive.

import Foundation

// MARK: - Models

struct Peer: Sendable, Codable {
    let id: UUID
    let name: String
    let role: String
    var lastSeen: Date
    let registeredAt: Date
}

struct Message: Sendable, Codable {
    let id: UUID
    let from: UUID
    let to: UUID
    let content: String
    var timestamp: Date
}

// MARK: - Errors

enum IPCError: Error, LocalizedError {
    case unregisteredPeer
    case peerNotFound(UUID)
    case contentTooLarge

    var errorDescription: String? {
        switch self {
        case .unregisteredPeer:
            return NSLocalizedString("You must register_peer first.", comment: "IPC error: caller has no registered peer")
        case let .peerNotFound(id):
            return String(
                format: NSLocalizedString("Peer not found: %@. Use list_peers to see available peers.", comment: "IPC error: unknown peer id"),
                id.uuidString
            )
        case .contentTooLarge:
            return NSLocalizedString("Message content exceeds maximum size (64KB).", comment: "IPC error: oversized message")
        }
    }
}

// MARK: - Store

/// Holds every registered peer and its inbox for the lifetime of the app.
///
/// Deliberately in-memory: messages surviving a restart is a feature nobody
/// asked for and a migration we would own forever.
actor IPCStore {
    private var peers: [UUID: Peer] = [:]
    private var inbox: [UUID: [Message]] = [:]

    /// How long a peer stays alive without activity.
    private let peerTTL: TimeInterval = 600
    private let maxMessagesPerPeer: Int = 100
    /// Max content size per message, in bytes.
    private let maxContentSize: Int = 65_536

    // MARK: - Liveness

    /// A peer is alive while its `lastSeen` is within `peerTTL`, or while it is
    /// pinned by being the sender or recipient of an in-flight message — so an
    /// undelivered message can never be orphaned by its peer expiring.
    private func isAlive(_ peer: Peer) -> Bool {
        if Date().timeIntervalSince(peer.lastSeen) <= peerTTL { return true }
        for (_, msgs) in inbox {
            if msgs.contains(where: { $0.from == peer.id || $0.to == peer.id }) {
                return true
            }
        }
        return false
    }

    /// The peer if alive; otherwise tears down peer and inbox and returns nil.
    /// Every public API gates on this so an expired peer cannot be revived.
    private func aliveOrPurge(_ id: UUID) -> Peer? {
        guard let peer = peers[id] else { return nil }
        if isAlive(peer) { return peer }
        peers.removeValue(forKey: id)
        inbox.removeValue(forKey: id)
        return nil
    }

    /// Appends to an inbox, dropping the oldest entries past `maxMessagesPerPeer`.
    private func appendCapped(_ message: Message, to recipientID: UUID) {
        inbox[recipientID, default: []].append(message)
        if let count = inbox[recipientID]?.count, count > maxMessagesPerPeer {
            inbox[recipientID]?.removeFirst(count - maxMessagesPerPeer)
        }
    }

    // MARK: - Peers

    func registerPeer(name: String, role: String) -> Peer {
        let now = Date()
        let peer = Peer(id: UUID(), name: name, role: role, lastSeen: now, registeredAt: now)
        peers[peer.id] = peer
        inbox[peer.id] = []
        return peer
    }

    func removePeer(id: UUID) {
        peers.removeValue(forKey: id)
        inbox.removeValue(forKey: id)
    }

    /// Every alive peer, lazily purging the rest.
    func listPeers() -> [Peer] {
        var result: [Peer] = []
        result.reserveCapacity(peers.count)
        for id in Array(peers.keys) {
            if let peer = aliveOrPurge(id) {
                result.append(peer)
            }
        }
        return result
    }

    func peerStatus(id: UUID) -> Peer? {
        aliveOrPurge(id)
    }

    /// Renames an existing peer in place, preserving `id` and `registeredAt` and
    /// bumping `lastSeen`. A nil argument leaves that field alone, so a caller
    /// supplying only a new name doesn't blank out the role. Returns nil when
    /// `id` has no alive peer.
    ///
    /// This is what keeps a re-registering surface from minting a second
    /// identity for itself.
    func updatePeer(id: UUID, name: String?, role: String?) -> Peer? {
        guard let existing = aliveOrPurge(id) else { return nil }
        let updated = Peer(
            id: existing.id,
            name: name ?? existing.name,
            role: role ?? existing.role,
            lastSeen: Date(),
            registeredAt: existing.registeredAt
        )
        peers[updated.id] = updated
        return updated
    }

    // MARK: - Messaging

    /// Delivers one message. Both ends must be alive; both get their `lastSeen`
    /// bumped, so an exchange keeps both parties registered.
    func sendMessage(from senderID: UUID, to recipientID: UUID, content: String) throws -> Message {
        guard content.utf8.count <= maxContentSize else { throw IPCError.contentTooLarge }
        guard aliveOrPurge(senderID) != nil else { throw IPCError.unregisteredPeer }
        guard aliveOrPurge(recipientID) != nil else { throw IPCError.peerNotFound(recipientID) }

        let now = Date()
        let message = Message(id: UUID(), from: senderID, to: recipientID, content: content, timestamp: now)
        appendCapped(message, to: recipientID)

        peers[senderID]?.lastSeen = now
        peers[recipientID]?.lastSeen = now

        return message
    }

    /// Delivers to every alive peer except the sender, returning what was sent.
    ///
    /// `recipients` narrows the audience — the caller passes the peers the
    /// sender is actually allowed to reach, since project scoping is the app's
    /// business and not something this store can see.
    func broadcast(from senderID: UUID, content: String, to recipients: [UUID]? = nil) throws -> [Message] {
        guard content.utf8.count <= maxContentSize else { throw IPCError.contentTooLarge }
        guard aliveOrPurge(senderID) != nil else { throw IPCError.unregisteredPeer }

        let now = Date()
        var messages: [Message] = []
        let audience = recipients ?? Array(peers.keys)

        for recipientID in audience where recipientID != senderID {
            guard aliveOrPurge(recipientID) != nil else { continue }

            let message = Message(id: UUID(), from: senderID, to: recipientID, content: content, timestamp: now)
            appendCapped(message, to: recipientID)
            peers[recipientID]?.lastSeen = now
            messages.append(message)
        }

        peers[senderID]?.lastSeen = now
        return messages
    }

    /// Drains the peer's inbox: delete-on-read, at-most-once. A message this
    /// returns is never returned again. Bumps the recipient's `lastSeen` and
    /// that of every distinct sender in the batch. An expired peer reads as
    /// empty and is purged.
    ///
    /// Read-then-acknowledge was the obvious alternative and is worse: agents
    /// don't reliably send the ack, so inboxes only grow and stale messages get
    /// re-read. `requeue` covers the one failure this loses to.
    func receiveMessages(for peerID: UUID) -> [Message] {
        guard aliveOrPurge(peerID) != nil else { return [] }

        let now = Date()
        let messages = inbox[peerID] ?? []
        inbox[peerID] = []
        peers[peerID]?.lastSeen = now

        var seenSenders: Set<UUID> = []
        for msg in messages where seenSenders.insert(msg.from).inserted {
            peers[msg.from]?.lastSeen = now
        }

        return messages
    }

    /// Puts messages back at the FRONT of an inbox, ahead of anything that
    /// arrived meanwhile, preserving their original order.
    ///
    /// Exists solely so the server can undo its own `receiveMessages` when it
    /// fails to serialize the result. It does not cover a failure further down
    /// the response path (encoding the reply envelope, or the socket write) —
    /// those lose the messages permanently, which is the accepted boundary of
    /// at-most-once delivery. No `lastSeen` bump: this is server-internal
    /// recovery, not a liveness signal from the client.
    func requeue(_ messages: [Message], for peerID: UUID) {
        guard aliveOrPurge(peerID) != nil else { return }
        guard !messages.isEmpty else { return }

        var combined = messages + (inbox[peerID] ?? [])
        if combined.count > maxMessagesPerPeer {
            combined.removeFirst(combined.count - maxMessagesPerPeer)
        }
        inbox[peerID] = combined
    }

    /// Messages waiting for `peerID`. A pure read: no `lastSeen` bump and no
    /// purge, since this backs UI badges rather than a client call.
    func inboxCount(for peerID: UUID) -> Int {
        (inbox[peerID] ?? []).count
    }

    /// Batch form of `inboxCount(for:)`, so refreshing every badge is one hop.
    func inboxCounts(for peerIDs: [UUID]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(peerIDs.count)
        for peerID in peerIDs {
            result[peerID] = inboxCount(for: peerID)
        }
        return result
    }

    // MARK: - Cleanup

    func cleanup() {
        peers.removeAll()
        inbox.removeAll()
    }

    // MARK: - Test Helpers

    func _testSetPeerLastSeen(peerId: UUID, date: Date) {
        peers[peerId]?.lastSeen = date
    }

    func _testSetMessageTimestamp(messageId: UUID, peerId: UUID, date: Date) {
        guard var messages = inbox[peerId] else { return }
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].timestamp = date
            inbox[peerId] = messages
        }
    }
}
