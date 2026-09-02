// ABOUTME: Decides what the Environment tab's Start button may run, by dev-command source.
// ABOUTME: Pure, so the one invariant it exists to hold can be tested without a view.

import Foundation

/// What Start is allowed to run for a workstream.
///
/// This exists to hold **one invariant**: the command string
/// `DevCommandResolver` builds for a `.processCompose` source is *never
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
enum RunCommandPlan: Equatable {
    /// Run this string as-is. Only ever the user's own per-workstream override,
    /// which they typed and which no gate applies to.
    case literal(String)
    /// Build and run the phase-scoped `prepare && execute` command for this
    /// config and binary. The only way a process-compose run may start.
    case phaseScoped(config: ProcessComposeConfig, binary: String)
    /// There is nothing safe to run, and Start should say so rather than fall
    /// back to anything.
    case nothing

    /// - Parameter devCommand: what `DevCommandResolver` resolved, or nil when it
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
    static func plan(
        devCommand: DevCommand?,
        config: ProcessComposeConfig?,
        binary: String?
    ) -> RunCommandPlan {
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
            return .phaseScoped(config: config, binary: binary)
        }
    }
}
