// ABOUTME: Tests for the sidebar's row-id reconciliation between a cached sort order and the live model.
// ABOUTME: Pins the invariant that no two sidebar rows can ever carry the same List selection tag.

@testable import Atelier
import XCTest

final class SidebarRowOrderTests: XCTestCase {
    private func ids(_ count: Int) -> [UUID] {
        (0 ..< count).map { i in
            UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-\(String(format: "%012d", i))")!
        }
    }

    func testCachedOrderIsHonouredWhenItStillMatchesTheModel() {
        let id = ids(3)

        XCTAssertEqual(
            sidebarRowOrder(cached: [id[2], id[0], id[1]], actual: [id[0], id[1], id[2]]),
            [id[2], id[0], id[1]]
        )
    }

    /// The frame after a purge: `onChange` has not run, so the cache still lists the
    /// workstream the model has already dropped. The row must not be emitted — it is
    /// the row that used to resolve positionally and come back wearing a live
    /// workstream's tag.
    func testIDsTheModelNoLongerHasAreDropped() {
        let id = ids(3)

        XCTAssertEqual(
            sidebarRowOrder(cached: [id[0], id[1], id[2]], actual: [id[0], id[2]]),
            [id[0], id[2]]
        )
    }

    /// The frame after a create, which is the same window in the other direction:
    /// the new workstream appears immediately rather than after the next rebuild.
    func testIDsTheCacheHasNotSeenYetAreAppendedInModelOrder() {
        let id = ids(4)

        XCTAssertEqual(
            sidebarRowOrder(cached: [id[1], id[0]], actual: [id[0], id[1], id[2], id[3]]),
            [id[1], id[0], id[2], id[3]]
        )
    }

    /// Two rows sharing a tag is what `List(selection:)` cannot survive: it
    /// highlights both, and a click elsewhere hands the selection back to the twin.
    func testResultIsDuplicateFreeEvenFromADuplicatedCache() {
        let id = ids(2)

        let order = sidebarRowOrder(cached: [id[0], id[1], id[0]], actual: [id[0], id[1]])

        XCTAssertEqual(order, [id[0], id[1]])
        XCTAssertEqual(Set(order).count, order.count)
    }

    func testAnEmptyCacheFallsBackToModelOrder() {
        let id = ids(3)

        XCTAssertEqual(sidebarRowOrder(cached: [], actual: id), id)
        XCTAssertEqual(sidebarRowOrder(cached: nil, actual: id), id)
    }

    /// Purging the last workstream of a project: every cached id goes, and the
    /// project falls through to its childless branch rather than emitting rows for
    /// workstreams that are gone.
    func testPurgingEveryWorkstreamLeavesNoRows() {
        XCTAssertEqual(sidebarRowOrder(cached: ids(3), actual: []), [])
    }
}
