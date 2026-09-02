// ABOUTME: Tests for turning declared ports into per-worktree numbers.
// ABOUTME: Covers stability, per-worktree divergence, fixed reservation, and collisions.

@testable import Atelier
import XCTest

final class PortPlanTests: XCTestCase {
    private let worktree = "/tmp/atelier-test/worktree-a"
    private let allFree: (Int) -> Bool = { _ in true }

    private func config(_ entries: [PortEntry]) -> PortsConfig {
        PortsConfig(entries: entries)
    }

    func testAssignedPortMatchesSaltedHash() {
        let plan = PortPlan.resolve(
            config([PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: false)]),
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(plan.values["BFF_PORT"], "\(PortAllocator.port(for: worktree, salt: "BFF_PORT"))")
    }

    func testFixedPortIsUsedVerbatim() {
        let plan = PortPlan.resolve(
            config([PortEntry(name: "RAILS_PORT", kind: .fixed(3005), isBrowser: false)]),
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(plan.values["RAILS_PORT"], "3005")
    }

    /// A fixed port is reserved before anything is assigned, so an assigned
    /// port can never land on it — even when the hash says it should.
    func testAssignedPortNeverCollidesWithAFixedOne() {
        let hashed = PortAllocator.port(for: worktree, salt: "BFF_PORT")

        let plan = PortPlan.resolve(
            config([
                PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: false),
                PortEntry(name: "PINNED", kind: .fixed(hashed), isBrowser: false),
            ]),
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(plan.values["PINNED"], "\(hashed)")
        XCTAssertNotEqual(plan.values["BFF_PORT"], "\(hashed)")
    }

    func testAssignedPortsDifferPerWorktree() {
        let entries = [PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: false)]

        let a = PortPlan.resolve(config(entries), workingDirectory: worktree, isFree: allFree)
        let b = PortPlan.resolve(config(entries), workingDirectory: "/tmp/atelier-test/worktree-b", isFree: allFree)

        XCTAssertNotEqual(a.values["BFF_PORT"], b.values["BFF_PORT"])
    }

    /// The same worktree must produce the same number every run, or a bookmark
    /// or OAuth redirect saved against it breaks on the next start.
    func testAssignedPortIsStableAcrossResolutions() {
        let entries = [PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: false)]

        let first = PortPlan.resolve(config(entries), workingDirectory: worktree, isFree: allFree)
        let second = PortPlan.resolve(config(entries), workingDirectory: worktree, isFree: allFree)

        XCTAssertEqual(first.values["BFF_PORT"], second.values["BFF_PORT"])
    }

    func testAssignedPortSkipsPortsInUse() {
        let hashed = PortAllocator.port(for: worktree, salt: "BFF_PORT")

        let plan = PortPlan.resolve(
            config([PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: false)]),
            workingDirectory: worktree,
            isFree: { $0 != hashed }
        )

        XCTAssertEqual(plan.values["BFF_PORT"], "\(hashed + 1)")
    }

    func testAssignedPortsNeverCollideWithEachOther() {
        let entries = (1 ... 20).map { PortEntry(name: "PORT_\($0)", kind: .assigned, isBrowser: false) }

        let plan = PortPlan.resolve(config(entries), workingDirectory: worktree, isFree: allFree)

        XCTAssertEqual(Set(plan.values.values).count, entries.count)
    }

    func testBrowserPortIsReported() {
        let plan = PortPlan.resolve(
            config([
                PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: true),
                PortEntry(name: "VITE_PORT", kind: .assigned, isBrowser: false),
            ]),
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(plan.browserPort.map(String.init), plan.values["BFF_PORT"])
    }

    func testNoBrowserPortWhenNoneDeclared() {
        let plan = PortPlan.resolve(
            config([PortEntry(name: "BFF_PORT", kind: .assigned, isBrowser: false)]),
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertNil(plan.browserPort)
    }
}
