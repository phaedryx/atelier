// ABOUTME: Tests for deterministic per-worktree port derivation.
// ABOUTME: Covers salting, range bounds, and the walk past ports already in use.

@testable import Atelier
import XCTest

final class PortAllocatorTests: XCTestCase {
    private let worktree = "/tmp/atelier-test/worktree-a"

    /// The unsalted value is what `ATELIER_PORT` has always been. Changing the
    /// hash would move it for every existing workstream, so it is pinned.
    func testUnsaltedPortHashesTheBarePath() {
        XCTAssertEqual(PortAllocator.port(for: "/a/b"), PortAllocator.port(for: "/a/b", salt: ""))
    }

    func testSaltChangesTheResult() {
        XCTAssertNotEqual(PortAllocator.port(for: worktree), PortAllocator.port(for: worktree, salt: "BFF_PORT"))
    }

    /// Literals, not `PortAllocator.rangeStart`/`rangeEnd`. Asserting against
    /// the constants under test made this pass for any range at all —
    /// `rangeStart = 80` was green.
    func testTheRangeIsTheDocumentedOne() {
        XCTAssertEqual(PortAllocator.rangeStart, 40001)
        XCTAssertEqual(PortAllocator.rangeEnd, 49999)
    }

    func testPortsStayInRange() {
        for index in 0 ..< 500 {
            let port = PortAllocator.port(for: "/tmp/w\(index)", salt: "SALT_\(index)")
            XCTAssertGreaterThanOrEqual(port, 40001)
            XCTAssertLessThanOrEqual(port, 49999)
        }
    }

    /// Golden values, because the doc comment on `port(for:salt:)` says the
    /// unsalted result "must keep hashing the bare path: changing it would move
    /// every existing workstream's port" — and nothing pinned it. Any change to
    /// the DJB2 constants, the seed, or the salt separator moves these.
    /// Computed independently: DJB2 with seed 5381, multiplier 33, mod 2^64,
    /// then `40001 + hash % 9999`. Changing the multiplier to 31 sends the
    /// first case to 40196.
    func testTheDerivedPortsAreThePinnedOnes() {
        XCTAssertEqual(PortAllocator.port(for: "/Users/tthorley/repos/app/main"), 43017)
        XCTAssertEqual(
            PortAllocator.port(for: "/Users/tthorley/repos/app/main", salt: "BFF_PORT"),
            42150
        )
        XCTAssertEqual(PortAllocator.port(for: "/tmp/w"), 48799)
    }

    func testAvailablePortReturnsHashWhenFree() {
        let hashed = PortAllocator.port(for: worktree, salt: "X")

        let port = PortAllocator.availablePort(for: worktree, salt: "X", claimed: [], isFree: { _ in true })

        XCTAssertEqual(port, hashed)
    }

    func testAvailablePortWalksPastClaimedPorts() {
        let hashed = PortAllocator.port(for: worktree, salt: "X")

        let port = PortAllocator.availablePort(
            for: worktree,
            salt: "X",
            claimed: [hashed, hashed + 1],
            isFree: { _ in true }
        )

        XCTAssertEqual(port, hashed + 2)
    }

    func testAvailablePortWalksPastBoundPorts() {
        let hashed = PortAllocator.port(for: worktree, salt: "X")

        let port = PortAllocator.availablePort(
            for: worktree,
            salt: "X",
            claimed: [],
            isFree: { $0 != hashed }
        )

        XCTAssertEqual(port, hashed + 1)
    }

    /// An exhausted range returns the hash rather than looping or returning a
    /// sentinel: a bind error is the honest outcome.
    func testAvailablePortGivesUpOnAnExhaustedRange() {
        let hashed = PortAllocator.port(for: worktree, salt: "X")

        let port = PortAllocator.availablePort(for: worktree, salt: "X", claimed: [], isFree: { _ in false })

        XCTAssertEqual(port, hashed)
    }

    func testProbeReportsABoundPortAsTaken() throws {
        let listener = try XCTUnwrap(TestListener())
        defer { listener.close() }

        XCTAssertFalse(PortAllocator.isPortFree(listener.port))
    }
}

/// A real listening socket, so the probe is tested against the thing it claims
/// to detect rather than against a stub.
private final class TestListener {
    let port: Int
    private let descriptor: Int32

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // let the kernel choose
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            return nil
        }

        descriptor = fd
        port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    func close() {
        Darwin.close(descriptor)
    }
}
