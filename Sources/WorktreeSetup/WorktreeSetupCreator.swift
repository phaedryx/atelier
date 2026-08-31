// ABOUTME: Orchestrates the full vibe worktree setup workflow end-to-end.
// ABOUTME: Creates worktree, copies env files, symlinks deps, sets up Claude, and installs.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "vibe.creator")

enum WorktreeSetupCreator {
    struct SetupResult: Sendable {
        let worktreePath: String
        let envFilesCopied: Int
        let symlinksCreated: Int
        let claudeSettingsLinked: Bool
        let dependencyInstallResult: DependencyInstaller.InstallResult?
        let errors: [String]
    }

    /// Create a vibe worktree with full setup: env files, symlinks, Claude settings, and deps.
    ///
    /// - Parameters:
    ///   - projectPath: Path to the main project/repo root
    ///   - projectName: Name of the project (used for worktree directory naming)
    ///   - workstreamName: Name for the new workstream/branch
    /// - Returns: SetupResult on success, nil if worktree creation failed
    static func create(
        projectPath: String,
        projectName: String,
        workstreamName: String
    ) -> SetupResult? {
        let config = WorktreeSetupConfig.load(from: projectPath)
        var errors: [String] = []

        // 1. Create git worktree
        logger.info("Creating vibe worktree '\(workstreamName, privacy: .public)' for \(projectName, privacy: .public)")
        guard let worktreePath = GitOperations.createWorktree(
            projectPath: projectPath,
            projectName: projectName,
            workstreamName: workstreamName
        ) else {
            logger.warning("Failed to create git worktree")
            return nil
        }

        // 2. Copy the seed directory (env files and friends)
        let envFilesCopied = EnvSeedSync.isEnabled()
            ? EnvSeedSync.sync(seedDirectory: config.seedDirectory(in: projectPath), to: worktreePath)
            : 0

        // 3. Create symlinks for heavy directories
        let symlinksCreated = SymlinkCreator.createSymlinks(
            from: projectPath,
            to: worktreePath,
            config: config
        )

        // 4. Set up Claude settings
        let claudeSettingsLinked = ClaudeSettingsSetup.setup(from: projectPath, to: worktreePath)

        // 5. Install dependencies if needed
        var installResult: DependencyInstaller.InstallResult?
        if DependencyInstaller.needsInstall(in: worktreePath) {
            installResult = DependencyInstaller.install(in: worktreePath, config: config)
            if let result = installResult, !result.success {
                errors.append("Dependency install failed: \(result.errorOutput)")
            }
        }

        // 6. Run post-setup commands
        for command in config.postSetupCommands {
            let success = ShellCommand.run(command, in: worktreePath)
            if !success {
                errors.append("Post-setup command failed: \(command)")
            }
        }

        logger.info("Worktree setup complete at \(worktreePath, privacy: .public)")
        return SetupResult(
            worktreePath: worktreePath,
            envFilesCopied: envFilesCopied,
            symlinksCreated: symlinksCreated,
            claudeSettingsLinked: claudeSettingsLinked,
            dependencyInstallResult: installResult,
            errors: errors
        )
    }

}
