// ABOUTME: Tmux session naming and command wrapping for persistent sessions.
// ABOUTME: Sessions survive app restarts but not system restarts.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "tmux")

enum TmuxSession {
    /// Path to the tmux stderr log file in the cache directory.
    static var stderrLogPath: String {
        AppConstants.cacheDirectory.appendingPathComponent("tmux-stderr.log").path
    }

    /// Build a deterministic session name from project, workstream, and role.
    static func sessionName(project: String, workstream: String, role: String) -> String {
        "\(AppConstants.appID)/\(sanitize(project))/\(sanitize(workstream))/\(role)"
    }

    /// Config strips all UI chrome (status bar, prefix key, keybindings) so tmux is
    /// invisible inside Atelier, which manages the terminal directly.
    /// Sessions are still accessible from external terminals via:
    ///   tmux -L atelier list-sessions
    ///   tmux -L atelier attach-session -t <name>
    static var configContents: String {
        """
        # Managed by \(AppConstants.appID). Do not edit.
        # Makes tmux act as a transparent session persistence wrapper.
        set -g status off
        set -g prefix None
        unbind-key -a
        set -g mouse off
        set -g history-limit 50000
        set -g escape-time 0
        set -g allow-passthrough on
        set -g extended-keys on
        set -g default-terminal "xterm-256color"
        set -ga terminal-features ',*:extkeys'
        set -g aggressive-resize on
        set -g window-size latest
        set -g remain-on-exit on
        set -g remain-on-exit-format ""
        """
    }

    /// Path to the minimal tmux config that makes tmux invisible.
    private static var configPath: String {
        let path = AppConstants.cacheDirectory.appendingPathComponent("tmux.conf")
        // Write config if missing or outdated
        let fm = FileManager.default
        try? fm.createDirectory(at: AppConstants.cacheDirectory, withIntermediateDirectories: true)
        if let existing = try? String(contentsOfFile: path.path, encoding: .utf8), existing == configContents {
            return path.path
        }
        try? configContents.write(toFile: path.path, atomically: true, encoding: .utf8)
        return path.path
    }

    /// Wrap a command to run inside a tmux session.
    /// Uses `new-session -A` which creates if missing, attaches if existing.
    /// Tmux is configured to be invisible: no status bar, no prefix key,
    /// mouse passthrough for scrolling.
    /// Dedicated socket name so we don't interfere with the user's tmux.
    private static let socketName = AppConstants.appID

    static func wrapCommand(tmuxPath: String, sessionName: String, command: String?, environmentVars: [String: String] = [:], respawnOnExit: Bool = false, shell: String = CommandBuilder.userShell) -> String {
        let socket = shellEscape(socketName)
        let conf = shellEscape(configPath)
        let escaped = shellEscape(sessionName)

        // Both halves escaped. The key was not, and keys come from
        // `ports.yaml` — repository content in an ordinary clone — so a name
        // containing a quote or `$(…)` was an ungated path from a repository
        // into `sh -c` whenever tmux mode was on. `PortsConfig.validateName`
        // now restricts names to variable-name characters; this is the second
        // line of that defence, not a substitute for it.
        let envFlags = environmentVars
            .map { "-e \"\(doubleQuoteEscape($0.key))=\(doubleQuoteEscape($0.value))\"" }
            .joined(separator: " ")

        // Build the tmux new-session command
        var tmuxCmd = "\(tmuxPath) -L \(socket) -f \(conf) new-session -A -s \(escaped)"
        if !envFlags.isEmpty {
            tmuxCmd += " \(envFlags)"
        }
        if let command {
            // Command is already shell-quoted by the caller (runScriptCommand/scriptCommand)
            tmuxCmd += " \(command)"
        }
        if respawnOnExit {
            tmuxCmd += " \\; set-hook pane-died 'respawn-pane'"
        }

        // Use login shell for proper PATH, with inner sh for POSIX syntax.
        // Both the sh -c argument and the outer login shell argument use
        // Fish-aware quoting when Fish is the shell.
        let setup = serverSetupCommand(tmuxPath: tmuxPath, configPath: configPath)
        let innerCmd = "\(setup); exec \(tmuxCmd)"
        let shArgQuote = CommandBuilder.isFish(shell)
            ? CommandBuilder.shellQuote(innerCmd, forShell: shell)
            : shellEscape(innerCmd)
        let shCmd = "exec sh -c \(shArgQuote)"
        return "\(shell) -lic \(CommandBuilder.shellQuote(shCmd, forShell: shell))"
    }

