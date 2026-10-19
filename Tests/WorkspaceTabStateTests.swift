// ABOUTME: Tests for workspace tab seeding and custom tab reordering.
// ABOUTME: Verifies a workstream seeds with the fixed tabs and custom tabs reorder deterministically.

import AppKit
@testable import Atelier
import XCTest

final class WorkspaceTabSnapshotTests: XCTestCase {
    func testStartupStateUsesSavedFixedTab() {
        let state = startupWorkspaceTabState(savedTab: .agent)

        // The seed is always the two permanent tabs; only the active tab varies.
        XCTAssertEqual(state.tabs, [.info, .agent])
        XCTAssertEqual(state.activeTab, .agent)
    }

    func testWorkspaceEnvironmentUsesSuppliedDefaultBranch() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

        let vars = workspaceEnvironmentVariables(
            workstreamID: workstreamID,
            projectName: "app",
            workstreamName: "task",
            projectDirectory: "/app",
            workingDirectory: "/app/task",
            port: 3000,
            defaultBranch: "develop"
        )

        XCTAssertEqual(vars["ATELIER_DEFAULT_BRANCH"], "develop")
        XCTAssertEqual(vars["FF_DEFAULT_BRANCH"], "develop")
    }

    func testUnknownSavedTabDoesNotDiscardOtherWorkstreams() throws {
        let key = "atelier.workspaceTabs"
        let known = UUID()
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // A tag written by a future build (or a removed tab kind).
        let raw: [String: String] = [known.uuidString: "changes", UUID().uuidString: "somethingNew"]
        try defaults.set(JSONEncoder().encode(raw), forKey: key)

        XCTAssertEqual(WorkspaceStateStore.load(for: known), .changes)
    }
}

final class WorkspaceTabStateTests: XCTestCase {
    /// The bracket pair is an `AppCommand` and the tab chords are still
    /// notifications, which is what `CommandKeyAction`'s two cases carry. The
    /// split is temporary; the table staying one table is not.
    func testCommandBracketShortcutsAreHandledBeforeTerminalInput() {
        XCTAssertEqual(
            commandKeyAction(charactersIgnoringModifiers: "[", modifierFlags: [.command]),
            .app(.prevWorkstream)
        )
        XCTAssertEqual(
            commandKeyAction(charactersIgnoringModifiers: "]", modifierFlags: [.command]),
            .app(.nextWorkstream)
        )
        // AppKit reports the shifted brackets as "{" / "}" — charactersIgnoringModifiers
        // drops every modifier except Shift, so these are the characters that arrive.
        XCTAssertEqual(
            commandKeyAction(charactersIgnoringModifiers: "{", modifierFlags: [.command, .shift]),
            .notification(.prevTab)
        )
        XCTAssertEqual(
            commandKeyAction(charactersIgnoringModifiers: "}", modifierFlags: [.command, .shift]),
            .notification(.nextTab)
        )
        XCTAssertEqual(
            commandKeyAction(charactersIgnoringModifiers: "w", modifierFlags: [.command]),
            .notification(.closeTerminal)
        )
    }

    func testShiftedBracketsAreNotReportedAsUnshiftedBrackets() {
        XCTAssertNil(commandKeyAction(charactersIgnoringModifiers: "[", modifierFlags: [.command, .shift]))
        XCTAssertNil(commandKeyAction(charactersIgnoringModifiers: "]", modifierFlags: [.command, .shift]))
    }

    func testCommandBracketShortcutsIgnoreOptionAndControlChords() {
        XCTAssertNil(commandKeyAction(charactersIgnoringModifiers: "[", modifierFlags: [.command, .option]))
        XCTAssertNil(commandKeyAction(charactersIgnoringModifiers: "[", modifierFlags: [.command, .control]))
        XCTAssertNil(commandKeyAction(charactersIgnoringModifiers: "x", modifierFlags: [.command]))
    }

