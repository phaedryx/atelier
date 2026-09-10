// ABOUTME: In-memory actor holding IPC peers and their message inboxes.
// ABOUTME: Pure logic — peer registration, liveness/TTL, send, broadcast, delete-on-read receive.

import Foundation

extension IPC {
    // MARK: - Models

    struct Peer: Codable {
        let id: UUID
        let name: String
        let role: String
        var lastSeen: Date
        let registeredAt: Date
    }

    struct Message: Codable {
        let id: UUID
        let from: Sender
        let to: UUID
        let content: String
        var timestamp: Date
    }

    /// Who a message came from.
    ///
    /// Two cases rather than one `UUID`, because an app-originated notice — a
    /// verification run finishing, so far the only one — has **no peer behind
    /// it**, and the alternatives were both worse. A reserved peer registered in
    /// the store would have to be filtered out of `listPeers`, out of a
    /// `broadcast` audience and out of `peersBySurface`, each one a place to
    /// forget; a sentinel UUID would let an agent try to `send_message` back to
    /// something that cannot read, and would put a lie where the type used to be
    /// honest. This way the compiler walks every site that assumed a sender peer
    /// existed — the liveness scan, the `lastSeen` bump on read — and the label
    /// an agent sees (`atelier/verification`) is not a peer id it can address.
    enum Sender: Codable, Equatable {
        case peer(UUID)
        /// A reserved sender inside Atelier itself, named for what sent it.
        case system(String)

        /// The peer that sent this, when one did. Nil for `.system`, which is
        /// exactly the distinction every caller here needs.
        var peerID: UUID? {
            switch self {
            case let .peer(id): id
            case .system: nil
            }
        }
    }

    // MARK: - Errors

    enum Error: Swift.Error, LocalizedError {
        case unregisteredPeer
        case peerNotFound(UUID)
        case contentTooLarge

        /// Agent-facing protocol text, not UI: these travel over the wire to a
        /// coding agent, so they are deliberately not localized.
        var errorDescription: String? {
            switch self {
            case .unregisteredPeer:
                "You must register_peer first."
            case let .peerNotFound(id):
                "Peer not found: \(id.uuidString). Use list_peers to see available peers."
            case .contentTooLarge:
                "Message content exceeds maximum size (64KB)."
            }
        }
    }

    // MARK: - Store

    /// Holds every registered peer and its inbox for the lifetime of the app.
    ///
    /// Deliberately in-memory: messages surviving a restart is a feature nobody
    /// asked for and a migration we would own forever.
    actor Store {
        private var peers: [UUID: Peer] = [:]
        private var inbox: [UUID: [Message]] = [:]
        /// Peers whose helper is known to be connected. See `pin`.
        private var pinned: Set<UUID> = []

        /// How long a peer stays alive without activity.
        private let peerTTL: TimeInterval = 600
        private let maxMessagesPerPeer: Int = 100
        /// Max content size per message, in bytes.
        private let maxContentSize: Int = 65_536

        // MARK: - Liveness

        /// A peer is alive while its helper is connected, while its `lastSeen` is
        /// within `peerTTL`, or while it is pinned by an in-flight message it sent
        /// or is due to receive — so an undelivered message can never be orphaned by
        /// its peer expiring.
        private func isAlive(_ peer: Peer) -> Bool {
            if pinned.contains(peer.id) {
                return true
            }
            if Date().timeIntervalSince(peer.lastSeen) <= peerTTL {
                return true
            }
            for (_, msgs) in inbox {
                if msgs.contains(where: { $0.from.peerID == peer.id || $0.to == peer.id }) {
                    return true
                }
            }
            return false
        }

        /// The peer if alive; otherwise tears down peer and inbox and returns nil.
        /// Every public API gates on this so an expired peer cannot be revived.
        private func aliveOrPurge(_ id: UUID) -> Peer? {
            guard let peer = peers[id] else { return nil }
            if isAlive(peer) {
                return peer
            }
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
            pinned.remove(id)
        }

        /// Marks a peer as backed by a live helper connection, exempting it from the
        /// TTL until the connection closes.
        ///
        /// The TTL alone evicts exactly the agents this feature exists to reach: one
        /// waiting for work is idle by definition, and after ten quiet minutes it
        /// would drop out of `list_peers` while its helper sat there connected, with
        /// messages to it refused rather than queued. An open socket is the real
        /// liveness signal — the same reasoning that makes a closing socket retire
        /// a peer — so the TTL is left as a backstop for a close that never arrives.
        func pin(_ id: UUID) {
            guard peers[id] != nil else { return }
            pinned.insert(id)
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
            guard content.utf8.count <= maxContentSize else { throw Error.contentTooLarge }
            guard aliveOrPurge(senderID) != nil else { throw Error.unregisteredPeer }
            guard aliveOrPurge(recipientID) != nil else { throw Error.peerNotFound(recipientID) }

            let now = Date()
            let message = Message(id: UUID(), from: .peer(senderID), to: recipientID, content: content, timestamp: now)
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
            guard content.utf8.count <= maxContentSize else { throw Error.contentTooLarge }
            guard aliveOrPurge(senderID) != nil else { throw Error.unregisteredPeer }

            let now = Date()
            var messages: [Message] = []
            let audience = recipients ?? Array(peers.keys)

            for recipientID in audience where recipientID != senderID {
                guard aliveOrPurge(recipientID) != nil else { continue }

                let message = Message(id: UUID(), from: .peer(senderID), to: recipientID, content: content, timestamp: now)
                appendCapped(message, to: recipientID)
                peers[recipientID]?.lastSeen = now
                messages.append(message)
            }

            peers[senderID]?.lastSeen = now
            return messages
        }

        /// Delivers a message that came from Atelier itself rather than from a
        /// peer — a verification run finishing, so far the only one.
        ///
        /// **This is new machinery, not a variation on `sendMessage`.** Every
        /// other message in this store has a peer on both ends, and the two
        /// guarantees that hang off that do not apply: there is no sender to
        /// prove alive, and no sender `lastSeen` to bump. What *does* still
        /// apply is the content cap, deliberately — a caller assembling a
        /// summary has to keep it small enough to deliver, and silently sending
        /// half of one would be worse than telling it so.
        ///
        /// Returns nil when the recipient is gone. That is an ordinary outcome
        /// rather than an error: the agent that asked for the run may have
        /// finished its session while the suite ran, and the results stay
        /// readable through `check_verification` either way.
        func deliverSystemMessage(from label: String, to recipientID: UUID, content: String) throws -> Message? {
            guard content.utf8.count <= maxContentSize else { throw Error.contentTooLarge }
            guard aliveOrPurge(recipientID) != nil else { return nil }

            let message = Message(id: UUID(), from: .system(label), to: recipientID, content: content, timestamp: Date())
            appendCapped(message, to: recipientID)
            return message
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
            for senderID in messages.compactMap(\.from.peerID) where seenSenders.insert(senderID).inserted {
                peers[senderID]?.lastSeen = now
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
            pinned.removeAll()
        }

        // MARK: - Test Helpers

        /// `pinned` is private and a removed peer's id can never be re-registered, so
        /// a stale pin has no observable consequence through the public API — which is
        /// why `test_removingAPeer_dropsItsPin` could only assert the peer was gone,
        /// something that held whether or not the pin was cleaned up.
        func _testIsPinned(peerId: UUID) -> Bool {
            pinned.contains(peerId)
        }

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
}
