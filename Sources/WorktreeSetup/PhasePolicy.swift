// ABOUTME: Decides whether an unattended process-compose phase runs, and what to report.
// ABOUTME: Pure, so the branch order can be tested without an actor or a subprocess.

import Foundation

/// The two decisions around an unattended phase: whether to run it, and what a
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
    /// `dispose` at archive runs repository-authored processes with nobody
    /// watching, so it answers to three preconditions and there is deliberately
    /// only one copy of them: a second, inlined set in `Workstream.Archiver`
    /// could not be tested and would not follow a change made here. Any new
    /// unattended path for repository-provided process-compose commands goes
    /// through here rather than growing its own.
    ///
    /// Initialization does **not** go through it, and that is not an omission: a
    /// step's command comes from `initialization.yaml` in the project directory,
    /// outside every work tree, so the location rule this gate implements has
    /// already answered the question.
    ///
    /// - Parameter phase: named only so the note can say which phase did not
    ///   run. It does not change any decision.
    /// - Parameter isApproved: whether the user has approved the
    ///   repository-provided files this config will load. Passed in as a closure
    ///   rather than a `Bool` so it is only asked where a config exists, and so
    ///   this stays testable without a defaults store. No default value: every
    ///   call site has to state its policy, because the one that forgets is the
    ///   one that runs a repository's YAML unattended.
    static func plan(
        phase: ProcessCompose.Phase,
        config: ProcessCompose.Config?,
        binary: String?,
        isApproved: (ProcessCompose.Config) -> Bool
    ) -> Plan {
        let name = phase.namespace
        guard let config else {
            return .nothingToDo(String(format: NSLocalizedString(
                "This project has no process-compose config, so no %@ ran.", comment: ""
            ), name))
        }
        guard let binary else {
            return .nothingToDo(String(format: NSLocalizedString(
                "process-compose was not found, so no %@ ran.", comment: ""
            ), name))
        }
        // Fail closed. These phases execute processes that arrived with the
        // repository, unattended and with nobody watching. So they run only
        // once the user has approved the contents of every repository-provided
        // file process-compose will load, which is not the same as the config
        // `locate` recorded: see `repositoryProvidedFiles`. A config the user
        // placed in the project directory contributes nothing to that list and
        // needs no approval — location is what decides, not content.
        //
        // This is the only gate. Adding a second one in `Workstream.Archiver`
        // would sit behind this guard and never be reached.
        //
        // Ordered after the binary check on purpose: when process-compose is
        // missing, nothing can run whatever the user approves, and saying so is
        // more actionable than asking for an approval that would change nothing.
        guard !config.requiresApproval || isApproved(config) else {
            return .nothingToDo(String(format: NSLocalizedString(
                "This project's process-compose files came with the repository and have not been approved, so no %@ ran.",
                comment: ""
            ), name))
        }
        return .run(config: config, binary: binary)
    }
}
