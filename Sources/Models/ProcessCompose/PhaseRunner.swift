// ABOUTME: Builds the process-compose command for each lifecycle phase.
// ABOUTME: One config, four namespaces, one predictable control socket.

import Foundation

enum ProcessComposePhase: String, CaseIterable {
    case bootstrap
    case prepare
    case execute
    case dispose

    var namespace: String {
        rawValue
    }

    /// Only `execute` is long-lived and shown in a terminal surface; the rest
    /// run headless and are awaited.
    var isInteractive: Bool {
        self == .execute
    }
}

enum PhaseRunner {
    /// Where the control sockets live. Under Caches beside run-state and
    /// tmux.conf, since a stale socket is disposable.
    static var socketDirectory: URL {
        AppConstants.cacheDirectory.appendingPathComponent("pc")
    }

    /// A predictable socket path for a workstream.
    ///
    /// `-U` alone generates a path containing process-compose's PID, which
    /// Atelier cannot predict and therefore cannot connect to — so the path is
    /// always passed explicitly. macOS caps `sun_path` at 104 bytes, and a full
    /// UUID under a long home directory gets close, so only the first segment of
    /// the id is used. Collisions across a single user's workstreams are not a
    /// practical concern at 8 hex digits.
    static func socketPath(for workstreamID: UUID) -> String {
        let short = workstreamID.uuidString.prefix(8).lowercased()
        return socketDirectory.appendingPathComponent("\(short).sock").path
    }

    static func ensureSocketDirectory() {
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
    }

    /// The command for one phase.
    ///
    /// A config in the worktree is left unnamed so process-compose's own
    /// discovery runs and picks up a sibling override. A config in the project
    /// directory must be named, which costs that discovery, so a worktree
    /// override is named too — but only when it exists, because a missing `-f`
    /// target is fatal.
    static func command(
        phase: ProcessComposePhase,
        config: ProcessComposeConfig,
        binary: String,
        workstreamID: UUID,
        selectedProcesses: [String]
    ) -> String {
        var parts = [
            CommandBuilder.shellQuote(binary),
            "up",
            "-u", CommandBuilder.shellQuote(socketPath(for: workstreamID)),
        ]

        if !phase.isInteractive {
            parts.append("-t=false")
        }

        if !config.isRepositoryProvided {
            parts += ["-f", CommandBuilder.shellQuote(config.path)]
            if let override = config.overridePath {
                parts += ["-f", CommandBuilder.shellQuote(override)]
            }
        }

        parts += ["-n", phase.namespace]

        if phase == .execute, !selectedProcesses.isEmpty {
            parts += selectedProcesses.map { CommandBuilder.shellQuote($0) }
        }

        return parts.joined(separator: " ")
    }

    /// What the Start button runs: prepare to completion, then execute.
    ///
    /// One shell command in one surface, so prepare's output appears where the
    /// user is already looking and its socket is released before execute claims
    /// the same path. `&&` means a failing prepare stops execute from starting.
    static func startCommand(
        config: ProcessComposeConfig,
        binary: String,
        workstreamID: UUID,
        selectedProcesses: [String]
    ) -> String {
        let prepare = command(
            phase: .prepare, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )
        let execute = command(
            phase: .execute, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: selectedProcesses
        )
        return "\(prepare) && \(execute)"
    }
}
