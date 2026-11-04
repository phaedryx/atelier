// ABOUTME: IPC.Service's messaging tools: registration, the peer list, and the inbox.
// ABOUTME: The six that were once the whole enum; nothing here touches the workspace.

import Foundation

extension IPC.Service {
    // MARK: - Messaging

    /// Registers this session, or renames the peer it already has.
    ///
    /// A helper that reconnects sends the peer id it was given, and gets that
    /// same identity back renamed — otherwise one agent would accumulate a new
    /// peer per registration and its inbox would strand behind the old id.
    func registerPeer(for request: Request) async -> Response {
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

    func listPeers(for request: Request) async -> Response {
        // Snapshotted **before** the await, and the prune is scoped to it —
        // see `pruneContexts(observed:stillAlive:)` for the registration
        // this would otherwise delete out from under a peer mid-hop.
        let observed = Set(contexts.keys)
        let peers = await store.listPeers()
        pruneContexts(observed: observed, stillAlive: peers.map(\.id))

        let visible = peers.filter { isVisible($0.id, to: request.client) && $0.id.uuidString != request.client.peerID }
        let counts = await store.inboxCounts(for: visible.map(\.id))
        let now = Date()
        let infos = visible.map { info(for: $0, pending: counts[$0.id] ?? 0, now: now) }
        return .success(id: request.id, .peers(infos))
    }

    func sendMessage(for request: Request) async -> Response {
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

    func broadcast(for request: Request) async -> Response {
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

    func receiveMessages(for request: Request) async -> Response {
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

    func getPeerStatus(for request: Request) async -> Response {
        guard let peerID = try? ToolArguments(request).uuid("peer_id") else {
            return .failure(id: request.id, ToolError.refused("get_peer_status needs a `peer_id`.").localizedDescription)
        }
        guard isVisible(peerID, to: request.client), let peer = await store.peerStatus(id: peerID) else {
            return .failure(id: request.id, Error.peerNotFound(peerID).localizedDescription)
        }
        return await .success(id: request.id, .peer(info(for: peer)))
    }
}
