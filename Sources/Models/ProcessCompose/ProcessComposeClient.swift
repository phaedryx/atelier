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

/// The manager operations the UI needs. A seam, so the process table's polling
/// and its error suppression can be tested without a live process-compose:
/// exactly the paths that only ever ran by hand otherwise.
protocol ProcessComposeControlling: Sendable {
    func processes() async throws -> [ProcessComposeProcess]
    func start(_ name: String) async throws
    func stop(_ name: String) async throws
    func restart(_ name: String) async throws
}

struct ProcessComposeClient: ProcessComposeControlling {
    let socketPath: String

    /// Bound on a single blocking `read`/`write` over the socket. `processes()`
    /// runs on the cooperative thread pool and `Task.cancel()` cannot interrupt
    /// a blocking syscall, so a server that accepts and never answers would
    /// otherwise pin a pool thread and a file descriptor forever — and Task 8
    /// polls this once a second, so that leak compounds fast enough to wedge
    /// every async task in the app within seconds. This is a local unix socket
    /// with no network hop, so a few seconds is generous; it is not tens.
    private static let ioTimeout = timeval(tv_sec: 5, tv_usec: 0)

    /// Bound on the *whole* response, where `ioTimeout` bounds one `read`.
    ///
    /// The two are not the same guarantee and only this one is a deadline. A
    /// peer that sends a byte every four seconds resets `SO_RCVTIMEO` on every
    /// iteration, so the read loop alone would run forever while every
    /// individual `read` looked healthy — which defeats `PhaseExecutor`'s
    /// deadline too, because it only re-checks between `processesSync()`
    /// returns.
    private static let requestTimeout: Double = 15

    /// Cap on a single response. `/processes` is a few KB for a large stack;
    /// this is three orders of magnitude above that, so it bounds a broken or
    /// hostile server streaming into memory without being reachable in normal
    /// use.
    private static let maxResponseBytes = 8 * 1024 * 1024

    enum ClientError: Error, Equatable, LocalizedError {
        case notRunning
        case transport(String)
        case http(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notRunning:
                NSLocalizedString("The process manager is not running.", comment: "")
            case let .transport(detail):
                String(format: NSLocalizedString("Could not reach the process manager: %@", comment: ""), detail)
            case let .http(code):
                String(format: NSLocalizedString("The process manager returned %d.", comment: ""), code)
            case .malformedResponse:
                NSLocalizedString("The process manager sent an unreadable response.", comment: "")
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
        try processesSync()
    }

    /// The same request, without the `async` wrapper.
    ///
    /// The transport is a blocking `read`/`write` on a unix socket either way —
    /// `processes()` never suspends. `PhaseExecutor` polls from a dedicated
    /// thread rather than the cooperative pool, and bridging back into `async`
    /// there would mean a `Task` plus a semaphore for no benefit. Only call
    /// this off the main actor.
    func processesSync() throws -> [ProcessComposeProcess] {
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

    /// Percent-encode one path segment.
    ///
    /// `.urlPathAllowed` permits `/`, which is the whole point of a *path*
    /// charset and exactly wrong for a single segment: a process named
    /// `web/api` would otherwise address `/process/stop/web/api` and 404.
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    private func escaped(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? name
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

        // Checked, because a silent failure here removes the per-read bound
        // and leaves a blocking syscall with no timeout at all.
        var timeout = Self.ioTimeout
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
        else { throw ClientError.transport("could not set socket timeouts") }

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
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw ClientError.transport("write timed out")
                    }
                    throw ClientError.transport("write failed")
                }
                guard n > 0 else { throw ClientError.transport("write failed") }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now() + .milliseconds(Int(Self.requestTimeout * 1000))
        while true {
            guard DispatchTime.now() < deadline else {
                throw ClientError.transport("response did not finish in time")
            }
            let n = read(descriptor, &chunk, chunk.count)
            if n == 0 {
                break
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ClientError.transport("read timed out")
                }
                throw ClientError.transport("read failed")
            }
            response.append(contentsOf: chunk[0 ..< n])
            guard response.count <= Self.maxResponseBytes else {
                throw ClientError.transport("response too large")
            }
        }

        return try Self.body(of: response)
    }

    /// Split headers from body, check the status line, and de-chunk if needed.
    ///
    /// **`Transfer-Encoding: chunked` is the normal case, not an exotic one.**
    /// process-compose's server is Go `net/http`, which buffers about 2 KB and
    /// then switches to chunked for any response where the handler set no
    /// `Content-Length`. A `/processes` listing crosses that at **six
    /// processes** (measured: 5 -> 1855 bytes identity, 6 -> 2236 bytes
    /// chunked), which is an ordinary stack, not a large one. `Connection:
    /// close` does not prevent it.
    ///
    /// Returning the framed bytes verbatim broke two things at once. The
    /// process table showed a permanent unreadable-response error for exactly
    /// the stacks it exists to show. Worse, `PhaseExecutor.pollToCompletion`
    /// reads through `try?`, so the decode failure was indistinguishable from
    /// "the server is not up yet": `sawServer` never set, the poll ran to its
    /// deadline, and a bootstrap that had already succeeded was reported as
    /// "did not finish in time" up to 30 minutes later.
    static func body(of response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else { throw ClientError.malformedResponse }
        let head = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        guard let statusLine = head.split(separator: "\r\n").first,
              let code = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { throw ClientError.malformedResponse }
        guard (200 ..< 300).contains(code) else { throw ClientError.http(code) }
        let payload = response[range.upperBound...]
        guard isChunked(head) else { return payload }
        return try dechunked(payload)
    }

    /// Whether any `Transfer-Encoding` header names `chunked`.
    ///
    /// Header names are case-insensitive and the value may be a list
    /// (`gzip, chunked`), so this matches on the last element rather than the
    /// whole value.
    static func isChunked(_ head: String) -> Bool {
        head.split(separator: "\r\n").dropFirst().contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "transfer-encoding"
            else { return false }
            return parts[1]
                .split(separator: ",")
                .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "chunked" }
        }
    }

    /// Reassemble a chunked body.
    ///
    /// Each chunk is a hex length (optionally followed by `;extension`), CRLF,
    /// that many bytes, CRLF. A zero length ends the body; any trailer after it
    /// is ignored, because nothing here reads trailers.
    static func dechunked(_ body: Data) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var out = Data()
        var index = body.startIndex
        while true {
            guard let lineEnd = body.range(of: crlf, in: index ..< body.endIndex) else {
                throw ClientError.malformedResponse
            }
            let sizeText = String(decoding: body[index ..< lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw ClientError.malformedResponse
            }
            index = lineEnd.upperBound
            if size == 0 {
                return out
            }
            guard let end = body.index(index, offsetBy: size, limitedBy: body.endIndex),
                  body.distance(from: index, to: end) == size
            else { throw ClientError.malformedResponse }
            out.append(body[index ..< end])
            index = end
            // The CRLF that closes the chunk must be exactly here; anything
            // else means the length lied about the payload.
            guard let after = body.range(of: crlf, in: index ..< body.endIndex),
                  after.lowerBound == index
            else { throw ClientError.malformedResponse }
            index = after.upperBound
        }
    }
}