    func testCustomTabsPersistAsInfo() {
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .terminal(UUID())), .info)
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .browser(UUID())), .info)
    }

    func testExecutionRestoresToExecution() {
        XCTAssertEqual(RestorableWorkspaceTab.execution.workspaceTab(), .execution)
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .execution), .execution)
    }

    func testStartupTabsOmitTheSingletons() {
        let state = startupWorkspaceTabState(savedTab: nil)
        XCTAssertEqual(state.tabs, [.info, .agent])
        XCTAssertEqual(state.activeTab, .info)
    }

    func testStartupClampsASavedSingletonToInfo() {
        // .changes, .execution and .verification still round-trip through
        // WorkspaceStateStore — a workstream saved before this seed changed has
        // one on disk — but none of the three is seeded any more, so restoring
        // one would leave activeTab outside tabs.
        for saved in [RestorableWorkspaceTab.changes, .execution, .verification] {
            let state = startupWorkspaceTabState(savedTab: saved)
            XCTAssertEqual(state.tabs, [.info, .agent])
            XCTAssertEqual(state.activeTab, .info)
        }
    }

    func test_restorable_verificationRoundTrips() {
        let restorable = RestorableWorkspaceTab(activeTab: .verification)
        XCTAssertEqual(restorable, .verification)
        XCTAssertEqual(restorable.rawValue, "verification")
        XCTAssertEqual(restorable.workspaceTab(), .verification)
    }

    /// Verification is a singleton like Changes and Execution, and the seed no
    /// longer carries any of them — the invariant that every
    /// `RestorableWorkspaceTab` case must be seeded is gone, replaced by
    /// `startupWorkspaceTabState`'s `tabs.contains` clamp. So a saved
    /// `.verification` is safe precisely because it is *not* restored.
    func test_startupState_doesNotSeedVerification() {
        let state = startupWorkspaceTabState(savedTab: .verification)
        XCTAssertFalse(state.tabs.contains(.verification))
        XCTAssertEqual(state.activeTab, .info)
    }

    func testChangesTabRoundTrips() {
        // init(activeTab:) maps .changes -> .changes, persists with its own raw value,
        // and workspaceTab() maps back to .changes.
        let restorable = RestorableWorkspaceTab(activeTab: .changes)
        XCTAssertEqual(restorable, .changes)
        XCTAssertEqual(restorable.rawValue, "changes")
        XCTAssertEqual(restorable.workspaceTab(), .changes)
    }

    func testReorderedCustomTabsKeepsFixedTabsInPlace() throws {
        let terminalA = try WorkspaceTab.terminal(XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")))
        let browserB = try WorkspaceTab.browser(XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")))
        let terminalC = try WorkspaceTab.terminal(XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")))
        let tabs: [WorkspaceTab] = [.info, .agent, terminalA, browserB, terminalC]

        let reordered = reorderedCustomTabs(tabs, dragging: terminalC, to: terminalA)

        XCTAssertEqual(reordered, [.info, .agent, terminalC, terminalA, browserB])
    }

    func testReorderedCustomTabsRefusesToDisturbThePermanentTabs() throws {
        let terminalA = try WorkspaceTab.terminal(XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")))
        let tabs: [WorkspaceTab] = [.info, .agent, .changes, terminalA]

        // Info and Agent are neither draggable nor drop targets; Changes is
        // both, so it must keep every other tab after index 1.
        XCTAssertEqual(reorderedCustomTabs(tabs, dragging: terminalA, to: .agent), tabs)
        XCTAssertEqual(reorderedCustomTabs(tabs, dragging: .info, to: terminalA), tabs)
        XCTAssertEqual(
            reorderedCustomTabs(tabs, dragging: terminalA, to: .changes),
            [.info, .agent, terminalA, .changes]
        )
    }

    func testRenderableWorkstreamIDKeepsOnlySelectedReadyWorkstream() throws {
        let selectedID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let previousID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let nextID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let unreadyID = try XCTUnwrap(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "selected", worktreePath: "/app/selected", id: selectedID, lastAccessedAt: Date(timeIntervalSince1970: 40)),
                Workstream(name: "previous", worktreePath: "/app/previous", id: previousID, lastAccessedAt: Date(timeIntervalSince1970: 50)),
                Workstream(name: "next", worktreePath: "/app/next", id: nextID, lastAccessedAt: Date(timeIntervalSince1970: 30)),
                Workstream(name: "unready", id: unreadyID, lastAccessedAt: Date(timeIntervalSince1970: 20)),
            ]
        )

        let id = renderableWorkstreamID(
            in: project,
            selectedWorkstreamID: selectedID,
            pathExists: { _ in true }
        )

        XCTAssertEqual(id, selectedID)
    }

    func testRenderableWorkstreamIDSkipsUnreadySelection() throws {
        let selectedID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "selected", id: selectedID),
            ]
        )

        let id = renderableWorkstreamID(in: project, selectedWorkstreamID: selectedID)

        XCTAssertNil(id)
    }

    func testRenderableWorkstreamIDSkipsMissingWorktreePath() throws {
        let selectedID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "selected", worktreePath: "/app/missing", id: selectedID),
            ]
        )

        let id = renderableWorkstreamID(
            in: project,
            selectedWorkstreamID: selectedID,
            pathExists: { _ in false }
        )

        XCTAssertNil(id)
    }

    /// A workstream with no worktree on disk is not a stop; the walk steps over it.
    func testCycleSkipsAWorkstreamWithNoWorktree() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let missingID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let previousID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let group = Workstream.Group(name: "app")
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "first", worktreePath: "/app/first", id: firstID, lastAccessedAt: Date(timeIntervalSince1970: 30), groupID: group.id),
                Workstream(name: "missing", worktreePath: "/app/missing", id: missingID, lastAccessedAt: Date(timeIntervalSince1970: 20), groupID: group.id),
                Workstream(name: "previous", worktreePath: "/app/previous", id: previousID, lastAccessedAt: Date(timeIntervalSince1970: 10), groupID: group.id),
            ],
            groups: [group]
        )

        let next = cycledSelection(
            in: project,
            selected: .workstream(firstID),
            direction: 1,
            order: .recent,
            pathExists: { $0 != "/app/missing" }
        )

        XCTAssertEqual(next, .workstream(previousID))
    }

    /// The cycle must walk the rows the sidebar drew. The fixture is chosen so the
    /// two orders are not rotations of each other — recency cycles
    /// alpha→zulu→mike, alphabetical cycles alpha→mike→zulu — so stepping once
    /// from `alpha` distinguishes them.
    func testCyclingFollowsTheConfiguredOrder() throws {
        let alphaID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let mikeID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let zuluID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let group = Workstream.Group(name: "app")

        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "alpha", worktreePath: "/app/alpha", id: alphaID, lastAccessedAt: Date(timeIntervalSince1970: 30), groupID: group.id),
                Workstream(name: "zulu", worktreePath: "/app/zulu", id: zuluID, lastAccessedAt: Date(timeIntervalSince1970: 20), groupID: group.id),
                Workstream(name: "mike", worktreePath: "/app/mike", id: mikeID, lastAccessedAt: Date(timeIntervalSince1970: 10), groupID: group.id),
            ],
            groups: [group]
        )

        XCTAssertEqual(
            cycledSelection(in: project, selected: .workstream(alphaID), direction: 1, order: .recent, pathExists: { _ in true }),
            .workstream(zuluID)
        )
        XCTAssertEqual(
            cycledSelection(in: project, selected: .workstream(alphaID), direction: 1, order: .alphabetical, pathExists: { _ in true }),
            .workstream(mikeID)
        )
    }

    /// Two groups, alphabetical so the order is fixed by name: "first" holds
    /// `missing` (no worktree) then `one`; "second" holds `two`.
    private func twoGroupProject() -> (Project, Workstream.Group, Workstream.Group, missing: UUID, one: UUID, two: UUID) {
        let first = Workstream.Group(name: "first")
        let second = Workstream.Group(name: "second")
        let missing = Workstream(name: "a-missing", worktreePath: "/app/missing", groupID: first.id)
        let one = Workstream(name: "b-one", worktreePath: "/app/one", groupID: first.id)
        let two = Workstream(name: "c-two", worktreePath: "/app/two", groupID: second.id)
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [two, one, missing],
            groups: [second, first]
        )
        return (project, first, second, missing.id, one.id, two.id)
    }

    func testCyclingForwardFromAGroupLandsOnItsFirstRenderableWorkstream() {
        let (project, first, _, _, one, _) = twoGroupProject()

        XCTAssertEqual(
            cycledSelection(in: project, selected: .group(first.id), direction: 1, order: .alphabetical, pathExists: { $0 != "/app/missing" }),
            .workstream(one)
        )
    }

    func testCyclingForwardFromTheLastWorkstreamWrapsToTheFirstGroup() {
        let (project, first, _, _, _, two) = twoGroupProject()

        XCTAssertEqual(
            cycledSelection(in: project, selected: .workstream(two), direction: 1, order: .alphabetical, pathExists: { _ in true }),
            .group(first.id)
        )
    }

    func testAGroupWithNoRenderableWorkstreamsIsStillAStop() {
        let first = Workstream.Group(name: "first")
        let second = Workstream.Group(name: "second")
        let unready = Workstream(name: "unready", worktreePath: "/app/unready", groupID: first.id)
        let project = Project(name: "app", directory: "/app", workstreams: [unready], groups: [first, second])
        let pathExists: (String) -> Bool = { _ in false }

        XCTAssertEqual(
            cycledSelection(in: project, selected: .group(first.id), direction: 1, order: .alphabetical, pathExists: pathExists),
            .group(second.id)
        )
        XCTAssertEqual(
            cycledSelection(in: project, selected: .group(second.id), direction: 1, order: .alphabetical, pathExists: pathExists),
            .group(first.id)
        )
    }

    /// From the project row (or anything not in the walk) forward lands on the
    /// first stop and backward on the last, as the single-project walk did.
    func testCyclingFromTheProjectEntersAtEitherEnd() {
        let (project, first, _, _, _, two) = twoGroupProject()

        XCTAssertEqual(
            cycledSelection(in: project, selected: .project(project.id), direction: 1, order: .alphabetical, pathExists: { _ in true }),
            .group(first.id)
        )
        XCTAssertEqual(
            cycledSelection(in: project, selected: .project(project.id), direction: -1, order: .alphabetical, pathExists: { _ in true }),
            .workstream(two)
        )
    }

    func testCyclingAProjectWithNoGroupsGoesNowhere() {
        let project = Project(name: "app", directory: "/app")

        XCTAssertNil(cycledSelection(in: project, selected: .project(project.id), direction: 1, order: .recent, pathExists: { _ in true }))
    }

    /// A renamed workstream sorts under its label, not the branch name behind it.
    func testAlphabeticalOrderSortsOnTheDisplayLabel() throws {
        let renamedID = try XCTUnwrap(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let plainID = try XCTUnwrap(UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))

        let workstreams = [
            Workstream(name: "zulu-branch", displayName: "apple", id: renamedID),
            Workstream(name: "banana", id: plainID),
        ]

        XCTAssertEqual(Project.SortOrder.alphabetical.sorted(workstreams).map(\.id), [renamedID, plainID])
    }
}

