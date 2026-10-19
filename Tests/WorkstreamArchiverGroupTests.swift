// ABOUTME: Tests removing a group: the refusal rule and the coordinator teardown.
// ABOUTME: Also pins the shared selection fallback Remove and Purge both use.

@testable import Atelier
import XCTest

@MainActor
final class WorkstreamArchiverGroupTests: XCTestCase {
    private var tracker: Workstream.AgentStateTracker {
        Workstream.AgentStateTracker.shared
    }

    override func setUp() {
        super.setUp()
        tracker.resetForTesting()
    }

    override func tearDown() {
        tracker.resetForTesting()
        super.tearDown()
    }

    private func project(groups: [Workstream.Group], members: [Workstream] = []) -> Project {
        var project = Project(name: "proj", directory: "/tmp/atelier-test/proj")
        project.groups = groups
        project.workstreams = members
        return project
    }

    func testRefusesAGroupWithMembers() {
        let group = Workstream.Group(name: "g")
        let project = project(
            groups: [group],
            members: [Workstream(name: "a", groupID: group.id), Workstream(name: "b", groupID: group.id)]
        )

        XCTAssertEqual(Workstream.Archiver.groupRemovalRefusal(group, in: project), .hasMembers(2))
    }

    func testAllowsAnEmptyGroup() {
        let group = Workstream.Group(name: "g")
        let other = Workstream.Group(name: "h")
        let project = project(groups: [group, other], members: [Workstream(name: "a", groupID: other.id)])

        XCTAssertNil(Workstream.Archiver.groupRemovalRefusal(group, in: project))
    }

    func testRemoveGroupDropsTheGroupAndClearsItsAgentState() {
        let group = Workstream.Group(name: "g")
        var project = project(groups: [group])
        let gid = group.id
        tracker.workstreamLookup = { _ in gid }
        tracker.handle(projectDir: "/tmp/atelier-test/proj", event: .waiting(agentId: "main"))
        tracker._backdateRun(agentId: "main", workstreamID: gid, lastEventAt: Date().addingTimeInterval(-1))
        XCTAssertFalse(tracker.runs(for: gid).isEmpty)

        Workstream.Archiver.removeGroup(
            gid, from: &project, surfaceCache: TerminalSurfaceCache(),
            agentStateTracker: tracker, tmuxPath: nil
        )

        XCTAssertEqual(project.groups, [])
        XCTAssertTrue(tracker.runs(for: gid).isEmpty)
    }

    func testRemoveGroupRefusesAGroupWithMembers() {
        let group = Workstream.Group(name: "g")
        var project = project(groups: [group], members: [Workstream(name: "a", groupID: group.id)])

        Workstream.Archiver.removeGroup(
            group.id, from: &project, surfaceCache: TerminalSurfaceCache(),
            agentStateTracker: tracker, tmuxPath: nil
        )

        XCTAssertEqual(project.groups?.count, 1)
    }

    // MARK: - Shared selection fallback

    private let projectID = UUID()

    func testFallbackPrefersTheNextWorkstreamInTheGroup() {
        let next = UUID()
        XCTAssertEqual(
            Workstream.RemoveConfirmation.fallbackSelection(
                projectID: projectID, groupID: UUID(), nextInGroup: next, groupExists: true
            ),
            .workstream(next)
        )
    }

    func testFallbackThenTheGroupItself() {
        let gid = UUID()
        XCTAssertEqual(
            Workstream.RemoveConfirmation.fallbackSelection(
                projectID: projectID, groupID: gid, nextInGroup: nil, groupExists: true
            ),
            .group(gid)
        )
    }

    func testFallbackThenTheProject() {
        XCTAssertEqual(
            Workstream.RemoveConfirmation.fallbackSelection(
                projectID: projectID, groupID: UUID(), nextInGroup: nil, groupExists: false
            ),
            .project(projectID)
        )
        XCTAssertEqual(
            Workstream.RemoveConfirmation.fallbackSelection(
                projectID: projectID, groupID: nil, nextInGroup: nil, groupExists: false
            ),
            .project(projectID)
        )
    }

    func testSelectionAfterRemovingLandsOnTheGroupNotAnotherGroup() {
        let removed = UUID()
        let gid = UUID()
        XCTAssertEqual(
            Workstream.RemoveConfirmation.selectionAfterRemoving(
                removed, from: .workstream(removed), projectID: projectID,
                nextWorkstreamID: nil, groupID: gid, groupExists: true
            ),
            .group(gid)
        )
    }
}
