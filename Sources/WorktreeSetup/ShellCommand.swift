// ABOUTME: Shared shell command runner used by worktree setup paths.
// ABOUTME: Provides a Sendable-compatible static method to run arbitrary shell commands in a directory.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "vibe.shell")

enum ShellCommand {
    /// Run a shell command in a given directory, returning true on success.
    ///
    /// Uses `zsh` if available, falling back to `bash`. Standard output is
    /// discarded; standard error is logged on failure.
    static func run(_ command: String, in directory: String) -> Bool {
        guard let shellPath = CommandLineTools.path(for: "zsh")
            ?? CommandLineTools.path(for: "bash")
        else {
            logger.warning("No shell found for post-setup command")
            return false
        }

        // GUI apps inherit a minimal PATH from launchd. Inject the login shell
        // PATH so commands can find tools installed via version managers (nvm, etc.).
        let shell = CommandBuilder.userShell
        var environment: [String: String]?
        if let resolvedPath = CommandLineTools.loginShellPath(shell: shell) {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = resolvedPath
            environment = env
        }

        // Bounded at the user-command tier: the command comes from the user's
        // repository, so it is long by nature but must still end. `ProcessRunner`
        // drains both streams concurrently — reading stderr only after the exit,
        // as this used to, wedges any command chatty enough to fill the pipe.
        guard let result = ProcessRunner.capture(
            executable: shellPath,
            arguments: ["-c", command],
            environment: environment,
            currentDirectory: URL(fileURLWithPath: directory),
            timeout: ProcessRunner.Timeout.userCommand
        ) else {
            logger.warning("Post-setup command '\(command, privacy: .public)' did not finish in time")
            return false
        }

        guard result.isSuccess else {
            logger.warning("Post-setup command '\(command, privacy: .public)' failed: \(result.stderrText, privacy: .public)")
            return false
        }
        return true
    }
}
