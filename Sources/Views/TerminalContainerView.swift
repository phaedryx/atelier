// ABOUTME: Workspace view with dynamic tabs for agent, terminals, and browsers.
// ABOUTME: Info and Agent are always present; every other tab closes and reopens on demand.

import os
import SwiftUI
import WebKit

private let logger = Logger(subsystem: "atelier", category: "surface-cache")

extension Notification.Name {
    static let terminalSurfaceClosed = Notification.Name("atelier.terminalSurfaceClosed")
    static let toggleInfo = Notification.Name("atelier.toggleInfo")
    static let toggleTerminal = Notification.Name("atelier.toggleTerminal")
    static let toggleBrowser = Notification.Name("atelier.toggleBrowser")
    static let focusAgent = Notification.Name("atelier.focusAgent")
    static let closeTerminal = Notification.Name("atelier.closeTerminal")
    static let nextTab = Notification.Name("atelier.nextTab")
    static let prevTab = Notification.Name("atelier.prevTab")
    static let terminalTitleChanged = Notification.Name("atelier.terminalTitleChanged")
    static let toggleEditor = Notification.Name("atelier.toggleEditor")
    static let toggleChanges = Notification.Name("atelier.toggleChanges")
    static let submitChangeReview = Notification.Name("atelier.submitChangeReview")
    static let toggleExecution = Notification.Name("atelier.toggleExecution")
    static let toggleVerification = Notification.Name("atelier.toggleVerification")
    /// Runs the active workstream's `bootstrap` namespace again. Declared here
    /// rather than beside `.asyncSetupStateChanged`, which `AsyncSetupService`
    /// posts: like `.rerunScript`, this one is posted by the palette and named
    /// in the file whose view receives it.
    static let rerunBootstrap = Notification.Name("atelier.rerunBootstrap")
    static let saveEditor = Notification.Name("atelier.saveEditor")
    static let saveEditorAs = Notification.Name("atelier.saveEditorAs")
    static let toggleFileFinder = Notification.Name("atelier.toggleFileFinder")
    /// Object is a stored prompt's id (uuidString): run it in the active workstream.
    static let runStoredPrompt = Notification.Name("atelier.runStoredPrompt")
}

enum RestorableWorkspaceTab: String, Codable {
    case info
    case agent
    case execution
    case changes
    case verification

    init(activeTab: WorkspaceTab) {
        switch activeTab {
        case .agent:
            self = .agent
        case .changes:
            self = .changes
        case .execution:
            self = .execution
        case .verification:
            self = .verification
        case .info, .terminal, .browser, .editor:
            self = .info
        }
    }

    func workspaceTab() -> WorkspaceTab {
        switch self {
        case .info:
            .info
        case .agent:
            .agent
        case .changes:
            .changes
        case .execution:
            .execution
        case .verification:
            .verification
        }
    }
}

enum WorkspaceStateStore {
    private static let userDefaultsKey = "atelier.workspaceTabs"

