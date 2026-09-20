// ABOUTME: The seam the execution IPC tools reach the dev stack through.
// ABOUTME: Declared on this side on purpose, so the tools compile and test against a stub.

import Foundation

extension IPC {
    /// Which way a single process is being driven.
    enum ProcessAction: String, Codable, Sendable, CaseIterable {
        case start
        case stop
        case restart
    }

    /// What the seven execution tools need from the app.
    ///
    /// **This side declares it and `IPC.ExecutionBridge` conforms**, mirroring
    /// `IPC.VerificationControlling`: the tools then have a test seam that needs
    /// no process-compose binary, no control socket and no worktree, and the two
    /// halves of the feature can land in either order.
    ///
    /// Everything crossing it is an `IPC` projection rather than
    /// `ProcessCompose.ProcessEntry` or `ProcessCompose.Resolution` — the
    /// relationship `PeerInfo` has to the store's `Peer`, and `TabInfo` to what
    /// `WorkspaceActions` reads.
    ///
    /// ### No approval gate, and why not
    ///
    /// `execution.process-compose.yaml` lives in the **project directory**,
    /// outside every work tree, so it cannot have arrived with a clone: it was
    /// placed by hand. That is the same location rule that leaves
    /// `start_verification` unasked-about and `dispose` ungated, and it is stated
    /// here rather than left to be inferred, because a reviewer will ask why an
    /// agent may run project-declared commands. The known hole is the one both
    /// existing configs already accept and this does not reopen: for an ordinary
    /// clone `Project.directory` *is* the checkout.
    ///
    /// ### No completion notices, deliberately
    ///
    /// Verification posts a notice per check because `Verification.Runner`
    /// already runs completions through the app. There is no headless equivalent
    /// here — the process table's polling (`TerminalContainerView.syncProcessPolling`)
    /// is view-owned by design — so notices would mean a second per-workstream
    /// polling lifecycle plus a definition of "finished" for a server that is
    /// meant to stay up. Agents poll `list_processes`, and `startExecution`'s
    /// answer says so in as many words. **Do not "fix" this asymmetry by
    /// mirroring verification.**
    ///
    /// ### The contract, beyond the signatures
    ///
    /// - **`startExecution` returns without waiting for the stack.**
    ///   `ProcessCompose.RunSession.start` is already synchronous — its socket
    ///   reclaim runs in a detached `Task` — so the answer is "started, now
    ///   poll", the shape `startVerification` uses for a run id.
    /// - **It must refuse rather than report a start that did not happen.**
    ///   `RunSession.start` opens with `guard !isReclaimingSocket else { return }`
    ///   and returns *silently*, so a conformance checks that flag itself. A run
    ///   already up is refused too, never silently restarted.
    /// - **`processes` scopes this run and nothing else.** It must never write
    ///   `atelier.processSelection.<id>`: an agent narrowing a run must not
    ///   re-tick the user's checkboxes. Empty means "use the stored selection",
    ///   which is exactly what the Start button reads.
    /// - **`stopExecution` must guard on `runStarted` itself.** `RunSession.stop()`
    ///   has no guard of its own — every caller today gates it externally, the
    ///   view's Stop button by rendering only when a run is up, and `close_tab`
    ///   through `stopIfTabOwnsRun`'s `closingTabStopsRun`. Called with nothing
    ///   running it still sets `runStoppedManually = true`, which **suppresses the
    ///   tmux restore on the next launch**, and still bumps `runGeneration`. Do
    ///   not move the guard into `stop()` — the view and `close_tab` depend on it
    ///   being unconditional once their own question is answered.
    /// - **Stopping a run that is not up is success, not a refusal**, and so is
    ///   controlling a process already in the asked-for state. That is what makes
    ///   the six replayable tools honestly replayable: a replay landing after the
    ///   first call succeeded must answer the same way rather than erroring on a
    ///   fact that is merely no longer true — the rule `close_tab` already states.
    /// - **The socket-backed operations refuse with the state's own reason** when
    ///   there is no manager to ask, rather than reporting an empty list as a
    ///   fact.
    protocol ExecutionControlling: Sendable {
        /// The run's state, what the config declares, and the live process table.
        ///
        /// Never throws for "nothing is running" — that is a state, not a
        /// failure, and it is the state the other six tools refuse on.
        func executionState(in workstreamID: UUID) async throws -> ExecutionInfo

        /// One process's log tail, newest last, already trimmed to a budget.
        func processLogs(in workstreamID: UUID, name: String, tail: Int) async throws -> ExecutionLogs

        /// Drive one process. Idempotent: an action already true succeeds.
        func controlProcess(in workstreamID: UUID, name: String, action: ProcessAction) async throws

        /// Start the dev stack, scoped to `processes` for this call only.
        ///
        /// - Parameter processes: **empty means "use the stored selection"**,
        ///   which is already this codebase's convention for a process selection
        ///   and is what the Start button does.
        func startExecution(in workstreamID: UUID, processes: [String]) async throws -> ExecutionStart

        /// Stop the run. Returns whether one was actually up; false is success,
        /// not a refusal.
        func stopExecution(in workstreamID: UUID) async throws -> Bool
    }

    /// Why an execution tool could not act, on this side of the seam.
    ///
    /// Every case is something the calling agent can act on. The app's own
    /// refusals — an unreachable manager, a process-compose error — arrive as
    /// `ProcessCompose.Client.ClientError` and are passed through verbatim, the
    /// way `Verification.Runner`'s are.
    enum ExecutionFailure: Swift.Error, LocalizedError {
        case notAvailable
        case noProcessTable(String)
        case nothingToRun(String)
        case alreadyRunning
        case startInFlight

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                "Execution is not available: Atelier has no run controller wired up."
            case let .noProcessTable(reason):
                "There is no process manager to ask in this workstream. \(reason) "
                    + "list_processes reports the run's state without one."
            case let .nothingToRun(reason):
                reason
            case .alreadyRunning:
                "This workstream's dev stack is already running. Read it with list_processes, "
                    + "or stop_execution first if you mean to restart it."
            case .startInFlight:
                "A start is already in flight for this workstream — Atelier is reclaiming the "
                    + "previous run's control socket. Do not retry: poll list_processes instead."
            }
        }
    }
}
