// ABOUTME: The one place a run's StartContext is assembled, for the view and the IPC bridge both.
// ABOUTME: Lifted out of TerminalContainerView so a second assembler cannot exist.

import Foundation

extension ProcessCompose {
    /// Assembles `RunSession.StartContext` from a resolved `Resolution` plus the
    /// facts only a caller can know.
    ///
    /// **One assembler, two callers.** This lived in `TerminalContainerView` as
    /// `resolvedRunCommand` and `runStartContext`, which made it unreachable from
    /// `WorkspaceActions` — the reason `close_tab(kind: "execution")` was refused
    /// outright until `RunSession` existed. A second copy in the IPC layer would be
    /// exactly the drift `RunSession`'s own doc comment warns about.
    ///
    /// **It consumes a `RunCommandPlan`; it never re-decides one.** `canRun` is
    /// what enables the Start button and what the IPC bridge refuses on, and both
    /// read the same resolved plan. Handing `RunSession.start` a non-optional
    /// command is what makes `restart`'s old hazard structural rather than a guard
    /// somebody has to remember.
    ///
    /// **The checklist selection is read here, and it is still not in
    /// `RunCommandPlan`.** That rule is unchanged by the move and a reviewer will
    /// pattern-match this to breaking it: `.nothing` in the plan would take
    /// `declaredExecuteProcesses` with it — that property matches on
    /// `.phaseScoped` — hiding the very checklist the user needs in order to tick
    /// a box again, and removing the Start button instead of disabling it. The
    /// plan answers "is there a safe command for this source"; this answers "is
    /// there anything to run it for". Only the *location* of the read changed.
    enum StartContextResolver {
        /// Everything a start needs that a `Resolution` cannot supply.
        ///
        /// Passed per call rather than cached, for the reason `StartContext`'s own
        /// doc gives: a run must use the world as it is when Start is pressed, not
        /// as it was when the session was created.
        struct Inputs {
            let workstreamID: UUID
            let workingDirectory: String
            let environment: [String: String]
            /// `atelier-run`, for port detection. Absent runs the command bare
            /// through `scriptCommand`.
            let launcherPath: String?
            /// Non-nil only when this run really will be wrapped, so the session
            /// records what it actually started in — what lets `stop()` kill the
            /// right session with no view mounted.
            let tmux: ProcessCompose.RunSession.TmuxContext?
            let shell: String
        }

        /// The command Start would run, or nil for "there is nothing to run".
        ///
        /// - Parameter processes: a per-call scope. Nil reads the workstream's
        ///   stored selection exactly as the Start button does. A list is used for
        ///   this call only and is **never** written back to the selection store —
        ///   an agent scoping a run must not re-tick the user's checkboxes.
        static func command(
            resolution: ProcessCompose.Resolution,
            workstreamID: UUID,
            processes: [String]?
        ) -> String? {
            switch resolution.plan {
            case let .literal(command):
                // The user's own typed override. The checklist scopes a
                // process-compose run and has nothing to say about this one.
                return command
            case let .phaseScoped(config, binary):
                // Nil is the checklist saying nothing is selected, and the refusal
                // is the point: an empty name list would start the whole namespace.
                guard let selected = selectedProcesses(
                    workstreamID: workstreamID,
                    declared: resolution.declaredExecuteProcesses,
                    processes: processes
                ) else {
                    return nil
                }
                ProcessCompose.PhaseRunner.ensureSocketDirectory()
                return ProcessCompose.PhaseRunner.startCommand(
                    config: config,
                    binary: binary,
                    workstreamID: workstreamID,
                    selectedProcesses: selected
                )
            case .nothing:
                return nil
            }
        }

        /// The full context, or nil when `command` is nil.
        static func context(
            resolution: ProcessCompose.Resolution,
            inputs: Inputs,
            processes: [String]?
        ) -> ProcessCompose.RunSession.StartContext? {
            guard let command = command(
                resolution: resolution, workstreamID: inputs.workstreamID, processes: processes
            ) else {
                return nil
            }
            return ProcessCompose.RunSession.StartContext(
                command: command,
                workingDirectory: inputs.workingDirectory,
                environment: inputs.environment,
                launcherPath: inputs.launcherPath,
                tmux: inputs.tmux,
                shell: inputs.shell
            )
        }

        /// A per-call list wins; otherwise the stored checklist decides.
        ///
        /// A per-call list is filtered by `runnableProcesses` too, so a caller
        /// cannot name a flag-shaped process the command would drop — and an empty
        /// result is nil, never `[]`, because `[]` starts the whole namespace.
        /// That is the same inversion `processesToStart` closes for the stored
        /// side, applied to the one input that does not go through it.
        private static func selectedProcesses(
            workstreamID: UUID,
            declared: [String],
            processes: [String]?
        ) -> [String]? {
            guard let processes else {
                return processesToStart(
                    stored: ProcessCompose.TableModel.selection(for: workstreamID),
                    declared: declared
                )
            }
            let runnable = ProcessCompose.PhaseRunner.runnableProcesses(processes)
            return runnable.isEmpty ? nil : runnable
        }
    }
}

/// The names to hand `ProcessCompose.PhaseRunner` for an `execute` run, or nil
/// when the checklist has nothing selected and there is nothing to run.
///
/// The run's own copy of the checklist's reconciliation, so the runner is
/// self-sufficient: `ProcessSelectionView.onAppear` writes a cleaned selection
/// back to the store, but Start is reachable from the command palette and
/// Cmd+Shift+Return without that view ever having appeared, so a stored name the
/// config no longer offers would otherwise go straight to the shell.
///
/// It filters `declared` itself rather than trusting a caller to have done it,
/// for the reason `Verification.Runner.resolveChecks` gives for the same move:
/// the guarantee must not depend on every call site remembering. That is what
/// closes the inversion — a stored selection whose only members are flag-shaped
/// resolves to `.all` here, which is what the checklist renders too, instead of
/// surviving as a non-empty selection that `PhaseRunner.command` then filters
/// down to nothing and runs the whole namespace for.
///
/// The nil is the other half of that: `.all` and `.nothing` both name no
/// processes, and only the type keeps them apart on the way to a runner that
/// reads no names as *everything*.
///
/// Declared here rather than beside the checklist view because the run decision
/// moved here; `ProcessSelectionView` still calls it.
func processesToStart(stored: ProcessSelection, declared: [String]) -> [String]? {
    processSelectionOnLoad(
        stored: stored,
        declared: ProcessCompose.PhaseRunner.runnableProcesses(declared)
    ).namesToRun
}
