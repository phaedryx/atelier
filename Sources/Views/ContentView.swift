// ABOUTME: Main application view composing the sidebar and terminal content area.
// ABOUTME: Uses NavigationSplitView for the sidebar/detail pattern.

import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "atelier", category: "content-view")

extension Notification.Name {
    static let workstreamCreated = Notification.Name("atelier.workstreamCreated")
    static let workstreamWorktreeReady = Notification.Name("atelier.workstreamWorktreeReady")
    static let workstreamCreationFailed = Notification.Name("atelier.workstreamCreationFailed")
    static let projectCreated = Notification.Name("atelier.projectCreated")
    static let purgeWorkstream = Notification.Name("atelier.purgeWorkstream")
}

final class ProjectList: ObservableObject {
    @Published var items: [Project]

    init() {
        items = ProjectStore.load()
    }
}

func workstreamHasUsablePath(_ workstream: Workstream, pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
    guard let worktreePath = workstream.worktreePath else { return false }
    return pathExists(worktreePath)
}

func renderableWorkstreamID(
    in project: Project,
    selectedWorkstreamID: UUID?,
    pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> UUID? {
    guard let selectedWorkstreamID else { return nil }
    return project.workstreams.contains {
        $0.id == selectedWorkstreamID && workstreamHasUsablePath($0, pathExists: pathExists)
    } ? selectedWorkstreamID : nil
}

func cycledWorkstreamID(
    in project: Project,
    selectedWorkstreamID: UUID?,
    direction: Int,
    pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> UUID? {
    let sorted = project.workstreams
        .filter { workstreamHasUsablePath($0, pathExists: pathExists) }
        .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    guard !sorted.isEmpty else { return nil }
    guard let selectedWorkstreamID,
          let currentIndex = sorted.firstIndex(where: { $0.id == selectedWorkstreamID })
    else {
        return direction > 0 ? sorted.first?.id : sorted.last?.id
    }
    let next = (currentIndex + direction + sorted.count) % sorted.count
    return sorted[next].id
}

func commandKeyNotification(charactersIgnoringModifiers: String?, modifierFlags: NSEvent.ModifierFlags) -> Notification.Name? {
    guard let charactersIgnoringModifiers else { return nil }
    let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return nil }
    let hasShift = flags.contains(.shift)

    switch (charactersIgnoringModifiers, hasShift) {
    case ("[", false): return .prevWorkstream
    case ("]", false): return .nextWorkstream
    case ("[", true): return .prevTab
    case ("]", true): return .nextTab
    case ("w", false): return .closeTerminal
    default: return nil
    }
}

struct ContentView: View {
    @StateObject private var projectList = ProjectList()
    @State private var selection: SidebarSelection? = SidebarSelection.loadSaved() ?? ContentView.initialSelection()
    @State private var selectionBeforeSettings: SidebarSelection?

    private var projects: [Project] {
        get { projectList.items }
        nonmutating set { projectList.items = newValue }
    }

    @StateObject private var surfaceCache = TerminalSurfaceCache()
    @StateObject private var appEnvironment = AppEnvironment()
    @StateObject private var usageStore = UsageStore()
    @ObservedObject private var agentStateTracker = WorkstreamAgentStateTracker.shared
    @State private var saveWork: DispatchWorkItem?
    @State private var workstreamToRemove: UUID?
    @State private var workstreamToPurge: UUID?
    @State private var purgeWarningMessage: String?
    @State private var removedProjectNames: [String] = []
    @State private var keyMonitorInstalled = false
    @StateObject private var commandRegistry = CommandRegistry(commands: defaultPaletteCommands())
    @State private var showCommandPalette = false
    /// Watches each worktree's git dir so `git branch -m` lands in the sidebar
    /// immediately. Built once here and reconciled by `syncHeadWatcher`.
    @State private var headWatcher: WorktreeHeadWatcher?
    @AppStorage("atelier.editorTabActive") private var editorTabActive: Bool = false

    private var paletteContext: PaletteContext {
        PaletteContext(
            workstreamActive: activeWorkstream != nil,
            editorActive: editorTabActive,
            // Requires a live agent surface, not just a selected workstream:
            // the workspace is unmounted while a worktree is still being
            // created, and a surface is never built when the setup script is
            // awaiting approval or claude isn't installed. Running a prompt in
            // any of those states would silently do nothing.
            agentCanReceivePrompt: activeWorkstream.map {
                PromptInjector.shared.canDeliver(to: $0.id)
            } ?? false
        )
    }

    private static func initialSelection() -> SidebarSelection? {
        let projects = ProjectStore.load()
        guard let mostRecent = projects.max(by: { $0.lastAccessedAt < $1.lastAccessedAt }) else { return nil }
        return .project(mostRecent.id)
    }

    private var activeProject: Project? {
        guard let selection else {
            logger.warning("[Atelier] activeProject: selection is nil")
            return nil
        }
        switch selection {
        case let .project(id):
            let found = projects.first(where: { $0.id == id })
            if found == nil { logger.warning("[Atelier] activeProject: project \(id, privacy: .public) not found in \(projects.count, privacy: .public) projects") }
            return found
        case let .workstream(wsID):
            let found = projects.first(where: { $0.workstreams.contains(where: { $0.id == wsID }) })
            if found == nil { logger.warning("[Atelier] activeProject: workstream \(wsID, privacy: .public) not found in any project") }
            return found
        case .settings, .help:
            return nil
        }
    }

    private var activeWorkstream: Workstream? {
        guard let wsID = selection?.workstreamID,
              let project = activeProject else { return nil }
        return project.workstreams.first(where: { $0.id == wsID })
    }

    @ViewBuilder
    private var detailView: some View {
        if selection == .settings {
            SettingsView()
                .navigationTitle("Settings")
                .navigationSubtitle(AppConstants.appName)
        } else if selection == .help {
            HelpView()
                .navigationTitle("Help")
                .navigationSubtitle(AppConstants.appName)
        } else if let workstream = activeWorkstream, let project = activeProject {
            if let workstreamID = renderableWorkstreamID(in: project, selectedWorkstreamID: workstream.id) {
                let workspaceModel = surfaceCache.workspaceModel(
                    for: workstreamID,
                    seed: startupWorkspaceTabState(
                        savedTab: WorkspaceStateStore.load(for: workstreamID)
                    )
                )
                TerminalContainerView(
                    workstreamID: workstreamID,
                    workingDirectory: workstream.workingDirectory(projectDirectory: project.directory),
                    projectDirectory: project.directory,
                    projectName: project.name,
                    workstreamName: workstream.name,
                    workstreamLabel: workstream.label,
                    bypassPermissions: workstream.bypassPermissions,
                    isActive: true,
                    model: workspaceModel
                )
                .id(workstreamID)
                .navigationTitle(appEnvironment.taskDescription(for: workstream.worktreePath) ?? workstream.label)
                .navigationSubtitle(workstreamSubtitle(project: project, workstream: workstream))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing workstream...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(appEnvironment.taskDescription(for: workstream.worktreePath) ?? workstream.label)
                .navigationSubtitle(workstreamSubtitle(project: project, workstream: workstream))
            }
        } else if let project = activeProject,
                  let projectIndex = projects.firstIndex(where: { $0.id == project.id })
        {
            ProjectOverviewView(
                project: $projectList.items[projectIndex],
                onSelectWorkstream: { wsID in selection = .workstream(wsID) },
                onRemoveWorkstream: { wsID in workstreamToRemove = wsID },
                onPurgeWorkstream: { wsID in confirmPurge(wsID) },
                onProjectChanged: {
                    ProjectStore.save(projects)
                    syncHeadWatcher(projects: projects)
                }
            )
            .navigationTitle(project.name)
            .navigationSubtitle(AppConstants.appName)
        } else {
            OnboardingView(toolStatus: appEnvironment.toolStatus, isDetecting: appEnvironment.isDetecting)
                .navigationTitle(AppConstants.appName)
        }
    }

    var body: some View {
        navigationView
            .overlay { commandPaletteOverlay }
            .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
                showCommandPalette.toggle()
            }
            // @Published replays the current prompts on subscription, so this
            // both seeds the registry at launch and rebuilds it on every edit.
            .onReceive(StoredPromptStore.shared.$prompts) { prompts in
                commandRegistry.sync(
                    idPrefix: storedPromptCommandPrefix,
                    with: promptPaletteCommands(for: prompts)
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openHelp)) { _ in
                if selection == .help {
                    selection = selectionBeforeSettings
                } else {
                    selectionBeforeSettings = selection
                    selection = .help
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { note in
                if let pane = SettingsPane.deepLinkTarget(from: note) {
                    // A pane-targeted open always lands on that pane; it never
                    // toggles settings closed like the plain menu action does.
                    UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.storageKey)
                    if selection != .settings {
                        selectionBeforeSettings = selection
                        selection = .settings
                    }
                } else if selection == .settings {
                    selection = selectionBeforeSettings
                } else {
                    selection = .settings
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearProjects)) { _ in
                for project in projects {
                    for ws in project.workstreams {
                        surfaceCache.removeWorkstreamSurfaces(for: ws.id)
                        agentStateTracker.clear(workstreamID: ws.id)
                    }
                }
                projects.removeAll()
                selectionBeforeSettings = nil
                selection = .settings
                ProjectStore.save([])
            }
            .onReceive(NotificationCenter.default.publisher(for: .openExternalTerminal)) { _ in
                openExternalTerminal()
            }
            .onChange(of: projectList.items) { _, newValue in
                // Debounce saves to avoid rapid I/O from activity updates
                saveWork?.cancel()
                let work = DispatchWorkItem { ProjectStore.save(newValue) }
                saveWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                refreshAgentStateLookup(projects: newValue)
                syncHeadWatcher(projects: newValue)
                syncShortcutStoryIDs(projects: newValue)
            }
            .alert(
                "Remove Workstream",
                isPresented: Binding(
                    get: { workstreamToRemove != nil },
                    set: { if !$0 { workstreamToRemove = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { workstreamToRemove = nil }
                Button("Remove", role: .destructive) {
                    performRemove()
                }
            } message: {
                Text("Ongoing terminals and Coding Agent sessions will be killed. The worktree and its files will remain on disk.")
            }
            .alert(
                "Purge Workstream",
                isPresented: Binding(
                    get: { workstreamToPurge != nil },
                    set: { if !$0 { workstreamToPurge = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { workstreamToPurge = nil }
                Button(purgeWarningMessage != nil ? "Purge Anyway" : "Purge", role: .destructive) {
                    performPurge()
                }
            } message: {
                if let warning = purgeWarningMessage {
                    Text(warning)
                } else {
                    Text("The worktree and its branch will be permanently deleted.")
                }
            }
            .alert(
                "Projects Not Found",
                isPresented: Binding(
                    get: { !removedProjectNames.isEmpty },
                    set: { if !$0 { removedProjectNames = [] } }
                )
            ) {
                Button("OK") { removedProjectNames = [] }
            } message: {
                Text(String(format: NSLocalizedString("The following projects were removed because their directories no longer exist on disk: %@", comment: ""), removedProjectNames.joined(separator: ", ")))
            }
    }

    private var navigationView: some View {
        navigationViewBase
            .onChange(of: appEnvironment.missingProjectIDs) { _, missing in
                guard !missing.isEmpty else { return }
                logger.warning("[Atelier] missingProjectIDs changed: \(missing.count, privacy: .public) missing, \(projects.count, privacy: .public) total projects")
                let names = projects.filter { missing.contains($0.id) }.map(\.name)
                logger.warning("[Atelier] removing projects: \(names, privacy: .public)")
                for id in missing {
                    if let project = projects.first(where: { $0.id == id }) {
                        for ws in project.workstreams {
                            surfaceCache.removeWorkstreamSurfaces(for: ws.id)
                            agentStateTracker.clear(workstreamID: ws.id)
                        }
                    }
                }
                projects.removeAll { missing.contains($0.id) }
                if let sel = selection, case let .project(pid) = sel, missing.contains(pid) {
                    selection = nil
                }
                if let sel = selection, case .workstream = sel, activeProject == nil {
                    selection = nil
                }
                ProjectStore.save(projects)
                removedProjectNames = names
            }
            .onChange(of: selection) { oldValue, newValue in
                logger.warning("[Atelier] selection changed: \(String(describing: oldValue), privacy: .public) -> \(String(describing: newValue), privacy: .public)")
                if newValue == .settings || newValue == .help {
                    selectionBeforeSettings = oldValue
                }
                // Don't persist settings/help as saved selection
                if newValue != .settings && newValue != .help {
                    newValue?.save()
                }
                let wsID: UUID? = {
                    if case let .workstream(id) = newValue { return id }
                    return nil
                }()
                agentStateTracker.currentSelection = wsID
                if let wsID { agentStateTracker.markSeen(workstreamID: wsID) }
            }
            .onKeyPress(.escape) {
                if selection == .settings || selection == .help {
                    selection = selectionBeforeSettings
                    return .handled
                }
                return .ignored
            }
            .onAppear {
                // Intercept Cmd+W at the app level to close tabs instead of the window
                guard !keyMonitorInstalled else { return }
                keyMonitorInstalled = true
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if let notification = commandKeyNotification(
                        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                        modifierFlags: event.modifierFlags
                    ) {
                        NotificationCenter.default.post(name: notification, object: nil)
                        return nil // swallow the event
                    }
                    return event
                }
            }
    }

    private var navigationViewBase: some View {
        NavigationSplitView {
            ProjectSidebar(
                projects: $projectList.items,
                selection: $selection,
                onProjectsChanged: {
                    ProjectStore.save(projects)
                    syncHeadWatcher(projects: projects)
                }
            )
            .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 350)
        } detail: {
            detailView
        }
        .environmentObject(surfaceCache)
        .environmentObject(appEnvironment)
        .environmentObject(usageStore)
        .environmentObject(agentStateTracker)
        .onAppear {
            // The nudge and prompt injector need the live surfaces this cache
            // owns; it is a @StateObject here rather than a singleton.
            AgentNudge.shared.surfaceCache = surfaceCache
            PromptInjector.shared.surfaceCache = surfaceCache
            appEnvironment.refresh()
            appEnvironment.refreshAllRepoInfo(projects: projects)
            appEnvironment.refreshPathValidity(projects: projects)
            appEnvironment.fetchOrigin(projects: projects)
            Task { await usageStore.refresh() }
            refreshAgentStateLookup(projects: projects)
            startHeadWatcher()
            // Apply saved appearance
            switch UserDefaults.standard.string(forKey: "atelier.appearance") ?? "system" {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToProject)) { _ in
            // Go back to project view from any workstream
            if let wsID = selection?.workstreamID,
               let project = projects.first(where: { $0.workstreams.contains(where: { $0.id == wsID }) })
            {
                selection = .project(project.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextWorkstream)) { _ in
            cycleWorkstream(direction: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .prevWorkstream)) { _ in
            cycleWorkstream(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextProject)) { _ in
            cycleProject(direction: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .prevProject)) { _ in
            cycleProject(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .archiveWorkstream)) { _ in
            if let wsID = selection?.workstreamID {
                workstreamToRemove = wsID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workstreamCreated)) { notification in
            guard let info = notification.userInfo,
                  let projectID = info["projectID"] as? UUID,
                  let workstream = info["workstream"] as? Workstream,
                  let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[index].workstreams.append(workstream)
            selection = .workstream(workstream.id)
            ProjectStore.save(projects)
            logger.warning("[Atelier] workstreamCreated notification handled: \(workstream.name, privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .workstreamWorktreeReady)) { notification in
            guard let info = notification.userInfo,
                  let workstreamID = info["workstreamID"] as? UUID,
                  let worktreePath = info["worktreePath"] as? String else { return }
            for pi in projects.indices {
                if let wi = projects[pi].workstreams.firstIndex(where: { $0.id == workstreamID }) {
                    projects[pi].workstreams[wi].worktreePath = worktreePath
                    ProjectStore.save(projects)
                    appEnvironment.refreshPathValidity(projects: projects)
                    // Project/Workstream equate by id only, so onChange(of: projectList.items)
                    // doesn't fire when worktreePath flips from nil to a real value. Refresh
                    // the agent-state lookup explicitly so hook events for this new workstream
                    // can resolve to its UUID.
                    refreshAgentStateLookup(projects: projects)
                    // Same reason: a brand-new worktree is exactly the one whose
                    // branch the agent is about to rename, so it has to start
                    // being watched now rather than on some later mutation.
                    syncHeadWatcher(projects: projects)
                    // And again: this is the moment a Shortcut workstream first has a path
                    // to key its story by. Without this the story staged at creation is
                    // never promoted and the info tab shows nothing for the whole session.
                    syncShortcutStoryIDs(projects: projects)
                    logger.warning("[Atelier] workstreamWorktreeReady: updated \(workstreamID, privacy: .public) with path \(worktreePath, privacy: .public)")
                    // Run the project's `bootstrap` namespace in the background.
                    let projectPath = projects[pi].directory
                    // Names, not just paths: bootstrap runs with the same
                    // `ATELIER_PROJECT` / `ATELIER_WORKSTREAM` the workstream's
                    // terminals get, and only the project model knows them.
                    let projectName = projects[pi].name
                    let workstreamName = projects[pi].workstreams[wi].name
                    Task {
                        await AsyncSetupService.shared.setupExistingWorktree(
                            workstreamID: workstreamID,
                            projectName: projectName,
                            workstreamName: workstreamName,
                            projectPath: projectPath,
                            worktreePath: worktreePath
                        )
                    }
                    return
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workstreamCreationFailed)) { notification in
            guard let info = notification.userInfo,
                  let projectID = info["projectID"] as? UUID,
                  let workstreamID = info["workstreamID"] as? UUID,
                  let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[pi].workstreams.removeAll { $0.id == workstreamID }
            if case let .workstream(selectedID) = selection, selectedID == workstreamID {
                selection = .project(projectID)
            }
            ProjectStore.save(projects)
            logger.warning("[Atelier] workstreamCreationFailed: removed \(workstreamID, privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectCreated)) { notification in
            guard let project = notification.userInfo?["project"] as? Project else { return }
            projects.append(project)
            selection = .project(project.id)
            ProjectStore.save(projects)
            appEnvironment.refreshPathValidity(projects: projects)
            appEnvironment.refreshAllRepoInfo(projects: projects)
            logger.warning("[Atelier] projectCreated notification handled: \(project.name, privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .purgeWorkstream)) { notification in
            if let wsID = notification.object as? UUID {
                confirmPurge(wsID)
            }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            appEnvironment.refreshAllRepoInfo(projects: projects)
            appEnvironment.refreshPathValidity(projects: projects)
            appEnvironment.refreshAllBranchPRs(projects: projects)
            appEnvironment.fetchOrigin(projects: projects)
            syncWorkstreamNamesFromBranches()
        }
        .modifier(UsagePolling(store: usageStore))
    }

    /// The palette lives in its own property: `navigationViewBase`'s modifier
    /// chain is long enough that inlining the ZStack tips the type checker over
    /// its time limit.
    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if showCommandPalette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { showCommandPalette = false }
                CommandPaletteView(
                    registry: commandRegistry,
                    context: paletteContext,
                    onDismiss: { showCommandPalette = false }
                )
                .padding(.top, 120)
            }
            .transition(.opacity)
        }
    }

    /// Rebuilds the projectDir → workstream-UUID lookup used by the agent
    /// state tracker. Paths are normalized via `WorkstreamAgentStateTracker.normalize`
    /// (resolves symlinks) so hook payloads match regardless of how Claude
    /// reports the path on macOS.
    private func refreshAgentStateLookup(projects: [Project]) {
        var index: [String: UUID] = [:]
        for project in projects {
            for ws in project.workstreams {
                guard let path = ws.worktreePath else { continue }
                index[WorkstreamAgentStateTracker.normalize(path)] = ws.id
            }
        }
        agentStateTracker.workstreamLookup = { projectDir in
            index[WorkstreamAgentStateTracker.normalize(projectDir)]
        }
    }

    private func workstreamSubtitle(project: Project, workstream: Workstream) -> String {
        let branch = appEnvironment.branchName(for: workstream.worktreePath)
        if let branch {
            return "\(project.name) · \(branch)"
        }
        return project.name
    }

    private func openExternalTerminal() {
        let dir: String?
        if let ws = activeWorkstream, let project = activeProject {
            dir = ws.workingDirectory(projectDirectory: project.directory)
        } else if let project = activeProject {
            dir = project.directory
        } else {
            dir = nil
        }
        guard let dir else { return }
        let terminalBundleID = UserDefaults.standard.string(forKey: "atelier.defaultTerminal") ?? ""
        if !terminalBundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID)
        {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: appURL, configuration: config)
        } else if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: terminalURL, configuration: config)
        }
    }

    /// Creates the HEAD watcher and points it at the current worktrees.
    ///
    /// The callback arrives on the watcher's queue for any git activity in the
    /// worktree, not just a rename, so it hops to the main actor and does the
    /// cheapest possible thing: re-read that one branch. The 15s poll still
    /// runs and remains the backstop for anything the vnode watch misses.
    private func startHeadWatcher() {
        guard headWatcher == nil else { return }
        let watcher = WorktreeHeadWatcher { worktreePath in
            Task { @MainActor in
                await appEnvironment.refreshBranchName(for: worktreePath)
                // Runs whether or not that published anything: the 15s poll
                // writes the same cache, so it can land the new branch first
                // and leave the refresh above with nothing to do — and the
                // sidebar name would then stay stale until the next tick. This
                // is an in-memory walk that saves only on a real change.
                syncWorkstreamNamesFromBranches()
            }
        }
        headWatcher = watcher
        syncHeadWatcher(projects: projects)
        syncShortcutStoryIDs(projects: projects)
    }

    /// Reconcile the watched worktrees.
    ///
    /// Must be called explicitly from every path that adds or removes a
    /// workstream. `onChange(of: projectList.items)` is not enough: Project and
    /// Workstream equate by id only, so a list with a workstream removed still
    /// compares equal to the list before it and the observer never fires.
    /// Missing a removal leaks a resumed DispatchSource and an open descriptor
    /// on a worktree nobody is watching for any more.
    private func syncHeadWatcher(projects: [Project]) {
        let paths = Set(projects.flatMap { $0.workstreams.compactMap(\.worktreePath) })
        headWatcher?.sync(paths: paths)
    }

    /// Teach `AppEnvironment` which worktree belongs to which Shortcut story.
    ///
    /// The story id lives on `Workstream`, but the info tab is a props view that never
    /// receives one, so the mapping has to be pushed here — this is the only place that
    /// holds both the project list and a reference to the environment.
    private func syncShortcutStoryIDs(projects: [Project]) {
        var livePaths: Set<String> = []
        for project in projects {
            for ws in project.workstreams {
                guard let path = ws.worktreePath, let storyID = ws.shortcutStoryID else { continue }
                livePaths.insert(path)
                appEnvironment.registerShortcutStory(id: storyID, for: path)
            }
        }
        // Reconcile rather than only insert, the way syncHeadWatcher does — otherwise an
        // archived workstream's story lingers and can surface on a reused path.
        appEnvironment.pruneShortcutStories(keeping: livePaths)
    }

    /// Update workstream names to match their branch name.
    /// Called periodically so that when the agent renames a branch, the sidebar reflects it.
    private func syncWorkstreamNamesFromBranches() {
        var changed = false
        for pi in projects.indices {
            for wi in projects[pi].workstreams.indices {
                let ws = projects[pi].workstreams[wi]
                guard let branch = appEnvironment.branchName(for: ws.worktreePath) else { continue }
                if branch != ws.name {
                    projects[pi].workstreams[wi].name = branch
                    changed = true
                }
            }
        }
        if changed {
            ProjectStore.save(projects)
        }
    }

    /// Cycle through workstreams within the active project.
    /// Only acts when a project or workstream is selected (not settings/help).
    private func cycleWorkstream(direction: Int) {
        guard let project = activeProject else { return }

        if selection?.workstreamID != nil || selection?.projectID != nil {
            guard let id = cycledWorkstreamID(in: project, selectedWorkstreamID: selection?.workstreamID, direction: direction) else { return }
            deferSelection(.workstream(id))
        }
    }

    private func deferSelection(_ target: SidebarSelection) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            guard selection != target else { return }
            selection = target
        }
    }

    /// Cycle through projects in sidebar display order, which is always A–Z.
    private func cycleProject(direction: Int) {
        let sorted = projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !sorted.isEmpty else { return }

        guard let current = activeProject,
              let currentIndex = sorted.firstIndex(where: { $0.id == current.id })
        else {
            // No active project: jump to first
            selection = .project(sorted.first!.id)
            return
        }
        let next = (currentIndex + direction + sorted.count) % sorted.count
        selection = .project(sorted[next].id)
    }

    private func confirmPurge(_ wsID: UUID) {
        let ws = projects.flatMap(\.workstreams).first(where: { $0.id == wsID })
        purgeWarningMessage = ws.flatMap { WorkstreamArchiver.purgeWarning(for: $0) }
        workstreamToPurge = wsID
    }

    private func performRemove() {
        guard let wsID = workstreamToRemove,
              let projectIndex = projects.firstIndex(where: { $0.workstreams.contains(where: { $0.id == wsID }) }) else { return }
        WorkstreamArchiver.remove(wsID, in: &projects[projectIndex], surfaceCache: surfaceCache, tmuxPath: appEnvironment.toolStatus.tmux.path)
        agentStateTracker.clear(workstreamID: wsID)
        ProjectStore.save(projects)
        syncHeadWatcher(projects: projects)
        workstreamToRemove = nil
    }

    private func performPurge() {
        guard let wsID = workstreamToPurge,
              let projectIndex = projects.firstIndex(where: { $0.workstreams.contains(where: { $0.id == wsID }) }) else { return }
        let projectID = projects[projectIndex].id
        WorkstreamArchiver.purge(wsID, in: &projects[projectIndex], surfaceCache: surfaceCache, tmuxPath: appEnvironment.toolStatus.tmux.path)
        agentStateTracker.clear(workstreamID: wsID)
        ProjectStore.save(projects)
        // Before anything else touches the deleted worktree: purge removes the
        // directory this was watching.
        syncHeadWatcher(projects: projects)
        if case let .workstream(id) = selection, id == wsID {
            selection = .project(projectID)
        }
        workstreamToPurge = nil
    }
}

enum ProjectStore {
    private static let userDefaultsKey = "atelier.projects"

    static func load(defaults: UserDefaults = .standard) -> [Project] {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let projects = try? JSONDecoder().decode([Project].self, from: data)
        else { return [] }
        return projects
    }

    static func save(_ projects: [Project], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }
}

/// Plan-usage polling, lifted out of `ContentView`'s modifier chain: that chain
/// is already long enough that two more inline modifiers tip the type checker
/// over its time limit.
private struct UsagePolling: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let store: UsageStore

    /// Whether any window is actually on screen. Injectable for tests.
    ///
    /// `scenePhase` alone is not enough: on macOS, hiding the app reports
    /// `.background`, but *miniaturizing* the window only reports `.inactive` —
    /// which is also what a visible-but-unfocused window reports. `isVisible`
    /// is false for both hidden and miniaturized windows, so it separates
    /// "nobody can see the meter" from "the meter just isn't frontmost".
    var isOnScreen: () -> Bool = { NSApp.windows.contains(where: \.isVisible) }

    /// Matches `UsageStore`'s own throttle, so a tick that lands early is a
    /// cheap no-op rather than a spawned process.
    private static let interval: TimeInterval = 300

    func body(content: Content) -> some View {
        content
            .onReceive(Timer.publish(every: Self.interval, on: .main, in: .common).autoconnect()) { _ in
                // Each tick spawns a `claude` process. Skip it when no window is
                // on screen — nobody can read the meter, and the phase change
                // below catches up when one comes back.
                guard isOnScreen() else { return }
                Task { await store.refresh() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Back on screen: the meter may be a full interval stale.
                // `refresh()` is still throttled, so this stays cheap.
                guard phase == .active else { return }
                Task { await store.refresh() }
            }
    }
}
