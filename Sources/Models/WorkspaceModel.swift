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

    /// Dev-server state. Held here rather than in the view for the same reason
    /// the tab list is: it must survive the view going away when the user
    /// navigates to another workstream.
    @Published var runStarted: Bool
    @Published var runStoppedManually: Bool

    /// Monotonic per-kind counters. They feed `derivedUUID` salts, so they must
    /// never rewind on close — a reused salt would collide with a surface the
    /// cache still holds.
    private(set) var terminalCount: Int
    private(set) var browserCount: Int
    private(set) var editorCount: Int

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

    /// Changes is a fixed tab that is always present — activating is all there is.
    func activateChanges() {
        activeTab = .changes
    }

    private func appendAndActivate(_ tab: WorkspaceTab) {
        tabs.append(tab)
        activeTab = tab
    }

    // MARK: - Closing and reordering

    /// Removes a tab and its per-tab state, moving the selection to a neighbour
    /// if the removed tab was active. Returns false when the tab is not open,
    /// so callers can skip their own teardown.
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
        case .info, .agent, .changes:
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
    func reconcile(liveSurfaceIDs: Set<UUID>) {
        tabs = tabs.filter { tab in
            if case let .terminal(id) = tab { return liveSurfaceIDs.contains(id) }
            return true
        }
        if !tabs.contains(activeTab) {
            activeTab = .agent
        }
    }

    // MARK: - Snapshot

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
