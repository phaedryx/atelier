// ABOUTME: Tests for Workstream.Group.Mirror, the lock-guarded live read of each workstream's group.
// ABOUTME: Includes the check that ProjectList.items feeds the shared mirror on in-place mutation.

@testable import Atelier
import XCTest

final class WorkstreamGroupMirrorTests: XCTestCase {
    func test_syncFromProjects_answersEachWorkstreamsGroup() {
        let blue = Workstream(name: "a", group: .cyan), plain = Workstream(name: "b")
        let mirror = Workstream.Group.Mirror()
        mirror.sync([Project(name: "app", directory: "/tmp/app", workstreams: [blue, plain])])
        XCTAssertEqual(mirror.group(forWorkstream: blue.id), .cyan)
        XCTAssertNil(mirror.group(forWorkstream: plain.id))
        XCTAssertNil(mirror.group(forWorkstream: UUID()))
    }

    func test_syncReplacesRatherThanMerges() {
        let gone = Workstream(name: "gone", group: .red)
        let mirror = Workstream.Group.Mirror()
        mirror.sync([Project(name: "app", directory: "/tmp/app", workstreams: [gone])])
        mirror.sync([Project(name: "app", directory: "/tmp/app", workstreams: [])])
        XCTAssertNil(mirror.group(forWorkstream: gone.id), "a removed workstream must not keep reporting a group")
    }

    /// The feed is `didSet`, not `.onChange`: a group change leaves every id in place,
    /// and `Project`/`Workstream` equate by id, so an `onChange` observer never fires.
    @MainActor
    func test_assigningProjectListItems_feedsTheSharedMirror() {
        let ws = Workstream(name: "a")
        let list = ProjectList()
        list.items = [Project(name: "app", directory: "/tmp/app", workstreams: [ws])]
        XCTAssertNil(Workstream.Group.Mirror.shared.group(forWorkstream: ws.id))
        list.items[0].setGroup(.green, forWorkstream: ws.id)
        XCTAssertEqual(Workstream.Group.Mirror.shared.group(forWorkstream: ws.id), .green)
    }
}
