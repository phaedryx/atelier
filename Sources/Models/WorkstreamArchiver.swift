// ABOUTME: Handles removing and purging workstreams from projects.
// ABOUTME: Shared by ContentView and ProjectSidebar to avoid duplicated workstream cleanup logic.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "workstream-archiver")

enum WorkstreamArchiver {
    /// Paths currently being archived (background removal in progress).
    @MainActor static var archivingPaths: Set<String> = []

    /// Posted on MainActor when a background worktree removal finishes.
    static let archivingDidComplete = Notification.Name("FFWorktreeArchivingComplete")

    /// Posted on MainActor when a background worktree removal begins.
    static let archivingDidStart = Notification.Name("FFWorktreeArchivingStart")

    /// Removes a workstream from the project without deleting the worktree from disk.
    /// Kills running terminals and tmux sessions but leaves files intact.
    @MainActor
    static func remove(
        _ workstreamID: UUID,
        in project: inout Project,
        surfaceCache: TerminalSurfaceCache,
        tmuxPath: String?
    ) {
        if let ws = project.workstreams.first(where: { $0.id == workstreamID }) {
            let projName = project.name
            let wsName = ws.name
            Task.detached {
                if let tmuxPath {
                    TmuxSession.killWorkstreamSessions(tmuxPath: tmuxPath, project: projName, workstream: wsName)
                }
            }
        }
        surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
        IPC.Config.remove(for: workstreamID)
        LaunchLogger.removeLog(for: workstreamID)
        project.workstreams.removeAll { $0.id == workstreamID }
    }

    /// Check if purging a workstream would lose work. Returns a warning message
    /// describing what would be lost, or nil if it is safe to purge.
    static func purgeWarning(for workstream: Workstream) -> String? {
        guard let path = workstream.worktreePath else { return nil }
        var warnings: [String] = []
        if GitOperations.hasUncommittedChanges(at: path) {
            warnings.append(NSLocalizedString("uncommitted changes", comment: ""))
        }
        if GitOperations.hasUnpushedCommits(at: path) {
            warnings.append(NSLocalizedString("unpushed commits", comment: ""))
        }
        guard !warnings.isEmpty else { return nil }
        let list = warnings.joined(separator: NSLocalizedString(" and ", comment: ""))
        return String(
            format: NSLocalizedString("This workstream has %@ that will be lost.", comment: ""),
            list
        )
    }

