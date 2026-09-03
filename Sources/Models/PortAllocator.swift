// ABOUTME: Derives a deterministic port number from a workstream path.
// ABOUTME: Port range 40001-49999, unique per worktree to avoid collisions.

import Darwin
import Foundation

extension Port {
    enum Allocator {
        static let rangeStart = 40001
        static let rangeEnd = 49999

        /// Derive a deterministic port from the working directory path.
        /// Uses DJB2 hash (stable across processes, unlike Swift's Hasher).
        ///
        /// A non-empty `salt` shifts the result, so one worktree can carry several
        /// distinct ports — one per named variable — without a second allocator.
        /// The empty salt is the historical `ATELIER_PORT` value and must keep
        /// hashing the bare path: changing it would move every existing workstream's
        /// port.
        static func port(for path: String, salt: String = "") -> Int {
            let input = salt.isEmpty ? path : salt + "\u{1}" + path
            var hash: UInt64 = 5381
            for byte in input.utf8 {
                hash = hash &* 33 &+ UInt64(byte)
            }
            let range = rangeEnd - rangeStart + 1
            return rangeStart + Int(hash % UInt64(range))
        }

        /// The hashed port for `salt`, or the next free one after it.
        ///
        /// The hash alone guarantees a port that is distinct per worktree and per
        /// variable, not one that is actually free — an unrelated project can land
        /// on the same number, and something outside Atelier can already hold it. So
        /// the hash is a starting point and this walks forward until a port is both
        /// unclaimed by this pass and bindable, wrapping at the end of the range.
        ///
        /// Returns the hashed port unchanged if the whole range is exhausted, which
        /// means something is very wrong and a bind error is the honest outcome.
        static func availablePort(
            for path: String,
            salt: String,
            claimed: Set<Int>,
            isFree: (Int) -> Bool = isPortFree
        ) -> Int {
            let start = port(for: path, salt: salt)
            let range = rangeEnd - rangeStart + 1
            for offset in 0 ..< range {
                let candidate = rangeStart + ((start - rangeStart + offset) % range)
                if claimed.contains(candidate) {
                    continue
                }
                if isFree(candidate) {
                    return candidate
                }
            }
            return start
        }

        /// Whether a TCP port can be bound right now.
        ///
        /// Binds to INADDR_ANY without SO_REUSEADDR, so a listener on either the
        /// wildcard address or loopback alone reads as taken. This is a snapshot:
        /// the port can be claimed between this check and the child binding it.
        /// Nothing here can close that window — the point is to avoid the common
        /// case of a port already in use, not to reserve it.
        static func isPortFree(_ port: Int) -> Bool {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = INADDR_ANY

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return bound == 0
        }
    }
}
