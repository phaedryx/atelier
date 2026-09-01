// ABOUTME: Loopback TCP listener that serves IPC requests from atelier-mcp helpers.
// ABOUTME: Newline-delimited JSON on 127.0.0.1 with an OS-assigned port and a token in ipc.json.

import Foundation
import Network
import os

private let logger = Logger(subsystem: "atelier", category: "ipc-server")

/// Serves the agent IPC surface over a private loopback socket.
///
/// This is a second listener rather than a route on `HookEventReceiver` on
/// purpose. That server is deliberately untokened — a `/bin/sh` + `curl` hook
/// script posts to it — and hanging a tokened surface off an untokened server is
/// how a token ends up bypassed. Speaking newline-delimited JSON instead of HTTP
/// also keeps a second HTTP parser out of the app.
final class IPCServer: @unchecked Sendable {
    static let shared = IPCServer()

    private let queue = DispatchQueue(label: "atelier.ipc-server", qos: .utility)
    private let service: IPCService
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The peer each connection last spoke for, so closing the socket can retire it.
    private var connectionPeers: [ObjectIdentifier: UUID] = [:]
    /// Which connection owns each peer. A request may only act as a peer whose
    /// owning connection is gone — otherwise one agent could speak as another,
    /// retire it by hanging up, or keep it alive indefinitely.
    private var peerOwners: [UUID: ObjectIdentifier] = [:]

    /// Largest frame the listener will buffer before hanging up. Generous next
    /// to the store's 64KB message cap; the point is that a client cannot make
    /// the app grow without bound by never sending a newline.
    private static let maxFrameBytes = 1_048_576
    private var token: String = ""
    /// The port this listener bound to, once ready. Read this rather than
    /// `ipc.json` when you need *this* server's port: the file is shared, and a
    /// server shutting down removes it.
    var boundPort: UInt16? {
        queue.sync { currentPort }
    }

    private var currentPort: UInt16?

