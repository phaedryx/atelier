// ABOUTME: Tests for Workstream.Slot, the dense per-workstream integer exported as ATELIER_SLOT.
// ABOUTME: Allocation, backfill, retirement on detach, reclaim on append, and the sweep.

@testable import Atelier
import XCTest

final class WorkstreamSlotTests: XCTestCase {
    private func ws(_ name: String, path: String? = nil, slot: Int? = nil) -> Workstream {
        Workstream(name: name, worktreePath: path ?? "/repos/app/\(name)", slot: slot)
    }

    private func project(_ workstreams: [Workstream], retired: [String: Int]? = nil) -> Project {
        Project(name: "app", directory: "/repos/app", checkoutDirectory: "/repos/app/main",
                workstreams: workstreams, retiredSlots: retired)
    }

    // MARK: - lowestFree / held

    func testLowestFreeStartsAtOne() {
        XCTAssertEqual(Workstream.Slot.lowestFree(held: []), 1)
    }

    func testLowestFreeSkipsHeldAndFillsGaps() {
        XCTAssertEqual(Workstream.Slot.lowestFree(held: [1, 2]), 3)
        XCTAssertEqual(Workstream.Slot.lowestFree(held: [1, 3]), 2)
        XCTAssertEqual(Workstream.Slot.lowestFree(held: [0, 2]), 1, "0 is never handed out, so holding it frees nothing")
    }

    func testHeldIncludesLiveAndRetired() {
        let held = Workstream.Slot.held(
            workstreams: [ws("a", slot: 1), ws("b", slot: nil), ws("c", slot: 4)],
            retired: ["/repos/app/old": 2]
        )
        XCTAssertEqual(held, [1, 2, 4])
    }

    // MARK: - backfill

    func testBackfillAssignsInArrayOrderAvoidingExistingAndRetired() {
        var p = project([ws("a"), ws("b", slot: 1), ws("c")], retired: ["/repos/app/old": 2])
        XCTAssertTrue(Workstream.Slot.backfill(&p))
        XCTAssertEqual(p.workstreams.map(\.slot), [3, 1, 4])
    }

    func testBackfillIsANoOpWhenEverySlotIsSetAndDistinct() {
        var p = project([ws("a", slot: 2), ws("b", slot: 1)])
        XCTAssertFalse(Workstream.Slot.backfill(&p))
        XCTAssertEqual(p.workstreams.map(\.slot), [2, 1])
    }

    func testBackfillRepairsADuplicateKeepingTheFirstHolder() {
        var p = project([ws("a", slot: 1), ws("b", slot: 1)])
        XCTAssertTrue(Workstream.Slot.backfill(&p))
        XCTAssertEqual(p.workstreams.map(\.slot), [1, 2])
    }

    /// A live workstream outranks a retired entry for the same slot: the
    /// collision means an adoption reclaimed it and `claim` never ran.
    func testBackfillDropsARetiredEntryCollidingWithALiveSlot() {
        var p = project([ws("a", slot: 3)], retired: ["/repos/app/old": 3, "/repos/app/older": 5])
        XCTAssertTrue(Workstream.Slot.backfill(&p))
        XCTAssertEqual(p.workstreams.map(\.slot), [3])
        XCTAssertEqual(p.retiredSlots, ["/repos/app/older": 5])
    }

    func testBackfillReplacesAnInvalidStoredSlot() {
        var p = project([ws("a", slot: 0)])
        XCTAssertTrue(Workstream.Slot.backfill(&p))
        XCTAssertEqual(p.workstreams.map(\.slot), [1])
    }

    // MARK: - detach

    func testDetachRemovesTheWorkstreamAndRetiresItsSlotUnderItsPath() {
        let a = ws("a", slot: 1)
        var p = project([a, ws("b", slot: 2)])
        Workstream.Slot.detach(a.id, from: &p)
        XCTAssertEqual(p.workstreams.map(\.name), ["b"])
        XCTAssertEqual(p.retiredSlots, ["/repos/app/a": 1])
    }

    /// The project's own directory never disappears, so a slot retired under
    /// it would never be swept.
    func testDetachFreesRatherThanRetiresWhenThePathIsTheProjectsOwn() {
        let onCheckout = ws("trunk", path: "/repos/app/main", slot: 1)
        let onDirectory = ws("home", path: "/repos/app/", slot: 2)
        var p = project([onCheckout, onDirectory])
        Workstream.Slot.detach(onCheckout.id, from: &p)
        Workstream.Slot.detach(onDirectory.id, from: &p)
        XCTAssertTrue(p.workstreams.isEmpty)
        XCTAssertNil(p.retiredSlots)
    }

    func testDetachOfAWorkstreamWithNoSlotOrNoPathRetiresNothing() {
        let noSlot = ws("a", slot: nil)
        var pathless = ws("b", slot: 2)
        pathless.worktreePath = nil
        var p = project([noSlot, pathless])
        Workstream.Slot.detach(noSlot.id, from: &p)
        Workstream.Slot.detach(pathless.id, from: &p)
        XCTAssertTrue(p.workstreams.isEmpty)
        XCTAssertNil(p.retiredSlots)
    }

    /// Retired keys are standardized, so a later lookup spelled differently
    /// still finds them.
    func testDetachStoresAStandardizedKey() {
        let a = ws("a", path: "/repos/app/./a/", slot: 1)
        var p = project([a])
        Workstream.Slot.detach(a.id, from: &p)
        XCTAssertEqual(p.retiredSlots, [Workstream.Slot.key(for: "/repos/app/a"): 1])
    }

    // MARK: - claim

    func testClaimDropsTheRetiredEntryTheNewWorkstreamTookOver() {
        var p = project([], retired: ["/repos/app/old": 3, "/repos/app/other": 4])
        Workstream.Slot.claim(ws("old", slot: 3), in: &p)
        XCTAssertEqual(p.retiredSlots, ["/repos/app/other": 4])
    }

    func testClaimLeavesAnEmptyMapAsNil() {
        var p = project([], retired: ["/repos/app/old": 3])
        Workstream.Slot.claim(ws("old", slot: 3), in: &p)
        XCTAssertNil(p.retiredSlots)
    }

    // MARK: - sweep

    func testSweepDropsRetiredEntriesWhoseDirectoryIsGone() {
        var p = project([], retired: ["/repos/app/gone": 1, "/repos/app/kept": 2])
        XCTAssertTrue(Workstream.Slot.sweep(&p, exists: { $0 == "/repos/app/kept" }))
        XCTAssertEqual(p.retiredSlots, ["/repos/app/kept": 2])
    }

    func testSweepReportsNoChangeWhenEverythingStillExists() {
        var p = project([], retired: ["/repos/app/kept": 2])
        XCTAssertFalse(Workstream.Slot.sweep(&p, exists: { _ in true }))
        var empty = project([])
        XCTAssertFalse(Workstream.Slot.sweep(&empty, exists: { _ in false }))
    }
}
