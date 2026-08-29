// ABOUTME: Unit tests for WorkspaceModel, the per-workstream tab state machine.
// ABOUTME: Covers tab open/close/reorder, per-tab state cleanup, and snapshot round-trip.

@testable import Atelier
import XCTest

@MainActor
final class WorkspaceModelTests: XCTestCase {
    private func makeModel(
        workstreamID: UUID = UUID(),
        activeTab: WorkspaceTab = .info
    ) -> WorkspaceModel {
        let snapshot = WorkspaceTabSnapshot(
            tabs: [.info, .agent, .changes],
            terminalCount: 0,
            browserCount: 0,
            editorCount: 0,
            activeTab: activeTab,
            browserTitles: [:],
            terminalTitles: [:],
            editorFilePaths: [:],
            runStarted: false,
            runStoppedManually: false
        )
        return WorkspaceModel(workstreamID: workstreamID, snapshot: snapshot)
    }

    func testAddTerminalAppendsTabAndActivatesIt() {
        let workstreamID = UUID()
        let model = makeModel(workstreamID: workstreamID)

        let id = model.addTerminal()

        XCTAssertEqual(id, derivedUUID(from: workstreamID, salt: "terminal-1"))
        XCTAssertEqual(model.tabs, [.info, .agent, .changes, .terminal(id)])
        XCTAssertEqual(model.activeTab, .terminal(id))
    }

    func testInstanceIDsAreStableAndDistinctPerKind() {
        let workstreamID = UUID()
        let model = makeModel(workstreamID: workstreamID)

        let firstTerminal = model.addTerminal()
        let secondTerminal = model.addTerminal()
        let firstBrowser = model.addBrowser()

        XCTAssertNotEqual(firstTerminal, secondTerminal)
        XCTAssertEqual(secondTerminal, derivedUUID(from: workstreamID, salt: "terminal-2"))
        XCTAssertEqual(firstBrowser, derivedUUID(from: workstreamID, salt: "browser-1"))
    }

    func testAddEditorRecordsFilePath() {
        let model = makeModel()

        let id = model.addEditor(filePath: "src/main.swift")

        XCTAssertEqual(model.editorFilePaths[id], "src/main.swift")
        XCTAssertEqual(model.activeTab, .editor(id))
    }

    func testAddEditorWithoutPathRecordsNothing() {
        let model = makeModel()

        let id = model.addEditor(filePath: nil)

        XCTAssertNil(model.editorFilePaths[id])
    }

    func testActivateChangesSelectsTheFixedChangesTab() {
        let model = makeModel()

        model.activateChanges()

        XCTAssertEqual(model.activeTab, .changes)
    }

    func testRemoveTabClearsEditorStateAndFallsBackToNeighbour() {
        let model = makeModel()
        let id = model.addEditor(filePath: "a.swift")
        model.editorDirtyState[id] = true

        let removed = model.removeTab(.editor(id))

        XCTAssertTrue(removed)
        XCTAssertEqual(model.tabs, [.info, .agent, .changes])
        XCTAssertNil(model.editorFilePaths[id])
        XCTAssertNil(model.editorDirtyState[id])
        XCTAssertEqual(model.activeTab, .changes)
    }

    func testRemoveTabLeavesActiveTabAloneWhenAnotherTabWasActive() {
        let model = makeModel()
        let terminal = model.addTerminal()
        let browser = model.addBrowser()
        model.activeTab = .terminal(terminal)

        model.removeTab(.browser(browser))

        XCTAssertEqual(model.activeTab, .terminal(terminal))
    }

    func testRemoveTabReturnsFalseForUnknownTab() {
        let model = makeModel()

        XCTAssertFalse(model.removeTab(.terminal(UUID())))
    }

    func testRemoveTabClearsBrowserTitle() {
        let model = makeModel()
        let browser = model.addBrowser()
        model.browserTitles[browser] = "localhost"

        model.removeTab(.browser(browser))

        XCTAssertNil(model.browserTitles[browser])
        XCTAssertFalse(model.hasBrowserTabs)
    }

