@testable import Atelier
import XCTest

final class WorkstreamGroupTests: XCTestCase {
    func testValidateNameTrimsAndAccepts() {
        XCTAssertEqual(Workstream.Group.validateName("  Billing  ", siblings: []), .success("Billing"))
    }

    func testValidateNameRefusesEmpty() {
        XCTAssertEqual(Workstream.Group.validateName("   ", siblings: []), .failure(.empty))
    }

    func testValidateNameRefusesASiblingName() {
        let a = Workstream.Group(name: "Billing")
        XCTAssertEqual(Workstream.Group.validateName("Billing", siblings: [a]), .failure(.taken("Billing")))
    }

    func testRenamingToASiblingNameIsRefused() {
        let a = Workstream.Group(name: "Billing"), b = Workstream.Group(name: "Search")
        XCTAssertEqual(Workstream.Group.validateName("Billing", siblings: [a, b], excluding: b.id), .failure(.taken("Billing")))
        XCTAssertEqual(Workstream.Group.validateName("Billing", siblings: [a, b], excluding: a.id), .success("Billing"))
    }

    func testHousingCreatesOneGroupNamedAfterTheProjectWhenThereAreWorkstreamsAndNoGroups() {
        let ws = Workstream(name: "fix-a", worktreePath: "/p/fix-a")
        let housed = Project(name: "Atelier", directory: "/p", workstreams: [ws]).housingWorkstreams()
        XCTAssertEqual(housed.groups?.count, 1)
        XCTAssertEqual(housed.groups?.first?.name, "Atelier")
        XCTAssertEqual(housed.workstreams[0].groupID, housed.groups?.first?.id)
    }

    func testHousingLeavesAProjectWithNoWorkstreamsWithNoGroups() {
        XCTAssertNil(Project(name: "Atelier", directory: "/p").housingWorkstreams().groups)
    }

    func testAWorkstreamWithAnUnknownGroupIDIsRehoused() {
        let g = Workstream.Group(name: "Billing")
        var ws = Workstream(name: "fix-a", worktreePath: "/p/fix-a")
        ws.groupID = UUID()
        let housed = Project(name: "P", directory: "/p", workstreams: [ws], groups: [g]).housingWorkstreams()
        XCTAssertEqual(housed.workstreams[0].groupID, g.id)
        XCTAssertEqual(housed.groups?.count, 1)
    }

    func testHousingIsIdempotent() {
        let ws = Workstream(name: "fix-a", worktreePath: "/p/fix-a")
        let once = Project(name: "P", directory: "/p", workstreams: [ws]).housingWorkstreams()
        XCTAssertEqual(once.housingWorkstreams().groups?.map(\.id), once.groups?.map(\.id))
    }

    func testWorkstreamsInGroupFiltersByGroupID() {
        let g = Workstream.Group(name: "A"), h = Workstream.Group(name: "B")
        var a = Workstream(name: "a", worktreePath: "/p/a"); a.groupID = g.id
        var b = Workstream(name: "b", worktreePath: "/p/b"); b.groupID = h.id
        let p = Project(name: "P", directory: "/p", workstreams: [a, b], groups: [g, h])
        XCTAssertEqual(p.workstreams(in: g.id).map(\.name), ["a"])
    }

    func testGroupLookupByTrimmedNameAndID() {
        let g = Workstream.Group(name: "Billing")
        let p = Project(name: "P", directory: "/p", groups: [g])
        XCTAssertEqual(p.group(named: "  Billing ")?.id, g.id)
        XCTAssertNil(p.group(named: "billing"))
        XCTAssertEqual(p.group(with: g.id)?.name, "Billing")
        XCTAssertEqual(p.sortedGroups.map(\.id), [g.id])
    }
}
