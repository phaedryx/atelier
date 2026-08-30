// ABOUTME: Tests for workspace tab seeding and custom tab reordering.
// ABOUTME: Verifies a workstream seeds with the fixed tabs and custom tabs reorder deterministically.

import AppKit
@testable import Atelier
import XCTest

final class WorkspaceTabSnapshotTests: XCTestCase {
    func testStartupStateUsesSavedFixedTab() {
        let state = startupWorkspaceTabState(savedTab: .agent)

        // The seed is always the four fixed tabs; only the active tab varies.
        XCTAssertEqual(state.tabs, [.info, .agent, .changes, .environment])
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
            agentTeams: false,
            defaultBranch: "develop",
            scriptSource: "conductor.json"
        )

        XCTAssertEqual(vars["ATELIER_DEFAULT_BRANCH"], "develop")
        XCTAssertEqual(vars["CONDUCTOR_DEFAULT_BRANCH"], "develop")
    }

    func testUnknownSavedTabDoesNotDiscardOtherWorkstreams() throws {
        let key = "atelier.workspaceTabs"
        let known = UUID()
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        // A tag written by a future build (or a removed tab kind).
        let raw: [String: String] = [known.uuidString: "changes", UUID().uuidString: "somethingNew"]
        defaults.set(try JSONEncoder().encode(raw), forKey: key)

        XCTAssertEqual(WorkspaceStateStore.load(for: known), .changes)
    }
}

final class WorkspaceTabStateTests: XCTestCase {
    func testCommandBracketShortcutsAreHandledBeforeTerminalInput() {
        XCTAssertEqual(
            commandKeyNotification(charactersIgnoringModifiers: "[", modifierFlags: [.command]),
            .prevWorkstream
        )
        XCTAssertEqual(
            commandKeyNotification(charactersIgnoringModifiers: "]", modifierFlags: [.command]),
            .nextWorkstream
        )
        XCTAssertEqual(
            commandKeyNotification(charactersIgnoringModifiers: "[", modifierFlags: [.command, .shift]),
            .prevTab
        )
        XCTAssertEqual(
            commandKeyNotification(charactersIgnoringModifiers: "]", modifierFlags: [.command, .shift]),
            .nextTab
        )
        XCTAssertEqual(
            commandKeyNotification(charactersIgnoringModifiers: "w", modifierFlags: [.command]),
            .closeTerminal
        )
    }

    func testCommandBracketShortcutsIgnoreOptionAndControlChords() {
        XCTAssertNil(commandKeyNotification(charactersIgnoringModifiers: "[", modifierFlags: [.command, .option]))
        XCTAssertNil(commandKeyNotification(charactersIgnoringModifiers: "[", modifierFlags: [.command, .control]))
        XCTAssertNil(commandKeyNotification(charactersIgnoringModifiers: "x", modifierFlags: [.command]))
    }

    func testCustomTabsPersistAsInfo() {
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .terminal(UUID())), .info)
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .browser(UUID())), .info)
    }

    func testEnvironmentRestoresToEnvironment() {
        XCTAssertEqual(RestorableWorkspaceTab.environment.workspaceTab(), .environment)
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .environment), .environment)
    }

    func testStartupTabsIncludeEnvironmentAfterChanges() {
        let state = startupWorkspaceTabState(savedTab: nil)
        XCTAssertEqual(state.tabs, [.info, .agent, .changes, .environment])
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

    func testCycleWorkstreamWrapsToPreviousExistingWorktree() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let missingID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let previousID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "first", worktreePath: "/app/first", id: firstID, lastAccessedAt: Date(timeIntervalSince1970: 30)),
                Workstream(name: "missing", worktreePath: "/app/missing", id: missingID, lastAccessedAt: Date(timeIntervalSince1970: 20)),
                Workstream(name: "previous", worktreePath: "/app/previous", id: previousID, lastAccessedAt: Date(timeIntervalSince1970: 10)),
            ]
        )

        let id = cycledWorkstreamID(
            in: project,
            selectedWorkstreamID: firstID,
            direction: -1,
            pathExists: { $0 != "/app/missing" }
        )

        XCTAssertEqual(id, previousID)
    }
}

final class SidebarExpansionTests: XCTestCase {
    func testSelectionExpansionAddsSelectedProject() throws {
        let selectedProjectID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let existingProjectID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let expanded = expandedProjectIDs(
            afterSelecting: .project(selectedProjectID),
            current: [existingProjectID],
            projectIDByWorkstreamID: [:]
        )

        XCTAssertEqual(expanded, [existingProjectID, selectedProjectID])
    }

    func testSelectionExpansionAddsParentProjectForWorkstream() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let projectID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let expanded = expandedProjectIDs(
            afterSelecting: .workstream(workstreamID),
            current: [],
            projectIDByWorkstreamID: [workstreamID: projectID]
        )

        XCTAssertEqual(expanded, [projectID])
    }

    func testSelectionExpansionIgnoresMissingWorkstreamParent() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

        let expanded = expandedProjectIDs(
            afterSelecting: .workstream(workstreamID),
            current: [],
            projectIDByWorkstreamID: [:]
        )

        XCTAssertEqual(expanded, [])
    }
}