    /// Purges a workstream by running its `dispose` phase, removing the git worktree from disk,
    /// deleting the local branch, updating the default branch to latest,
    /// killing tmux sessions, and evicting terminal surfaces from the cache.
    @MainActor
    static func purge(
        _ workstreamID: UUID,
        in project: inout Project,
        surfaceCache: TerminalSurfaceCache,
        tmuxPath: String?
    ) {
        if let ws = project.workstreams.first(where: { $0.id == workstreamID }) {
            let projectDir = project.directory
            let worktreePath = ws.worktreePath ?? projectDir
            // Only the real worktree, never the `?? projectDir` fallback above.
            // A workstream archived before `workstreamWorktreeReady` lands has no
            // worktree path, and `dispose` now runs arbitrary project-authored
            // processes — running them against the user's main checkout is a
            // different and much worse thing than the `teardown` script this
            // replaced ever risked.
            let disposePath = ws.worktreePath
            let standardizedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
            let wsName = ws.name
            let projName = project.name
            // Capture the branch name before the worktree is removed
            let branchName = GitOperations.currentBranch(at: worktreePath)
            archivingPaths.insert(standardizedPath)
            NotificationCenter.default.post(name: archivingDidStart, object: nil)
            let composeBinary = ProcessComposeSettings.resolveBinary()
            Task.detached {
                defer {
                    Task { @MainActor in
                        archivingPaths.remove(standardizedPath)
                        NotificationCenter.default.post(name: archivingDidComplete, object: nil)
                    }
                }
                // A bootstrap for this workstream may still be running: it goes
                // on in the background behind an already-open terminal, so
                // "created a workstream, then archived it" overlaps them. Stop
                // it before dispose runs in the same directory and before
                // `git worktree remove` deletes that directory underneath it.
                // Before anything else: stop the dev stack. In tmux mode the
                // surface removal above only detaches, so without this the
                // `execute` run kept going *through* dispose — two
                // process-compose runs over one project — and then through
                // `git worktree remove --force`, which deletes the tree under
                // it.
                if let tmuxPath {
                    TmuxSession.killRunSession(tmuxPath: tmuxPath, project: projName, workstream: wsName)
                }
                await AsyncSetupService.shared.cancelBootstrap(
                    for: workstreamID,
                    binary: composeBinary,
                    worktreePath: disposePath ?? worktreePath
                )
                // Everything below blocks: dispose is a whole process-compose
                // phase at up to `Timeout.userCommand`, and each git call waits
                // on a child. On the cooperative pool that pins a thread for
                // minutes, so it goes to a utility queue — the same bridge
                // `AsyncSetupService` uses for bootstrap, and for the same
                // reason.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        // Before the worktree is removed:
                        // `ProcessComposeConfig.locate` reads the worktree, and
                        // dispose runs in it.
                        if let disposePath {
                            runDispose(
                                workstreamID: workstreamID,
                                projectName: projName,
                                workstreamName: wsName,
                                worktreePath: disposePath,
                                projectDirectory: projectDir
                            )
                        }
                        GitOperations.removeWorktree(projectPath: projectDir, worktreePath: worktreePath)
                        if let branchName {
                            GitOperations.deleteLocalBranch(at: projectDir, branchName: branchName)
                        }
                        GitOperations.fetchDefaultBranch(at: projectDir)
                        if let tmuxPath {
                            TmuxSession.killWorkstreamSessions(tmuxPath: tmuxPath, project: projName, workstream: wsName)
                        }
                        // Clean up the agent launch script for this workstream.
                        try? FileManager.default.removeItem(atPath: AppConstants.agentScriptPath(for: workstreamID))
                        continuation.resume()
                    }
                }
                // The state entry outlives the workstream otherwise: nothing
                // else called this, so `states` grew by one per archive for the
                // life of the process.
                await AsyncSetupService.shared.clearState(for: workstreamID)
            }
        }
        surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
        LaunchLogger.removeLog(for: workstreamID)
        project.workstreams.removeAll { $0.id == workstreamID }
    }

    /// Run the project's `dispose` namespace before the worktree goes away.
    ///
    /// This replaces the `teardown` script: a project now says what archiving
    /// should clean up in the same file it uses for everything else.
    ///
    /// The preconditions are not restated here. `PhasePolicy.plan` owns
    /// them — integration on, a config located, a binary to run it with, and
    /// approval of every repository-provided file process-compose will load —
    /// and dispose is unattended in exactly the way bootstrap is, so a second
    /// inline copy would be a second security policy with no tests and no way to
    /// follow a change made to the first.
    ///
    /// Nothing here can stop the archive. Every refusal returns quietly and a
    /// failure is logged and swallowed: a workstream stranded half-archived is
    /// worse than cleanup that did not happen, and the user has already said to
    /// remove it. `PhaseExecutor` bounds the run at `Timeout.userCommand`, so a
    /// wedged dispose delays the archive rather than blocking it forever.
    /// What archiving would run, and why it would not.
    ///
    /// Split out from `runDispose` and left internal so the wiring is
    /// observable: a `runDispose` that stopped consulting `PhasePolicy`
    /// altogether would still pass every test of the policy itself. This is the
    /// seam a test can hold, since `runDispose` proper spawns process-compose
    /// and `purge` destroys a worktree.
    static func disposePlan(worktreePath: String, projectDirectory: String) -> PhasePolicy.Plan {
        PhasePolicy.plan(
            phase: .dispose,
            isEnabled: ProcessComposeSettings.isEnabled,
            config: ProcessComposeConfig.locate(
                worktree: worktreePath, projectDirectory: projectDirectory
            ),
            binary: ProcessComposeSettings.resolveBinary(),
            isApproved: {
                ScriptTrust.isApproved(configFiles: $0.repositoryProvidedFiles, for: projectDirectory)
            }
        )
    }

    private static func runDispose(
        workstreamID: UUID,
        projectName: String,
        workstreamName: String,
        worktreePath: String,
        projectDirectory: String
    ) {
        let plan = disposePlan(worktreePath: worktreePath, projectDirectory: projectDirectory)
        let config: ProcessComposeConfig
        let binary: String
        switch plan {
        case let .run(planned, planBinary):
            config = planned
            binary = planBinary
        case let .nothingToDo(message):
            logger.info("No dispose for \(worktreePath, privacy: .public): \(message, privacy: .public)")
            return
        }

        // The same variables `prepare` and `execute` see. A `dispose` process
        // that has to reach the project directory or a declared port cannot do
        // it from the app's own environment; see `PhaseEnvironment`.
        let environment = PhaseEnvironment.variables(
            workstreamID: workstreamID,
            projectName: projectName,
            workstreamName: workstreamName,
            projectDirectory: projectDirectory,
            worktreePath: worktreePath,
            defaultBranch: GitOperations.defaultBranch(at: projectDirectory)
        )

        let outcome = PhaseExecutor.run(
            phase: .dispose,
            config: config,
            binary: binary,
            workstreamID: workstreamID,
            workingDirectory: worktreePath,
            environment: environment,
            timeout: ProcessRunner.Timeout.userCommand
        )
        if case let .failed(detail) = outcome {
            logger.warning("Dispose for \(worktreePath, privacy: .public) failed: \(detail, privacy: .public)")
        }
    }

    /// Warning describing what work would be lost if the orphan worktree at `path`
    /// is purged, or nil if it is safe to purge.
    static func orphanPurgeWarning(at path: String) -> String? {
        var warnings: [String] = []
        if GitOperations.hasUncommittedChanges(at: path) {
            warnings.append(NSLocalizedString("uncommitted changes", comment: ""))
        }
        if GitOperations.hasUnpushedCommits(at: path) {
            warnings.append(NSLocalizedString("unpushed commits", comment: ""))
        }
        guard !warnings.isEmpty else { return nil }
        let list = warnings.joined(separator: NSLocalizedString(" and ", comment: ""))
        return String(
            format: NSLocalizedString("This worktree has %@ that will be lost.", comment: ""),
            list
        )
    }

    /// Purges an orphan worktree (one that is not associated with any workstream):
    /// removes the worktree from disk, deletes the local branch, and refreshes
    /// the default branch. Does not touch workstream-only state (terminals,
    /// tmux, agent script) because there is none.
    @MainActor
    static func purgeOrphanWorktree(projectDirectory: String, worktreePath: String) {
        let standardizedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        let branchName = GitOperations.currentBranch(at: worktreePath)
        archivingPaths.insert(standardizedPath)
        NotificationCenter.default.post(name: archivingDidStart, object: nil)
        Task.detached {
            defer {
                Task { @MainActor in
                    archivingPaths.remove(standardizedPath)
                    NotificationCenter.default.post(name: archivingDidComplete, object: nil)
                }
            }
            GitOperations.removeWorktree(projectPath: projectDirectory, worktreePath: worktreePath)
            if let branchName {
                GitOperations.deleteLocalBranch(at: projectDirectory, branchName: branchName)
            }
            GitOperations.fetchDefaultBranch(at: projectDirectory)
        }
    }
}
