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

    /// A predictable socket path for a workstream's phase.
    ///
    /// `-U` alone generates a path containing process-compose's PID, which
    /// Atelier cannot predict and therefore cannot connect to — so the path is
    /// always passed explicitly. macOS caps `sun_path` at 104 bytes, and a full
    /// UUID under a long home directory gets close, so only the first segment of
    /// the id is used. Collisions across a single user's workstreams are not a
    /// practical concern at 8 hex digits.
    ///
    /// Only `execute` gets the bare path, because it is the one the UI attaches
    /// to. The headless phases are namespaced, so a `bootstrap` that is still
    /// running when the user presses Start cannot collide with `execute` on one
    /// socket: they overlap in time now that bootstrap runs in the background
    /// behind an already-open terminal, and a second `up` on a path a live
    /// server holds rebinds it, stranding the first server with no way to
    /// reach it.
    static func socketPath(for workstreamID: UUID, phase: ProcessComposePhase = .execute) -> String {
        let short = workstreamID.uuidString.prefix(8).lowercased()
        let suffix = phase.isInteractive ? "" : "-\(phase.namespace)"
        return socketDirectory.appendingPathComponent("\(short)\(suffix).sock").path
    }

    static func ensureSocketDirectory() {
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
    }

    /// The command for one phase.
    ///
    /// **Every file is named with `-f`, always.** That turns process-compose's
    /// own discovery off, which is the point: the files that execute are then
    /// exactly `config.loadedFiles`, which is what `ScriptTrust` fingerprints
    /// and what `ConfigApprovalView` displays.
    ///
    /// A worktree config used to be left unnamed so discovery could pick up its
    /// sibling override. That was sound while honouring overrides was the only
    /// goal, but it made the approval gate a mirror of discovery's rules, and a
    /// mirror can be stepped around: discovery also loads `compose.yaml`, a name
    /// Atelier deliberately does not detect, so a repository could ship a benign
    /// `process-compose.yaml` to be approved and a `compose.yaml` to be run.
    /// Verified against v1.122.0 — with both present, `compose.yaml` wins and
    /// `process-compose.yaml` is never read. Naming the files closes the class,
    /// not just that instance.
    ///
    /// `loadedFiles` existence-filters, so the "a missing `-f` target is fatal"
    /// hazard cannot be reached through it.
    ///
    /// `keepProject` holds the control server open after every process in the
    /// namespace has finished, so a caller can read their exit codes before
    /// shutting it down. `process-compose up` exits 0 whatever the processes
    /// did unless the config opts into `restart: exit_on_failure`, so the API
    /// is the only honest way to tell a clean bootstrap from a broken one; see
    /// `PhaseExecutor`. It must stay off for the chained `startCommand`, where
    /// `prepare` has to exit on its own for `execute` to follow it.
    static func command(
        phase: ProcessComposePhase,
        config: ProcessComposeConfig,
        binary: String,
        workstreamID: UUID,
        selectedProcesses: [String],
        keepProject: Bool = false
    ) -> String {
        var parts = [
            CommandBuilder.shellQuote(binary),
            "up",
            "-u", CommandBuilder.shellQuote(socketPath(for: workstreamID, phase: phase)),
        ]

        if !phase.isInteractive {
            parts.append("-t=false")
        }

        if keepProject {
            parts.append("--keep-project")
        }

        // Every file, always named. See `command`'s note: this is what makes
        // the approved set and the executed set the same set.
        for file in config.loadedFiles {
            parts += ["-f", CommandBuilder.shellQuote(file)]
        }

        parts += ["-n", phase.namespace]

        if phase == .execute, !selectedProcesses.isEmpty {
            parts += selectedProcesses.map { CommandBuilder.shellQuote($0) }
        }

        return parts.joined(separator: " ")
    }

    /// What the Start button runs: prepare to completion, then execute.
    ///
    /// Both halves name their files with `-f`, as everything does now; see
    /// `command`. One shell command in one surface, so prepare's output appears
    /// where the user is already looking. `&&` means a failing prepare stops execute from
    /// starting. The two no longer share a socket path — `socketPath` scopes
    /// the headless phases by namespace — so the ordering here is about output
    /// and about not starting a stack whose prepare failed, nothing else.
    ///
    /// `prepare` is chained only when the config actually declares a process
    /// for it. process-compose does not exit when told to run an empty
    /// namespace — it idles forever — so unconditionally chaining `up -n
    /// prepare` ahead of execute would hang Start forever for any config that
    /// has not adopted the `prepare` namespace, including one that predates
    /// this convention and declares no namespaces at all. `execute` is never
    /// conditional: skipping it as well would make Start silently do nothing,
    /// which is worse than running an execute namespace that turns out empty.
    /// `namespaceIsConfidentlyEmpty` fails open (returns false) on any parse
    /// failure, so a config that genuinely declares `prepare` is never
    /// silently skipped because of a read/parse error.
    static func startCommand(
        config: ProcessComposeConfig,
        binary: String,
        workstreamID: UUID,
        selectedProcesses: [String]
    ) -> String {
        let execute = command(
            phase: .execute, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: selectedProcesses
        )
        guard !config.namespaceIsConfidentlyEmpty(ProcessComposePhase.prepare.namespace) else {
            return execute
        }
        let prepare = command(
            phase: .prepare, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )
        return "\(prepare) && \(execute)"
    }
}
