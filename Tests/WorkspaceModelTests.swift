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
        model.terminalTitles[dead] = "zsh"

        model.reconcile(liveSurfaceIDs: [live])

        XCTAssertEqual(model.tabs, [.info, .agent, .changes, .terminal(live), .browser(browser)])
        XCTAssertEqual(model.activeTab, .agent)
        // Reconcile goes through removeTab, so it clears per-tab state too.
        XCTAssertNil(model.terminalTitles[dead])
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

    func testBridgesAreCreatedOnceAndReused() {
        let model = makeModel()

        XCTAssertNil(model.editorBridge)
        XCTAssertNil(model.diffBridge)

        let editor = model.ensureEditorBridge()
        let diff = model.ensureDiffBridge()

        XCTAssertTrue(model.ensureEditorBridge() === editor)
        XCTAssertTrue(model.ensureDiffBridge() === diff)
        XCTAssertNotNil(model.editorBridge)
        XCTAssertNotNil(model.diffBridge)
    }

    func testAutoFocusAgentOnlyForUnvisitedWorkstreams() {
        XCTAssertTrue(shouldAutoFocusAgent(hasExistingModel: false, savedTab: nil))
        XCTAssertFalse(shouldAutoFocusAgent(hasExistingModel: false, savedTab: .changes))
        XCTAssertFalse(shouldAutoFocusAgent(hasExistingModel: true, savedTab: nil))
    }
}

@MainActor
final class WorkspaceModelCacheTests: XCTestCase {
    private func seed() -> WorkspaceTabSnapshot {
        startupWorkspaceTabState(savedTab: nil)
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

    /// A shell that exits is pruned at exit, not at the next mount — a
    /// mount-time prune races `TerminalSurfaceView.updateNSView`, which
    /// recreates any missing surface as soon as its tab renders.
    func testExitedTerminalSurfaceDropsItsTabFromTheOwningModel() {
        let cache = TerminalSurfaceCache()
        let owner = cache.workspaceModel(for: UUID(), seed: seed())
        let bystander = cache.workspaceModel(for: UUID(), seed: seed())
        let terminal = owner.addTerminal()
        let survivor = owner.addTerminal()
        let otherTerminal = bystander.addTerminal()
        owner.terminalTitles[terminal] = "zsh"

        cache.removeTerminalTab(surfaceID: terminal)

        XCTAssertFalse(owner.tabs.contains(.terminal(terminal)))
        XCTAssertTrue(owner.tabs.contains(.terminal(survivor)))
        XCTAssertNil(owner.terminalTitles[terminal])
        XCTAssertTrue(bystander.tabs.contains(.terminal(otherTerminal)))
    }

    /// The agent, dev-server, and setup-gate surfaces close through the same
    /// path but belong to no tab.
    func testRemovingATerminalTabIgnoresSurfaceIDsNoTabOwns() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()
        let model = cache.workspaceModel(for: workstreamID, seed: seed())
        let before = model.tabs

        cache.removeTerminalTab(surfaceID: workstreamID)

        XCTAssertEqual(model.tabs, before)
    }

    func testRemovingWorkstreamSurfacesDropsTheModel() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()
        let first = cache.workspaceModel(for: workstreamID, seed: seed())

        cache.removeWorkstreamSurfaces(for: workstreamID)
        let second = cache.workspaceModel(for: workstreamID, seed: seed())

        XCTAssertFalse(first === second)
    }

    func testHasWorkspaceModelDoesNotCreateOne() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()

        XCTAssertFalse(cache.hasWorkspaceModel(for: workstreamID))

        _ = cache.workspaceModel(for: workstreamID, seed: seed())

        XCTAssertTrue(cache.hasWorkspaceModel(for: workstreamID))
    }
}
