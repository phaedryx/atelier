// ABOUTME: Conforms the run session and the process-compose client to IPC.ExecutionControlling.
// ABOUTME: Owns the projection, the four-state read, and the two guards RunSession does not carry.

import Foundation

extension IPC {
    /// The adapter between the Execution feature and the seven MCP tools.
    ///
    /// **Everything socket-backed is view-independent**, because
    /// `ProcessCompose.PhaseRunner.socketPath(for:)` derives the control socket
    /// from the workstream id alone. Only starting and stopping a run needs the
    /// `ProcessCompose.RunSession`, which `TerminalSurfaceCache` owns for the
    /// workstream's life — which is the whole reason this is possible at all.
    /// Before `RunSession` existed the run's state was view `@State`, and
    /// `close_tab(kind: "execution")` was refused outright for exactly that
    /// reason.
    ///
    /// **It resolves its own `Resolution`**, off the Execution tab's, the same
    /// thing `Verification.Runner.start` does when it re-loads `verification.yaml`
    /// rather than reading the tab's copy. One function asked twice is not two
    /// copies — the distinction `RunCommandPlan` draws between agreement and
    /// freshness — and the alternative is a tool that answers nothing whenever
    /// the user has not opened the pane.
    ///
    /// **It does not assemble a `StartContext` of its own.**
    /// `ProcessCompose.StartContextResolver` is the one assembler, shared with
    /// `TerminalContainerView`; a second copy here is the drift that type was
    /// created to end.
    @MainActor
    final class ExecutionBridge: ExecutionControlling {
        private let runSession: @MainActor (UUID) -> ProcessCompose.RunSession
        private let target: @MainActor (UUID) throws -> WorkspaceActions.ExecutionTarget
        private let client: @Sendable (UUID) -> ProcessCompose.Controlling
        private let resolution: @Sendable (WorkspaceActions.ExecutionTarget) -> ProcessCompose.Resolution

        /// Every seam is injected and defaulted, the shape `Verification.Runner`
        /// uses for `SurfaceHosting` and `killGrace`: the four states and the two
        /// guards are the subtlest behaviour here and the hardest to reach with a
        /// live stack.
        init(
            runSession: @escaping @MainActor (UUID) -> ProcessCompose.RunSession,
            target: @escaping @MainActor (UUID) throws -> WorkspaceActions.ExecutionTarget,
            client: @escaping @Sendable (UUID) -> ProcessCompose.Controlling = { workstreamID in
                ProcessCompose.Client(
                    socketPath: ProcessCompose.PhaseRunner.socketPath(for: workstreamID)
                )
            },
            resolution: @escaping @Sendable (WorkspaceActions.ExecutionTarget) -> ProcessCompose.Resolution = { target in
                ProcessCompose.ResolutionModel.resolve(
                    projectDirectory: target.projectDirectory,
                    override: target.devCommandOverride
                )
            }
        ) {
            self.runSession = runSession
            self.target = target
            self.client = client
            self.resolution = resolution
        }

        // MARK: - Reads

        func executionState(in workstreamID: UUID) async throws -> ExecutionInfo {
            let target = try target(workstreamID)
            let resolved = await resolved(for: target)
            let session = runSession(workstreamID)
            let state = Self.state(
                plan: resolved.plan,
                usesProcessCompose: resolved.usesProcessCompose,
                runStarted: session.runStarted
            )
            // A manager that went away between the run flag and this read is an
            // ordinary race — stopping the last process ends the whole project —
            // not a fault. The state above is what the agent reads; an empty
            // table beside it is honest.
            let entries: [ProcessCompose.ProcessEntry] = if state == .running {
                await (try? client(workstreamID).processes()) ?? []
            } else {
                []
            }
            let ports = session.portPlan.values
            return ExecutionInfo(
                state: state,
                unavailableReason: state == .unavailable ? resolved.startUnavailableReason : nil,
                declaredProcesses: resolved.declaredExecuteProcesses,
                processes: entries.map { entry in
                    ExecutionProcessInfo(
                        name: entry.name,
                        namespace: entry.namespace,
                        status: entry.status,
                        isReady: entry.isReady,
                        hasReadyProbe: entry.hasReadyProbe,
                        restarts: entry.restarts,
                        exitCode: entry.exitCode,
                        pid: entry.pid,
                        isRunning: entry.isRunning,
                        port: ProcessCompose.TableModel.port(for: entry.name, in: ports)
                    )
                },
                // The loaded files, never the un-`-n`'d `process-compose up`
                // string: that is a display string which must not reach anything
                // that could execute it, and an agent is exactly such a thing.
                command: resolved.loadedFiles.isEmpty
                    ? resolved.devCommand?.command
                    : resolved.loadedFiles.joined(separator: ", ")
            )
        }