    func testCountersDoNotRewindAfterClose() {
        let workstreamID = UUID()
        let model = makeModel(workstreamID: workstreamID)

        let first = model.addTerminal()
        model.removeTab(.terminal(first))
        let second = model.addTerminal()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, derivedUUID(from: workstreamID, salt: "terminal-2"))
    }

    func testMoveTabReordersCloseableTabsOnly() {
        let model = makeModel()
        let terminal = model.addTerminal()
        let browser = model.addBrowser()

        model.moveTab(dragging: .browser(browser), to: .terminal(terminal))

        XCTAssertEqual(model.tabs, [.info, .agent, .changes, .browser(browser), .terminal(terminal)])
    }

    func testReconcileDropsDeadTerminalsAndKeepsEverythingElse() {
        let model = makeModel()
        let live = model.addTerminal()
        let dead = model.addTerminal()
        let browser = model.addBrowser()
        model.activeTab = .terminal(dead)

        model.reconcile(liveSurfaceIDs: [live])

        XCTAssertEqual(model.tabs, [.info, .agent, .changes, .terminal(live), .browser(browser)])
        XCTAssertEqual(model.activeTab, .agent)
    }

    func testSnapshotRoundTrip() {
        let model = makeModel()
        let terminal = model.addTerminal()
        let editor = model.addEditor(filePath: "b.swift")
        model.terminalTitles[terminal] = "zsh"
        model.runStarted = true

        let snapshot = model.snapshot()
        let restored = WorkspaceModel(workstreamID: model.workstreamID, snapshot: snapshot)

        XCTAssertEqual(restored.tabs, model.tabs)
        XCTAssertEqual(restored.activeTab, model.activeTab)
        XCTAssertEqual(restored.terminalTitles[terminal], "zsh")
        XCTAssertEqual(restored.editorFilePaths[editor], "b.swift")
        XCTAssertTrue(restored.runStarted)
        XCTAssertFalse(restored.runStoppedManually)
    }

    func testEditorActivityHelpers() {
        let model = makeModel()
        let editor = model.addEditor(filePath: "c.swift")

        XCTAssertTrue(model.isEditorTabActive)
        XCTAssertFalse(model.isActiveEditorDirty)

        model.editorDirtyState[editor] = true
        XCTAssertTrue(model.isActiveEditorDirty)
        XCTAssertTrue(model.isEditorDirty(.editor(editor)))

        model.activateChanges()
        XCTAssertFalse(model.isEditorTabActive)
        XCTAssertFalse(model.isActiveEditorDirty)
    }
}

@MainActor
final class WorkspaceModelCacheTests: XCTestCase {
    private func seed() -> WorkspaceTabSnapshot {
        startupWorkspaceTabState(snapshot: nil, savedTab: nil)
    }

    func testCacheReturnsTheSameModelForTheSameWorkstream() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()

        let first = cache.workspaceModel(for: workstreamID, seed: seed())
        let second = cache.workspaceModel(for: workstreamID, seed: seed())

        XCTAssertTrue(first === second)
    }

    func testCacheKeepsModelsDistinctPerWorkstream() {
        let cache = TerminalSurfaceCache()

        let a = cache.workspaceModel(for: UUID(), seed: seed())
        let b = cache.workspaceModel(for: UUID(), seed: seed())

        XCTAssertFalse(a === b)
    }

    func testSeedIsIgnoredAfterTheModelExists() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()
        let model = cache.workspaceModel(for: workstreamID, seed: seed())
        let terminal = model.addTerminal()

        let again = cache.workspaceModel(for: workstreamID, seed: seed())

        XCTAssertTrue(again.tabs.contains(.terminal(terminal)))
    }

    /// Navigating away destroys `TerminalContainerView`, and coming back re-runs
    /// its `init` against a fresh seed. Per-tab titles and file paths must ride
    /// on the cached model, not on anything the seed can overwrite.
    func testPerTabTitlesAndPathsSurviveARepeatLookup() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()
        let model = cache.workspaceModel(for: workstreamID, seed: seed())
        let browser = model.addBrowser()
        let terminal = model.addTerminal()
        let editor = model.addEditor(filePath: "src/main.swift")
        model.browserTitles[browser] = "Example Domain"
        model.terminalTitles[terminal] = "zsh"

        let again = cache.workspaceModel(for: workstreamID, seed: seed())

        XCTAssertEqual(again.browserTitles[browser], "Example Domain")
        XCTAssertEqual(again.terminalTitles[terminal], "zsh")
        XCTAssertEqual(again.editorFilePaths[editor], "src/main.swift")
    }

    func testRemovingWorkstreamSurfacesDropsTheModel() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()
        let first = cache.workspaceModel(for: workstreamID, seed: seed())

        cache.removeWorkstreamSurfaces(for: workstreamID)
        let second = cache.workspaceModel(for: workstreamID, seed: seed())

        XCTAssertFalse(first === second)
    }
}
