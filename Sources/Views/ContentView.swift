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
    /// object: the workstream's `UUID`. Posted by `Workstream.AgentStateTracker`
    /// on the edges into and out of a permission block; received here, where the
    /// workstream's name and the current selection are known.
    static let agentBlockedOnPermission = Notification.Name("atelier.agentBlockedOnPermission")
    static let agentPermissionResolved = Notification.Name("atelier.agentPermissionResolved")
    /// object: the workstream's `UUID`. Posted when a blocked-agent notification
    /// is clicked, so the sidebar selects the workstream that was waiting.
    static let focusWorkstream = Notification.Name("atelier.focusWorkstream")
    /// object: the project's `UUID`. The named-destination counterpart to
    /// `.switchToProject`, which carries no payload and can only mean "the
    /// project the selected workstream belongs to".
    static let focusProject = Notification.Name("atelier.focusProject")
    /// object: the worktree path (`String`), from `Worktree.HeadWatcher`'s own
    /// callback in `startHeadWatcher`. A hint, not a diff, exactly as the
    /// watcher's own doc says: any git activity in that worktree, not only a
    /// branch change. `VerificationTabView` is the first consumer — it uses
    /// this to know when a worktree's uncommitted content may have moved, so
    /// it can recompute staleness without polling `git hash-object` on a
    /// timer. The subscription lives only as long as the view does, which is
    /// what confines it to "while the tab is visible" with no extra state.
    static let worktreeGitActivity = Notification.Name("atelier.worktreeGitActivity")
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

