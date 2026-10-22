// ABOUTME: The detail pane for a workstream group: its coordinator agent and an Info tab.
// ABOUTME: CoordinatorLaunch is the pure half — what the coordinator runs, with what environment, where.

import os
import SwiftUI

private let logger = Logger(subsystem: "atelier", category: "coordinator")

/// What a group's coordinator will run, or why it cannot run at all.
///
/// The one place the command, the environment and the working directory are
/// decided, so the pane only gathers inputs and performs the side effects
/// around it (the MCP and status-line config writes, the launch log). Pure:
/// nothing here touches the filesystem or libghostty.
enum CoordinatorLaunch {
    struct Inputs {
        let claudePath: String?
        let tmuxPath: String?
        let tmuxMode: Bool
        let supportsSessionName: Bool
        let agentIPC: Bool
        let defaultBranch: String
    }

    struct Plan: Equatable {
        let command: String
        let environment: [String: String]
        let workingDirectory: String
    }

    /// Nil when Claude Code is not installed, which the pane shows as such.
    ///
    /// The working directory is `project.directory`, never the checkout: the
    /// coordinator sits above every worktree it coordinates.
    static func plan(
        project: Project,
        group: Workstream.Group,
        inputs: Inputs,
        mcpConfigPath: String?,
        settingsPath: String?
    ) -> Plan? {
        guard let claudePath = inputs.claudePath else { return nil }
        // The prompt's IPC half and `--mcp-config` appear together or not at
        // all, the rule `Workstream.AgentCommand.systemPrompt` documents.
        let mcpConfigPath = inputs.agentIPC ? mcpConfigPath : nil
        let members = project.workstreams(in: group.id).map {
            SystemPrompts.CoordinatorMember(
                name: $0.name,
                worktreePath: $0.workingDirectory(checkout: project.checkout)
            )
        }
        let systemPrompt = Workstream.AgentCommand.coordinatorSystemPrompt(
            groupName: group.name,
            projectName: project.name,
            rootDirectory: project.directory,
            checkoutDirectory: project.checkout,
            members: members,
            mcpConfigWritten: mcpConfigPath != nil
        )
        let environment = Workstream.Environment.coordinatorVariables(
            groupID: group.id,
            groupName: group.name,
            projectName: project.name,
            projectDirectory: project.directory,
            defaultBranch: inputs.defaultBranch
        )
        let command = Workstream.AgentCommand.coordinator(
            claudePath: claudePath,
            groupID: group.id,
            groupName: group.name,
            supportsSessionName: inputs.supportsSessionName,
            bypassPermissions: group.bypassPermissions,
            systemPrompt: systemPrompt,
            mcpConfigPath: mcpConfigPath,
            settingsPath: settingsPath
        )
        // Keyed on the group id, not its name: see `coordinatorTmuxSegment`,
        // which `Archiver` reads too, so the session it kills is this one.
        let finalCommand = Workstream.AgentCommand.tmuxWrapped(
            command,
            tmuxPath: inputs.tmuxMode ? inputs.tmuxPath : nil,
            projectName: project.name,
            workstreamName: group.coordinatorTmuxSegment,
            environmentVars: environment
        )
        return Plan(command: finalCommand, environment: environment, workingDirectory: project.directory)
    }
}

/// A group's coordinator: a Claude Code session at the project root, and Info.
///
/// Keeps its own tab state rather than a `WorkspaceModel`: the coordinator
/// has two fixed tabs and no worktree, run session or closeable tabs for a
/// model to track. Its surface id is the group id, which is what agent state,
/// the context meter and pending permissions are keyed by.
struct CoordinatorPaneView: View {
    let project: Project
    let group: Workstream.Group
    let isActive: Bool

    @EnvironmentObject private var surfaceCache: TerminalSurfaceCache
    @EnvironmentObject private var appEnv: AppEnvironment
    @AppStorage("atelier.tmuxMode") private var tmuxMode: Bool = false
    @AppStorage(IPC.AgentSettings.enabledKey) private var agentIPC: Bool = false

    @State private var activeTab: WorkspaceTab = .agent
    /// Built once, after the default branch is known, the way
    /// `TerminalContainerView` caches its agent command: rebuilding it per
    /// render would rewrite the config files and change the surface's command.
    @State private var cachedPlan: CoordinatorLaunch.Plan?

