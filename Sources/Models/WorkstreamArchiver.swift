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
        IPCConfig.remove(for: workstreamID)
        LaunchLogger.removeLog(for: workstreamID)
        SetupStateStore.remove(for: workstreamID)
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

    /// Purges a workstream by running teardown, removing the git worktree from disk,
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
            let standardizedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
            let wsName = ws.name
            let projName = project.name
            // Capture the branch name before the worktree is removed
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
                // Before the worktree is removed: `ProcessComposeConfig.locate`
                // reads the worktree, and dispose runs in it.
                runDispose(
                    workstreamID: workstreamID,
                    worktreePath: worktreePath,
                    projectDirectory: projectDir
                )
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
            }
        }
        surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
        LaunchLogger.removeLog(for: workstreamID)
        SetupStateStore.remove(for: workstreamID)
        project.workstreams.removeAll { $0.id == workstreamID }
    }

    /// Run the project's `dispose` namespace before the worktree goes away.
    ///
    /// This replaces the `teardown` script: a project now says what archiving
    /// should clean up in the same file it uses for everything else. The
    /// preconditions mirror `BootstrapPolicy.plan` — integration on, a config
    /// located, a binary to run it with, and approval when the config arrived
    /// with the repository — because dispose is unattended in exactly the way
    /// bootstrap is.
    ///
    /// Nothing here can stop the archive. Every refusal returns quietly and a
    /// failure is logged and swallowed: a workstream stranded half-archived is
    /// worse than cleanup that did not happen, and the user has already said to
    /// remove it. `PhaseExecutor` bounds the run at
    /// `Timeout.userCommand`, so a wedged dispose delays the archive rather than
    /// blocking it forever.
    private static func runDispose(
        workstreamID: UUID,
        worktreePath: String,
        projectDirectory: String
    ) {
        guard ProcessComposeSettings.isEnabled,
              let config = ProcessComposeConfig.locate(
                  worktree: worktreePath, projectDirectory: projectDirectory
              ),
              let binary = ProcessComposeSettings.resolveBinary()
        else { return }

        guard !config.isRepositoryProvided
            || ScriptTrust.isApproved(configFile: config.path, for: projectDirectory)
        else {
            logger.info("Skipping dispose for \(worktreePath, privacy: .public): config not approved")
            return
        }

        let outcome = PhaseExecutor.run(
            phase: .dispose,
            config: config,
            binary: binary,
            workstreamID: workstreamID,
            workingDirectory: worktreePath,
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