final class SidebarExpansionTests: XCTestCase {
    func testSelectionExpansionAddsSelectedProject() throws {
        let selectedProjectID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let existingProjectID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let expanded = expandedProjectIDs(
            afterSelecting: .project(selectedProjectID),
            current: [existingProjectID],
            projectIDByWorkstreamID: [:],
            projectIDByGroupID: [:]
        )

        XCTAssertEqual(expanded, [existingProjectID, selectedProjectID])
    }

    func testSelectionExpansionAddsParentProjectForWorkstream() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let projectID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let expanded = expandedProjectIDs(
            afterSelecting: .workstream(workstreamID),
            current: [],
            projectIDByWorkstreamID: [workstreamID: projectID],
            projectIDByGroupID: [:]
        )

        XCTAssertEqual(expanded, [projectID])
    }

    func testSelectionExpansionIgnoresMissingWorkstreamParent() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

        let expanded = expandedProjectIDs(
            afterSelecting: .workstream(workstreamID),
            current: [],
            projectIDByWorkstreamID: [:],
            projectIDByGroupID: [:]
        )

        XCTAssertEqual(expanded, [])
    }

    func testSelectionExpansionAddsParentProjectForGroup() throws {
        let groupID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let projectID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let expanded = expandedProjectIDs(
            afterSelecting: .group(groupID),
            current: [],
            projectIDByWorkstreamID: [:],
            projectIDByGroupID: [groupID: projectID]
        )

        XCTAssertEqual(expanded, [projectID])
    }

    /// The id the agent-state tracker treats as "being looked at": a workstream's
    /// own id, or a group's — the coordinator's state is keyed by the group id.
    func testAgentStateIDFollowsWorkstreamsAndGroups() {
        let id = UUID()
        XCTAssertEqual(SidebarSelection.workstream(id).agentStateID, id)
        XCTAssertEqual(SidebarSelection.group(id).agentStateID, id)
        XCTAssertNil(SidebarSelection.project(id).agentStateID)
        XCTAssertNil(SidebarSelection.settings.agentStateID)
    }

    /// A workstream inside a collapsed group has no row, so selecting one (from
    /// ⌘[ / ⌘], a notification, `focusWorkstream`) must open its group too.
    func testSelectingAWorkstreamExpandsItsGroup() {
        let workstreamID = UUID()
        let groupID = UUID()
        let other = UUID()

        XCTAssertEqual(
            expandedGroupIDs(afterSelecting: .workstream(workstreamID), current: [other], groupIDByWorkstreamID: [workstreamID: groupID]),
            [other, groupID]
        )
        XCTAssertEqual(
            expandedGroupIDs(afterSelecting: .group(groupID), current: [other], groupIDByWorkstreamID: [:]),
            [other]
        )
        XCTAssertEqual(
            expandedGroupIDs(afterSelecting: nil, current: [other], groupIDByWorkstreamID: [workstreamID: groupID]),
            [other]
        )
    }
}
