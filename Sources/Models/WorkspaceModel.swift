// ABOUTME: Per-workstream tab state: the tab list, active tab, and per-tab metadata.
// ABOUTME: A pure state machine — callers own every side effect (surfaces, watchers, telemetry).

import Foundation

/// One workstream's workspace tab state.
///
/// Lives in `TerminalSurfaceCache` rather than in `TerminalContainerView`, so it
/// survives the view going away and can be read from outside the view hierarchy.
/// Mutating methods only touch state held here; teardown of surfaces, webviews,
/// Monaco models, and the dev server stays with the caller, which is the only
/// place that knows about them.
@MainActor
final class WorkspaceModel: ObservableObject {
    let workstreamID: UUID

    @Published var tabs: [WorkspaceTab]
    @Published var activeTab: WorkspaceTab
    @Published var browserTitles: [UUID: String]
    @Published var terminalTitles: [UUID: String]
    @Published var editorFilePaths: [UUID: String]
    @Published var editorDirtyState: [UUID: Bool] = [:]

    /// Whether this workstream's workspace has been on screen yet. A fresh
    /// model means a workstream nobody has visited this session, which is what
    /// decides the one-time jump to the Coding Agent. Deliberately not
    /// `@Published` — nothing renders from it, so publishing it from `.onAppear`
    /// would invalidate the view for no reason.
    var hasBeenPresented = false

    /// Dev-server state. Held here rather than in the view for the same reason
    /// the tab list is: it must survive the view going away when the user
    /// navigates to another workstream.
    @Published var runStarted: Bool
    @Published var runStoppedManually: Bool

    /// The run surface's generation, and the command it was started with.
    ///
    /// Here rather than in the view, and the pairing with `runStarted` above is
    /// the whole point. While these were `@State` on `TerminalContainerView` —
    /// which `ContentView` keys `.id(workstreamID)` — navigating to another
    /// workstream and back destroyed them while `runStarted` survived here. The
    /// view came back believing a run was live with `runGeneration` reset to 0,
    /// so Stop called `removeSurface` on the generation-0 id, which is a no-op
    /// against a live generation-3 surface: the stack kept running with no UI
    /// able to see or stop it, and the next Start rebound its socket and
    /// stranded the server.
    ///
    /// Deliberately absent from `WorkspaceTabSnapshot`: they must outlive a
    /// view remount, not an app relaunch. Across a launch no surface exists and
    /// a restored command string would be a lie.
    @Published var runGeneration = 0
    @Published var runCommandString: String?

    /// Monotonic per-kind counters. They feed `derivedUUID` salts, so they must
    /// never rewind on close — a reused salt would collide with a surface the
    /// cache still holds.
    private(set) var terminalCount: Int
    private(set) var browserCount: Int
    private(set) var editorCount: Int

    /// Monaco WebViews are expensive (~17 MB of JS), so both bridges are created
    /// on demand and then kept for the workstream's lifetime — closing the last
    /// editor tab must not tear them down.
    @Published private(set) var editorBridge: MonacoEditorBridge?
    @Published private(set) var diffBridge: MonacoDiffBridge?

    /// Review comments for the Changes tab. Cheap (unlike the bridges), so it is
    /// created eagerly; lives here so unsent comments survive tab switches and
    /// webview reloads, and die with the workstream.
    let annotationStore = ChangeAnnotationStore()

    @discardableResult
    func ensureEditorBridge() -> MonacoEditorBridge {
        if let editorBridge { return editorBridge }
        let bridge = MonacoEditorBridge()
        editorBridge = bridge
        return bridge
    }

    @discardableResult
    func ensureDiffBridge() -> MonacoDiffBridge {
        if let diffBridge { return diffBridge }
        let bridge = MonacoDiffBridge()
        diffBridge = bridge
        return bridge
    }

    init(workstreamID: UUID, snapshot: WorkspaceTabSnapshot) {
        self.workstreamID = workstreamID
        tabs = snapshot.tabs
        activeTab = snapshot.activeTab
        terminalCount = snapshot.terminalCount
        browserCount = snapshot.browserCount
        editorCount = snapshot.editorCount
        browserTitles = snapshot.browserTitles
        terminalTitles = snapshot.terminalTitles
        editorFilePaths = snapshot.editorFilePaths
        runStarted = snapshot.runStarted
        runStoppedManually = snapshot.runStoppedManually
    }

    // MARK: - Derived state

    var hasBrowserTabs: Bool {
        tabs.contains { if case .browser = $0 { return true } else { return false } }
    }

    var hasEditorTabs: Bool {
        tabs.contains { if case .editor = $0 { return true } else { return false } }
    }

    var isEditorTabActive: Bool {
        if case .editor = activeTab { return true }
        return false
    }

    var isActiveEditorDirty: Bool {
        if case let .editor(id) = activeTab { return editorDirtyState[id] == true }
        return false
    }

    func isEditorDirty(_ tab: WorkspaceTab) -> Bool {
        if case let .editor(id) = tab { return editorDirtyState[id] == true }
        return false
    }