    /// Build a script that can be `source`d directly into an interactive shell (zsh).
    /// No `sh -c` wrapping — commands run in the current shell to preserve terminal capabilities.
    static func sourceableScript(tmuxPath: String, sessionName: String, command: String, environmentVars: [String: String] = [:]) -> String {
        let socket = shellEscape(socketName)
        let conf = shellEscape(configPath)
        let escaped = shellEscape(sessionName)
        let logFile = shellEscape(stderrLogPath)

        // Both halves escaped. The key was not, and keys come from
        // `ports.yaml` — repository content in an ordinary clone — so a name
        // containing a quote or `$(…)` was an ungated path from a repository
        // into `sh -c` whenever tmux mode was on. `PortsConfig.validateName`
        // now restricts names to variable-name characters; this is the second
        // line of that defence, not a substitute for it.
        let envFlags = environmentVars
            .map { "-e \"\(doubleQuoteEscape($0.key))=\(doubleQuoteEscape($0.value))\"" }
            .joined(separator: " ")

        var lines: [String] = []
        lines.append("\(tmuxPath) -L \(socket) start-server 2>>\(logFile) || true")
        lines.append("\(tmuxPath) -L \(socket) source-file \(conf) 2>>\(logFile)")
        lines.append("\(tmuxPath) -L \(socket) set-hook -gu pane-died 2>>\(logFile) || true")

        var tmuxCmd = "exec \(tmuxPath) -L \(socket) -f \(conf) new-session -A -s \(escaped)"
        if !envFlags.isEmpty {
            tmuxCmd += " \(envFlags)"
        }
        // tmux new-session doesn't interpret shell operators (||, 2>), so wrap in sh -c.
        // This sh -c runs inside tmux's pseudo-terminal, not the outer interactive shell.
        tmuxCmd += " sh -c \(shellEscape(command))"
        lines.append(tmuxCmd)

        return lines.joined(separator: "\n")
    }

    /// Kill a tmux session by name.
    ///
    /// Bounded, like every tmux call here: these are local and near-instant, so
    /// a wait that does not return means the server is wedged — and archiving a
    /// workstream must not wedge with it.
    static func killSession(tmuxPath: String, sessionName: String) {
        ProcessRunner.succeeds(
            executable: tmuxPath,
            arguments: ["-L", socketName, "kill-session", "-t", sessionName],
            timeout: ProcessRunner.Timeout.local
        )
    }

    static func sessionExists(tmuxPath: String, sessionName: String) -> Bool {
        ProcessRunner.succeeds(
            executable: tmuxPath,
            arguments: ["-L", socketName, "has-session", "-t", sessionName],
            timeout: ProcessRunner.Timeout.local
        )
    }

    /// Kill the agent tmux session for a workstream.
    static func killWorkstreamSessions(tmuxPath: String, project: String, workstream: String) {
        // Both roles. This killed only `agent`, so an archived workstream left
        // its `run` session — and with it the whole dev stack — alive forever:
        // nothing else names that session except `stopRun`, which archive does
        // not call, so the processes outlived their own worktree and kept
        // holding its ports until the app quit.
        killSession(tmuxPath: tmuxPath, sessionName: sessionName(project: project, workstream: workstream, role: "agent"))
        killRunSession(tmuxPath: tmuxPath, project: project, workstream: workstream)
    }

    /// Kill just the dev-server session.
    ///
    /// Separate because archive has to do this *before* `dispose` runs and
    /// before the worktree is removed: a live `execute` stack during dispose
    /// means two process-compose runs over one project, and `git worktree
    /// remove --force` then deletes the tree from under the running one.
    static func killRunSession(tmuxPath: String, project: String, workstream: String) {
        killSession(tmuxPath: tmuxPath, sessionName: sessionName(project: project, workstream: workstream, role: "run"))
    }

    /// Kill the entire tmux server on the atelier socket.
    /// Call on app termination to prevent orphaned sessions.
    static func killAllSessions(tmuxPath: String) {
        logger.detailed("Killing tmux server on socket \(socketName)")
        // Bounded: this runs on app termination, where a wedged tmux would
        // otherwise keep the app from quitting.
        ProcessRunner.succeeds(
            executable: tmuxPath,
            arguments: ["-L", socketName, "kill-server"],
            timeout: ProcessRunner.Timeout.local
        )
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func shellEscape(_ str: String) -> String {
        "'\(str.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Escape a string for safe embedding inside double quotes in a shell command.
    private static func doubleQuoteEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func serverSetupCommand(tmuxPath: String, configPath: String) -> String {
        let socket = shellEscape(socketName)
        let conf = shellEscape(configPath)
        let logFile = shellEscape(stderrLogPath)
        let startServer = "\(tmuxPath) -L \(socket) -f \(conf) start-server 2>>\(logFile) || true"
        let sourceFile = "\(tmuxPath) -L \(socket) source-file \(conf) 2>>\(logFile)"
        return "\(startServer); \(sourceFile)"
    }
}