        /// The four-state read, as a pure function so every branch is assertable
        /// without a socket.
        static func state(
            plan: ProcessCompose.RunCommandPlan,
            usesProcessCompose: Bool,
            runStarted: Bool
        ) -> ExecutionRunState {
            guard plan.canRun else { return .unavailable }
            guard runStarted else { return .idle }
            return usesProcessCompose ? .running : .runningWithoutProcessTable
        }

        func processLogs(in workstreamID: UUID, name: String, tail: Int) async throws -> ExecutionLogs {
            try await requireProcessTable(in: workstreamID)
            let raw = try await client(workstreamID).logs(name: name, tail: tail)
            let trimmed = ExecutionLogs.trimmed(lines: raw)
            return ExecutionLogs(process: name, lines: trimmed.lines, wasTrimmed: trimmed.wasTrimmed)
        }

        // MARK: - Control

        func controlProcess(in workstreamID: UUID, name: String, action: ProcessAction) async throws {
            try await requireProcessTable(in: workstreamID)
            let client = client(workstreamID)
            switch action {
            case .start: try await client.start(name)
            case .stop: try await client.stop(name)
            case .restart: try await client.restart(name)
            }
        }

        func startExecution(in workstreamID: UUID, processes: [String]) async throws -> ExecutionStart {
            let target = try target(workstreamID)
            let session = runSession(workstreamID)
            guard !session.runStarted else { throw ExecutionFailure.alreadyRunning }
            // `RunSession.start` opens with `guard !isReclaimingSocket else { return }`
            // and returns SILENTLY, so without this a start reported as success
            // would be a press that did nothing at all.
            guard !session.isReclaimingSocket else { throw ExecutionFailure.startInFlight }

            let resolved = await resolved(for: target)
            let scope = processes.isEmpty ? nil : processes
            if let scope, let unknown = Self.undeclared(scope, in: resolved), !unknown.isEmpty {
                throw ExecutionFailure.unknownProcesses(unknown, declared: resolved.declaredExecuteProcesses)
            }
            guard let context = ProcessCompose.StartContextResolver.context(
                resolution: resolved,
                inputs: Self.inputs(for: target),
                processes: scope
            ) else {
                throw ExecutionFailure.nothingToRun(
                    resolved.startUnavailableReason
                        ?? "Nothing is selected to run: the user's Execution checklist has every process "
                        + "unticked. Name processes explicitly, or ask them to tick one."
                )
            }
            session.start(context)
            return ExecutionStart(
                started: scope ?? [],
                isReclaimingSocket: session.isReclaimingSocket
            )
        }

        func stopExecution(in workstreamID: UUID) async throws -> Bool {
            let session = runSession(workstreamID)
            // `RunSession.stop()` carries no guard of its own — every caller gates
            // it externally, the view's Stop button by rendering only when a run
            // is up and `close_tab` through `stopIfTabOwnsRun`. Called with
            // nothing running it still sets `runStoppedManually`, which suppresses
            // the next launch's tmux restore, and still bumps `runGeneration`. Do
            // not move this into `stop()`: those two callers need it
            // unconditional once their own question is answered.
            guard session.runStarted else { return false }
            session.stop()
            return true
        }

        // MARK: - Helpers

        /// Refuses the socket-backed operations when there is no manager to ask,
        /// naming which of the three reasons it is rather than reporting an empty
        /// stack as a fact.
        private func requireProcessTable(in workstreamID: UUID) async throws {
            let info = try await executionState(in: workstreamID)
            switch info.state {
            case .running:
                return
            case .unavailable:
                throw ExecutionFailure.noProcessTable(
                    info.unavailableReason ?? "Nothing is configured to run here."
                )
            case .idle:
                throw ExecutionFailure.noProcessTable("Nothing is running — start_execution first.")
            case .runningWithoutProcessTable:
                throw ExecutionFailure.noProcessTable(
                    "This workstream runs the user's own dev command, which has no process manager."
                )
            }
        }