/// The workstream ⌘[ / ⌘] lands on next.
///
/// `order` has no default on purpose: it must be the same `Project.SortOrder` the
/// sidebar drew with, and a default here would let a caller silently walk the rows
/// in an order nobody is looking at.
func cycledWorkstreamID(
    in project: Project,
    selectedWorkstreamID: UUID?,
    direction: Int,
    order: Project.SortOrder,
    pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> UUID? {
    let sorted = order.sorted(
        project.workstreams.filter { workstreamHasUsablePath($0, pathExists: pathExists) }
    )
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

    // charactersIgnoringModifiers strips every modifier except Shift, so the
    // shifted brackets arrive as "{" / "}" — matching "[" / "]" there never fired.
    switch (charactersIgnoringModifiers, hasShift) {
    case ("[", false): return .prevWorkstream
    case ("]", false): return .nextWorkstream
    case ("{", true): return .prevTab
    case ("}", true): return .nextTab
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
    @StateObject private var usageStore = Usage.Store()
    /// One runner for the app's lifetime, not one per tab.
    ///
    /// `<id>-verify.sock` admits exactly one server, so "one run per
    /// workstream" needs a single enforcement point — see
    /// `Verification.Runner`'s own doc. Held here, beside the other app-level
    /// services, and handed to `TerminalContainerView` as a plain `let`: the
    /// Verification tab observes it through its own `@ObservedObject`, and a
    /// runner owned by the tab would lose every run the moment the tab closed
    /// or the user switched workstreams.
    ///
    /// **`@State`, not `@StateObject`, and the difference is not cosmetic.**
    /// Both give the object this view's lifetime; only `@StateObject`
    /// subscribes to it. Nothing here renders from the runner, so a
    /// subscription would re-evaluate this whole body on every `runs` publish —
    /// about once a second for the length of a run — and each re-evaluation
    /// re-initialises `TerminalContainerView`, whose `init` eagerly resolves
    /// the dev command and so locates a process-compose config. `@State` keeps
    /// the lifetime and drops the subscription.
    @State private var verificationRunner = Verification.Runner()
    @ObservedObject private var agentStateTracker = Workstream.AgentStateTracker.shared
    @ObservedObject private var channelProbe = HookChannelProbe.shared
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
    @State private var headWatcher: Worktree.HeadWatcher?
    @AppStorage("atelier.editorTabActive") private var editorTabActive: Bool = false
    @AppStorage(Workstream.PermissionNotifier.enabledKey) private var notifyOnPermission: Bool = true
    /// Must agree with the sidebar's own copy — ⌘[ / ⌘] walks the rows the sidebar drew.
    @AppStorage(Project.SortOrder.storageKey) private var workstreamSortOrder: Project.SortOrder = .recent

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
            if found == nil {
                logger.warning("[Atelier] activeProject: project \(id, privacy: .public) not found in \(projects.count, privacy: .public) projects")
            }
            return found
        case let .workstream(wsID):
            let found = projects.first(where: { $0.workstreams.contains(where: { $0.id == wsID }) })
            if found == nil {
                logger.warning("[Atelier] activeProject: workstream \(wsID, privacy: .public) not found in any project")
            }
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
                    workingDirectory: workstream.workingDirectory(checkout: project.checkout),
                    projectDirectory: project.directory,
                    projectName: project.name,
                    workstreamName: workstream.name,
                    workstreamLabel: workstream.label,
                    bypassPermissions: workstream.bypassPermissions,
                    isActive: true,
                    model: workspaceModel,
                    verificationRunner: verificationRunner
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
            // Same shape, same reason: `@Published` replays the current list on
            // subscription, so this seeds the go-to family at launch and
            // rebuilds it whenever a project or workstream is added, renamed or
            // removed. Subscribing to the publisher rather than `onChange(of:)`
            // is what gets the launch seeding for free.
            .onReceive(projectList.$items) { items in
                syncGotoCommands(projects: items)
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
                    set: {
                        if !$0 {
                            workstreamToRemove = nil
                        }
                    }
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
                    set: {
                        if !$0 {
                            workstreamToPurge = nil
                        }
                    }
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
                    set: {
                        if !$0 {
                            removedProjectNames = []
                        }
                    }
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
                if newValue != .settings, newValue != .help {
                    newValue?.save()
                }
                let wsID: UUID? = {
                    if case let .workstream(id) = newValue {
                        return id
                    }
                    return nil
                }()
                agentStateTracker.currentSelection = wsID
                if let wsID {
                    agentStateTracker.markSeen(workstreamID: wsID)
                }
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

    /// The split view and the receivers that change what is *selected*.
    ///
    /// Split out of `navigationViewBase` below, and it has to stay split: the
    /// two together are one modifier chain of twenty-odd `.onReceive`s, and the
    /// Swift type-checker gives up on it ("unable to type-check this expression
    /// in reasonable time"). Adding a receiver to either half is fine; merging
    /// them back is not.
    private var selectionReceivingSplitView: some View {
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
        .environmentObject(channelProbe)
        .onAppear {
            // The nudge and prompt injector need the live surfaces this cache
            // owns; it is a @StateObject here rather than a singleton.
            AgentNudge.shared.surfaceCache = surfaceCache
            PromptInjector.shared.surfaceCache = surfaceCache
            // The IPC workspace tools reach the live app through the same weak
            // references; `IPC.Service` is an actor with no view hierarchy.
            WorkspaceActions.shared.surfaceCache = surfaceCache
            WorkspaceActions.shared.projectList = projectList
            WorkspaceActions.shared.appEnvironment = appEnvironment
            // `start_verification` and `check_verification` act through the same
            // runner the Verification tab does — one run per workstream needs one
            // enforcement point. Built here because the bridge takes `onFinish`,
            // which is a single slot: constructing a second one would silently
            // unsubscribe the first.
            let verificationBridge = IPC.VerificationRunnerBridge(runner: verificationRunner)
            Task { await IPC.Service.shared.setVerificationRunner(verificationBridge) }
            // Creating a workstream needs the same list, and stays out of
            // `WorkspaceActions` on purpose: it is a workstream-lifecycle
            // operation the sidebar could route through too, and an IPC-named
            // type owning it would point the dependency the wrong way.
            Workstream.Launcher.shared.projectList = projectList
            appEnvironment.refresh()
            appEnvironment.refreshAllRepoInfo(projects: projects)
            appEnvironment.refreshPathValidity(projects: projects)
            // Costs nothing for a store with no stranded record, which is the
            // normal case; see the doc for the four ways it stays cheap.
            reconcileStrandedWorkstreams()
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
        .onReceive(NotificationCenter.default.publisher(for: .agentBlockedOnPermission)) { notification in
            guard let wsID = notification.object as? UUID else { return }
            notifyAgentBlocked(wsID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentPermissionResolved)) { notification in
            guard let wsID = notification.object as? UUID else { return }
            Workstream.PermissionNotifier.shared.withdraw(workstreamID: wsID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusWorkstream)) { notification in
            guard let wsID = notification.object as? UUID,
                  projects.contains(where: { $0.workstreams.contains(where: { $0.id == wsID }) })
            else { return }
            selection = .workstream(wsID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusProject)) { notification in
            focusProject(from: notification)
        }
    }

    /// The rest of the chain: cycling, workstream lifecycle, and the polls.
    /// See `selectionReceivingSplitView` above for why this is two properties.
    private var navigationViewBase: some View {
        selectionReceivingSplitView
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
                // Every UI producer of this notification is a button the user
                // just pressed, so selecting is the right default and they omit
                // the key. `Workstream.Launcher` passes false: an agent creating
                // a workstream over IPC must not pull the user out of the pane
                // they are in. The row still appears here immediately, so the
                // creation is visible without being disruptive.
                if info["select"] as? Bool ?? true {
                    selection = .workstream(workstream.id)
                }
                ProjectStore.save(projects)
                logger.warning("[Atelier] workstreamCreated notification handled: \(workstream.name, privacy: .public)")
            }
            .onReceive(NotificationCenter.default.publisher(for: .workstreamWorktreeReady)) { notification in
                guard let info = notification.userInfo,
                      let workstreamID = info["workstreamID"] as? UUID,
                      let worktreePath = info["worktreePath"] as? String,
                      let found = attachWorktreePath(worktreePath, to: workstreamID) else { return }
                logger.warning("[Atelier] workstreamWorktreeReady: updated \(workstreamID, privacy: .public) with path \(worktreePath, privacy: .public)")
                // Run the project's `bootstrap` namespace in the background. This is
                // the half `attachWorktreePath` deliberately leaves to its callers —
                // see its doc for why a repair must not do it.
                let projectPath = projects[found.project].directory
                // Names, not just paths: bootstrap runs with the same
                // `ATELIER_PROJECT` / `ATELIER_WORKSTREAM` the workstream's
                // terminals get, and only the project model knows them.
                let projectName = projects[found.project].name
                let workstreamName = projects[found.project].workstreams[found.workstream].name
                Task {
                    await AsyncSetupService.shared.setupExistingWorktree(
                        workstreamID: workstreamID,
                        projectName: projectName,
                        workstreamName: workstreamName,
                        projectPath: projectPath,
                        worktreePath: worktreePath
                    )
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
    /// state tracker. Paths are normalized via `Workstream.AgentStateTracker.normalize`
    /// (resolves symlinks) so hook payloads match regardless of how Claude
    /// reports the path on macOS.
    /// Writes a resolved worktree path onto a workstream, and runs everything that
    /// has to happen the moment a workstream first has one — **except**
    /// `bootstrap`.
    ///
    /// Two callers, and the exclusion is the reason this is a helper rather than a
    /// copy. `.workstreamWorktreeReady` runs `bootstrap` itself afterwards, because
    /// the worktree it is announcing was created seconds ago and has never been set
    /// up. `reconcileStrandedWorkstreams` must not: the worktree it repairs predates
    /// this launch, so its `bootstrap` either ran or was declined, and re-running a
    /// repository's own commands unprompted at startup is not a repair's business.
    /// The Info tab's Re-run is how a user asks for that.
    ///
    /// The five side effects below are all here for the same underlying reason:
    /// `Project` and `Workstream` equate by id alone, so flipping `worktreePath`
    /// from nil to a path fires no `onChange(of:)` and nothing downstream notices
    /// on its own.
    ///
    /// Returns where the workstream was found so a caller needing the project's own
    /// fields does not search for it twice.
    @discardableResult
    private func attachWorktreePath(
        _ worktreePath: String,
        to workstreamID: UUID
    ) -> (project: Int, workstream: Int)? {
        guard let pi = projects.firstIndex(where: { project in
            project.workstreams.contains { $0.id == workstreamID }
        }),
            let wi = projects[pi].workstreams.firstIndex(where: { $0.id == workstreamID })
        else { return nil }

        projects[pi].workstreams[wi].worktreePath = worktreePath
        ProjectStore.save(projects)
        appEnvironment.refreshPathValidity(projects: projects)
        // So hook events for this workstream can resolve to its UUID.
        refreshAgentStateLookup(projects: projects)
        // A newly-pathed worktree is exactly the one whose branch an agent is about
        // to rename, so it has to start being watched now.
        syncHeadWatcher(projects: projects)
        // And this is the moment a Shortcut workstream first has a path to key its
        // story by; without it the story staged at creation is never promoted.
        syncShortcutStoryIDs(projects: projects)
        return (pi, wi)
    }

    /// Reattaches workstreams that were persisted with no worktree path to the
    /// worktrees git actually has, and forgets the ones with nothing to attach to.
    ///
    /// This is **not** what keeps such records out of the store — `ProjectStore.save`
    /// does that, and does it for every save site at once. What this buys is *repair
    /// instead of orphan*: a record stranded before that filter existed has a real
    /// worktree sitting on disk, and without this the user's only route back to it
    /// is noticing it in the project overview and adopting it by hand, which creates
    /// a different workstream and loses the original's name, label and story id.
    ///
    /// Narrow in four ways, each of which is load-bearing:
    ///
    /// - **Only a nil path.** A path that is *set* but missing is a different
    ///   failure with the same symptom: an unmounted volume and a deleted worktree
    ///   are indistinguishable from here, and forgetting a record because a disk is
    ///   asleep destroys the row for nothing.
    /// - **One `worktree list --porcelain` per project, and only for a project that
    ///   has a stranded record** — normally none, so normally no subprocess at all.
    ///   Not `listWorktreesWithInfo`, whose per-row status probes are exactly the
    ///   launch fan-out that produced these records in the first place.
    /// - **Matched on branch, not on name.** A name freed by a purge and reused
    ///   would otherwise repair the new record onto the old worktree.
    /// - **A git failure forgets nothing.** `registeredWorktrees` returns nil rather
    ///   than an empty array when it could not ask, because "git says no such
    ///   worktree" and "git did not answer" must not both mean discard.
    ///
    /// Repairs go one at a time through `attachWorktreePath`, so N of them in one
    /// project cost N saves rather than one. Left that way on purpose: batching
    /// would mean not reusing `attachWorktreePath`, and a second copy of its five
    /// side effects is the drift this whole helper exists to prevent. N is the
    /// number of *stranded* records, normally zero; and the sweep half collapses
    /// anyway, since `refreshPathValidity` defers a request that arrives while one
    /// is running and coalesces every later one into a single follow-up.
    ///
    /// The loop iterates a snapshot of ids and names taken before the `Task`, and
    /// both mutating helpers re-look-up by id — so a repair that reshapes
    /// `projects` cannot invalidate the iteration.
    private func reconcileStrandedWorkstreams() {
        let stranded: [(checkout: String, workstreams: [(id: UUID, name: String)])] = projects.compactMap { project in
            let unresolved = project.workstreams.filter { $0.worktreePath == nil }
            guard !unresolved.isEmpty else { return nil }
            return (project.checkout, unresolved.map { ($0.id, $0.name) })
        }
        guard !stranded.isEmpty else { return }

        Task {
            for project in stranded {
                let checkout = project.checkout
                // Detached: `registeredWorktrees` spawns a child and blocks the
                // thread it runs on for its lifetime.
                let registered = await Task.detached {
                    Git.Operations.registeredWorktrees(at: checkout)
                }.value
                guard let registered else {
                    logger.warning("[Atelier] reconcile: could not list worktrees at \(checkout, privacy: .public); leaving records alone")
                    continue
                }
                var pathsByBranch: [String: String] = [:]
                for entry in registered {
                    guard let branch = entry.branch else { continue }
                    pathsByBranch[branch] = entry.path
                }

                for workstream in project.workstreams {
                    if let path = pathsByBranch[workstream.name],
                       FileManager.default.fileExists(atPath: path)
                    {
                        attachWorktreePath(path, to: workstream.id)
                        logger.warning("[Atelier] reconcile: repaired \(workstream.name, privacy: .public) -> \(path, privacy: .public)")
                    } else {
                        forgetStrandedWorkstream(workstream.id, name: workstream.name)
                    }
                }
            }
        }
    }

    /// Drops an in-memory workstream that has no path and no worktree to attach to.
    ///
    /// It is already absent from the store — `ProjectStore.save` never wrote it —
    /// so this only stops the detail pane spinning on "Preparing workstream..." for
    /// the rest of the session for a row that can never render. Same shape as the
    /// `.workstreamCreationFailed` handler, including moving the selection off it,
    /// because it is the same situation observed one launch later.
    private func forgetStrandedWorkstream(_ workstreamID: UUID, name: String) {
        guard let pi = projects.firstIndex(where: { project in
            project.workstreams.contains { $0.id == workstreamID }
        }) else { return }
        projects[pi].workstreams.removeAll { $0.id == workstreamID }
        if case let .workstream(selectedID) = selection, selectedID == workstreamID {
            selection = .project(projects[pi].id)
        }
        logger.warning("[Atelier] reconcile: no worktree for \(name, privacy: .public); forgetting the record")
    }

    private func refreshAgentStateLookup(projects: [Project]) {
        var index: [String: UUID] = [:]
        for project in projects {
            for ws in project.workstreams {
                guard let path = ws.worktreePath else { continue }
                index[Workstream.AgentStateTracker.normalize(path)] = ws.id
            }
        }
        agentStateTracker.workstreamLookup = { projectDir in
            index[Workstream.AgentStateTracker.normalize(projectDir)]
        }
    }

    /// Shows the "waiting for approval" banner for a workstream that just
    /// blocked, unless its pane is already in front of the user.
    ///
    /// The name and subtitle come from the live `projects` here rather than from
    /// the tracker, which knows workstreams only by id.
    private func notifyAgentBlocked(_ wsID: UUID) {
        guard Workstream.PermissionNotifier.shouldNotify(
            enabled: notifyOnPermission,
            isAppActive: NSApp.isActive,
            selection: selection,
            workstreamID: wsID
        ),
            let project = projects.first(where: { $0.workstreams.contains(where: { $0.id == wsID }) }),
            let workstream = project.workstreams.first(where: { $0.id == wsID })
        else { return }

        Workstream.PermissionNotifier.shared.notify(
            workstreamID: wsID,
            title: workstream.name,
            body: String(
                format: NSLocalizedString(
                    "Waiting for approval — %@",
                    comment: "Blocked-agent notification body; %@ is the project and branch"
                ),
                workstreamSubtitle(project: project, workstream: workstream)
            )
        )
    }

    private func workstreamSubtitle(project: Project, workstream: Workstream) -> String {
        let branch = appEnvironment.branchName(for: workstream.worktreePath)
        if let branch {
            return "\(project.name) · \(branch)"
        }
        return project.name
    }

    private func openExternalTerminal() {
        let dir: String? = if let ws = activeWorkstream, let project = activeProject {
            ws.workingDirectory(checkout: project.checkout)
        } else if let project = activeProject {
            project.checkout
        } else {
            nil
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
        let watcher = Worktree.HeadWatcher { worktreePath in
            Task { @MainActor in
                await appEnvironment.refreshBranchName(for: worktreePath)
                // Runs whether or not that published anything: the 15s poll
                // writes the same cache, so it can land the new branch first
                // and leave the refresh above with nothing to do — and the
                // sidebar name would then stay stale until the next tick. This
                // is an in-memory walk that saves only on a real change.
                syncWorkstreamNamesFromBranches()
                // Broadcast last, and unconditionally — a listener does not
                // know or care whether the branch name moved, only that git
                // activity happened in this worktree. See the notification's
                // own doc for why `VerificationTabView` is the reason this
                // exists.
                NotificationCenter.default.post(name: .worktreeGitActivity, object: worktreePath)
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
    /// Selects the project a `.focusProject` notification names, ignoring one
    /// that names a project no longer in the list — the go-to command family is
    /// rebuilt from that list, but a stale command could still be in flight from
    /// an open palette.
    ///
    /// Extracted rather than inlined in the modifier chain: `body`'s run of
    /// `.onReceive`s is long enough that one more multi-statement closure tips
    /// the type-checker over its time limit.
    private func focusProject(from notification: Notification) {
        guard let projectID = notification.object as? UUID,
              projects.contains(where: { $0.id == projectID })
        else { return }
        selection = .project(projectID)
    }

    /// Rebuilds the palette's go-to family from the project list. Extracted for
    /// the same reason as `focusProject(from:)` above.
    private func syncGotoCommands(projects: [Project]) {
        commandRegistry.sync(
            idPrefix: gotoCommandPrefix,
            with: gotoPaletteCommands(for: projects)
        )
    }

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
            guard let id = cycledWorkstreamID(
                in: project,
                selectedWorkstreamID: selection?.workstreamID,
                direction: direction,
                order: workstreamSortOrder
            ) else { return }
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
        purgeWarningMessage = ws.flatMap { Workstream.Archiver.purgeWarning(for: $0) }
        workstreamToPurge = wsID
    }

    private func performRemove() {
        guard let wsID = workstreamToRemove,
              let projectIndex = projects.firstIndex(where: { $0.workstreams.contains(where: { $0.id == wsID }) }) else { return }
        Workstream.Archiver.remove(wsID, in: &projects[projectIndex], surfaceCache: surfaceCache, tmuxPath: appEnvironment.toolStatus.tmux.path)
        agentStateTracker.clear(workstreamID: wsID)
        ProjectStore.save(projects)
        syncHeadWatcher(projects: projects)
        workstreamToRemove = nil
    }

    private func performPurge() {
        guard let wsID = workstreamToPurge,
              let projectIndex = projects.firstIndex(where: { $0.workstreams.contains(where: { $0.id == wsID }) }) else { return }
        let projectID = projects[projectIndex].id
        Workstream.Archiver.purge(wsID, in: &projects[projectIndex], surfaceCache: surfaceCache, tmuxPath: appEnvironment.toolStatus.tmux.path)
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

    /// Element-wise, because `save` below writes straight back over this key: a
    /// read that discarded the whole list over one unreadable project turned the
    /// user's next edit into a permanent deletion of all of them. See
    /// `LossyStore`.
    static func load(defaults: UserDefaults = .standard) -> [Project] {
        LossyStore.loadArray(Project.self, forKey: userDefaultsKey, from: defaults) ?? []
    }

    /// **Does not round-trip.** A workstream with no `worktreePath` is dropped on
    /// the way out, so a stored workstream always has one.
    ///
    /// The nil is a real and wanted *in-memory* state: `Workstream.Launcher`
    /// posts `.workstreamCreated` with no path so the sidebar row appears while
    /// `git worktree add` is still running, and `.workstreamWorktreeReady` fills
    /// it in (`ContentView`'s handlers for both). What must not happen is that
    /// transient state reaching a durable store — and it did, because the whole
    /// list is re-encoded here on *every* save, so any unrelated edit during the
    /// creation window cemented the half-made record. A quit in that window, or a
    /// `createWorktree` that succeeded on disk while `ProcessRunner` reported a
    /// deadline failure, then left a workstream that could never render:
    /// `workstreamHasUsablePath` refuses a nil path and the detail pane spins on
    /// "Preparing workstream..." forever, with nothing in the UI to repair it.
    ///
    /// Filtering here rather than in the `.workstreamCreated` handler is the
    /// point. The handler is one of many callers; the invariant belongs to the
    /// store, where no future save site can forget it. The cost of a quit
    /// mid-creation is now an in-memory row that is simply gone next launch,
    /// while the worktree — if `git` did make one — is listed in the project
    /// overview with Adopt beside it.
    static func save(_ projects: [Project], defaults: UserDefaults = .standard) {
        let persistable = projects.map { project -> Project in
            guard project.workstreams.contains(where: { $0.worktreePath == nil }) else { return project }
            var pruned = project
            pruned.workstreams.removeAll { $0.worktreePath == nil }
            return pruned
        }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }
}

/// Plan-usage polling, lifted out of `ContentView`'s modifier chain: that chain
/// is already long enough that two more inline modifiers tip the type checker
/// over its time limit.
private struct UsagePolling: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let store: Usage.Store

    /// Whether any window is actually on screen. Injectable for tests.
    ///
    /// `scenePhase` alone is not enough: on macOS, hiding the app reports
    /// `.background`, but *miniaturizing* the window only reports `.inactive` —
    /// which is also what a visible-but-unfocused window reports. `isVisible`
    /// is false for both hidden and miniaturized windows, so it separates
    /// "nobody can see the meter" from "the meter just isn't frontmost".
    var isOnScreen: () -> Bool = { NSApp.windows.contains(where: \.isVisible) }

    /// Matches `Usage.Store`'s own throttle, so a tick that lands early is a
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
