// ABOUTME: Decides what the Execution tab's Start button may run, by dev-command source.
// ABOUTME: Pure, so the one invariant it exists to hold can be tested without a view.

import Foundation

extension ProcessCompose {
    /// What Start is allowed to run for a workstream.
    ///
    /// This exists to hold **one invariant**: the command string
    /// `DevCommand.Resolver` builds for a `.processCompose` source is *never
    /// executed*. That string is `process-compose up -U -f <files>` — it carries no
    /// `-n`, so process-compose runs every namespace it finds, `bootstrap` and
    /// `dispose` included. Those two are exactly what `PhasePolicy` gates behind the
    /// user having approved every repository-provided file, and that string reaches
    /// process-compose without passing through `PhasePolicy` or `ScriptTrust` at
    /// all. It is a display string: the pane shows it so the user can see which
    /// files are in play. It is not a runnable one.
    ///
    /// The invariant used to be defended by guarding its *preconditions* — and that
    /// failed four times, each time by a different route: a worktree override
    /// process-compose discovered but Atelier never showed; `compose.yaml` winning
    /// discovery outright; the integration toggle being off; and the binary being
    /// unresolvable while the toggle was on. Each fix closed one door. The shape of
    /// the bug is that the fallback is reachable whenever *any* precondition of the
    /// gated path fails, so enumerating preconditions can only ever be behind.
    ///
    /// So the decision is made on the **source** instead, here, at the consumer. A
    /// `.processCompose` source has exactly one legal command — the phase-scoped one
    /// — and if that cannot be produced the answer is `.nothing`. A new precondition
    /// added tomorrow makes this return `.nothing` rather than reopening the
    /// bypass, because there is no branch left that returns the un-`-n`'d string.
    ///
    /// One such precondition has since been added, and it is the reason this type
    /// is also where `execute`'s own presence is checked: `up -n execute` against a
    /// namespace no process declares idles forever rather than failing, so the
    /// honest answer is `.nothing` plus a reason, not an empty TUI. It belongs here
    /// and not in `PhaseRunner.startCommand` because `canRun` is what enables the
    /// Start button — deciding it further down would leave the button enabled over
    /// a run that does nothing, which is the exact disagreement this type exists to
    /// prevent.
    enum RunCommandPlan: Equatable {
        /// Run this string as-is. Only ever the user's own per-workstream override,
        /// which they typed and which no gate applies to.
        case literal(String)
        /// Build and run the phase-scoped `prepare && execute` command for this
        /// config and binary. The only way a process-compose run may start.
        case phaseScoped(config: ProcessCompose.Config, binary: String)
        /// There is nothing safe to run, and Start should say so rather than fall
        /// back to anything.
        case nothing

        /// - Parameter devCommand: what `DevCommand.Resolver` resolved, or nil when it
        ///   found nothing.
        /// - Parameter config: the config located for the *run*, or nil when the run
        ///   is not a process-compose run.
        /// - Parameter binary: the resolved process-compose binary, or nil when there
        ///   isn't one. Nil here is not a licence to run the command by another
        ///   route: `scriptCommand` would wrap the fallback in `$SHELL -lic`, so PATH
        ///   would resolve the very binary `resolveBinary` just failed to find —
        ///   defeating that function's own documented promise that a
        ///   configured-but-missing path fails rather than letting something else
        ///   stand in for it.
        /// Whether Start may run anything at all.
        ///
        /// The Execution pane's Start button is enabled on exactly this, and
        /// `doStartRun` refuses on exactly this, because they are the same question
        /// asked once. They used to be two: the button was enabled on
        /// `devCommand?.command != nil` while the run guarded the resolved command,
        /// so an unresolvable binary rendered an enabled button that did nothing and
        /// said nothing.
        var canRun: Bool {
            self != .nothing
        }

        /// Why Start can do nothing, phrased for the pane, or nil when it can run —
        /// or when the pane's own copy already explains it.
        ///
        /// Kept as a separate function rather than an associated value on
        /// `.nothing`: the plan is authoritative about *whether* Start may run and
        /// the tests that pin that invariant compare against a bare `.nothing`.
        /// This only explains *why*, and both are set together in one refresh so
        /// they cannot describe different states.
        ///
        /// - Parameter isEnabled: whether the integration is switched on. Needed
        ///   because `DevCommand.Resolver` detects nothing while it is off, which
        ///   arrives here as `devCommand == nil` — indistinguishable, without this,
        ///   from a project that genuinely has no config, and those want opposite
        ///   advice.
        static func unavailableReason(
            devCommand: DevCommand?,
            config: ProcessCompose.Config?,
            binary: String?,
            isEnabled: Bool
        ) -> String? {
            guard let devCommand else {
                guard !isEnabled else { return nil }
                return NSLocalizedString(
                    "The process-compose integration is turned off, so nothing was detected. Turn it on in Settings, or set a command with Customize.",
                    comment: ""
                )
            }
            switch devCommand.source {
            case .override:
                return nil
            case .processCompose:
                if config == nil {
                    return NSLocalizedString(
                        "This project's process-compose config could not be located, so there is nothing to start.",
                        comment: ""
                    )
                }
                if binary == nil {
                    return NSLocalizedString(
                        "process-compose was not found. Install it, or set its path in Settings, then try again.",
                        comment: ""
                    )
                }
                // Mirrors `plan`'s fifth precondition, in the same order, and
                // nothing but a test enforces the agreement — see
                // `RunCommandPlanTests`, which asserts `canRun` and this function
                // answer the same question for this case.
                if config?.namespacePresence(ProcessCompose.Phase.execute.namespace) == .empty {
                    return NSLocalizedString(
                        "This project's process-compose config declares no execute processes, so there is nothing to start.",
                        comment: ""
                    )
                }
                return nil
            }
        }

        static func plan(
            devCommand: DevCommand?,
            config: ProcessCompose.Config?,
            binary: String?
        ) -> ProcessCompose.RunCommandPlan {
            guard let devCommand else { return .nothing }
            // Exhaustive on purpose. A new `DevCommand.Source` must not be able to
            // default into `.literal`: a source whose command is a display string
            // needs its own considered branch, and a `switch` cannot compile past
            // one while `default` would silently make it runnable.
            switch devCommand.source {
            case .override:
                return .literal(devCommand.command)
            case .processCompose:
                guard let config, let binary else { return .nothing }
                // The fifth precondition, and the only one about the config's
                // *contents*. `up -n execute` against a namespace nobody declared
                // does not fail and does not exit — measured against v1.122.0, it
                // idles indefinitely with no output — so Start would open a TUI
                // with an empty process list and no way out but Stop.
                //
                // `.empty` only, never `.unknown`. `.empty` is a fact: every
                // loaded file parsed and none of them put a process in `execute`.
                // `.unknown` is a failure to *read* — a top-level `include:`, a
                // `namespace` given as a list — and refusing there would turn a
                // parse gap into a permanently dead Start button. That is the same
                // asymmetry `ProcessCompose.PhaseRunner.startCommand` applies to
                // `prepare`, for the same reason.
                guard config.namespacePresence(ProcessCompose.Phase.execute.namespace) != .empty else {
                    return .nothing
                }
                return .phaseScoped(config: config, binary: binary)
            }
        }
    }
}