        /// The resolution, off the main actor.
        ///
        /// `ProcessCompose.ResolutionModel.resolve` locates and parses
        /// `execution.process-compose.yaml` and probes three directories for the
        /// process-compose binary — file IO, and `ResolutionModel` is already
        /// built to run off the main actor for exactly that reason (its own first
        /// pass is the only synchronous one, and only because a pane with nothing
        /// resolved is not neutral). This type is `@MainActor` because
        /// `ProcessCompose.RunSession` and the target lookup are, so calling the
        /// closure inline ran that IO on the main thread — once per
        /// `list_processes`, and twice per `read_process_logs` or `*_process`,
        /// since `requireProcessTable` reads the state again before every one.
        /// An agent polling the process table is not a reason to stall the UI.
        ///
        /// The seam is already `@Sendable` and `ExecutionTarget` is `Sendable`,
        /// so the hop costs nothing but the suspension.
        private func resolved(for target: WorkspaceActions.ExecutionTarget) async -> ProcessCompose.Resolution {
            let resolution = resolution
            // `.userInitiated` because an agent is blocked on the reply, the
            // same priority `ProcessCompose.ResolutionModel.refresh` gives its
            // own off-main pass and `AppEnvironment.defaultBranch(for:)` gives
            // its detached probe.
            return await Task.detached(priority: .userInitiated) { resolution(target) }.value
        }

        /// The names in `scope` this config does not declare, or nil when the
        /// question cannot honestly be asked.
        ///
        /// Ordered **after** the plan is resolved and **before** the context is
        /// built, and both halves of that matter:
        ///
        /// - Nil for anything but `.phaseScoped`. A `.literal` plan is the user's
        ///   own typed dev command, which has no namespace and no process names;
        ///   a `.nothing` plan has no run at all, and the honest answer there is
        ///   `startUnavailableReason` through the existing `nothingToRun` path,
        ///   not "no such process".
        /// - Nil for a `.phaseScoped` plan that declares nothing, which is
        ///   reachable only for a config Yams could not decode —
        ///   `RunCommandPlan` turns a genuinely `.empty` execute namespace into
        ///   `.nothing`. Refusing there would report "this project declares:
        ///   nothing" as a fact about the user's file when what actually happened
        ///   is that Atelier could not read it.
        ///
        /// `declaredExecuteProcesses` is already `runnableProcesses`-filtered, so
        /// membership subsumes the flag-shaped-name check too: a `-web` is
        /// refused *as undeclared* rather than silently filtered out and then
        /// reported as an empty checklist, which is what the `nothingToRun`
        /// fallback used to say for a start nobody's checklist was involved in.
        ///
        /// **This is not the checklist gate moving into the plan.** The selection
        /// store is untouched here and `RunCommandPlan` is not consulted for it —
        /// this asks only whether the names the *caller* supplied exist, which is
        /// the same question `Verification.Runner.start` asks of a check name.
        /// `nonisolated` because it is pure — this type is `@MainActor` only
        /// because the run session and the target lookup are, and a question
        /// about two lists needs neither.
        nonisolated static func undeclared(_ scope: [String], in resolution: ProcessCompose.Resolution) -> [String]? {
            guard case .phaseScoped = resolution.plan else { return nil }
            let declared = Set(resolution.declaredExecuteProcesses)
            guard !declared.isEmpty else { return nil }
            return scope.filter { !declared.contains($0) }
        }

        /// The run's environment and wrapping, from the target alone.
        ///
        /// `ProcessCompose.PhaseEnvironment.variables` is the one place that
        /// assembles the full `ATELIER_*` set plus `ports.yaml` for a caller with
        /// no plan to hand over, which is exactly this caller. Allocation is
        /// deterministic per worktree and per name, so it lands on the numbers a
        /// view-driven Start would.
        private static func inputs(
            for target: WorkspaceActions.ExecutionTarget
        ) -> ProcessCompose.StartContextResolver.Inputs {
            var environment = ProcessCompose.PhaseEnvironment.variables(
                workstreamID: target.workstreamID,
                projectName: target.projectName,
                workstreamName: target.workstreamName,
                projectDirectory: target.projectDirectory,
                worktreePath: target.worktreePath,
                defaultBranch: target.defaultBranch
            )
            // The same correction `runEnvironmentVars` makes, for the same
            // reason: a headless terminal cannot answer Next.js's first-run
            // telemetry prompt.
            environment["NEXT_TELEMETRY_DISABLED"] = "1"
            return ProcessCompose.StartContextResolver.Inputs(
                workstreamID: target.workstreamID,
                workingDirectory: target.worktreePath,
                environment: environment,
                launcherPath: target.launcherPath,
                tmux: target.tmuxPath.map { path in
                    ProcessCompose.RunSession.TmuxContext(
                        path: path,
                        sessionName: TmuxSession.sessionName(
                            project: target.projectName,
                            workstream: target.workstreamName,
                            role: "run"
                        )
                    )
                },
                shell: target.shell
            )
        }
    }
}