    private var sessionMode: TerminalSessionMode {
        TerminalSessionMode.resolve(
            tmuxModeEnabled: tmuxMode,
            isDetectingTools: appEnv.isDetecting,
            tmuxInstalled: appEnv.toolStatus.tmux.isInstalled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .task(id: group.id) {
            let branch = await appEnv.defaultBranch(for: project.directory)
            guard !Task.isCancelled else { return }
            buildPlan(defaultBranch: branch)
        }
        .onChange(of: appEnv.isDetecting) {
            // `buildPlan` refuses while tools are being detected.
            guard !appEnv.isDetecting, cachedPlan == nil else { return }
            Task {
                let branch = await appEnv.defaultBranch(for: project.directory)
                buildPlan(defaultBranch: branch)
            }
        }
        .onAppear {
            surfaceCache.respawnableIDs.insert(group.id)
            updateOcclusion()
        }
        .onChange(of: activeTab) { updateOcclusion() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in
            guard isActive else { return }
            activeTab = .info
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { _ in
            guard isActive else { return }
            activeTab = .agent
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach([WorkspaceTab.info, .agent], id: \.self) { tab in
                WorkspaceTabButton(
                    tab: tab,
                    label: tab.kind.staticLabel,
                    icon: tab.kind.icon,
                    shortcut: tab.kind.shortcutBadge,
                    isActive: activeTab == tab,
                    onSelect: { activeTab = tab }
                )
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private var tabContent: some View {
        if activeTab == .info {
            infoContent
        } else {
            agentContent
        }
    }

    // MARK: - Coding Agent

    @ViewBuilder
    private var agentContent: some View {
        if sessionMode == .waitingForTools || appEnv.isDetecting {
            loadingView(message: "Checking terminal tools...")
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
        } else if let plan = cachedPlan {
            VStack(spacing: 0) {
                PermissionRequestBannerHost(workstreamID: group.id, agentSurfaceID: group.id)
                SingleTerminalView(
                    surfaceID: group.id,
                    workingDirectory: plan.workingDirectory,
                    command: plan.command,
                    isFocused: true,
                    environmentVars: plan.environment
                )
            }
        } else {
            loadingView(message: "Preparing Coding Agent...")
        }
    }

    private func loadingView(message: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Info

    private var members: [Workstream] {
        project.workstreams(in: group.id)
    }

    private var infoContent: some View {
        Form {
            Section("Group") {
                LabeledContent("Name") {
                    Text(group.name)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Root directory") {
                    DirectoryRow(path: project.directory)
                }
            }
            Section("Members") {
                if members.isEmpty {
                    Text("No workstreams in this group yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members) { workstream in
                        LabeledContent(workstream.name) {
                            DirectoryRow(
                                path: workstream.workingDirectory(checkout: project.checkout)
                            )
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Launch

    private func updateOcclusion() {
        surfaceCache.updateOcclusion(visibleSurfaceIDs: activeTab == .agent ? [group.id] : [])
    }

    private func buildPlan(defaultBranch: String) {
        // Detection decides both whether claude exists and whether tmux mode
        // can apply; a plan built before it ends would be cached with neither.
        // The `isDetecting` observer builds it once detection is done.
        guard !appEnv.isDetecting else { return }
        let inputs = CoordinatorLaunch.Inputs(
            claudePath: appEnv.toolStatus.claude.path,
            tmuxPath: appEnv.toolStatus.tmux.path,
            tmuxMode: sessionMode == .tmux,
            supportsSessionName: appEnv.toolStatus.claudeSupportsSessionName,
            agentIPC: agentIPC,
            defaultBranch: defaultBranch
        )
        // Nothing is written for a coordinator that cannot start.
        guard inputs.claudePath != nil else {
            cachedPlan = nil
            return
        }
        let plan = CoordinatorLaunch.plan(
            project: project,
            group: group,
            inputs: inputs,
            mcpConfigPath: agentIPC ? IPC.Config.write(for: group.id) : nil,
            settingsPath: StatusLine.Config.write(for: group.id, cwd: project.directory)
        )
        cachedPlan = plan
        guard let plan else { return }
        logger.info("[Atelier] coordinator cmd built: \(plan.command.prefix(80), privacy: .public)")

        LaunchLogger.log(LaunchLogEntry(
            workstreamID: group.id,
            event: "agent-start",
            finalCommand: plan.command,
            intermediateCommands: [],
            environmentVariables: plan.environment,
            workingDirectory: project.directory,
            toolPaths: LaunchLogEntry.ToolPaths(
                claude: inputs.claudePath,
                tmux: inputs.tmuxPath,
                ffRun: RunLauncher.executableURL()?.path
            ),
            settings: LaunchLogEntry.Settings(
                tmuxMode: inputs.tmuxMode,
                bypassPermissions: group.bypassPermissions,
                // Neither applies to a coordinator, which has no worktree or branch.
                autoRenameBranch: false,
                allowOutsideWorktree: false
            ),
            shell: CommandBuilder.userShell
        ))
    }
}