    /// Decoded per entry, not as one dictionary: a tag this build does not
    /// recognise — written by a newer build, or by a tab kind since removed —
    /// must drop that one workstream's saved tab, not everyone's.
    private static func loadAll() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let saved = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return saved
    }

    static func load(for workstreamID: UUID) -> RestorableWorkspaceTab? {
        guard let raw = loadAll()[workstreamID.uuidString] else { return nil }
        return RestorableWorkspaceTab(rawValue: raw)
    }

    static func save(_ tab: RestorableWorkspaceTab, for workstreamID: UUID) {
        var saved = loadAll()
        saved[workstreamID.uuidString] = tab.rawValue
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

func reorderedCustomTabs(_ tabs: [WorkspaceTab], dragging draggedTab: WorkspaceTab, to targetTab: WorkspaceTab) -> [WorkspaceTab] {
    guard draggedTab != targetTab,
          draggedTab.isCloseable,
          targetTab.isCloseable,
          let sourceIndex = tabs.firstIndex(of: draggedTab),
          let targetIndex = tabs.firstIndex(of: targetTab)
    else {
        return tabs
    }

    var reordered = tabs
    let movedTab = reordered.remove(at: sourceIndex)
    let insertionIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
    reordered.insert(movedTab, at: insertionIndex)
    return reordered
}

/// A tab in the workspace. Info and Agent are permanent; everything else — the
/// Changes, Execution and Verification singletons included — closes, reopens,
/// and reorders by drag.
enum WorkspaceTab: Hashable {
    case info
    case agent
    case changes
    case execution
    case verification
    case terminal(UUID)
    case browser(UUID)
    case editor(UUID)

    var isCloseable: Bool {
        kind.isCloseable
    }
}

extension WorkspaceTab {
    var kind: WorkspaceTabKind {
        switch self {
        case .info: .info
        case .agent: .agent
        case .changes: .changes
        case .execution: .execution
        case .verification: .verification
        case .terminal: .terminal
        case .browser: .browser
        case .editor: .editor
        }
    }

    /// Identifier used by the tab bar's drag-and-drop: instance UUID for
    /// closeable tabs, the kind id for pinned ones.
    var dragIdentifier: String {
        switch self {
        case let .terminal(id), let .browser(id), let .editor(id):
            id.uuidString
        default:
            kind.id
        }
    }
}

/// A workstream's workspace tab state as plain data.
///
/// Seeds a new `WorkspaceModel` and is the inverse of `WorkspaceModel.snapshot()`.
/// It is no longer stored anywhere: the model itself survives navigation, so
/// there is nothing to save and restore.
struct WorkspaceTabSnapshot {
    var tabs: [WorkspaceTab]
    var terminalCount: Int
    var browserCount: Int
    var editorCount: Int
    var activeTab: WorkspaceTab
    var browserTitles: [UUID: String]
    var terminalTitles: [UUID: String]
    var editorFilePaths: [UUID: String]
    var runStarted: Bool
    var runStoppedManually: Bool
}

/// The state a workstream's model starts life with: the two permanent tabs and
/// nothing else. Tab lists are never persisted across launches, so every
/// workstream opens the same way and Changes, Execution and Verification are
/// opened when they are wanted — from the tab bar's quick-add buttons, the
/// command palette, or ⌘-shortcuts.
///
/// `activeTab` is therefore clamped rather than trusted. `savedTab` restores the
/// last-active tab *kind*, and three of the five kinds it can name are no longer
/// seeded; a `.changes` restored onto a strip with no Changes tab would render
/// that pane with nothing selected in the strip, and with the quick-add button
/// still offering to open what is already on screen. The saved kind survives
/// where it still can — Info versus Agent — and falls back to Info where it
/// cannot. Any future seed change has to keep the `tabs.contains` clamp: it is
/// what holds `activeTab` inside `tabs`.
func startupWorkspaceTabState(savedTab: RestorableWorkspaceTab?) -> WorkspaceTabSnapshot {
    let tabs: [WorkspaceTab] = [.info, .agent]
    let restored = (savedTab ?? .info).workspaceTab()

    return WorkspaceTabSnapshot(
        tabs: tabs,
        terminalCount: 0,
        browserCount: 0,
        editorCount: 0,
        activeTab: tabs.contains(restored) ? restored : .info,
        browserTitles: [:],
        terminalTitles: [:],
        editorFilePaths: [:],
        runStarted: false,
        runStoppedManually: false
    )
}

func workspaceEnvironmentVariables(
    workstreamID: UUID,
    projectName: String,
    workstreamName: String,
    projectDirectory: String,
    workingDirectory: String,
    port: Int,
    defaultBranch: String,
    portPlan: ProcessCompose.PortPlan = .empty
) -> [String: String] {
    Workstream.Environment.variables(
        workstreamID: workstreamID,
        projectName: projectName,
        workstreamName: workstreamName,
        projectDirectory: projectDirectory,
        workingDirectory: workingDirectory,
        port: port,
        defaultBranch: defaultBranch,
        portPlan: portPlan
    )
}

enum TerminalSessionMode: Equatable {
    case standard
    case tmux
    case waitingForTools

    static func resolve(tmuxModeEnabled: Bool, isDetectingTools: Bool, tmuxInstalled: Bool) -> Self {
        if tmuxModeEnabled {
            if isDetectingTools {
                return .waitingForTools
            }
            if tmuxInstalled {
                return .tmux
            }
        }
        return .standard
    }
}

struct TerminalContainerView: View {
    let workstreamID: UUID
    let workingDirectory: String
    let projectDirectory: String
    let projectName: String
    let workstreamName: String
    let workstreamLabel: String
    let bypassPermissions: Bool
    let isActive: Bool

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache
    @EnvironmentObject var appEnv: AppEnvironment
    /// Per-workstream tab state. Resolved by `ContentView` from the surface
    /// cache and passed in, because `surfaceCache` is an `@EnvironmentObject`
    /// and so is not available here in `init`. It must stay a stored
    /// `@ObservedObject`: a computed property re-resolving it on each access
    /// would never subscribe, and the view would silently render stale tabs.
    @ObservedObject var model: WorkspaceModel
    /// The app-level verification runner, created by `ContentView` and passed
    /// through. Not an `@ObservedObject` here: nothing in this view renders
    /// from it, and `VerificationTabView` — which does — observes it itself.
    let verificationRunner: Verification.Runner
    @AppStorage("atelier.defaultBrowser") private var defaultBrowser: String = ""
    @AppStorage("atelier.tmuxMode") private var tmuxMode: Bool = false
    @AppStorage("atelier.autoRenameBranch") private var autoRenameBranch: Bool = false
    @AppStorage("atelier.allowOutsideWorktree") private var allowOutsideWorktree: Bool = false
    @AppStorage(IPC.AgentSettings.enabledKey) private var agentIPC: Bool = false
    /// Both process-compose settings, observed rather than read.
    ///
    /// They are inputs to `runPlan`, and they are changed in the Settings
    /// window, which never touches this view — so without an observer the pane
    /// would keep a plan built before the change. That matters most in the state
    /// the plan's own message describes: "process-compose was not found, set its
    /// path in Settings" is advice the user follows, and Start has to become
    /// enabled when they do. `@AppStorage` watches UserDefaults process-wide, so
    /// a write from the other window lands here.
    @AppStorage(ProcessCompose.Settings.enabledKey) private var processComposeEnabled: Bool = false
    @AppStorage(ProcessCompose.Settings.binaryPathKey) private var processComposeBinaryPath: String = ""
    @AppStorage("atelier.editorTabActive") private var editorTabActive: Bool = false
    @AppStorage("atelier.editorFileDirty") private var editorFileDirty: Bool = false
    @State private var fileTree: [FileNode] = []
    @State private var gitFileStatuses = Git.FileStatusProvider()
    @State private var directoryWatcher: DirectoryWatcher?
    @State private var refreshGeneration = 0
    @State private var refreshDebounceTask: Task<Void, Never>?
    @State private var fileFinderRequest = 0
    @State private var cachedClaudeCommand: String?
    @State private var draggedCustomTab: WorkspaceTab?
    @StateObject private var portDetector: Port.Detector
    @State private var browserStartPending = false
    @State private var devCommandOverride: String?
    @State private var resolvedDevCommand: DevCommand?
    @State private var defaultBranch = "main"
    /// Every repository-provided file process-compose would load here, or empty
    /// when there is nothing to approve — the integration is off, no config was
    /// found, or the only config sits in the project directory and is the user's
    /// own with no worktree override beside it.
    ///
    /// A list, not a path: a repository can ship a benign base config plus an
    /// override that discovery loads, and showing only the base would ask the
    /// user to approve a file that is not the whole of what runs.
    ///
    /// Resolved with a bare `ProcessCompose.Config.locate`, deliberately not
    /// through `processComposeConfig`: that one is narrowed to the *run*, so it
    /// disappears when the user has a per-workstream override. Bootstrap and
    /// dispose locate unconditionally, so hanging the approval off the run's
    /// config would hide it in exactly the case where bootstrap still wants to
    /// run.
    @State private var repositoryConfigFiles: [String] = []
    @State private var configApproved = false
    @State private var isReviewingConfig = false
    /// Resolved once per change rather than per render: resolving binds a socket
    /// to check whether each port is free.
    @State private var portPlan: ProcessCompose.PortPlan = .empty
    /// What Start may run, decided once per change in `refreshDevCommand`.
    ///
    /// Stored rather than recomputed because *agreement* is the invariant here,
    /// not freshness. The Execution pane's Start button is enabled on this
    /// value and `doStartRun` refuses on this value, so the two cannot describe
    /// different worlds; a plan that is a moment stale but consistent is
    /// harmless, while a fresh plan disagreeing with the button is exactly the
    /// bug — an enabled Start that silently did nothing. Do not turn this back
    /// into a computed property: `ProcessCompose.RunCommandPlan.plan` locates the config and
    /// stats the binary, so reading it from the view body would also put
    /// filesystem work in every render pass.
    ///
    /// What invalidates it: the per-workstream override, and **both
    /// process-compose settings** — the integration switch and the binary path,
    /// observed via `@AppStorage` because they are changed in a different window
    /// that never touches this view. Those two are not optional. The plan's own
    /// message tells the user to go and change them, so a plan that did not
    /// notice would leave Start disabled after they had done exactly what it
    /// asked. Do not drop them when adding another input here.
    @State private var runPlan: ProcessCompose.RunCommandPlan = .nothing
    /// Every file the run's config will load, for the pane to show in place of a
    /// command string. Set in the same refresh as `runPlan`.
    @State private var devCommandFiles: [String] = []
    /// Why Start can do nothing, when it can do nothing and the pane's own copy
    /// does not already explain it. Set in the same refresh as `runPlan`.
    @State private var runUnavailableReason: String?
    /// The Verification tab's two availability inputs, resolved together in
    /// `refreshVerificationAvailability` and handed in.
    ///
    /// State rather than computed properties for the same two reasons `runPlan`
    /// is: resolving them locates the config, stats the binary and hashes the
    /// approval-relevant files, which has no business in a render pass — and
    /// *agreement* is the invariant, since `Verification.Runner.start` guards
    /// on the same `PhasePolicy.plan` the reason below was produced from.
    @State private var declaredVerifyChecks: [String] = []
    @State private var verifyUnavailableReason: String?
    /// True while `doStartRun` is awaiting `down` on a socket it has to reclaim.
    ///
    /// Start is otherwise synchronous, and that is what kept it safe to press
    /// twice: the second press found `runStarted` already true. The reclaim path
    /// awaits a child process before flipping any state, which reopens that
    /// window for as long as `down` takes — and a second press would then run a
    /// second `down` and a second `beginRun`, the later one bumping
    /// `runGeneration` and replacing the surface the earlier one just built.
    ///
    /// Passed to `ExecutionTabView` as well as guarding `doStartRun`, because
    /// a button that silently swallows a press reads as broken. The guard still
    /// has to be there: `.rerunScript` (⌘⇧⏎) reaches `startRunIfNeeded` without
    /// going through the button at all.
    @State private var isReclaimingRunSocket = false
    /// The last thing background setup said about this workstream.
    ///
    /// `AsyncSetupService` has posted `.asyncSetupStateChanged` since it
    /// existed, and until now nothing listened — so `.completedWithNote`, the
    /// state whose whole job is to say *why* no bootstrap ran, was written and
    /// discarded. It is read here and rendered on the Info tab, which is
    /// permanent and cannot be closed out from under the message.
    @State private var setupState: AsyncSetupState = .idle
    @StateObject private var processTable: ProcessCompose.TableModel
    init(
        workstreamID: UUID,
        workingDirectory: String,
        projectDirectory: String,
        projectName: String,
        workstreamName: String,
        workstreamLabel: String? = nil,
        bypassPermissions: Bool,
        isActive: Bool,
        model: WorkspaceModel,
        verificationRunner: Verification.Runner
    ) {
        self.workstreamID = workstreamID
        self.workingDirectory = workingDirectory
        self.projectDirectory = projectDirectory
        self.projectName = projectName
        self.workstreamName = workstreamName
        self.workstreamLabel = workstreamLabel ?? workstreamName
        self.bypassPermissions = bypassPermissions
        self.isActive = isActive
        self.model = model
        self.verificationRunner = verificationRunner
        _portDetector = StateObject(wrappedValue: Port.Detector(workstreamID: workstreamID))
        _processTable = StateObject(wrappedValue: ProcessCompose.TableModel(
            socketPath: ProcessCompose.PhaseRunner.socketPath(for: workstreamID)
        ))

        let savedOverride = DevCommand.Resolver.savedOverride(for: workstreamID)
        _devCommandOverride = State(initialValue: savedOverride)
        _resolvedDevCommand = State(initialValue: DevCommand.Resolver.resolve(
            workingDirectory: workingDirectory,
            projectDirectory: projectDirectory,
            override: savedOverride
        ))
    }

    private var claudeID: UUID {
        workstreamID
    }

    private var quickActionRunner: QuickAction.Runner {
        surfaceCache.quickActionRunner(for: workstreamID)
    }

    /// Surface IDs that should be rendering for the active tab.
    private var visibleSurfaceIDs: Set<UUID>? {
        switch model.activeTab {
        case .agent:
            [claudeID]
        case let .terminal(id): [id]
        case .info, .changes, .execution, .verification, .browser, .editor: []
        }
    }

    private var sessionMode: TerminalSessionMode {
        TerminalSessionMode.resolve(
            tmuxModeEnabled: tmuxMode,
            isDetectingTools: appEnv.isDetecting,
            tmuxInstalled: appEnv.toolStatus.tmux.isInstalled
        )
    }

    private var useTmux: Bool {
        sessionMode == .tmux
    }

    private var workstreamPort: Int {
        Port.Allocator.port(for: workingDirectory)
    }

    /// A declared `browser: true` port wins over detection: Atelier assigned it,
    /// so there is nothing to infer. Detection cannot help here anyway —
    /// RunState.PortSelectionTracker returns nil once more than one process is listening
    /// and no port was expected, which is every multi-service stack.
    private var browserDefaultURL: String {
        let port = portPlan.browserPort ?? portDetector.selectedPort ?? workstreamPort
        return "http://localhost:\(port)/"
    }

    /// The run session's surface ID. Bumped on stop/restart so a fresh
    /// surface replaces the previous one.
    private var runID: UUID {
        derivedUUID(from: workstreamID, salt: "env-run-\(model.runGeneration)")
    }

    /// The dev server is coming up but has not exposed a port yet. Covers the
    /// window between a browser-triggered start and the first atelier-run state
    /// write, so the browser never navigates to the placeholder port.
    private var isWaitingForServer: Bool {
        portDetector.status == .starting || (portDetector.status == .none && browserStartPending)
    }

    /// The located process-compose config, when this workstream's run is a
    /// process-compose run.
    ///
    /// Asks the same two questions as `usesProcessCompose` — the integration is
    /// on, and the resolved dev command came from a config rather than from the
    /// user's own override, which `DevCommand.Resolver.resolve` prefers. It takes
    /// the dev command as a parameter rather than reading `resolvedDevCommand`
    /// because `refreshDevCommand` needs the config for the resolution it is in
    /// the middle of storing, not for the previous one.
    ///
    /// A function, and called only from `refreshDevCommand`, so locating the
    /// config never happens in a render pass.
    private func processComposeConfig(for devCommand: DevCommand?) -> ProcessCompose.Config? {
        guard ProcessCompose.Settings.isEnabled, devCommand?.source == .processCompose else { return nil }
        return ProcessCompose.Config.locate(worktree: workingDirectory, projectDirectory: projectDirectory)
    }

    /// The command that starts the dev server: process-compose's chained
    /// `prepare && execute`, or the user's own per-workstream override.
    ///
    /// The decision itself lives in `ProcessCompose.RunCommandPlan.plan`, which is where the
    /// reasoning is. The short version: this must never fall back to
    /// `resolvedDevCommand?.command` for a `.processCompose` source, because
    /// that string carries no `-n` and would run `bootstrap` and `dispose`
    /// without ever passing `PhasePolicy`. If the phase-scoped command cannot
    /// be built — no config, or no binary — the answer is nil and Start reports
    /// that, rather than running something unscoped.
    ///
    /// Processes the located config declares in `execute`.
    ///
    /// Read off the stored plan's config rather than by locating again, so the
    /// selection list and the command Start builds cannot disagree about which
    /// config they mean. Empty when the config is unparseable, which the
    /// selection list treats as "offer no choices" rather than "no processes".
    private var declaredExecuteProcesses: [String] {
        guard case let .phaseScoped(config, _) = runPlan else { return [] }
        return config.declaredProcesses(in: ProcessCompose.Phase.execute.namespace) ?? []
    }

    /// Reads the stored `runPlan` rather than re-deriving one, so this is nil
    /// for exactly the plans whose `canRun` is false — which is what the Start
    /// button's enablement is drawn from. Deriving a second plan here is how
    /// the button and this guard came to disagree.
    private var resolvedRunCommand: String? {
        switch runPlan {
        case let .literal(command):
            return command
        case let .phaseScoped(config, binary):
            ProcessCompose.PhaseRunner.ensureSocketDirectory()
            return ProcessCompose.PhaseRunner.startCommand(
                config: config,
                binary: binary,
                workstreamID: workstreamID,
                selectedProcesses: ProcessCompose.TableModel.selected(for: workstreamID)
            )
        case .nothing:
            return nil
        }
    }

    /// Env vars for the run/dev-server surface. Adds the var that silences
    /// the Next.js first-run telemetry prompt, which a headless terminal
    /// cannot answer.
    private var runEnvironmentVars: [String: String] {
        var vars = terminalEnvVars
        vars["NEXT_TELEMETRY_DISABLED"] = "1"
        return vars
    }

    private var branchPR: GitHub.PR? {
        guard let branch = appEnv.branchName(for: workingDirectory) else { return nil }
        return appEnv.githubPR(for: projectDirectory, branch: branch)
    }

    private func buildClaudeCommand() -> String? {
        guard let basePath = appEnv.toolStatus.claude.path else { return nil }
        let sessionID = workstreamID.uuidString.lowercased()

        // A file path rather than inline JSON, even though --mcp-config accepts
        // both: LaunchLogger records finalCommand verbatim. --strict-mcp-config
        // stays off, since turning it on would silently drop the user's own
        // global MCP servers.
        let mcpConfigPath = agentIPC ? IPC.Config.write(for: workstreamID) : nil
        // Shared with `open_agent_tab`, which spawns a second agent into this
        // same worktree and must not assemble its own, differently-gated copy.
        let combinedSystemPrompt = Workstream.AgentCommand.systemPrompt(
            allowOutsideWorktree: allowOutsideWorktree,
            autoRenameBranch: autoRenameBranch,
            worktreePath: workingDirectory,
            workstreamName: workstreamName,
            mcpConfigWritten: mcpConfigPath != nil
        )

        var resume = CommandBuilder(basePath)
        resume.option("--resume", sessionID)
        if appEnv.toolStatus.claudeSupportsSessionName {
            resume.option("--name", workstreamName)
        }
        if bypassPermissions {
            resume.flag("--dangerously-skip-permissions")
        }
        if let combinedSystemPrompt {
            resume.option("--append-system-prompt", combinedSystemPrompt)
        }
        if let mcpConfigPath {
            resume.option("--mcp-config", mcpConfigPath)
        }

        var fresh = CommandBuilder(basePath)
        fresh.option("--session-id", sessionID)
        if appEnv.toolStatus.claudeSupportsSessionName {
            fresh.option("--name", workstreamName)
        }
        if bypassPermissions {
            fresh.flag("--dangerously-skip-permissions")
        }
        if let combinedSystemPrompt {
            fresh.option("--append-system-prompt", combinedSystemPrompt)
        }
        if let mcpConfigPath {
            fresh.option("--mcp-config", mcpConfigPath)
        }

        let cmd = CommandBuilder.withFallback(
            resume.command, fresh.command,
            message: "Starting new session..."
        )

        return wrapAgentCommand(cmd, intermediates: [resume.command, fresh.command, cmd], toolPathsClaude: basePath)
    }

    /// Shared tail of agent command building: optional tmux wrapping + launch log.
    private func wrapAgentCommand(_ cmd: String, intermediates: [String], toolPathsClaude: String?) -> String {
        let finalCommand: String
        var intermediates = intermediates
        if useTmux, let tmuxPath = appEnv.toolStatus.tmux.path {
            finalCommand = Workstream.AgentCommand.tmuxWrapped(
                cmd,
                tmuxPath: tmuxPath,
                projectName: projectName,
                workstreamName: workstreamName,
                environmentVars: envVars
            )
            intermediates.append(finalCommand)
        } else {
            finalCommand = cmd
        }

        LaunchLogger.log(LaunchLogEntry(
            workstreamID: workstreamID,
            event: "agent-start",
            finalCommand: finalCommand,
            intermediateCommands: intermediates,
            environmentVariables: envVars,
            workingDirectory: workingDirectory,
            toolPaths: LaunchLogEntry.ToolPaths(
                claude: toolPathsClaude ?? appEnv.toolStatus.claude.path,
                tmux: appEnv.toolStatus.tmux.path,
                ffRun: RunLauncher.executableURL()?.path
            ),
            settings: LaunchLogEntry.Settings(
                tmuxMode: tmuxMode,
                bypassPermissions: bypassPermissions,
                autoRenameBranch: autoRenameBranch,
                allowOutsideWorktree: allowOutsideWorktree
            ),
            shell: CommandBuilder.userShell
        ))

        return finalCommand
    }

    private func rebuildClaudeCommand() {
        cachedClaudeCommand = buildClaudeCommand()
        if let cmd = cachedClaudeCommand {
            logger.info("[Atelier] claude cmd rebuilt: \(cmd.prefix(80), privacy: .public)")
        }
    }

    private var fixedTabs: [WorkspaceTab] {
        model.tabs.filter { !$0.isCloseable }
    }

    private var closeableTabs: [WorkspaceTab] {
        model.tabs.filter(\.isCloseable)
    }

    /// The singleton tabs whose quick-add button is currently showing, in the
    /// order the buttons appear.
    ///
    /// One list, read by both the buttons and the divider that separates them
    /// from the add-another-one buttons, so the two cannot disagree about
    /// whether the group is empty. Since `startupWorkspaceTabState` seeds
    /// neither singleton, the usual state is both buttons showing; the empty
    /// case is a workstream with both tabs open, and the divider has to
    /// disappear with them rather than dangle at the head of the group.
    private var closedSingletons: [SingletonQuickAdd] {
        SingletonQuickAdd.all.filter { !model.tabs.contains($0.tab) }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            // Permanent tabs (Info, Agent)
            ForEach(fixedTabs, id: \.self) { tab in
                tabButton(for: tab)
            }

            // Scrollable closeable tabs (Changes, Execution, terminals, browsers, editors)
            if !closeableTabs.isEmpty {
                ScrollableTabStrip(
                    tabs: closeableTabs,
                    activeTab: model.activeTab,
                    tabButton: { tab in tabButton(for: tab) }
                )
                .layoutPriority(-1)
            }

            Spacer()

            // Quick actions to add tabs
            HStack(spacing: 2) {
                // Shown only while the tab is closed. ⌘1-9 is positional over
                // the tabs that are open, so no number reaches a closed one;
                // this and the command palette are the way back.
                ForEach(closedSingletons, id: \.tab) { singleton in
                    TabBarActionButton(icon: singleton.tab.kind.icon, tooltip: singleton.tooltip) {
                        model.activateSingleton(singleton.tab)
                    }
                }
                // Marks the boundary the two halves of this group mean
                // different things across: reopen the one there is only ever
                // one of, versus add another of something there can be many
                // of. Drawn only when the left half is non-empty.
                if !closedSingletons.isEmpty {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                // Icons come from the kind rather than a literal, the same way
                // the singleton buttons above take theirs: a quick-add button
                // and the tab it opens must not be able to drift apart.
                TabBarActionButton(icon: WorkspaceTabKind.terminal.icon, tooltip: "New Terminal", action: addTerminal)
                TabBarActionButton(icon: WorkspaceTabKind.browser.icon, tooltip: "New Browser", action: addBrowser)
                TabBarActionButton(icon: WorkspaceTabKind.editor.icon, tooltip: "New Editor", action: openEditor)
            }
            .fixedSize()

            if let pr = branchPR, let url = URL(string: pr.url) {
                let prColor = pr.status.color
                Button(action: { NSWorkspace.shared.open(url) }) {
                    HStack(spacing: 4) {
                        Image(systemName: pr.status.symbolName)
                            .font(.system(size: 11))
                        if pr.checks != .none {
                            Image(systemName: pr.checks.symbolName)
                                .font(.system(size: 9))
                                .foregroundStyle(pr.checks.color)
                        }
                        Text(verbatim: "#\(pr.number)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(prColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(prColor)
                }
                .buttonStyle(.borderless)
                .help(pr.title)
                .accessibilityLabel(Text(verbatim: "Pull request #\(pr.number)"))
                .accessibilityHint(pr.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private func tabButton(for tab: WorkspaceTab) -> some View {
        let shortcut = tabShortcut(tab) ?? closeableTabShortcut(tab)
        let button = WorkspaceTabButton(
            tab: tab,
            label: tabLabel(tab),
            icon: tabIcon(tab),
            shortcut: shortcut,
            isActive: model.activeTab == tab,
            isDirty: model.isEditorDirty(tab),
            onSelect: { model.activeTab = tab },
            onClose: tab.isCloseable ? { closeTab(tab) } : nil
        )

        if tab.isCloseable {
            button
                .onDrag {
                    draggedCustomTab = tab
                    return NSItemProvider(object: NSString(string: tab.dragIdentifier))
                }
                .onDrop(of: [.text], delegate: WorkspaceTabDropDelegate {
                    moveCustomTab(to: tab)
                })
        } else {
            button
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.activeTab {
        case .info:
            WorkstreamInfoView(
                workstreamID: workstreamID,
                workingDirectory: workingDirectory,
                projectDirectory: projectDirectory,
                repositoryConfigFiles: repositoryConfigFiles,
                configApproved: configApproved,
                setupState: setupState,
                onReviewConfig: { isReviewingConfig = true },
                onRevokeConfig: revokeProcessConfig,
                onRerunBootstrap: rerunBootstrap
            )
        case .changes:
            if let bridge = model.diffBridge {
                ChangesView(
                    workstreamID: workstreamID,
                    workingDirectory: workingDirectory,
                    projectDirectory: projectDirectory,
                    bridge: bridge,
                    annotations: model.annotationStore
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .execution:
            if sessionMode == .waitingForTools {
                terminalLoadingView(message: "Checking terminal tools...")
            } else {
                ExecutionTabView(
                    workstreamID: workstreamID,
                    workingDirectory: workingDirectory,
                    useTmux: useTmux,
                    environmentVars: runEnvironmentVars,
                    runCommand: model.runCommandString,
                    devCommand: resolvedDevCommand,
                    devCommandOverride: $devCommandOverride,
                    runStarted: $model.runStarted,
                    runGeneration: model.runGeneration,
                    processTable: processTable,
                    showsProcessTable: usesProcessCompose,
                    portsByName: portPlan.values,
                    declaredProcesses: declaredExecuteProcesses,
                    canStart: runPlan.canRun,
                    isReclaimingSocket: isReclaimingRunSocket,
                    devCommandFiles: devCommandFiles,
                    startUnavailableReason: runUnavailableReason,
                    unapprovedConfigFiles: configApproved ? [] : repositoryConfigFiles,
                    onReviewConfig: { isReviewingConfig = true },
                    onStart: doStartRun,
                    onStop: stopRun,
                    onRestart: restartRun
                )
            }
        case .verification:
            VerificationTabView(
                workstreamID: workstreamID,
                // Passed through exactly as it arrived. `workingDirectory` is
                // `Workstream.workingDirectory(checkout:)` — `worktreePath ??
                // checkout` — and `Worktree.HeadWatcher` is registered with
                // `workstream.worktreePath`, so the string this view compares a
                // `.worktreeGitActivity` notification against has to stay
                // byte-identical to the one the watcher posts. Any
                // normalization here (a trailing slash, `standardizedFileURL`,
                // resolving a symlink) would silently stop the staleness banner
                // updating on git activity, with no log and no fallback.
                worktreePath: workingDirectory,
                projectDirectory: projectDirectory,
                projectName: projectName,
                workstreamName: workstreamName,
                declaredProcesses: declaredVerifyChecks,
                unavailableReason: verifyUnavailableReason,
                runner: verificationRunner
            )
        case .agent:
            if sessionMode == .waitingForTools || appEnv.isDetecting {
                terminalLoadingView(message: "Checking terminal tools...")
            } else if appEnv.toolStatus.claude.path == nil {
                VStack(spacing: 16) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Claude Code not found")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Install Claude Code to use the Coding Agent.")
                        .foregroundStyle(.tertiary)
                    Link("Install Claude Code", destination: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let claudeCommand = cachedClaudeCommand {
                VStack(spacing: 0) {
                    // Above the terminal rather than over it: what is being
                    // approved is often a command, and covering the output that
                    // led to it is the wrong thing to hide.
                    PermissionRequestBannerHost(workstreamID: workstreamID, agentSurfaceID: claudeID)
                    SingleTerminalView(
                        surfaceID: claudeID,
                        workingDirectory: workingDirectory,
                        command: claudeCommand,
                        isFocused: true,
                        environmentVars: envVars
                    )
                }
            } else {
                terminalLoadingView(message: "Preparing Coding Agent...")
            }
        case let .terminal(id):
            SingleTerminalView(
                surfaceID: id,
                workingDirectory: workingDirectory,
                isFocused: true,
                environmentVars: terminalEnvVars(for: id)
            )
        case let .browser(id):
            BrowserView(defaultURL: browserDefaultURL, isWaitingForServer: isWaitingForServer, tabID: id, webView: surfaceCache.webView(for: id))
                .id(id)
        case let .editor(id):
            if let bridge = model.editorBridge {
                EditorView(
                    workingDirectory: workingDirectory,
                    fileTree: fileTree,
                    gitStatus: gitFileStatuses,
                    initialFilePath: model.editorFilePaths[id],
                    bridge: bridge,
                    modelId: id.uuidString,
                    initialLine: { model.takeInitialLine(for: id) },
                    isDirtyState: Binding(
                        get: { model.editorDirtyState[id] ?? false },
                        set: { model.editorDirtyState[id] = $0 }
                    ),
                    onFileChanged: { path in
                        if let path {
                            model.editorFilePaths[id] = path
                        } else {
                            model.editorFilePaths.removeValue(forKey: id)
                        }
                    },
                    onExpandFolder: { path in
                        expandFileTreeFolder(path)
                    },
                    fileFinderRequest: fileFinderRequest
                )
                .id(id)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The half of the chain that rebuilds the agent command and handles the
    /// two tabs that are always there.
    ///
    /// Split out of `mainContent` for the reason `ContentView`'s
    /// `selectionReceivingSplitView` is split out of its own base: the two
    /// together are one modifier chain long enough that the Swift type-checker
    /// gives up on it ("unable to type-check this expression in reasonable
    /// time"), which is exactly what adding the `.toggleVerification` receiver
    /// did. Adding a modifier to either half is fine; merging them back is not.
    private var commandRebuildingContent: some View {
        mainLayout
            .onChange(of: tmuxMode) { rebuildClaudeCommand() }
            .onChange(of: bypassPermissions) { rebuildClaudeCommand() }
            .onChange(of: autoRenameBranch) { rebuildClaudeCommand() }
            .onChange(of: allowOutsideWorktree) { rebuildClaudeCommand() }
            .onChange(of: workstreamName) { rebuildClaudeCommand() }
            .onChange(of: appEnv.isDetecting) {
                rebuildClaudeCommand()
                if isActive {
                    preloadSurfaces()
                }
                // Tmux mode isn't resolvable until detection finishes; restore
                // the run session then, not just on the Execution tab's own
                // appearance, so a live session is picked up even if that tab
                // is never opened.
                restoreRunState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in
                guard isActive else { return }
                model.activeTab = .info
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { _ in
                guard isActive else { return }
                model.activeTab = .agent
            }
            .onReceive(NotificationCenter.default.publisher(for: .runStoredPrompt)) { note in
                guard isActive else { return }
                guard let idString = note.object as? String,
                      let id = UUID(uuidString: idString),
                      let prompt = StoredPromptStore.shared.prompt(id: id) else { return }
                model.activeTab = .agent
                PromptInjector.shared.inject(prompt.text, into: workstreamID)
            }
    }

    /// The half of the chain that opens, closes and reruns tabs. See
    /// `commandRebuildingContent` for why this is two properties.
    private var mainContent: some View {
        commandRebuildingContent
            .onReceive(NotificationCenter.default.publisher(for: .rerunScript)) { _ in
                guard isActive else { return }
                guard resolvedRunCommand != nil else { return }
                if model.runStarted {
                    restartRun()
                } else {
                    startRunIfNeeded()
                }
                model.activateSingleton(.execution)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTerminal)) { _ in
                guard isActive else { return }
                addTerminal()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleBrowser)) { _ in
                guard isActive else { return }
                addBrowser()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleEditor)) { _ in
                guard isActive else { return }
                openEditor()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFileFinder)) { _ in
                guard isActive else { return }
                if case .editor = model.activeTab {
                    fileFinderRequest += 1
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleChanges)) { _ in
                guard isActive else { return }
                addChanges()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleExecution)) { _ in
                guard isActive else { return }
                model.activateSingleton(.execution)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleVerification)) { _ in
                guard isActive else { return }
                model.activateSingleton(.verification)
            }
            // On `mainContent`, which is mounted whatever the active tab is, so
            // the palette reaches this from the Agent tab and not only from
            // Info where the button lives. The availability question splits the
            // way the rest of this file's palette commands split it:
            // `DefaultCommands` asks whether there is a workspace to act on,
            // and the receiver asks whether there is something to do right now.
            .onReceive(NotificationCenter.default.publisher(for: .rerunBootstrap)) { _ in
                guard isActive, canRerunBootstrap(setupState) else { return }
                rerunBootstrap()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTerminal)) { _ in
                guard isActive else { return }
                if model.activeTab.isCloseable {
                    closeTab(model.activeTab)
                }
            }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .onReceive(NotificationCenter.default.publisher(for: .asyncSetupStateChanged)) { notification in
            guard let info = notification.userInfo,
                  info["workstreamID"] as? UUID == workstreamID,
                  let state = info["state"] as? AsyncSetupState else { return }
            setupState = state
        }
        .task(id: workstreamID) {
            // Seeded as well as observed: bootstrap for a brand-new workstream
            // can finish before this view exists, and a note nobody was
            // listening for is the bug being fixed rather than a smaller
            // version of it.
            setupState = await AsyncSetupService.shared.state(for: workstreamID)
        }
        .task(id: workstreamID) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let branch = await Task.detached {
                Git.Operations.defaultBranch(at: projectDirectory)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                startWorkspace(defaultBranch: branch)
            }
        }
        .onAppear {
            // Safety net for terminal tabs whose surface disappeared without
            // `TerminalSurfaceCache.removeTerminalTab(surfaceID:)` seeing it —
            // that prune handles the ordinary shell exit, on screen or off.
            model.reconcile(liveSurfaceIDs: surfaceCache.liveSurfaceIDs())
            // New workstreams open on the Coding Agent; previously-visited ones
            // keep whatever tab they were left on. First mount is the only place
            // that can be asked without ambiguity — the model's mere existence
            // cannot answer it, since `ContentView`'s body creates the model
            // while deciding what to render. Runs after `reconcile` so this is
            // the last word on the selection.
            if !model.hasBeenPresented {
                model.hasBeenPresented = true
                if WorkspaceStateStore.load(for: workstreamID) == nil {
                    model.activeTab = .agent
                }
            }
            if isActive {
                editorTabActive = model.isEditorTabActive
                editorFileDirty = model.isActiveEditorDirty
            }
            if model.hasEditorTabs {
                startFileTreeWatcherIfNeeded()
            }
            restoreRunState()
            syncProcessPolling()
            // Here as well as in `refreshDevCommand`, and this is not
            // belt-and-braces. `startWorkspace` — which is what calls
            // `refreshDevCommand` on first mount — runs from a `.task` behind a
            // 50ms sleep *and* a `Git.Operations.defaultBranch` hop, so until it
            // lands `verifyUnavailableReason` is still its initial nil, which
            // this tab reads as "everything is fine": an enabled Run over an
            // empty check list. Observed, not theorised — a workstream whose
            // repository-provided config was unapproved rendered exactly that.
            // Nothing here touches git, so it can run at appear and close the
            // window to a frame. (`Verification.Runner.start` calls
            // `PhasePolicy.plan` itself and throws `Failure.unavailable`, which
            // the tab renders, so even that frame explains itself rather than
            // silently doing nothing.)
            refreshVerificationAvailability()
        }
        .onDisappear {
            if isActive {
                editorTabActive = false
                editorFileDirty = false
            }
        }
        .onChange(of: model.activeTab) {
            guard isActive else { return }
            editorTabActive = model.isEditorTabActive
            editorFileDirty = model.isActiveEditorDirty
            surfaceCache.updateOcclusion(visibleSurfaceIDs: visibleSurfaceIDs)
            WorkspaceStateStore.save(RestorableWorkspaceTab(activeTab: model.activeTab), for: workstreamID)
            appEnv.refreshWorktreeState(for: workingDirectory, projectDirectory: projectDirectory)
        }
        .onChange(of: model.isActiveEditorDirty) {
            guard isActive else { return }
            editorFileDirty = model.isActiveEditorDirty
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalActivity)) { notification in
            guard isActive else { return }
            guard let wsID = notification.object as? UUID, wsID == workstreamID else { return }
            appEnv.refreshWorktreeState(for: workingDirectory, projectDirectory: projectDirectory)
        }
    }

    var body: some View {
        mainContent
            // On the container rather than on either tab, because both the
            // Execution banner and the Info row open it and Execution is a
            // closeable tab.
            .sheet(isPresented: $isReviewingConfig) {
                if !repositoryConfigFiles.isEmpty {
                    ConfigApprovalView(
                        filePaths: repositoryConfigFiles,
                        onApprove: approveProcessConfig,
                        onCancel: { isReviewingConfig = false }
                    )
                }
            }
            .onChange(of: devCommandOverride) { _, newValue in
                DevCommand.Resolver.saveOverride(newValue, for: workstreamID)
                refreshDevCommand()
            }
            // The two Settings-window inputs to `runPlan`. `refreshConfigApproval`
            // comes along because it is guarded on the same switch: with the
            // integration turned on mid-session, a repository-provided config
            // has to start asking for approval too.
            .onChange(of: processComposeEnabled) { _, _ in
                refreshConfigApproval()
                refreshDevCommand()
            }
            .onChange(of: processComposeBinaryPath) { _, _ in
                refreshDevCommand()
            }
            .onChange(of: model.runStarted) { _, started in
                // A session restored from tmux (or started before TerminalApp
                // was ready) needs its command assembled on the container side
                // so the restored surface reattaches to the existing session.
                if started, model.runCommandString == nil, let command = resolvedRunCommand {
                    model.runCommandString = buildRunCommand(script: command)
                    preloadRunSurface()
                }
                // Driven here rather than from doStartRun/stopRun because a
                // session restored from tmux sets this directly and never goes
                // through either of them.
                syncProcessPolling()
            }
            .onChange(of: portDetector.status) { _, newStatus in
                // Once the session materializes (atelier-run wrote state), the
                // waiting overlay is driven by the status itself.
                if newStatus != .none {
                    browserStartPending = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchByNumber)) { notification in
                guard isActive else { return }
                guard let n = notification.object as? Int, n >= 1 else { return }
                // Cmd+1-9 maps to all tabs in display order
                guard n <= model.tabs.count else { return }
                model.activeTab = model.tabs[n - 1]
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextTab)) { _ in
                guard isActive else { return }
                guard let currentIndex = model.tabs.firstIndex(of: model.activeTab) else { return }
                model.activeTab = model.tabs[(currentIndex + 1) % model.tabs.count]
            }
            .onReceive(NotificationCenter.default.publisher(for: .prevTab)) { _ in
                guard isActive else { return }
                guard let currentIndex = model.tabs.firstIndex(of: model.activeTab) else { return }
                model.activeTab = model.tabs[(currentIndex - 1 + model.tabs.count) % model.tabs.count]
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalTabExited)) { notification in
                guard let surfaceID = notification.object as? UUID else { return }
                if surfaceID == runID {
                    // The dev-server session died; no port is coming.
                    browserStartPending = false
                    // And the run is over, which has to be recorded rather than
                    // left implied. `runStarted` stayed true here, so the pane
                    // kept rendering `SingleTerminalView` with the stored
                    // command — and `TerminalSurfaceView.updateNSView`
                    // recreates a missing surface from that command on the next
                    // render. Stopping the last process therefore rebooted the
                    // whole stack with no user action, and Stop acted on a run
                    // that did not exist until a render brought it back.
                    //
                    // `runStoppedManually` is deliberately left alone: the run
                    // died on its own, and marking it manual would suppress the
                    // tmux restore the user never asked to suppress.
                    model.runStarted = false
                    model.runCommandString = nil
                    syncProcessPolling()
                }
                // Tab removal for exited terminals happens at exit time, in
                // handleSurfaceClosed via removeTerminalTab(surfaceID:) — by
                // the time this notification arrives the tab is already gone.
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserTitleChanged)) { notification in
                guard let tabID = notification.object as? UUID else { return }
                model.browserTitles[tabID] = notification.userInfo?["title"] as? String
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalTitleChanged)) { notification in
                guard let surfaceID = notification.object as? UUID else { return }
                model.terminalTitles[surfaceID] = notification.userInfo?["title"] as? String
            }
            .onReceive(NotificationCenter.default.publisher(for: .openExternalBrowser)) { _ in
                guard isActive else { return }
                guard let url = URL(string: browserDefaultURL) else { return }
                if defaultBrowser.isEmpty {
                    NSWorkspace.shared.open(url)
                } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultBrowser) {
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            .toolbar {
                if isActive {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let githubURL = appEnv.githubURL(for: projectDirectory) {
                            Button {
                                NSWorkspace.shared.open(githubURL)
                            } label: {
                                Label(NSLocalizedString("GitHub", comment: ""), image: "github")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Open on GitHub")
                        }

                        GitHubActionMenu(
                            runner: quickActionRunner,
                            claudePath: appEnv.toolStatus.claude.path,
                            ghPath: appEnv.toolStatus.gh.path,
                            workingDirectory: workingDirectory,
                            branchName: appEnv.branchName(for: workingDirectory),
                            bypassPermissions: bypassPermissions,
                            worktreeState: appEnv.worktreeState(for: workingDirectory),
                            hasGitHubRemote: appEnv.hasGitHubRemote(projectDirectory),
                            branchPR: branchPR
                        )
                    }
                }
            }
            .onChange(of: isActive) { _, active in
                editorTabActive = active && model.isEditorTabActive
                editorFileDirty = active && model.isActiveEditorDirty
                if active {
                    surfaceCache.updateOcclusion(visibleSurfaceIDs: visibleSurfaceIDs)
                }
            }
    }

    // MARK: - Tab management

    /// Number of per-tab-titled tabs beyond which labels are hidden to save
    /// space.
    private static let compactTabThreshold = 3

    /// Counts the tabs whose title is per-tab, which is what this used to mean
    /// when only those kinds were closeable. Changes and Execution are
    /// closeable now but carry fixed labels, so counting them would trip
    /// compact mode two tabs early and hide browser titles that still fit.
    /// (Only `tabLabel`'s browser branch consults this; editor tabs keep their
    /// filename either way.)
    private var useCompactTabs: Bool {
        model.tabs.count(where: { $0.kind.staticLabel == nil }) > Self.compactTabThreshold
    }

    private func tabLabel(_ tab: WorkspaceTab) -> String? {
        if let fixed = tab.kind.staticLabel {
            return fixed
        }
        switch tab {
        case let .browser(id):
            guard !useCompactTabs else { return nil }
            guard let title = model.browserTitles[id], !title.isEmpty else { return nil }
            return title.count > 20 ? String(title.prefix(20)) + "..." : title
        case let .editor(id):
            guard let path = model.editorFilePaths[id] else { return nil }
            let name = (path as NSString).lastPathComponent
            return name.count > 20 ? String(name.prefix(20)) + "..." : name
        default:
            return nil
        }
    }

    private func tabIcon(_ tab: WorkspaceTab) -> String {
        tab.kind.icon
    }

    private func closeableTabShortcut(_ tab: WorkspaceTab) -> String? {
        guard tab.isCloseable,
              let idx = model.tabs.firstIndex(of: tab),
              idx < 9 else { return nil }
        return "\(idx + 1)"
    }

    private func tabShortcut(_ tab: WorkspaceTab) -> String? {
        tab.kind.shortcutBadge
    }

    private func addTerminal() {
        _ = model.addTerminal()
    }

    private func addBrowser() {
        startRunIfNeeded()
        _ = model.addBrowser()
    }

    /// Starts the dev server when the browser asks for it — a browser tab with
    /// nothing serving it is a page that cannot load.
    ///
    /// Opening starts the run; closing does not stop it. That asymmetry is the
    /// point: a browser tab is one view onto a running server, and the last one
    /// closing says nothing about whether the server is still wanted. Only the
    /// Execution tab's close stops a run — see `closingTabStopsRun`.
    private func startRunIfNeeded() {
        guard resolvedRunCommand != nil else { return }
        guard sessionMode != .waitingForTools, !appEnv.isDetecting else { return }
        guard portDetector.status == .none else { return }
        restartRun()
    }

    /// Start, after reclaiming this workstream's execute socket if anything is
    /// still holding it.
    ///
    /// `process-compose up` refuses to bind a socket another server holds:
    /// `unix socket <path> is already in use`, exit 1. In the chained
    /// `prepare && execute` that `ProcessCompose.PhaseRunner.startCommand`
    /// builds, it refuses at the **end** — so the user waits out the entire
    /// prepare phase, which for a real project is an install, a package build
    /// and a bundle install, and is then told about a unix socket.
    ///
    /// Whatever holds it is this workstream's own orphaned run: the path is
    /// named for the workstream id. It happens because `stopRun` kills the tmux
    /// session and drops the surface without ever calling `down`, so a server
    /// can outlive the run Atelier believes it stopped — and `runStarted` then
    /// reads false while the socket is still bound, which is exactly the state
    /// that makes Start look available and fail.
    ///
    /// Reclaiming belongs to Start rather than to Stop, or as well as to Stop:
    /// Start already means "tear down and re-run" — it kills the tmux session
    /// and bumps `runGeneration` — and a server stranded by a *crash*, or by a
    /// quit that raced `stopAllServers`, was never going to be cleaned up by a
    /// Stop that is not coming.
    ///
    /// A leftover socket *file* is deliberately not handled: process-compose
    /// overwrites one. See `ProcessCompose.Client.isServerListening`.
    ///
    /// Every way into a run comes through here — the Start button, Rerun via
    /// `restartRun`, and the browser tab via `startRunIfNeeded` — so the probe
    /// is paid once and cannot be routed around.
    @MainActor
    private func doStartRun() {
        guard let command = resolvedRunCommand else { return }

        // A reclaim already in flight owns this press. See
        // `isReclaimingRunSocket`.
        guard !isReclaimingRunSocket else { return }

        let socketPath = ProcessCompose.PhaseRunner.socketPath(for: workstreamID)
        guard ProcessCompose.Client.isServerListening(atSocketPath: socketPath),
              let binary = ProcessCompose.Settings.resolveBinary()
        else {
            beginRun(command: command)
            return
        }

        logger.warning("[Atelier] doStartRun: reclaiming execute socket still in use")
        let worktree = workingDirectory
        isReclaimingRunSocket = true
        Task {
            // Cleared however this ends — a thrown or cancelled Task that left
            // the flag set would make Start permanently inert for this
            // workstream, which is worse than the double-press it prevents.
            defer { isReclaimingRunSocket = false }
            // `down` spawns a child and waits on it, so it stays off the main
            // actor. The run begins once the socket is free, not before: that
            // ordering is the whole point.
            await Task.detached {
                ProcessCompose.PhaseExecutor.shutDown(
                    binary: binary,
                    socketPath: socketPath,
                    workingDirectory: worktree
                )
            }.value
            beginRun(command: command)
        }
    }

    /// Starts the run session. The command is either the user's own override or
    /// the phase-scoped `prepare && execute` Atelier composes from the located
    /// config. Nothing here is gated behind approval, because this is attended:
    /// the user pressed Start, the output lands in a surface in front of them,
    /// and Stop is to hand. The pane does *not* display this command — what it
    /// shows for a process-compose source is the list of files that will be
    /// loaded.
    private func beginRun(command: String) {
        // A run always gets an Execution tab, because that tab is what can
        // see and stop it — and, since browser tabs stopped claiming the run,
        // the only thing that can. `addBrowser` starts the dev server through
        // `startRunIfNeeded` and opens only a browser, so without this a run
        // could exist with no Execution tab at all and nothing left that
        // stops it short of quitting. This line is what keeps
        // `closingTabStopsRun`'s single owner present for every run.
        //
        // Ensure rather than activate: the browser tab the user just asked for
        // must keep focus.
        model.ensureSingleton(.execution)
        killRunTmuxSession()
        surfaceCache.removeSurface(for: runID)
        model.runStoppedManually = false
        model.runGeneration += 1
        model.runCommandString = buildRunCommand(script: command)
        model.runStarted = true
        markBrowserStartPending()
        preloadRunSurface()
    }

    private func stopRun() {
        killRunTmuxSession()
        surfaceCache.removeSurface(for: runID)
        model.runStoppedManually = true
        model.runStarted = false
        browserStartPending = false
        model.runCommandString = nil
        model.runGeneration += 1
    }

    /// Whether this workstream's run is a process-compose run, and so has a
    /// control socket worth polling. Read off the already-resolved dev command
    /// rather than re-locating the config, because this is read per render (via
    /// `tabContent`'s `.execution` case) and locating stats the filesystem.
    ///
    /// `resolvedRunCommand`'s process-compose branch requires this to be true
    /// first, so the two cannot disagree about whether process-compose is in
    /// play. This can still be true while `resolveBinary()` fails — a config
    /// was detected, there is just nothing to run it with — and in that state
    /// `resolvedRunCommand` is now **nil**, so Start reports that no command is
    /// available and this table simply never gets a run to poll.
    ///
    /// A previous version of this comment reasoned about that state and
    /// concluded it "does not violate the invariant this guards", on the
    /// grounds that the worst case was a table reading "Nothing running."
    /// **That was wrong, and the error was in what it measured.** The invariant
    /// that matters is not about the table: it is that the un-`-n`'d
    /// `process-compose up -U -f <files>` string is never executed. Back then
    /// `resolvedRunCommand` did fall through to exactly that string when the
    /// binary was unresolvable, which ran `bootstrap` and `dispose` with no
    /// approval — and `scriptCommand` wrapped it in `$SHELL -lic`, so PATH
    /// resolved the very binary `resolveBinary` had just failed to find.
    /// Reasoning about the process table hid that for a whole review round.
    /// `ProcessCompose.RunCommandPlan` now holds the invariant structurally; this property is
    /// only about whether there is a socket worth polling.
    ///
    /// The `isEnabled` half is belt-and-braces rather than the load-bearing
    /// check: `DevCommand.Resolver.detectProcessCompose` refuses to detect
    /// anything while the setting is off, so a `.processCompose` source already
    /// implies it. Kept anyway, because the two are read from different places
    /// and a reader here should not have to go and confirm that the resolver
    /// still guards. It cannot *disagree* with the resolver — only be redundant
    /// with it.
    private var usesProcessCompose: Bool {
        ProcessCompose.Settings.isEnabled && resolvedDevCommand?.source == .processCompose
    }

    /// Polls the control socket exactly while a process-compose run is up.
    /// Called from every place `runStarted` can change, including the tmux
    /// restore path, which sets it without going through `doStartRun`.
    @MainActor
    private func syncProcessPolling() {
        if model.runStarted, usesProcessCompose {
            processTable.startPolling()
        } else {
            processTable.stopPolling()
        }
    }

    /// Rerun: stop what is running, then go through Start.
    ///
    /// This used to inline `beginRun`'s body — kill the tmux session, bump
    /// `runGeneration`, set `runStarted` — and so skipped the socket reclaim
    /// entirely. Rerun is the path *most* likely to need it: killing the tmux
    /// session without calling `down` is exactly how a process-compose server
    /// gets stranded, and Rerun does that immediately before running `up`
    /// again on the same socket. It failed the way Start used to, at the end
    /// of prepare.
    ///
    /// Routing through `stopRun` first, rather than teaching this path its own
    /// reclaim, is what keeps Stop out of the reclaim window: `runStarted` is
    /// false for the whole of it, and the Stop and Rerun controls are rendered
    /// only when it is true. A Stop landing mid-reclaim would otherwise be
    /// followed by the run it just cancelled.
    ///
    /// `stopRun` sets `runStoppedManually`, which suppresses the tmux restore —
    /// but `beginRun` clears it again on the far side, so the pair lands where
    /// the old inline body did.
    private func restartRun() {
        // Kept ahead of `stopRun`: without it a Rerun with no runnable command
        // would stop the run and then decline to start one, which is a Stop
        // wearing Rerun's label.
        guard resolvedRunCommand != nil else { return }
        if model.runStarted {
            stopRun()
        }
        doStartRun()
    }

    /// Marks the start so browser tabs hold the waiting overlay until a port
    /// appears. Self-clears after a few seconds so a failed spawn (nothing
    /// ever wrote state) still falls through to the error view.
    @MainActor
    private func markBrowserStartPending() {
        browserStartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            guard browserStartPending else { return }
            browserStartPending = false
        }
    }

    /// Create the run surface eagerly so the dev server starts even while the
    /// browser tab is active and the Info pane is not rendered.
    private func preloadRunSurface() {
        guard let commandString = model.runCommandString else { return }
        guard let app = TerminalApp.shared.app else { return }
        _ = surfaceCache.surface(
            for: runID,
            app: app,
            workingDirectory: workingDirectory,
            command: commandString,
            environmentVars: runEnvironmentVars
        )
    }

    /// Assembles the final run command: atelier-run wrap (port detection) + tmux wrap.
    private func buildRunCommand(script: String) -> String {
        let baseCommand: String
        let ffRunPath = RunLauncher.executableURL()?.path
        if let launcherPath = ffRunPath {
            baseCommand = runScriptCommand(script: script, workstreamID: workstreamID, launcherPath: launcherPath)
        } else {
            baseCommand = scriptCommand(script: script)
        }

        let finalCommand: String
        if useTmux, let tmuxPath = appEnv.toolStatus.tmux.path {
            let session = TmuxSession.sessionName(project: projectName, workstream: workstreamName, role: "run")
            finalCommand = TmuxSession.wrapCommand(tmuxPath: tmuxPath, sessionName: session, command: baseCommand, environmentVars: runEnvironmentVars)
        } else {
            finalCommand = baseCommand
        }

        var intermediates = [script, baseCommand]
        if finalCommand != baseCommand {
            intermediates.append(finalCommand)
        }
        LaunchLogger.log(LaunchLogEntry(
            workstreamID: workstreamID,
            event: "run-start",
            finalCommand: finalCommand,
            intermediateCommands: intermediates,
            environmentVariables: runEnvironmentVars,
            workingDirectory: workingDirectory,
            toolPaths: LaunchLogEntry.ToolPaths(
                claude: nil,
                tmux: useTmux ? appEnv.toolStatus.tmux.path : nil,
                ffRun: ffRunPath
            ),
            settings: LaunchLogEntry.Settings(
                tmuxMode: useTmux,
                bypassPermissions: false,
                autoRenameBranch: false,
                allowOutsideWorktree: false
            ),
            shell: CommandBuilder.userShell
        ))

        return finalCommand
    }

    /// Re-resolve the dev command *and* the run plan, together.
    ///
    /// One function on purpose. The plan is derived from the dev command, and
    /// every caller that invalidates one invalidates the other, so splitting
    /// them would give the pane a way to render a button whose plan came from an
    /// earlier dev command. Both are also the only two inputs the Start button
    /// reads, so this is the whole of what has to stay in step.
    private func refreshDevCommand() {
        let devCommand = DevCommand.Resolver.resolve(
            workingDirectory: workingDirectory,
            projectDirectory: projectDirectory,
            override: devCommandOverride
        )
        resolvedDevCommand = devCommand
        let config = processComposeConfig(for: devCommand)
        let binary = ProcessCompose.Settings.resolveBinary()
        devCommandFiles = config?.loadedFiles ?? []
        runPlan = ProcessCompose.RunCommandPlan.plan(devCommand: devCommand, config: config, binary: binary)
        runUnavailableReason = ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: devCommand,
            config: config,
            binary: binary,
            isEnabled: ProcessCompose.Settings.isEnabled
        )
        // Same triggers, deliberately: the Verification tab answers to the
        // integration switch and the binary path too, and Task 11's first
        // version resolved them on `.onAppear` alone — so flipping the switch
        // in Settings never reached the tab.
        refreshVerificationAvailability()
    }

    /// Resolve the Verification tab's two availability inputs together, from
    /// `PhasePolicy.plan`.
    ///
    /// **The decision is `plan`'s, and this function does not make a second
    /// one.** `Verification.Runner.start` calls
    /// `PhasePolicy.plan(phase: .verify, …)` before it spawns anything, so the
    /// tab's idea of "nothing can run" has to come from that same call — a
    /// separate precondition chain here would be the duplicate
    /// `ExecutionTabView.canStart`'s own doc records as a bug already paid for
    /// once: "They used to be two […] and an unresolvable process-compose
    /// binary rendered an enabled Start that did nothing and explained
    /// nothing." `verificationUnavailableReason` is called for the *wording*
    /// only, and is handed the very locals `plan` was given, so the two cannot
    /// disagree about the facts. `plan`'s own strings are past tense ("so no
    /// `verify` ran") because they report on bootstrap and dispose after the
    /// fact; this tab has run nothing, so none of them may appear here.
    ///
    /// `.run` is not quite the whole of availability, and this is the part that
    /// is easy to miss: `plan` answers the four preconditions and stops, so a
    /// config that declares no `verify` processes — or that could not be parsed
    /// at all — still comes back `.run`. `start` refuses both (`Failure.unavailable`
    /// for a parse failure, `resolveChecks` for an empty declared list, because
    /// `up -n verify` on an empty namespace never exits), so the declared list
    /// is the fifth fact the wording needs. It is read only on the `.run`
    /// branch: `plan` is what decides whether asking is meaningful.
    ///
    /// Called from `refreshDevCommand`, so every trigger that re-resolves the
    /// Execution tab's equivalent state re-resolves this too, and from the two
    /// approval paths — approval is one of the four facts and
    /// `refreshDevCommand` does not observe it.
    private func refreshVerificationAvailability() {
        // Located unconditionally, the way `refreshConfigApproval` does it and
        // `processComposeConfig(for:)` deliberately does not: that one is
        // narrowed to the *run*, so it disappears behind a per-workstream
        // override — and verify is not the run.
        let isEnabled = ProcessCompose.Settings.isEnabled
        let config = ProcessCompose.Config.locate(
            worktree: workingDirectory, projectDirectory: projectDirectory
        )
        let binary = ProcessCompose.Settings.resolveBinary()
        // Folds in `requiresApproval` so it means what `plan`'s guard means: a
        // config the user placed in the project directory needs no approval.
        // Resolved to a `Bool` up front, rather than left as `plan`'s closure,
        // so the fact `plan` judged and the fact the wording is produced from
        // are literally the same value.
        let isApproved = config.map {
            !$0.requiresApproval || ScriptTrust.isApproved(
                configFiles: $0.repositoryProvidedFiles, for: projectDirectory
            )
        } ?? false
        let plan = PhasePolicy.plan(
            phase: .verify,
            isEnabled: isEnabled,
            config: config,
            binary: binary,
            isApproved: { _ in isApproved }
        )

        let declared: [String]? = switch plan {
        case let .run(planConfig, _):
            // Read off the plan's own config rather than by locating a second
            // time — the rule `declaredExecuteProcesses` follows, so the list
            // the checklist offers and the config `start` will run are one
            // config. nil means "could not be parsed" and is never folded into
            // an empty list: `verificationUnavailableReason` tells the two
            // apart, and they need different words.
            planConfig.declaredProcesses(in: ProcessCompose.Phase.verify.namespace)
        case .nothingToDo:
            nil
        }
        declaredVerifyChecks = declared ?? []
        verifyUnavailableReason = verificationUnavailableReason(
            isEnabled: isEnabled,
            hasConfig: config != nil,
            hasBinary: binary != nil,
            isApproved: isApproved,
            declared: declared
        )
    }

    /// Re-reads ports.yaml and resolves it for this worktree. A malformed file
    /// leaves the plan empty and logs — the Execution tab surfaces the error
    /// in Task 8; nothing here should throw into a view update.
    private func refreshPortPlan() {
        do {
            guard let config = try ProcessCompose.PortsConfig.load(from: projectDirectory) else {
                portPlan = .empty
                return
            }
            portPlan = ProcessCompose.PortPlan.resolve(config, workingDirectory: workingDirectory)
        } catch {
            logger.warning("ports.yaml: \(error.localizedDescription, privacy: .public)")
            portPlan = .empty
        }
    }

    private func killRunTmuxSession() {
        guard useTmux, let tmuxPath = appEnv.toolStatus.tmux.path else { return }
        let session = TmuxSession.sessionName(project: projectName, workstream: workstreamName, role: "run")
        TmuxSession.killSession(tmuxPath: tmuxPath, sessionName: session)
    }

    /// Restores `runStarted` from a run session already alive in tmux —
    /// survives relaunch, or a session started before this container existed.
    /// Lives here rather than on the Execution tab because it must run
    /// before the user ever opens that tab: on launch (once tool detection
    /// has resolved whether tmux is usable) and whenever detection state
    /// changes. The guards make re-invocation harmless.
    private func restoreRunState() {
        guard !model.runStarted,
              useTmux,
              resolvedRunCommand != nil,
              let tmuxPath = appEnv.toolStatus.tmux.path else { return }
        let session = TmuxSession.sessionName(project: projectName, workstream: workstreamName, role: "run")
        let hasExistingRunSession = TmuxSession.sessionExists(tmuxPath: tmuxPath, sessionName: session)
        if shouldRestoreRunSession(
            useTmux: useTmux,
            hasRunScript: resolvedRunCommand != nil,
            hasExistingRunSession: hasExistingRunSession,
            wasStoppedManually: model.runStoppedManually
        ) {
            // The same guarantee `beginRun` makes, on the other path that can
            // set `runStarted`. Only the Execution tab's close stops a run
            // (`closingTabStopsRun`), so a restored run without that tab is a
            // run nothing can stop short of quitting — and the tab really can
            // be absent here: `terminalTabExited` sets `runStarted = false`
            // and deliberately leaves `runStoppedManually` alone, so the tab
            // can be closed with no consequence while tmux still has a session
            // for the next launch to find.
            model.ensureSingleton(.execution)
            model.runStarted = true
        }
    }

    private func openEditor() {
        addEditor()
    }

    /// Show the Changes tab, reopening it first if the user closed it.
    private func addChanges() {
        model.activateSingleton(.changes)
    }

    private func addEditor(filePath: String? = nil) {
        // Create bridge before adding the tab — never during body evaluation
        createEditorBridgeIfNeeded()
        _ = model.addEditor(filePath: filePath)
        startFileTreeWatcherIfNeeded()
    }

    private func startFileTreeWatcherIfNeeded() {
        guard directoryWatcher == nil else { return }
        refreshFileTree()
        directoryWatcher = DirectoryWatcher(path: workingDirectory) { [self] in
            debounceRefreshFileTree()
        }
    }

    private func debounceRefreshFileTree() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refreshFileTree()
        }
    }

    private func refreshFileTree() {
        refreshGeneration += 1
        let gen = refreshGeneration
        let currentTree = fileTree
        DispatchQueue.global(qos: .userInitiated).async {
            let tree: [FileNode] = if currentTree.isEmpty {
                FileNode.buildShallowTree(rootPath: workingDirectory)
            } else {
                FileNode.refreshLoadedNodes(in: currentTree, rootPath: workingDirectory)
            }
            let statuses = Git.Operations.fileStatuses(at: workingDirectory)
            DispatchQueue.main.async {
                guard gen == refreshGeneration else { return }
                fileTree = tree
                gitFileStatuses = Git.FileStatusProvider(fileStatuses: statuses)
            }
        }
    }

    private func expandFileTreeFolder(_ relativePath: String) {
        if let node = FileNode.findNode(atPath: relativePath, in: fileTree), node.isLoaded {
            return
        }
        let gen = refreshGeneration
        let root = workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let children = FileNode.loadChildren(atRelativePath: relativePath, rootPath: root)
            DispatchQueue.main.async {
                guard gen == refreshGeneration else { return }
                fileTree = FileNode.insertChildren(children, atPath: relativePath, in: fileTree)
            }
        }
    }

    private func stopFileTreeWatcherIfUnneeded() {
        if !model.hasEditorTabs {
            refreshGeneration += 1
            directoryWatcher?.stop()
            directoryWatcher = nil
            fileTree = []
            gitFileStatuses = Git.FileStatusProvider()
            // The Monaco bridge is deliberately untouched here: it lives on
            // WorkspaceModel (model.editorBridge) precisely so closing the
            // last editor tab never tears down the ~17 MB WebView.
        }
    }

    private func createEditorBridgeIfNeeded() {
        guard model.editorBridge == nil else { return }
        let bridge = model.ensureEditorBridge()
        // `weak`, not a strong capture: the model owns the bridge, the bridge owns
        // this closure, so a strong `model` here would retain a whole Monaco
        // WebView per workstream forever.
        bridge.onContentChanged = { [weak model] modelId, dirty in
            guard let model, let uuid = UUID(uuidString: modelId) else { return }
            model.editorDirtyState[uuid] = dirty
        }
    }

    private func createDiffBridgeIfNeeded() {
        model.ensureDiffBridge()
    }

    private func closeTab(_ tab: WorkspaceTab) {
        if case let .editor(id) = tab, model.editorDirtyState[id] == true {
            confirmCloseEditor(tab: tab, id: id)
            return
        }
        forceCloseTab(tab)
    }

    private func confirmCloseEditor(tab: WorkspaceTab, id: UUID) {
        let fileName = (model.editorFilePaths[id] as? NSString)?.lastPathComponent ?? "file"
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Do you want to save changes to \"%@\"?", comment: ""),
            fileName
        )
        alert.informativeText = NSLocalizedString("Your changes will be lost if you don't save them.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Don't Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Save then close — async to wait for bridge.getContent()
            Task {
                if let bridge = model.editorBridge,
                   let relativePath = model.editorFilePaths[id]
                {
                    let fullPath = (workingDirectory as NSString)
                        .appendingPathComponent(relativePath)
                    // A nil result means this bridge never opened the model.
                    // There is nothing to write, but the close must still
                    // happen — a Save the user asked for can never silently
                    // do nothing.
                    if let content = await bridge.getContent(modelId: id.uuidString) {
                        do {
                            try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
                        } catch {
                            let errorAlert = NSAlert(error: error)
                            errorAlert.runModal()
                            return
                        }
                    }
                }
                forceCloseTab(tab)
            }
        case .alertSecondButtonReturn:
            // Don't save, just close
            forceCloseTab(tab)
        default:
            // Cancel — do nothing
            break
        }
    }

    private func forceCloseTab(_ tab: WorkspaceTab) {
        // The model drops the tab and moves the selection to a neighbour; the
        // view is left to tear down the resources the tab was holding.
        guard model.removeTab(tab) else { return }

        switch tab {
        case let .terminal(id):
            surfaceCache.removeSurface(for: id)
        case let .browser(id):
            surfaceCache.removeWebView(for: id)
        case let .editor(id):
            model.editorBridge?.closeModel(modelId: id.uuidString)
        default:
            break
        }
        // Which tab's close stops the run is one rule, tested without a view.
        // It lives outside the switch because it is not per-tab teardown: the
        // run is a workstream-wide thing that exactly one tab owns, and asking
        // the question once here is what keeps a second tab from quietly
        // claiming it again.
        if closingTabStopsRun(tab, runStarted: model.runStarted) {
            stopRun()
        }
        stopFileTreeWatcherIfUnneeded()
    }

    private func moveCustomTab(to targetTab: WorkspaceTab) {
        guard let currentDraggedTab = draggedCustomTab else { return }
        model.moveTab(dragging: currentDraggedTab, to: targetTab)
        draggedCustomTab = nil
    }

    @MainActor
    private func startWorkspace(defaultBranch: String) {
        self.defaultBranch = defaultBranch
        quickActionRunner.onSuccess = { action in
            appEnv.refreshWorktreeState(for: workingDirectory, projectDirectory: projectDirectory)
            if let branch = appEnv.branchName(for: workingDirectory) {
                if action == .closePR {
                    appEnv.clearBranchPR(for: projectDirectory, branch: branch)
                }
                if action == .createPR || action == .closePR {
                    appEnv.refreshGitHubInfo(for: projectDirectory, branch: branch)
                }
            }
        }
        appEnv.refreshWorktreeState(for: workingDirectory, projectDirectory: projectDirectory)
        rebuildClaudeCommand()
        refreshConfigApproval()
        refreshPortPlan()
        refreshDevCommand()
        surfaceCache.respawnableIDs.insert(claudeID)
        preloadSurfaces()
        // Eagerly create the Monaco bridge so it's ready when the user opens
        // an editor tab. The WKWebView is created lazily when MonacoEditorView
        // enters the tree (it needs a real container to avoid 0x0 initialization).
        createEditorBridgeIfNeeded()
        createDiffBridgeIfNeeded()
        surfaceCache.updateOcclusion(visibleSurfaceIDs: visibleSurfaceIDs)
    }

    /// Pre-create terminal surfaces so they start running before their tab is visible.
    private func preloadSurfaces() {
        guard sessionMode != .waitingForTools else { return }
        guard let app = TerminalApp.shared.app else { return }
        if let cmd = cachedClaudeCommand {
            _ = surfaceCache.ensureSurface(
                for: claudeID,
                app: app,
                workingDirectory: workingDirectory,
                command: cmd,
                environmentVars: envVars
            )
        }
    }

    /// Env vars for surfaces that are not the Coding Agent: the run session and
    /// the base for terminal tabs. Clears tmux vars to prevent
    /// inheritance, and the Agent surface's id — a tab that kept it would claim
    /// the Agent's pane as its nudge target, which is the exact misdelivery the
    /// per-surface marker exists to prevent.
    private var terminalEnvVars: [String: String] {
        var vars = envVars
        vars["TMUX"] = ""
        vars["TMUX_PANE"] = ""
        vars.removeValue(forKey: "ATELIER_SURFACE_ID")
        return vars
    }

    /// Env vars for one terminal tab, carrying that tab's own surface id.
    ///
    /// An agent the user starts by hand in a tab can then be messaged *and*
    /// nudged in its own pane, instead of being pull-only for want of an
    /// address. The run surface deliberately stays on the plain
    /// `terminalEnvVars` above: nothing there reads an inbox, so nothing should
    /// be typed into it.
    private func terminalEnvVars(for surfaceID: UUID) -> [String: String] {
        var vars = terminalEnvVars
        vars["ATELIER_SURFACE_ID"] = surfaceID.uuidString
        return vars
    }

    /// Env vars for the Coding Agent surface.
    private var envVars: [String: String] {
        var vars = workspaceEnvironmentVariables(
            workstreamID: workstreamID,
            projectName: projectName,
            workstreamName: workstreamName,
            projectDirectory: projectDirectory,
            workingDirectory: workingDirectory,
            port: workstreamPort,
            defaultBranch: defaultBranch,
            portPlan: portPlan
        )
        // claudeID is the workstream id, so the Agent surface addresses itself
        // the same way every other surface does.
        vars["ATELIER_SURFACE_ID"] = claudeID.uuidString
        return vars
    }

    // MARK: - Process config approval

    /// Re-reads whether this worktree has a repository-provided config and
    /// whether it is approved. Called on appear and after an approval, not from
    /// the view body: it stats the worktree and hashes a file.
    private func refreshConfigApproval() {
        guard ProcessCompose.Settings.isEnabled,
              let config = ProcessCompose.Config.locate(
                  worktree: workingDirectory, projectDirectory: projectDirectory
              ),
              config.requiresApproval
        else {
            repositoryConfigFiles = []
            configApproved = false
            return
        }
        repositoryConfigFiles = config.repositoryProvidedFiles
        configApproved = ScriptTrust.isApproved(
            configFiles: repositoryConfigFiles, for: projectDirectory
        )
    }

    /// Approve the repository's config, then run the bootstrap it was refused.
    ///
    /// Bootstrap already ran — and reported that it did nothing — by the time
    /// anyone can see this, so approval on its own would only help the *next*
    /// worktree. `setupExistingWorktree` recomputes the plan against the
    /// worktree that already exists, which is what makes this one recoverable.
    private func approveProcessConfig() {
        guard !repositoryConfigFiles.isEmpty else { return }
        ScriptTrust.approve(configFiles: repositoryConfigFiles, for: projectDirectory)
        isReviewingConfig = false
        refreshConfigApproval()
        // Approval is one of `PhasePolicy.plan`'s four facts, and it is the one
        // `refreshDevCommand` has no reason to watch — Start is never gated by
        // it. Without this the Verification tab would keep telling the user to
        // approve a config they just approved.
        refreshVerificationAvailability()
        // An unreadable file has no fingerprint, so `approve` was a no-op and
        // nothing has been trusted. Do not run anything on the strength of a
        // button press that did not take.
        guard configApproved else { return }
        rerunBootstrap()
    }

    /// Run the project's `bootstrap` namespace against this worktree again.
    ///
    /// Two callers, and deliberately no preconditions of its own.
    /// `approveProcessConfig` calls it to recover the bootstrap its approval
    /// was too late for; the Info tab's Rerun button and the palette's Rerun
    /// Bootstrap call it because the user asked.
    ///
    /// In particular this is **not** behind `configApproved`.
    /// `approveProcessConfig` checks that before calling, because there the
    /// guard is asking whether the approval it just wrote actually took — an
    /// unreadable file has no fingerprint, so `approve` was a no-op. A manual
    /// rerun has no approval to doubt, and every reason bootstrap might do
    /// nothing is `PhasePolicy.plan`'s to decide and report as a
    /// `.completedWithNote` the Info row renders. Guarding here would trade
    /// that explanation for a button that silently does nothing, in the one
    /// state where the user most needs to be told why.
    private func rerunBootstrap() {
        let id = workstreamID
        let project = projectDirectory
        let worktree = workingDirectory
        // Copied out for the same reason as the paths above: capturing a
        // stored property would capture the whole view into the Task.
        let capturedProjectName = projectName
        let capturedWorkstreamName = workstreamName
        Task {
            await AsyncSetupService.shared.setupExistingWorktree(
                workstreamID: id,
                projectName: capturedProjectName,
                workstreamName: capturedWorkstreamName,
                projectPath: project,
                worktreePath: worktree
            )
        }
    }

    private func revokeProcessConfig() {
        ScriptTrust.revokeConfigFiles(for: projectDirectory)
        refreshConfigApproval()
        refreshVerificationAvailability()
    }

    private func terminalLoadingView(message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab button

private struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let label: String?
    let icon: String
    var shortcut: String?
    let isActive: Bool
    var isDirty: Bool = false
    let onSelect: () -> Void
    var onClose: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isDirty {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 6, height: 6)
            }
            Image(systemName: icon)
                .font(.system(size: 11))
            if let label {
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            if let shortcut {
                (Text(Image(systemName: "command")) + Text(shortcut))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let onClose, isHovering || isActive {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(Circle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.15) : (isHovering ? Color.primary.opacity(0.05) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(isActive ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

/// One singleton tab's quick-add button, as data.
///
/// The tab bar's trailing group holds two kinds of button and the divider
/// between them says so: everything in `all` reopens a tab there is exactly
/// one of, everything after the divider adds another of a kind there can be
/// many of. A new singleton kind is one entry here and nothing else — the
/// buttons and the divider both read the list, so neither can be added
/// without the other.
private struct SingletonQuickAdd {
    let tab: WorkspaceTab
    /// Spelled out rather than derived from the kind's label: a key built by
    /// interpolation is a key `genstrings` cannot see.
    let tooltip: String

    static let all: [SingletonQuickAdd] = [
        SingletonQuickAdd(tab: .changes, tooltip: NSLocalizedString("Show Changes", comment: "Tab bar button tooltip")),
        SingletonQuickAdd(tab: .execution, tooltip: NSLocalizedString("Show Execution", comment: "Tab bar button tooltip")),
    ]
}

private struct TabBarActionButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? .primary : .tertiary)
                .padding(.horizontal, 6)
                .frame(minHeight: 24)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }
}

private struct WorkspaceTabDropDelegate: DropDelegate {
    let onDropTab: () -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        true
    }

    func performDrop(info _: DropInfo) -> Bool {
        onDropTab()
        return true
    }
}

private struct GitHubActionMenu: View {
    @ObservedObject var runner: QuickAction.Runner
    let claudePath: String?
    let ghPath: String?
    let workingDirectory: String
    let branchName: String?
    let bypassPermissions: Bool
    let worktreeState: Worktree.State
    let hasGitHubRemote: Bool
    let branchPR: GitHub.PR?

    private var prState: String? {
        branchPR?.state
    }

    private var hasOpenPR: Bool {
        prState == "OPEN"
    }

    private var isMerged: Bool {
        prState == "MERGED"
    }

    /// The most relevant next action to move the workflow forward.
    private var primaryAction: PrimaryAction? {
        if isMerged {
            return nil
        }
        if hasOpenPR {
            if worktreeState.hasUncommittedChanges {
                return .quickAction(.commit)
            }
            if worktreeState.hasUnpushedCommits, worktreeState.hasRemote {
                return .quickAction(.push)
            }
            if let pr = branchPR {
                return .openPR(pr)
            }
        }
        if prState == nil, hasGitHubRemote, worktreeState.hasBranchCommits {
            return .quickAction(.createPR)
        }
        if worktreeState.hasUncommittedChanges {
            return .quickAction(.commit)
        }
        if worktreeState.hasUnpushedCommits, worktreeState.hasRemote {
            return .quickAction(.push)
        }
        return nil
    }

    /// Secondary actions shown in the dropdown, excluding the primary.
    private var secondaryActions: [PrimaryAction] {
        guard let primary = primaryAction else { return [] }
        var actions: [PrimaryAction] = []

        if worktreeState.hasUncommittedChanges {
            actions.append(.quickAction(.commit))
        }
        if worktreeState.hasUnpushedCommits, worktreeState.hasRemote {
            actions.append(.quickAction(.push))
        }
        if prState == nil, hasGitHubRemote, worktreeState.hasBranchCommits {
            actions.append(.quickAction(.createPR))
        }
        if let pr = branchPR, hasOpenPR {
            actions.append(.openPR(pr))
            actions.append(.quickAction(.closePR))
        }

        return actions.filter { $0 != primary }
    }

    private var isRunning: Bool {
        if case .running = runner.state {
            return true
        }
        return false
    }

    private func isRunningAction(_ action: QuickAction) -> Bool {
        if case let .running(a) = runner.state {
            return a == action
        }
        return false
    }

    private func resultState(for action: QuickAction) -> QuickAction.State? {
        switch runner.state {
        case let .succeeded(a) where a == action: runner.state
        case let .failed(a) where a == action: runner.state
        default: nil
        }
    }

    private func disabledReason(for action: QuickAction) -> String? {
        if action.usesLLM {
            if claudePath == nil {
                return NSLocalizedString("Claude Code is not installed.", comment: "Quick actions unavailable because the Claude Code CLI is missing")
            }
            if !bypassPermissions {
                return NSLocalizedString("Enable \"Bypass permission prompts\" in Settings.", comment: "")
            }
        }
        if action == .closePR, ghPath == nil {
            return NSLocalizedString("gh CLI is not installed.", comment: "")
        }
        return nil
    }

    private func runAction(_ action: QuickAction) {
        guard disabledReason(for: action) == nil else { return }
        runner.run(
            action: action,
            claudePath: claudePath,
            ghPath: ghPath,
            workingDirectory: workingDirectory,
            branchName: branchName
        )
    }

    private func executePrimary(_ action: PrimaryAction) {
        guard !isRunning else { return }
        switch action {
        case let .quickAction(qa):
            runAction(qa)
        case let .openPR(pr):
            if let url = URL(string: pr.url) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @ViewBuilder
    private func label(for action: PrimaryAction) -> some View {
        switch action {
        case let .quickAction(qa):
            if isRunningAction(qa) {
                ProgressView()
                    .controlSize(.mini)
            } else if case .succeeded = resultState(for: qa) {
                Label(qa.label, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else if case .failed = resultState(for: qa) {
                Label(qa.label, systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
            } else {
                Label(qa.label, systemImage: qa.icon)
                    .labelStyle(.titleAndIcon)
            }
        case let .openPR(pr):
            Label(
                String(format: NSLocalizedString("Open #%d", comment: ""), pr.number),
                systemImage: "arrow.up.forward"
            )
            .labelStyle(.titleAndIcon)
        }
    }

    var body: some View {
        if let primary = primaryAction {
            let secondary = secondaryActions
            if secondary.isEmpty {
                Button { executePrimary(primary) } label: { label(for: primary) }
                    .disabled(isRunning || primaryDisabled(primary))
                    .help(primaryHelp(primary))
            } else {
                Menu {
                    ForEach(secondary) { action in
                        switch action {
                        case let .quickAction(qa):
                            Button { runAction(qa) } label: {
                                Label(qa.label, systemImage: qa.icon)
                            }
                            .disabled(isRunning || disabledReason(for: qa) != nil)
                        case let .openPR(pr):
                            Button {
                                if let url = URL(string: pr.url) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label(
                                    String(format: NSLocalizedString("Open #%d", comment: ""), pr.number),
                                    systemImage: "arrow.up.forward"
                                )
                            }
                        }
                    }
                } label: {
                    label(for: primary)
                } primaryAction: {
                    executePrimary(primary)
                }
                .disabled(isRunning)
                .menuIndicator(.hidden)
                .help(primaryHelp(primary))
            }
        }
    }

    private func primaryDisabled(_ action: PrimaryAction) -> Bool {
        if case let .quickAction(qa) = action {
            return disabledReason(for: qa) != nil
        }
        return false
    }

    private func primaryHelp(_ action: PrimaryAction) -> String {
        if case let .quickAction(qa) = action {
            return disabledReason(for: qa) ?? qa.label
        }
        if case let .openPR(pr) = action {
            return pr.title
        }
        return ""
    }
}

/// Represents either a quick action or opening a PR in the browser.
private enum PrimaryAction: Equatable, Identifiable {
    case quickAction(QuickAction)
    case openPR(GitHub.PR)

    var id: String {
        switch self {
        case let .quickAction(qa): qa.id
        case let .openPR(pr): "openPR-\(pr.number)"
        }
    }
}

/// Names the tab strip's ScrollView frame, so the content's `minX` measured against it says
/// how far the strip has been scrolled rather than where it sits on screen. A file-level
/// constant because `ScrollableTabStrip` is generic, and a generic type cannot hold a static
/// stored property.
private let tabStripScrollSpace = "workspaceTabStrip"

/// A pixel of slack at each end of the tab strip. The reported offset settles on fractional
/// values, so comparing against a bare zero leaves the left arrow drawn at rest and the
/// right arrow drawn at the far end.
private let tabStripScrollEpsilon: CGFloat = 1

private struct ScrollableTabStrip<TabContent: View>: View {
    let tabs: [WorkspaceTab]
    let activeTab: WorkspaceTab
    @ViewBuilder let tabButton: (WorkspaceTab) -> TabContent

    @State private var contentOverflows = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var canScrollLeft: Bool {
        scrollOffset > tabStripScrollEpsilon
    }

    private var canScrollRight: Bool {
        scrollOffset < contentWidth - viewportWidth - tabStripScrollEpsilon
    }

    var body: some View {
        HStack(spacing: 0) {
            if contentOverflows, canScrollLeft {
                scrollArrow(direction: .left)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs, id: \.self) { tab in
                            tabButton(tab)
                                .id(tab)
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear
                            .preference(key: ContentWidthKey.self, value: geo.size.width)
                            // How far the content has been dragged out of the viewport's
                            // leading edge. Nothing wrote `scrollOffset` before this, so
                            // it sat at its initial 0 for the life of the view: the left
                            // arrow never appeared at any scroll position and the right
                            // arrow never went away at the end of the strip.
                            .preference(
                                key: ScrollOffsetKey.self,
                                value: -geo.frame(in: .named(tabStripScrollSpace)).minX
                            )
                    })
                }
                .coordinateSpace(name: tabStripScrollSpace)
                .onPreferenceChange(ContentWidthKey.self) { width in
                    contentWidth = width
                    checkOverflow()
                }
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    scrollOffset = offset
                }
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportWidth = geo.size.width; checkOverflow() }
                        .onChange(of: geo.size.width) { _, new in viewportWidth = new; checkOverflow() }
                })
                .onChange(of: activeTab) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(activeTab, anchor: .center)
                    }
                }
            }

            if contentOverflows, canScrollRight {
                scrollArrow(direction: .right)
            }
        }
    }

    private enum ScrollDirection {
        case left, right
    }

    private func scrollArrow(direction: ScrollDirection) -> some View {
        Button(action: {}) {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func checkOverflow() {
        contentOverflows = contentWidth > viewportWidth + 1
    }
}

private struct ContentWidthKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - SingleTerminalView

struct SingleTerminalView: View {
    let surfaceID: UUID
    let workingDirectory: String
    var command: String?
    var initialInput: String?
    var isFocused: Bool = true
    var environmentVars: [String: String] = [:]

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache

    var body: some View {
        if let failedCommand = surfaceCache.failedSurfaces[surfaceID] {
            SurfaceErrorView(command: failedCommand) {
                surfaceCache.retrySurface(for: surfaceID)
            }
        } else {
            GeometryReader { geo in
                TerminalSurfaceView(
                    surfaceID: surfaceID,
                    workingDirectory: workingDirectory,
                    command: command,
                    initialInput: initialInput,
                    isFocused: isFocused,
                    environmentVars: environmentVars,
                    size: geo.size
                )
            }
        }
    }
}

private struct SurfaceErrorView: View {
    let command: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Terminal failed to start")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal, 40)
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalSurfaceView: NSViewRepresentable {
    let surfaceID: UUID
    let workingDirectory: String
    var command: String?
    var initialInput: String?
    var isFocused: Bool = true
    var environmentVars: [String: String] = [:]
    var size: CGSize

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard let app = TerminalApp.shared.app else { return }

        let terminalView = surfaceCache.surface(
            for: surfaceID,
            app: app,
            workingDirectory: workingDirectory,
            command: command,
            initialInput: initialInput,
            environmentVars: environmentVars
        )

        if terminalView.superview !== container {
            terminalView.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(terminalView)
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        // Explicitly push the SwiftUI-measured size to the Ghostty surface.
        // SwiftUI does not reliably call NSView.setFrameSize on resize
        // (see Ghostty SurfaceView.swift:613-616), so we drive it from
        // the GeometryReader instead.
        if terminalView.window != nil {
            terminalView.notifySizeChanged(size)
        }

        if isFocused {
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }
}

// MARK: - Surface cache

extension Notification.Name {
    static let terminalTabExited = Notification.Name("atelier.terminalTabExited")
}

@MainActor
final class TerminalSurfaceCache: ObservableObject {
    private var surfaces: [UUID: TerminalView] = [:]
    private var surfaceParams: [UUID: SurfaceParams] = [:]
    private var webViews: [UUID: WKWebView] = [:]
    private var quickActionRunners: [UUID: QuickAction.Runner] = [:]
    private var workspaceModels: [UUID: WorkspaceModel] = [:]
    /// Surface IDs that should respawn when closed (e.g., the agent).
    var respawnableIDs: Set<UUID> = []
    /// Guards against concurrent respawns for the same surface ID.
    private var respawning = Set<UUID>()
    /// Surface IDs where creation failed, with the command that was attempted.
    private(set) var failedSurfaces: [UUID: String] = [:]
    /// Tracks when each surface was created, for detecting immediate process death.
    private var creationTimes: [UUID: Date] = [:]
    /// Surfaces created outside the view, running a command the view did not
    /// choose. See `seedSurface` and the adoption branch in `ensureSurface`.
    private var seededSurfaces: Set<UUID> = []
    /// Surfaces that died within this interval after creation are treated as launch failures.
    private static let healthCheckWindow: TimeInterval = 2.0

    struct SurfaceParams {
        let workingDirectory: String
        let command: String?
        let initialInput: String?
        let environmentVars: [String: String]
    }

    init() {
        NotificationCenter.default.addObserver(
            forName: .terminalSurfaceClosed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let closedView = notification.object as? TerminalView else { return }
            Task { @MainActor in
                self.handleSurfaceClosed(closedView)
            }
        }
    }

    /// Marks surfaces in the given set as visible; all others are occluded.
    /// Pass nil to mark all surfaces as visible.
    func updateOcclusion(visibleSurfaceIDs: Set<UUID>?) {
        for (id, view) in surfaces {
            let visible = visibleSurfaceIDs.map { $0.contains(id) } ?? true
            view.setVisible(visible)
        }
    }

    func surface(for id: UUID, app: ghostty_app_t, workingDirectory: String, command: String? = nil, initialInput: String? = nil, environmentVars: [String: String] = [:]) -> TerminalView {
        if let existing = surfaces[id] {
            existing.workstreamID = id
            return existing
        }
        let view = TerminalView(app: app, workingDirectory: workingDirectory, command: command, initialInput: initialInput, environmentVars: environmentVars)
        view.workstreamID = id
        surfaces[id] = view
        surfaceParams[id] = SurfaceParams(workingDirectory: workingDirectory, command: command, initialInput: initialInput, environmentVars: environmentVars)
        if view.surface == nil {
            logger.error("Surface creation failed for \(id) command=\(command ?? "<shell>")")
            failedSurfaces[id] = command ?? "(default shell)"
            objectWillChange.send()
        } else {
            creationTimes[id] = Date()
        }
        return view
    }

    /// Creates a surface whose command a non-view caller chose, and records that
    /// the view must *adopt* it rather than reconcile it.
    ///
    /// `create_workstream` starts the Coding Agent for a workstream nobody is
    /// looking at, so the surface has to exist before `TerminalContainerView`
    /// ever renders — and it runs a command that view would never build, because
    /// it carries the agent's initial prompt. `ensureSurface` compares stored
    /// commands and destroys a surface whose command differs, so without the
    /// marker the first render would kill that agent mid-turn.
    ///
    /// The marker is one-shot on purpose. Making the two commands *equal* was the
    /// other option, and it would stake a running agent's life on byte-equality
    /// between two builders reading eight settings each; one divergence — an MCP
    /// config path that resolved in one and not the other — is the same kill,
    /// just harder to see. Adoption drops the requirement entirely: the view's
    /// command is recorded on its first pass, and from there this surface is an
    /// ordinary one, so a later settings change still respawns it and a respawn
    /// after the agent exits uses the view's resume-first command rather than
    /// replaying the prompt.
    /// - Returns: whether the surface was created here. `false` means one already
    ///   existed, so `command` never ran — the caller must report that rather
    ///   than what it intended to do.
    func seedSurface(
        for id: UUID,
        app: ghostty_app_t,
        workingDirectory: String,
        command: String,
        environmentVars: [String: String]
    ) -> Bool {
        // A surface that already exists is the view's, and the view is the
        // authority on it — seeding over the top would be the destroy-and-respawn
        // this whole mechanism exists to avoid. `Launcher.beforeReady` is what
        // makes this the unreachable case rather than the racy one; the check
        // stays because what it guards is an agent's prompt going missing in
        // silence, and reporting that is worth two lines.
        if surfaces[id] != nil {
            return false
        }
        seededSurfaces.insert(id)
        _ = surface(
            for: id,
            app: app,
            workingDirectory: workingDirectory,
            command: command,
            environmentVars: environmentVars
        )
        return true
    }

    /// Creates the surface for `id`, replacing any existing surface whose
    /// stored command differs. A matching surface is returned untouched.
    ///
    /// A seeded surface is adopted instead of compared, once: its recorded
    /// params become the ones passed here, and the marker is cleared. See
    /// `seedSurface`.
    func ensureSurface(for id: UUID, app: ghostty_app_t, workingDirectory: String, command: String?, initialInput: String? = nil, environmentVars: [String: String] = [:]) -> TerminalView {
        if seededSurfaces.contains(id), let seeded = surfaces[id] {
            seededSurfaces.remove(id)
            logger.info("Adopting seeded surface \(id) — keeping the running agent, recording the view's command")
            surfaceParams[id] = SurfaceParams(
                workingDirectory: workingDirectory,
                command: command,
                initialInput: initialInput,
                environmentVars: environmentVars
            )
            return seeded
        }
        if let existing = surfaces[id],
           let params = surfaceParams[id],
           params.command == command,
           params.workingDirectory == workingDirectory
        {
            return existing
        }
        if let stale = surfaces[id] {
            logger.info("Replacing surface \(id) — command changed")
            respawnableIDs.remove(id)
            removeSurface(for: id)
        }
        return surface(
            for: id,
            app: app,
            workingDirectory: workingDirectory,
            command: command,
            initialInput: initialInput,
            environmentVars: environmentVars
        )
    }

    /// The surfaces that currently exist. Feeds `WorkspaceModel.reconcile`, which
    /// drops terminal tabs whose surface is gone.
    func liveSurfaceIDs() -> Set<UUID> {
        Set(surfaces.keys)
    }

    /// Retry creating a surface that previously failed.
    func retrySurface(for id: UUID) {
        guard let params = surfaceParams[id],
              let app = TerminalApp.shared.app else { return }
        logger.detailed("Retrying surface creation for \(id)")
        if let view = surfaces.removeValue(forKey: id) {
            view.destroy()
        }
        failedSurfaces.removeValue(forKey: id)
        let view = TerminalView(app: app, workingDirectory: params.workingDirectory, command: params.command, initialInput: params.initialInput, environmentVars: params.environmentVars)
        view.workstreamID = id
        surfaces[id] = view
        if view.surface == nil {
            logger.error("Surface retry failed for \(id)")
            failedSurfaces[id] = params.command ?? "(default shell)"
        } else {
            creationTimes[id] = Date()
        }
        objectWillChange.send()
    }

    func webView(for id: UUID) -> WKWebView {
        if let existing = webViews[id] {
            return existing
        }
        let view = BrowserWebView()
        webViews[id] = view
        return view
    }

    func quickActionRunner(for workstreamID: UUID) -> QuickAction.Runner {
        if let existing = quickActionRunners[workstreamID] {
            return existing
        }
        let runner = QuickAction.Runner()
        quickActionRunners[workstreamID] = runner
        return runner
    }

    /// The workstream's tab state. Created on first access from `seed`, which is
    /// ignored on every later call — the model, not the seed, is the source of
    /// truth once it exists.
    func workspaceModel(for workstreamID: UUID, seed: @autoclosure () -> WorkspaceTabSnapshot) -> WorkspaceModel {
        if let existing = workspaceModels[workstreamID] {
            return existing
        }
        let model = WorkspaceModel(workstreamID: workstreamID, snapshot: seed())
        workspaceModels[workstreamID] = model
        return model
    }

    /// Drops the tab that owned a terminal surface which has just exited.
    ///
    /// This has to happen here, at exit, rather than as a prune when a
    /// workstream is mounted: `TerminalSurfaceView.updateNSView` recreates any
    /// missing surface the moment its tab renders, so a mount-time prune either
    /// runs after the resurrection and sees a live id, or runs before it and
    /// leaves the same render pass to spawn a shell for a tab that is already
    /// gone. At exit the tab is dead and nothing is about to re-render it.
    ///
    /// A no-op for the agent, dev-server, and setup-gate surfaces, which no
    /// workspace tab owns.
    func removeTerminalTab(surfaceID: UUID) {
        let tab = WorkspaceTab.terminal(surfaceID)
        guard let owner = workspaceModels.values.first(where: { $0.tabs.contains(tab) }) else { return }
        owner.removeTab(tab)
    }

    func removeWebView(for id: UUID) {
        webViews.removeValue(forKey: id)
    }

    func removeSurface(for id: UUID) {
        if let view = surfaces.removeValue(forKey: id) {
            view.destroy()
        }
        surfaceParams.removeValue(forKey: id)
        failedSurfaces.removeValue(forKey: id)
        creationTimes.removeValue(forKey: id)
        // The marker describes a surface, not an id: leaving it behind would
        // make the *next* surface for this id adopt whatever the view passed,
        // skipping a reconciliation that is then the correct answer.
        seededSurfaces.remove(id)
    }

    /// Every surface id this workstream can have created, derived from the
    /// counters that produced them.
    ///
    /// The counters are the bound, not a fixed ceiling. The previous sweep ran
    /// `0 ... 99` per prefix, and `WorkspaceModel`'s per-kind counters are
    /// monotonic *and* persisted in `WorkspaceTabSnapshot` — they must never
    /// rewind, or a reused salt would collide with a live surface. So a workstream
    /// that had opened its 101st terminal tab held a surface at `terminal-100`
    /// that archiving could not reach, and a ghostty surface with a live shell
    /// under it survived for the rest of the process. `runGeneration` is not
    /// persisted, and Start/Stop/Restart each remove the outgoing generation's
    /// surface before incrementing, so only the current one can be live — it is
    /// swept from zero anyway, because being thorough here costs a hash.
    ///
    /// `env-setup` is not swept: nothing derives that salt. It outlived whatever
    /// created it and only ever cost 100 hashes per archive.
    ///
    /// Internal and static so the enumeration can be tested without a terminal.
    static func derivedSurfaceIDs(
        for workstreamID: UUID,
        terminalCount: Int,
        browserCount: Int,
        editorCount: Int,
        runGeneration: Int
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        for (prefix, highest) in [
            ("terminal", terminalCount),
            ("browser", browserCount),
            ("editor", editorCount),
            ("env-run", runGeneration),
        ] {
            for index in 0 ... max(0, highest) {
                ids.insert(derivedUUID(from: workstreamID, salt: "\(prefix)-\(index)"))
            }
        }
        return ids
    }

    func removeWorkstreamSurfaces(for workstreamID: UUID) {
        // Captured before the model goes: its counters are what bound the sweep.
        let model = workspaceModels[workstreamID]
        workspaceModels.removeValue(forKey: workstreamID)
        if let runner = quickActionRunners.removeValue(forKey: workstreamID) {
            runner.cancel()
        }
        // Remove agent surface
        removeSurface(for: workstreamID)
        let derivedIDs = Self.derivedSurfaceIDs(
            for: workstreamID,
            terminalCount: model?.terminalCount ?? 0,
            browserCount: model?.browserCount ?? 0,
            editorCount: model?.editorCount ?? 0,
            runGeneration: model?.runGeneration ?? 0
        )
        for id in derivedIDs {
            if surfaces[id] != nil {
                removeSurface(for: id)
            }
            if webViews[id] != nil {
                removeWebView(for: id)
            }
        }
    }

    private func handleSurfaceClosed(_ closedView: TerminalView) {
        guard let (id, _) = surfaces.first(where: { $0.value === closedView }) else { return }

        // Check if the surface died immediately after creation (launch failure).
        let diedImmediately: Bool
        if let created = creationTimes[id] {
            let age = Date().timeIntervalSince(created)
            diedImmediately = age < Self.healthCheckWindow
            if diedImmediately {
                logger.error("Surface \(id) died after \(String(format: "%.1f", age))s, treating as launch failure")
            }
        } else {
            diedImmediately = false
        }

        if respawnableIDs.contains(id) {
            // If the surface died immediately, show error state instead of respawning in a loop.
            if diedImmediately {
                let command = surfaceParams[id]?.command ?? "(default shell)"
                failedSurfaces[id] = command
                objectWillChange.send()
                return
            }

            guard !respawning.contains(id) else {
                logger.detailed("Skipping concurrent respawn for surface \(id)")
                return
            }
            guard let params = surfaceParams[id],
                  let app = TerminalApp.shared.app else { return }

            respawning.insert(id)
            surfaces.removeValue(forKey: id)
            let newView = TerminalView(app: app, workingDirectory: params.workingDirectory, command: params.command, initialInput: params.initialInput, environmentVars: params.environmentVars)
            newView.workstreamID = id
            surfaces[id] = newView
            respawning.remove(id)
            if newView.surface == nil {
                logger.error("Respawn failed for surface \(id)")
                failedSurfaces[id] = params.command ?? "(default shell)"
            } else {
                creationTimes[id] = Date()
                logger.detailed("Respawned surface \(id)")
            }
            objectWillChange.send()
        } else if diedImmediately {
            // Terminal tab died immediately: show error instead of closing the tab.
            let command = surfaceParams[id]?.command ?? "(default shell)"
            failedSurfaces[id] = command
            objectWillChange.send()
        } else {
            removeSurface(for: id)
            removeTerminalTab(surfaceID: id)
            NotificationCenter.default.post(name: .terminalTabExited, object: id)
        }
    }

    // MARK: - Text injection

    /// Whether a live surface exists for `id`. Callers that type into a pane
    /// must check this first: `sendText` and `sendReturn` drop silently when
    /// the surface was never created (no agent command resolved, setup script
    /// still awaiting approval), which reads to the user as the input vanishing.
    func hasLiveSurface(_ id: UUID) -> Bool {
        surfaces[id]?.surface != nil
    }

    /// Type `text` into a surface and submit it.
    ///
    /// Two stages, both deferred: the first Return confirms the paste the
    /// agent's input widget just took, the second submits it. Sending one
    /// immediately looks fine by hand and drops input intermittently in use.
    /// Each Return is re-checked through `whileSafe`, because half a second is
    /// long enough for a turn to start or for the user to start typing in that
    /// pane — an unconditional Return would submit whatever is on the line,
    /// theirs included.
    ///
    /// The 0.5s spacing is tuned to terminal paste behavior; it lives here so
    /// both callers (`AgentNudge`, `PromptInjector`) retune together.
    func typeAndSubmit(_ text: String, into surfaceID: UUID, whileSafe: @escaping @MainActor () -> Bool) {
        sendText(to: surfaceID, text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, whileSafe() else { return }
            sendReturn(to: surfaceID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, whileSafe() else { return }
                sendReturn(to: surfaceID)
            }
        }
    }

    /// Send text to a terminal surface as if it were typed.
    func sendText(to surfaceID: UUID, text: String) {
        guard let view = surfaces[surfaceID],
              let surface = view.surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Send a synthetic Return keypress to a terminal surface.
    ///
    /// A trailing newline inside `sendText` is not enough: a program reading
    /// with bracketed paste enabled treats it as literal text in the buffer,
    /// not as submit. Only a real key event ends the line.
    func sendReturn(to surfaceID: UUID) {
        guard let view = surfaces[surfaceID],
              let surface = view.surface else { return }

        var keyEvent = ghostty_input_key_s()
        keyEvent.keycode = 0x24 // Return
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false

        keyEvent.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, keyEvent)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, keyEvent)
    }
}
