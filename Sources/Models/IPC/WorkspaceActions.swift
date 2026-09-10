// ABOUTME: The app-side seam the IPC workspace tools act through — tabs, editor, review comments.
// ABOUTME: Weak-reference singleton set from ContentView, the same shape as AgentNudge and PromptInjector.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "workspace-actions")

/// What `IPC.Service` reaches the live app through.
///
/// `IPC.Service` is an actor with no view hierarchy and no `@EnvironmentObject`;
/// the workspace tools need `TerminalSurfaceCache` (tabs and surfaces),
/// `ProjectList` (which workstream is which) and `AppEnvironment` (tool paths).
/// All three are `@StateObject`s owned by `ContentView`, so this holds them
/// weakly and is populated from that view's `.onAppear` — the same pattern, on
/// the same two lines, as `AgentNudge.surfaceCache` and
/// `PromptInjector.surfaceCache`.
///
/// Deliberately not a second `CockpitAppAccess`-style protocol boundary: Calix
/// needs one because its equivalent walks `NSApp.delegate` and cannot be
/// constructed in a test host. Everything here is a plain lookup on objects that
/// already exist, and the parts worth testing (`resolve`, path validation) are
/// pure statics that take their inputs rather than reading these references.
@MainActor
final class WorkspaceActions {
    static let shared = WorkspaceActions()

    weak var surfaceCache: TerminalSurfaceCache?
    weak var projectList: ProjectList?
    weak var appEnvironment: AppEnvironment?

    /// Everything a workspace tool needs about the workstream it was called from.
    ///
    /// Carries `project` whole rather than a path, because `Project.checkout` and
    /// `Project.directory` are different answers to different questions and
    /// collapsing them into one "project path" is a documented way to reintroduce
    /// a real bug — see `CLAUDE.md` on the bare-repo layout.
    struct Context {
        let project: Project
        let workstream: Workstream
        let model: WorkspaceModel

        /// Where this workstream's shells run. `Workstream.workingDirectory`
        /// falls back to `Project.checkout`, never `Project.directory`.
        var workingDirectory: String {
            workstream.workingDirectory(checkout: project.checkout)
        }
    }