    init(service: IPCService = .shared) {
        self.service = service
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.setupListener()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            currentPort = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
            connectionPeers.removeAll()
            peerOwners.removeAll()

            let service = service
            Task { await service.releaseAll() }
            try? FileManager.default.removeItem(at: IPCEndpoint.fileURL)
        }
    }

    private func setupListener() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let newListener = try NWListener(using: params)
            token = Self.makeToken()

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = newListener.port else { return }
                    self?.currentPort = port.rawValue
                    self?.writeEndpointFile(port: port.rawValue)
                case let .failed(error):
                    logger.error("IPC listener failed: \(error.localizedDescription)")
                    newListener.cancel()
                case .cancelled:
                    logger.info("IPC listener cancelled")
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection) }
            }

            listener = newListener
            newListener.start(queue: queue)
        } catch {
            logger.error("Failed to create IPC listener: \(error.localizedDescription)")
        }
    }

    /// Random 256-bit token, regenerated on every start so a stale `ipc.json` a
    /// crashed run left behind can't admit anyone.
    private static func makeToken() -> String {
        (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }

    private func writeEndpointFile(port: UInt16) {
        let endpoint = IPCEndpoint(port: port, token: token)
        do {
            try FilePersistence.writeAtomically(JSONEncoder().encode(endpoint), to: IPCEndpoint.fileURL)
            logger.info("IPC listening on port \(port)")
        } catch {
            logger.error("Failed to write ipc.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.forget(connection) }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// A helper holds one connection open for its whole session, so this loops
    /// rather than closing after a single exchange.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            // Checked before splitting, on everything held rather than on the
            // unterminated tail: a newline arriving in the same chunk as a huge
            // frame would otherwise let one read overshoot the cap.
            guard accumulated.count <= Self.maxFrameBytes else {
                logger.warning("IPC frame exceeded \(Self.maxFrameBytes) bytes; closing the connection")
                connection.cancel()
                return
            }

            let (lines, remainder) = IPCFraming.lines(from: accumulated)
            for line in lines {
                // A line that hangs up the connection ends the batch. The rest
                // of this read belongs to a socket that is already closing, and
                // acting on it would bind peers to a connection whose `forget`
                // has not run yet.
                guard handle(line: line, on: connection) else { return }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(on: connection, buffer: remainder)
        }
    }

    /// Returns false when this line closed the connection, so the caller stops
    /// processing whatever else arrived in the same read.
    @discardableResult
    private func handle(line: Data, on connection: NWConnection) -> Bool {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
            // Never silently drop: the caller is blocked on a reply it will
            // never get. Hanging up gives the helper a clean reconnect instead
            // of a hang, which is what version skew between a running helper
            // and an upgraded app looks like.
            logger.warning("Unparseable IPC request; closing the connection")
            connection.cancel()
            return false
        }
        guard constantTimeEquals(request.token, token) else {
            logger.warning("Rejected an IPC request with a bad token")
            send(.failure(id: request.id, "Unauthorized."), on: connection)
            return true
        }

        guard claim(request.client.peerID, for: connection) else {
            logger.warning("Rejected a request claiming a peer owned by a live connection")
            send(.failure(id: request.id, "That peer id belongs to another session."), on: connection)
            return true
        }

        let service = service
        Task { [weak self] in
            let response = await service.handle(request)
            // register_peer is the one call whose peer id arrives in the reply
            // rather than the request, and an agent that registers and then
            // exits is exactly the case that would otherwise leave a ghost.
            if case let .peer(peer) = response.payload {
                self?.queue.async { _ = self?.claim(peer.id, for: connection) }
            }
            self?.send(response, on: connection)
        }
        return true
    }

    /// Binds a peer to this connection, or refuses if a live connection already
    /// owns it.
    ///
    /// Ownership transfers freely once the previous owner is gone, which is what
    /// makes the helper's reconnect work: it comes back on a new socket carrying
    /// the peer id from before, and the dead connection no longer holds a claim.
    /// Gating on the owner still being live — rather than on a claim merely
    /// existing — is the difference between this and a lockout.
    private func claim(_ peerID: String?, for connection: NWConnection) -> Bool {
        guard let peerID = peerID.flatMap(UUID.init(uuidString:)) else { return true }
        let key = ObjectIdentifier(connection)

        // A reply can land after its connection died. Nothing to bind it to —
        // and since registration already created the peer, dropping the claim
        // here would strand it: `forget` has already run and found nothing bound,
        // and a pinned peer no longer expires. Retire it instead.
        guard connections[key] != nil else {
            retire(peerID)
            return false
        }
        if let owner = peerOwners[peerID], owner != key, connections[owner] != nil {
            return false
        }

        // One connection speaks for one peer. Registering a second time on the
        // same socket abandons the first, which would otherwise stay pinned with
        // nobody left to close it.
        if let previous = connectionPeers[key], previous != peerID {
            peerOwners.removeValue(forKey: previous)
            retire(previous)
        }

        peerOwners[peerID] = key
        connectionPeers[key] = peerID
        return true
    }

    /// Drops a peer from the store without going through a connection close.
    private func retire(_ peerID: UUID) {
        let service = service
        Task { await service.release(peerID: peerID) }
    }

    /// Retires the connection and the peer it spoke for: an agent whose helper
    /// exited should stop appearing in `list_peers` immediately, not linger for
    /// the rest of its TTL while messages pile up in an inbox nobody will read.
    private func forget(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.removeValue(forKey: key)
        guard let peerID = connectionPeers.removeValue(forKey: key) else { return }

        // Only retire a peer this connection still owns. A helper that dropped
        // and reconnected has already claimed it on the new socket, and the old
        // socket's close — which can arrive afterwards under load — must not
        // take the live session down with it.
        guard peerOwners[peerID] == key else { return }
        peerOwners.removeValue(forKey: peerID)
        retire(peerID)
    }

    private func send(_ response: IPCResponse, on connection: NWConnection) {
        guard let data = try? IPCFraming.encode(response) else {
            logger.error("Failed to encode IPC response \(response.id)")
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("Failed to send IPC response: \(error.localizedDescription)")
            }
        })
    }

    /// Compares without an early exit, so a caller can't recover the token one
    /// byte at a time by timing rejections.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}