    // MARK: - Opening tabs

    func addTerminal() -> UUID {
        terminalCount += 1
        let id = derivedUUID(from: workstreamID, salt: "terminal-\(terminalCount)")
        appendAndActivate(.terminal(id))
        return id
    }

    func addBrowser() -> UUID {
        browserCount += 1
        let id = derivedUUID(from: workstreamID, salt: "browser-\(browserCount)")
        appendAndActivate(.browser(id))
        return id
    }

    func addEditor(filePath: String?) -> UUID {
        editorCount += 1
        let id = derivedUUID(from: workstreamID, salt: "editor-\(editorCount)")
        if let filePath {
            editorFilePaths[id] = filePath
        }
        appendAndActivate(.editor(id))
        return id
    }

    /// Shows one of the singleton tabs (Changes, Environment), reopening it at
    /// the end of the strip if the user closed it. Instanced kinds have no
    /// business here — there can be many of each, so "the" tab is meaningless.
    func activateSingleton(_ tab: WorkspaceTab) {
        if !tabs.contains(tab) {
            tabs.append(tab)
        }
        activeTab = tab
    }

    /// Make sure a singleton tab exists, without changing which tab is active.
    ///
    /// `activateSingleton` also selects the tab, which is wrong when the run is
    /// starting as a side effect of something else — opening a browser tab
    /// starts the dev server, and stealing focus back off the browser the user
    /// just asked for would be its own bug.
    func ensureSingleton(_ tab: WorkspaceTab) {
        if !tabs.contains(tab) {
            tabs.append(tab)
        }
    }

    private func appendAndActivate(_ tab: WorkspaceTab) {
        tabs.append(tab)
        activeTab = tab
    }

    // MARK: - Closing and reordering

    /// Removes a tab and its per-tab state, moving the selection to a neighbour
    /// if the removed tab was active. Returns false when the tab is not open,
    /// so callers can skip their own teardown.
    ///
    /// Callers must pass closeable tabs only — Info and Agent are permanent,
    /// and like the original closeTab contract this method does not guard
    /// against them. Changes and Environment are ordinary closeable tabs: they
    /// carry no per-tab state to clear, and everything durable behind them (the
    /// diff bridge, the annotation store, the dev server) belongs to the
    /// workstream rather than the tab, so closing one frees nothing.
    @discardableResult
    func removeTab(_ tab: WorkspaceTab) -> Bool {
        guard let index = tabs.firstIndex(of: tab) else { return false }
        tabs.remove(at: index)

        switch tab {
        case let .browser(id):
            browserTitles.removeValue(forKey: id)
        case let .terminal(id):
            terminalTitles.removeValue(forKey: id)
        case let .editor(id):
            editorFilePaths.removeValue(forKey: id)
            editorDirtyState.removeValue(forKey: id)
        case .info, .agent, .changes, .environment:
            break
        }

        if activeTab == tab, !tabs.isEmpty {
            activeTab = tabs[min(index, tabs.count - 1)]
        }
        return true
    }

    func moveTab(dragging draggedTab: WorkspaceTab, to targetTab: WorkspaceTab) {
        tabs = reorderedCustomTabs(tabs, dragging: draggedTab, to: targetTab)
    }

    /// Drops terminal tabs whose surface no longer exists. Browser and editor
    /// tabs are kept regardless — they do not use terminal surfaces.
    ///
    /// Goes through `removeTab` so there is a single clearing rule: a filter
    /// over `tabs` alone would strand the dead terminal's title behind it.
    func reconcile(liveSurfaceIDs: Set<UUID>) {
        let deadTabs = tabs.filter { tab in
            if case let .terminal(id) = tab { return !liveSurfaceIDs.contains(id) }
            return false
        }
        guard !deadTabs.isEmpty else { return }
        // Note this differs from the primary path: a shell that exits is caught
        // by `TerminalSurfaceCache.removeTerminalTab(surfaceID:)`, which goes
        // through `removeTab` and hands the selection to the dead tab's
        // neighbour. This is the safety net for a surface that disappeared
        // without that hook running, and it lands on Agent instead — a
        // workstream being re-entered has no meaningful neighbour context.
        let activeDied = deadTabs.contains(activeTab)
        for tab in deadTabs {
            removeTab(tab)
        }
        if activeDied {
            activeTab = .agent
        }
    }

    // MARK: - Snapshot

    /// The inverse of `init(workstreamID:snapshot:)`. No production caller —
    /// kept deliberately: the round-trip test is how the seeding contract
    /// stays verified. Not dead code; do not delete.
    func snapshot() -> WorkspaceTabSnapshot {
        WorkspaceTabSnapshot(
            tabs: tabs,
            terminalCount: terminalCount,
            browserCount: browserCount,
            editorCount: editorCount,
            activeTab: activeTab,
            browserTitles: browserTitles,
            terminalTitles: terminalTitles,
            editorFilePaths: editorFilePaths,
            runStarted: runStarted,
            runStoppedManually: runStoppedManually
        )
    }
}