    /// Why a workspace tool could not act. Every case is something an agent can
    /// act on or report, never a bare nil — a tool that quietly does nothing is
    /// worse than one that says why it didn't.
    enum Failure: Error, LocalizedError {
        case notInAWorkstream
        case unknownWorkstream
        case appNotReady
        case missingArgument(String)
        case invalidArgument(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .notInAWorkstream:
                "This tool only works from an agent running inside an Atelier workstream."
            case .unknownWorkstream:
                "This workstream is no longer open in Atelier."
            case .appNotReady:
                "Atelier's workspace is not ready yet. Try again in a moment."
            case let .missingArgument(name):
                "Missing required argument `\(name)`."
            case let .invalidArgument(name, reason):
                "Invalid `\(name)`: \(reason)"
            }
        }
    }

    // MARK: - Resolution

    /// The project and workstream a workstream id names, or nil.
    ///
    /// Pure and static so the lookup is testable without a live `ProjectList`.
    /// Searches by workstream id rather than by the caller's `ATELIER_PROJECT_DIR`
    /// because the id is exact: a project directory is a string comparison that a
    /// symlinked or trailing-slashed path can lose.
    nonisolated static func resolve(
        workstreamID: UUID,
        in projects: [Project]
    ) -> (project: Project, workstream: Workstream)? {
        for project in projects {
            if let workstream = project.workstreams.first(where: { $0.id == workstreamID }) {
                return (project, workstream)
            }
        }
        return nil
    }

    func context(workstreamID: UUID) throws -> Context {
        guard let projectList, let surfaceCache else { throw Failure.appNotReady }
        guard let found = Self.resolve(workstreamID: workstreamID, in: projectList.items) else {
            throw Failure.unknownWorkstream
        }
        let model = surfaceCache.workspaceModel(
            for: workstreamID,
            seed: startupWorkspaceTabState(savedTab: nil)
        )
        return Context(project: found.project, workstream: found.workstream, model: model)
    }

    // MARK: - Reads

    /// The workstream's tabs, in the order they are shown.
    ///
    /// `peers` maps a surface id to the agent registered from it — supplied by
    /// the caller rather than looked up here, because peer identity is
    /// `IPC.Service`'s and this type has no business knowing about it.
    func tabs(
        workstreamID: UUID,
        callerSurfaceID: UUID?,
        peers: [UUID: (id: String, name: String)]
    ) throws -> [IPC.TabInfo] {
        let context = try context(workstreamID: workstreamID)
        let model = context.model
        return model.tabs.map { tab in
            let surfaceID = Self.surfaceID(of: tab, workstreamID: workstreamID)
            let peer = surfaceID.flatMap { peers[$0] }
            return IPC.TabInfo(
                kind: tab.kind.id,
                surfaceID: surfaceID?.uuidString,
                title: Self.title(of: tab, model: model),
                isActive: tab == model.activeTab,
                isCaller: surfaceID != nil && surfaceID == callerSurfaceID,
                peerID: peer?.id,
                peerName: peer?.name
            )
        }
    }

    /// The surface a tab owns, or nil for one that has no shell.
    ///
    /// The Coding Agent's surface id *is* the workstream id — the same identity
    /// `AgentNudge` relies on — so it is reported here rather than left nil; it
    /// is the one tab a caller is most likely to want to address.
    nonisolated static func surfaceID(of tab: WorkspaceTab, workstreamID: UUID) -> UUID? {
        switch tab {
        case .agent: workstreamID
        case let .terminal(id): id
        case .info, .changes, .environment, .browser, .editor: nil
        }
    }

    private static func title(of tab: WorkspaceTab, model: WorkspaceModel) -> String? {
        switch tab {
        case let .terminal(id): model.terminalTitles[id]
        case let .browser(id): model.browserTitles[id]
        case let .editor(id): model.editorFilePaths[id]
        case .info, .agent, .changes, .environment: nil
        }
    }

    /// The user's review comments on this workstream's diff, newest scope first.
    ///
    /// Read-only on purpose. The comments are the user's, and the existing
    /// "send to agent" button in `ChangesView` is how they choose to hand them
    /// over; this lets an agent *ask* for them instead of waiting to be given
    /// them, and gives it file/line/side structure rather than the prose that
    /// button pastes.
    func reviewComments(workstreamID: UUID) throws -> [IPC.ReviewCommentInfo] {
        let context = try context(workstreamID: workstreamID)
        return context.model.annotationStore.comments.map { comment in
            IPC.ReviewCommentInfo(
                filePath: comment.filePath,
                mode: comment.mode.rawValue,
                side: comment.side.rawValue,
                line: comment.line,
                endLine: comment.endLine,
                lineText: comment.lineText,
                text: comment.text,
                isOrphaned: comment.isOrphaned
            )
        }
    }

    // MARK: - Actions

    /// Opens `path` in the workstream's editor and makes it the active tab.
    ///
    /// The path is resolved against the worktree and must stay inside it. That
    /// is not a security boundary — the calling agent already has a shell — it
    /// is about not hijacking the user's editor to somewhere they have no
    /// context for. `SystemPrompts.restrictToWorktreePrompt` already tells the
    /// agent the same thing about writes; this keeps the tool honest when the
    /// prompt is off.
    @discardableResult
    func openEditor(workstreamID: UUID, path: String, line: Int?) throws -> String {
        let context = try context(workstreamID: workstreamID)
        let resolved = try Self.resolvePath(path, inWorktree: context.workingDirectory)
        if let line, line < 1 {
            throw Failure.invalidArgument(name: "line", reason: "must be 1 or greater.")
        }
        _ = context.model.addEditor(filePath: resolved, line: line)
        logger.detailed("open_editor: \(resolved)")
        return resolved
    }

    // MARK: - Spawning an agent

    /// What `open_agent_tab` needs about a workstream before it leaves the main
    /// actor.
    ///
    /// The spawn is three steps in two isolation domains: read the app's state
    /// here, build the environment off-main (it asks git for the default branch
    /// and reads `ports.yaml`, neither of which the main actor should wait on),
    /// then come back to create the tab. This is the first step's result, and it
    /// is plain `Sendable` data so it can cross.
    struct AgentTabPlan: Sendable {
        let workstreamID: UUID
        let workstreamName: String
        let projectName: String
        /// `Project.directory` — the repository's home, never its checkout.
        let projectDirectory: String
        let workingDirectory: String
        let bypassPermissions: Bool
        let claudePath: String?
    }

    func agentTabPlan(workstreamID: UUID) throws -> AgentTabPlan {
        let context = try context(workstreamID: workstreamID)
        return AgentTabPlan(
            workstreamID: workstreamID,
            workstreamName: context.workstream.name,
            projectName: context.project.name,
            projectDirectory: context.project.directory,
            workingDirectory: context.workingDirectory,
            bypassPermissions: context.workstream.bypassPermissions,
            claudePath: appEnvironment?.toolStatus.claude.path
        )
    }

    /// The environment a spawned tab's shell gets. Call off the main actor.
    ///
    /// Built from `ProcessCompose.PhaseEnvironment.variables`, which is the one
    /// place that assembles the full `ATELIER_*` set plus `ports.yaml` for a
    /// caller with no plan to hand over — the same problem the unattended phases
    /// had. Then two corrections, both of which the Coding Agent tab's own
    /// `terminalEnvVars` makes for the same reasons:
    ///
    /// - `TMUX`/`TMUX_PANE` are cleared, so a tab spawned while tmux mode is on
    ///   does not inherit the Agent's session and try to nest.
    /// - `ATELIER_SURFACE_ID` is *this* surface's, so the agent that starts here
    ///   registers as its own peer and is nudged in its own pane. Inheriting the
    ///   Agent tab's id is the exact misdelivery the per-surface marker exists to
    ///   prevent.
    nonisolated static func environment(for plan: AgentTabPlan, surfaceID: UUID) -> [String: String] {
        var vars = ProcessCompose.PhaseEnvironment.variables(
            workstreamID: plan.workstreamID,
            projectName: plan.projectName,
            workstreamName: plan.workstreamName,
            projectDirectory: plan.projectDirectory,
            worktreePath: plan.workingDirectory,
            defaultBranch: Git.Operations.defaultBranch(at: plan.projectDirectory)
        )
        vars["TMUX"] = ""
        vars["TMUX_PANE"] = ""
        vars["ATELIER_SURFACE_ID"] = surfaceID.uuidString
        return vars
    }

    /// Opens a terminal tab and, when `command` is given, starts it running that.
    ///
    /// The surface is created here rather than left to the view. `WorkspaceModel`
    /// only records the tab; the shell appears when `TerminalSurfaceView` renders
    /// it, and only the selected workstream renders. Creating it eagerly — the
    /// same construction `TerminalSurfaceCache.retrySurface` already does outside
    /// any render pass — is what lets an agent spawn a peer into a workstream the
    /// user is not currently looking at.
    /// `command` and `environment` are closures over the new surface's id
    /// because both depend on it and it does not exist until `addTerminal` runs:
    /// the agent's Claude session is keyed on the surface, and the environment
    /// carries `ATELIER_SURFACE_ID`. Taking them as values would mean either
    /// allocating the id twice or handing the agent the wrong identity.
    @discardableResult
    func spawnTerminalTab(
        workstreamID: UUID,
        title: String?,
        command: (UUID) -> String?,
        environment: (UUID) -> [String: String]
    ) throws -> UUID {
        let context = try context(workstreamID: workstreamID)
        guard let surfaceCache, let app = TerminalApp.shared.app else { throw Failure.appNotReady }

        let surfaceID = context.model.addTerminal()
        if let title, !title.isEmpty {
            context.model.terminalTitles[surfaceID] = title
        }
        let resolved = command(surfaceID)
        _ = surfaceCache.surface(
            for: surfaceID,
            app: app,
            workingDirectory: context.workingDirectory,
            command: resolved,
            environmentVars: environment(surfaceID)
        )
        logger.detailed("open_agent_tab: spawned surface \(surfaceID) agent=\(resolved != nil)")
        return surfaceID
    }

    /// Resolves a tool-supplied path against the worktree.
    ///
    /// Accepts a repo-relative path or an absolute one inside the worktree, and
    /// rejects anything that escapes it — including by way of `..`, which is why
    /// this standardizes before comparing rather than checking the raw string.
    /// Pure and static so the traversal cases are testable without a workspace.
    nonisolated static func resolvePath(
        _ path: String,
        inWorktree worktree: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.missingArgument("path") }

        let root = URL(fileURLWithPath: worktree).standardizedFileURL
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).standardizedFileURL
            : root.appendingPathComponent(trimmed).standardizedFileURL

        // Compare path components, not string prefixes: "/repo/app" is not
        // inside "/repo/ap", but a prefix test says it is.
        let rootParts = root.pathComponents
        guard candidate.pathComponents.count > rootParts.count,
              Array(candidate.pathComponents.prefix(rootParts.count)) == rootParts
        else {
            throw Failure.invalidArgument(
                name: "path",
                reason: "must be inside this workstream's worktree (\(root.path))."
            )
        }
        guard fileExists(candidate.path) else {
            throw Failure.invalidArgument(name: "path", reason: "no such file: \(candidate.path)")
        }
        return candidate.path
    }
}
