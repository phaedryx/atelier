// ABOUTME: Runs the appropriate package manager install command in a worktree.
// ABOUTME: Only installs if package.json exists and node_modules is not symlinked.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "vibe.deps")

enum DependencyInstaller {
    struct InstallResult {
        let success: Bool
        let output: String
        let errorOutput: String
    }

    /// Check whether dependency installation is needed in the worktree.
    /// Returns false if no package.json exists or if node_modules is already symlinked.
    static func needsInstall(in worktreeDir: String) -> Bool {
        let fm = FileManager.default
        let packageJson = URL(fileURLWithPath: worktreeDir).appendingPathComponent("package.json").path
        let nodeModules = URL(fileURLWithPath: worktreeDir).appendingPathComponent("node_modules").path

        guard fm.fileExists(atPath: packageJson) else { return false }

        // If node_modules is a symlink, deps are shared — no install needed
        if let attrs = try? fm.attributesOfItem(atPath: nodeModules),
           let fileType = attrs[.type] as? FileAttributeType,
           fileType == .typeSymbolicLink
        {
            return false
        }

        return true
    }

    /// Run the install command for the detected package manager.
    /// Returns nil if no install is needed, otherwise returns the result.
    static func install(
        in worktreeDir: String,
        config: WorktreeSetupConfig? = nil
    ) -> InstallResult? {
        guard needsInstall(in: worktreeDir) else {
            logger.info("No dependency install needed in \(worktreeDir, privacy: .public)")
            return nil
        }

        guard let detected = PackageManagerDetector.detect(in: worktreeDir, config: config) else {
            logger.info("No package manager detected in \(worktreeDir, privacy: .public)")
            return nil
        }

        let command = detected.installCommand
        logger.info("Running \(command.joined(separator: " "), privacy: .public) in \(worktreeDir, privacy: .public)")

        guard let toolPath = CommandLineTools.path(for: command[0]) else {
            logger.warning("Could not find \(command[0], privacy: .public) in PATH")
            return InstallResult(
                success: false,
                output: "",
                errorOutput: "Could not find \(command[0]) in PATH"
            )
        }

        // GUI apps inherit a minimal PATH from launchd. Inject the login shell
        // PATH so that shebang-based tools (e.g. npm → #!/usr/bin/env node)
        // can resolve their runtime.
        let shell = CommandBuilder.userShell
        var environment: [String: String]?
        if let shellPath = CommandLineTools.loginShellPath(shell: shell) {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = shellPath
            environment = env
        }

        // `ProcessRunner` drains both streams concurrently. That is not a nicety
        // here: an install is the chattiest thing this app spawns, and a package
        // manager that outgrows the ~64 KB pipe buffer on either stream blocks
        // writing to it while we wait for an exit that can no longer come.
        // The deadline is the loosest tier for the same reason — a cold install
        // is minutes, so it is there to break a wedge, not to enforce a pace.
        guard let result = ProcessRunner.capture(
            executable: toolPath,
            arguments: Array(command.dropFirst()),
            environment: environment,
            currentDirectory: URL(fileURLWithPath: worktreeDir),
            timeout: ProcessRunner.Timeout.install
        ) else {
            return InstallResult(
                success: false,
                output: "",
                errorOutput: "\(command[0]) did not finish in time"
            )
        }

        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        let errorOutput = String(data: result.stderr, encoding: .utf8) ?? ""

        var success = result.isSuccess
        if success {
            // Verify node_modules was actually created. Some package managers
            // (notably Yarn v1) can exit 0 even when the install was aborted
            // (e.g. engine incompatibility), leaving no node_modules behind.
            let nodeModulesPath = URL(fileURLWithPath: worktreeDir)
                .appendingPathComponent("node_modules").path
            if !FileManager.default.fileExists(atPath: nodeModulesPath) {
                success = false
                let reason = errorOutput.isEmpty ? output : errorOutput
                logger.warning("Install exited 0 but node_modules missing. Output: \(reason.prefix(300), privacy: .public)")
            } else {
                logger.info("Dependency install completed successfully")
            }
        } else {
            logger.warning("Dependency install failed (exit \(result.status, privacy: .public)): \(errorOutput, privacy: .public)")
        }

        return InstallResult(success: success, output: output, errorOutput: errorOutput)
    }
}
