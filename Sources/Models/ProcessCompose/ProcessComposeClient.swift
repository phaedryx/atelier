// ABOUTME: Minimal HTTP client for process-compose's API over a unix socket.
// ABOUTME: Decoding is separated from transport so responses are testable offline.

import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "process-compose")

/// One process as the API reports it. Only the fields Atelier displays are
/// decoded; the API carries more and adds more over time.
struct ProcessComposeProcess: Decodable, Equatable, Identifiable {
    let name: String
    let namespace: String
    let status: String
    let isReady: String
    let hasReadyProbe: Bool
    let restarts: Int
    let exitCode: Int
    let pid: Int
    let isRunning: Bool

    var id: String {
        name
    }

    enum CodingKeys: String, CodingKey {
        case name, namespace, status, restarts, pid
        case isReady = "is_ready"
        case hasReadyProbe = "has_ready_probe"
        case exitCode = "exit_code"
        case isRunning = "is_running"
    }
}

struct ProcessComposeClient {
    let socketPath: String

    enum ClientError: Error, LocalizedError {
        case notRunning
        case transport(String)
        case http(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return NSLocalizedString("The process manager is not running.", comment: "")
            case let .transport(detail):
                return String(format: NSLocalizedString("Could not reach the process manager: %@", comment: ""), detail)
            case let .http(code):
                return String(format: NSLocalizedString("The process manager returned %d.", comment: ""), code)
            case .malformedResponse:
                return NSLocalizedString("The process manager sent an unreadable response.", comment: "")
            }
        }
    }

    private struct Envelope: Decodable {
        let data: [ProcessComposeProcess]
    }

    static func decodeProcesses(_ data: Data) throws -> [ProcessComposeProcess] {
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).data
        } catch {
            throw ClientError.malformedResponse
        }
    }

    func processes() async throws -> [ProcessComposeProcess] {
        try Self.decodeProcesses(request(method: "GET", path: "/processes"))
    }

    func start(_ name: String) async throws {
        _ = try request(method: "POST", path: "/process/start/\(escaped(name))")
    }

    func stop(_ name: String) async throws {
        _ = try request(method: "PATCH", path: "/process/stop/\(escaped(name))")
    }

    func restart(_ name: String) async throws {
        _ = try request(method: "POST", path: "/process/restart/\(escaped(name))")
    }

    private func escaped(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    }

    // MARK: - Transport

    /// A single request over the unix socket.
    ///
    /// URLSession has no unix-socket transport on macOS, and the payloads here
    /// are small and infrequent, so this speaks the minimum HTTP/1.1 needed:
    /// one request, `Connection: close`, read to EOF, split on the blank line.
    private func request(method: String, path: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ClientError.notRunning
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.transport("socket() failed") }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.transport("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let connected = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.notRunning }

        let request = """
        \(method) \(path) HTTP/1.1\r
        Host: localhost\r
        Connection: close\r
        \r

        """
        try Array(request.utf8).withUnsafeBufferPointer { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                guard n > 0 else { throw ClientError.transport("write failed") }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(descriptor, &chunk, chunk.count)
            if n == 0 { break }
            guard n > 0 else { throw ClientError.transport("read failed") }
            response.append(contentsOf: chunk[0 ..< n])
        }

        return try Self.body(of: response)
    }

    /// Split headers from body and check the status line.
    static func body(of response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else { throw ClientError.malformedResponse }
        let head = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        guard let statusLine = head.split(separator: "\r\n").first,
              let code = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { throw ClientError.malformedResponse }
        guard (200 ..< 300).contains(code) else { throw ClientError.http(code) }
        return response[range.upperBound...]
    }
}
