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
    private var token: String = ""

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
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
            self.connectionPeers.removeAll()
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

            let (lines, remainder) = IPCFraming.lines(from: accumulated)
            for line in lines {
                self.handle(line: line, on: connection)
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: remainder)
        }
    }

    private func handle(line: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
            logger.warning("Discarded an unparseable IPC request")
            return
        }
        guard constantTimeEquals(request.token, token) else {
            logger.warning("Rejected an IPC request with a bad token")
            send(.failure(id: request.id, "Unauthorized."), on: connection)
            return
        }

        remember(request.client.peerID, on: connection)

        let service = service
        Task { [weak self] in
            let response = await service.handle(request)
            // register_peer is the one call whose peer id arrives in the reply
            // rather than the request, and an agent that registers and then
            // exits is exactly the case that would otherwise leave a ghost.
            if case let .peer(peer) = response.payload {
                self?.queue.async { self?.remember(peer.id, on: connection) }
            }
            self?.send(response, on: connection)
        }
    }

    private func remember(_ peerID: String?, on connection: NWConnection) {
        guard let peerID = peerID.flatMap(UUID.init(uuidString:)) else { return }
        connectionPeers[ObjectIdentifier(connection)] = peerID
    }

    /// Retires the connection and the peer it spoke for: an agent whose helper
    /// exited should stop appearing in `list_peers` immediately, not linger for
    /// the rest of its TTL while messages pile up in an inbox nobody will read.
    private func forget(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.removeValue(forKey: key)
        guard let peerID = connectionPeers.removeValue(forKey: key) else { return }
        let service = service
        Task { await service.release(peerID: peerID) }
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
