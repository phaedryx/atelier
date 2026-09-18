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
            editorFilePaths: [:]
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

    func testActivateSingletonSelectsAnOpenTabWithoutDuplicatingIt() {
        let model = makeModel()

        model.activateSingleton(.changes)

        XCTAssertEqual(model.tabs, [.info, .agent, .changes])
        XCTAssertEqual(model.activeTab, .changes)
    }

    func testClosingASingletonHandsSelectionToItsNeighbour() {
        let model = makeModel(activeTab: .changes)

        XCTAssertTrue(model.removeTab(.changes))

        XCTAssertEqual(model.tabs, [.info, .agent])
        XCTAssertEqual(model.activeTab, WorkspaceTab.agent)
    }

    func testReopeningASingletonAppendsItLikeAnyOtherTab() {
        let model = makeModel()
        model.removeTab(.changes)
        let terminal = model.addTerminal()

        model.activateSingleton(.changes)

        XCTAssertEqual(model.tabs, [.info, .agent, .terminal(terminal), .changes])
        XCTAssertEqual(model.activeTab, .changes)
    }

    func testSingletonsReorderByDragLikeInstancedTabs() {
        let model = makeModel()
        let terminal = model.addTerminal()

        // Changes is an ordinary drop target now, so a terminal can be moved
        // ahead of it.
        model.moveTab(dragging: .terminal(terminal), to: .changes)

        XCTAssertEqual(model.tabs, [.info, .agent, .terminal(terminal), .changes])
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

        let snapshot = model.snapshot()
        let restored = WorkspaceModel(workstreamID: model.workstreamID, snapshot: snapshot)

        XCTAssertEqual(restored.tabs, model.tabs)
        XCTAssertEqual(restored.activeTab, model.activeTab)
        XCTAssertEqual(restored.terminalTitles[terminal], "zsh")
        XCTAssertEqual(restored.editorFilePaths[editor], "b.swift")
    }

    func testEditorActivityHelpers() {
        let model = makeModel()
        let editor = model.addEditor(filePath: "c.swift")

        XCTAssertTrue(model.isEditorTabActive)
        XCTAssertFalse(model.isActiveEditorDirty)

        model.editorDirtyState[editor] = true
        XCTAssertTrue(model.isActiveEditorDirty)
        XCTAssertTrue(model.isEditorDirty(.editor(editor)))

        model.activateSingleton(.changes)
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

    func testAnnotationStoreIsStablePerModel() {
        let model = makeModel()
        let first = model.annotationStore
        XCTAssertTrue(first === model.annotationStore)
    }

    // MARK: - Permanent tabs

    /// Info and Agent are permanent. `removeTab` used to splice the tab out
    /// before its per-kind switch ran, so passing one removed it and only the
    /// state cleanup was skipped — the "callers must pass closeable tabs only"
    /// contract was enforced by nothing.
    func testRemoveTabRefusesInfo() {
        let model = makeModel()

        XCTAssertFalse(model.removeTab(.info))
        XCTAssertEqual(model.tabs, [.info, .agent, .changes])
    }

    func testRemoveTabRefusesAgent() {
        let model = makeModel(activeTab: .agent)

        XCTAssertFalse(model.removeTab(.agent))
        XCTAssertEqual(model.tabs, [.info, .agent, .changes])
        XCTAssertEqual(model.activeTab, .agent)
    }

    /// The refusal must not leak into the closeable singletons, which look
    /// similar (no instance UUID) but close like any terminal.
    func testRemoveTabStillClosesChanges() {
        let model = makeModel()

        XCTAssertTrue(model.removeTab(.changes))
        XCTAssertEqual(model.tabs, [.info, .agent])
    }

    /// `activeTab` is not optional, so the old `!tabs.isEmpty` guard left it
    /// pointing at the tab that had just been removed when it was the last one.
    /// Agent is the fallback, matching `reconcile` — it is not in `tabs` either,
    /// because a workspace with no tabs at all has nothing live to point at. The
    /// `isCloseable` guard makes this unreachable in production, where Info and
    /// Agent cannot be removed; this pins the fallback for a restored snapshot
    /// that never had them.
    func testRemovingTheLastTabFallsBackToAgentRatherThanTheRemovedTab() {
        let snapshot = WorkspaceTabSnapshot(
            tabs: [.changes],
            terminalCount: 0,
            browserCount: 0,
            editorCount: 0,
            activeTab: .changes,
            browserTitles: [:],
            terminalTitles: [:],
            editorFilePaths: [:]
        )
        let model = WorkspaceModel(workstreamID: UUID(), snapshot: snapshot)

        XCTAssertTrue(model.removeTab(.changes))
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNotEqual(model.activeTab, .changes)
        XCTAssertEqual(model.activeTab, .agent)
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

    /// The one-time jump to the Coding Agent fires on a model's first mount, so
    /// the flag must start false, survive later lookups of the same workstream,
    /// and come back false once the workstream is archived and re-created.
    func testPresentationFlagStartsFalseAndResetsWithTheWorkstream() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()

        let model = cache.workspaceModel(for: workstreamID, seed: seed())
        XCTAssertFalse(model.hasBeenPresented)

        model.hasBeenPresented = true
        XCTAssertTrue(cache.workspaceModel(for: workstreamID, seed: seed()).hasBeenPresented)

        cache.removeWorkstreamSurfaces(for: workstreamID)

        XCTAssertFalse(cache.workspaceModel(for: workstreamID, seed: seed()).hasBeenPresented)
    }

    // MARK: - Singleton tabs

    /// `doStartRun` uses this so a run always has an Execution tab to be
    /// stopped from. It must not steal focus: the browser path starts the run
    /// while opening a browser tab, and that tab has to stay active.
    func testEnsureSingletonAddsTheTabWithoutActivatingIt() {
        let snapshot = WorkspaceTabSnapshot(
            tabs: [.info, .agent],
            terminalCount: 0,
            browserCount: 0,
            editorCount: 0,
            activeTab: WorkspaceTab.agent,
            browserTitles: [:],
            terminalTitles: [:],
            editorFilePaths: [:]
        )
        let model = WorkspaceModel(workstreamID: UUID(), snapshot: snapshot)
        XCTAssertFalse(model.tabs.contains(WorkspaceTab.execution))

        model.ensureSingleton(WorkspaceTab.execution)

        XCTAssertTrue(model.tabs.contains(WorkspaceTab.execution))
        XCTAssertEqual(model.activeTab, WorkspaceTab.agent, "focus must stay where it was")
    }

    func testEnsureSingletonDoesNotDuplicateAnExistingTab() {
        let snapshot = WorkspaceTabSnapshot(
            tabs: [.info, .agent],
            terminalCount: 0,
            browserCount: 0,
            editorCount: 0,
            activeTab: WorkspaceTab.agent,
            browserTitles: [:],
            terminalTitles: [:],
            editorFilePaths: [:]
        )
        let model = WorkspaceModel(workstreamID: UUID(), snapshot: snapshot)
        model.ensureSingleton(WorkspaceTab.execution)
        model.ensureSingleton(WorkspaceTab.execution)

        XCTAssertEqual(model.tabs.filter { $0 == WorkspaceTab.execution }.count, 1)
        XCTAssertEqual(model.activeTab, .agent)
    }

    // MARK: - Run state is not here any more

    /// `runStarted`, `runStoppedManually`, `runGeneration` and
    /// `runCommandString` used to live on this model and two of them travelled
    /// in the snapshot. They are all `ProcessCompose.RunSession`'s now, and the
    /// snapshot carries none of it — which is what this pins, because the reason
    /// they survived a view remount was never the snapshot. It was that the
    /// surface cache owns the model, and the cache owns the session the same
    /// way. See `RunSessionTests`.
    func testTheSnapshotCarriesNoRunState() {
        let cache = TerminalSurfaceCache()
        cache.terminalApp = { nil }
        let id = UUID()
        let session = cache.runSession(for: id)
        session.start(ProcessCompose.RunSession.StartContext(
            command: "just dev",
            workingDirectory: "/repo",
            environment: [:],
            launcherPath: nil,
            tmux: nil,
            shell: "/bin/zsh"
        ))

        let model = cache.workspaceModel(for: id, seed: makeSnapshot())
        let restored = WorkspaceModel(workstreamID: id, snapshot: model.snapshot())

        // Rebuilding the model from its snapshot cannot touch the run, because
        // the snapshot has no way to describe one.
        XCTAssertTrue(cache.runSession(for: id).runStarted)
        XCTAssertTrue(restored.tabs.contains(.agent))
    }

    private func makeSnapshot() -> WorkspaceTabSnapshot {
        WorkspaceTabSnapshot(
            tabs: [.info, .agent],
            terminalCount: 0,
            browserCount: 0,
            editorCount: 0,
            activeTab: .info,
            browserTitles: [:],
            terminalTitles: [:],
            editorFilePaths: [:]
        )
    }
}
