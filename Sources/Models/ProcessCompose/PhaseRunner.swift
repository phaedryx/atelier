// ABOUTME: Builds the process-compose command for each lifecycle phase.
// ABOUTME: One config, four namespaces, one predictable control socket.

import Foundation

extension ProcessCompose {
    enum Phase: String, CaseIterable {
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
        static func socketPath(for workstreamID: UUID, phase: ProcessCompose.Phase = .execute) -> String {
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
        /// `ProcessCompose.PhaseExecutor`. It must stay off for the chained `startCommand`, where
        /// `prepare` has to exit on its own for `execute` to follow it.
        static func command(
            phase: ProcessCompose.Phase,
            config: ProcessCompose.Config,
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
                // Shell-quoting protects the shell; it does not protect
                // process-compose's own flag parser, which reads these as trailing
                // arguments. A repository YAML may name a process whatever it
                // likes, and a process called `-n` would make this
                // `up -n execute -n dispose` — re-selecting the namespace this
                // command exists to scope. Names that could be read as flags are
                // dropped rather than passed: process-compose cannot start a
                // process by a name it would parse as a flag anyway, so nothing
                // legitimate is lost.
                parts += selectedProcesses
                    .filter { !$0.hasPrefix("-") }
                    .map { CommandBuilder.shellQuote($0) }
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
        /// `prepare` is chained only when the config is **known** to declare a
        /// process for it — `.present`, never `.unknown`. process-compose does not
        /// exit when told to run an empty namespace, it idles forever, so chaining
        /// `up -n prepare` ahead of execute for a namespace that turns out not to
        /// exist hangs Start with no output and no way out but Stop. `execute` is
        /// never conditional: skipping it as well would make Start silently do
        /// nothing, which is worse than running an execute namespace that turns out
        /// empty.
        ///
        /// **This is the one place `.unknown` must fail closed, and it is the
        /// opposite of `ProcessCompose.PhaseExecutor`'s answer to the same question.** There, a
        /// config Yams cannot decode still runs its phase, because refusing would
        /// silently skip work the project may really have declared — and the cost of
        /// being wrong is bounded, by `min(timeout, userCommand)` and a grace period
        /// that ends in `.skipped`. Here nothing is bounded: the chained command
        /// runs in a terminal surface with no deadline, so failing open trades "a
        /// declared prepare was skipped" for "Start never returns". The costs invert,
        /// so the direction does. Reachable today — an override file with no
        /// top-level `processes:` key makes `declaredNamespaces` return nil.
        static func startCommand(
            config: ProcessCompose.Config,
            binary: String,
            workstreamID: UUID,
            selectedProcesses: [String]
        ) -> String {
            let execute = command(
                phase: .execute, config: config, binary: binary,
                workstreamID: workstreamID, selectedProcesses: selectedProcesses
            )
            guard config.namespacePresence(ProcessCompose.Phase.prepare.namespace) == .present else {
                return execute
            }
            let prepare = command(
                phase: .prepare, config: config, binary: binary,
                workstreamID: workstreamID, selectedProcesses: []
            )
            return "\(prepare) && \(execute)"
        }
    }
}
