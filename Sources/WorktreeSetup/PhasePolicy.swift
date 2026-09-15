// ABOUTME: Decides whether an unattended process-compose phase runs, and what to report.
// ABOUTME: Pure, so the branch order can be tested without an actor or a subprocess.

import Foundation

/// Whether an unattended phase runs, and what to say when it does not.
///
/// It lives outside the actor that calls it because an actor's own surface — a
/// detached `Task`, a real worktree, a real process-compose — is almost
/// impossible to test, while this branch order is the part that can actually be
/// got wrong.
///
/// **`dispose` is the only caller left.** `plan` was shared with `bootstrap`
/// until setup moved out of process-compose and into `initialization.yaml`,
/// which is also what retired `state(for:)` — that mapped an outcome into
/// `AsyncSetupState` and was bootstrap's alone. The name stays phase-neutral
/// rather than becoming `DisposePolicy`: naming a gate for its single caller is
/// what invites the next unattended phase to inline a second copy of it, which
/// is the one thing this type exists to prevent.
enum PhasePolicy {
    /// What to do before running anything.
    enum Plan: Equatable {
        case run(config: ProcessCompose.Config, binary: String)
        /// There is no phase to run, and this says why. The worktree still
        /// exists and is usable in every one of these cases.
        case nothingToDo(String)
    }

    /// Whether an unattended phase may run, and what to report when it may not.
    ///
    /// `dispose` at archive runs the project's processes with nobody watching,
    /// so it answers to two preconditions and there is deliberately only one
    /// copy of them: a second, inlined set in `Workstream.Archiver` could not be
    /// tested and would not follow a change made here. Any new unattended path
    /// for process-compose commands goes through here rather than growing its
    /// own.
    ///
    /// **There were three.** The third was approval of every repository-provided
    /// file process-compose would load, and it went with the work-tree tiers it
    /// gated: `ProcessCompose.Config.locate` now reads
    /// `execution.process-compose.yaml` in the project directory and nowhere
    /// else, so a config cannot have arrived with a clone and there is nothing
    /// left to approve. That is the same location rule `initialization.yaml` and
    /// `verification.yaml` already state — which is why neither of those goes
    /// through this gate either, and why it is now three files answering to one
    /// rule rather than one file with an exemption. Do not add a gate back here
    /// without first putting a work-tree tier back in `locate`.
    ///
    /// - Parameter phase: named only so the note can say which phase did not
    ///   run. It does not change any decision.
    static func plan(
        phase: ProcessCompose.Phase,
        config: ProcessCompose.Config?,
        binary: String?
    ) -> Plan {
        let name = phase.namespace
        guard let config else {
            return .nothingToDo(String(format: NSLocalizedString(
                "This project has no execution.process-compose.yaml, so no %@ ran.", comment: ""
            ), name))
        }
        guard let binary else {
            return .nothingToDo(String(format: NSLocalizedString(
                "process-compose was not found, so no %@ ran.", comment: ""
            ), name))
        }
        // This is the only gate. Adding a second one in `Workstream.Archiver`
        // would sit behind these guards and never be reached.
        return .run(config: config, binary: binary)
    }
}
