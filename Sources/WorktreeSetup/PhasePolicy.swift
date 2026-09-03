// ABOUTME: Decides whether an unattended process-compose phase runs, and what to report.
// ABOUTME: Pure, so the branch order can be tested without an actor or a subprocess.

import Foundation

/// The two decisions around an unattended phase: whether to run it, and what a
/// finished run means. They live outside `AsyncSetupService` because the actor's
/// own surface — a detached `Task`, a real worktree, a real process-compose — is
/// almost impossible to test, while these branches are the part that can
/// actually be got wrong.
///
/// `plan` is shared by `bootstrap` and `dispose`; `state` is bootstrap's alone,
/// because only bootstrap reports into `AsyncSetupState`. The name is
/// phase-neutral for that reason: naming it for bootstrap invited a second,
/// inlined copy of the gate in `Workstream.Archiver` for dispose.
enum PhasePolicy {
    /// What to do before running anything.
    enum Plan: Equatable {
        case run(config: ProcessComposeConfig, binary: String)
        /// There is no phase to run, and this says why. The worktree still
        /// exists and is usable in every one of these cases.
        case nothingToDo(String)
    }

    /// Whether an unattended phase may run, and what to report when it may not.
    ///
    /// Shared by `bootstrap` at worktree creation and `dispose` at archive.
    /// Both run repository-authored processes with nobody watching, so both
    /// answer to the same four preconditions and there is deliberately only one
    /// copy of them: a second, inlined set in `Workstream.Archiver` could not be
    /// tested and would not follow a change made here.
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
        phase: ProcessComposePhase,
        isEnabled: Bool,
        config: ProcessComposeConfig?,
        binary: String?,
        isApproved: (ProcessComposeConfig) -> Bool
    ) -> Plan {
        let name = phase.namespace
        guard isEnabled else {
            return .nothingToDo(String(format: NSLocalizedString(
                "The process-compose integration is turned off, so no %@ ran.", comment: ""
            ), name))
        }
        guard let config else {
            return .nothingToDo(String(format: NSLocalizedString(
                "This project has no process-compose.yaml, so no %@ ran.", comment: ""
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
        // This is the only gate. Adding a second one in `AsyncSetupService` or
        // `Workstream.Archiver` would sit behind this guard and never be reached.
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

    /// How a finished phase is reported. `.skipped` is deliberately neither a
    /// success, which would claim work that never happened, nor a failure,
    /// which would claim a broken worktree.
    static func state(for outcome: PhaseExecutor.Outcome) -> AsyncSetupState {
        switch outcome {
        case .succeeded:
            .completed
        case .skipped:
            .completedWithNote(NSLocalizedString(
                "This project declares no bootstrap processes, so nothing ran.", comment: ""
            ))
        case let .failed(detail):
            .failed(String(format: NSLocalizedString("Bootstrap failed: %@", comment: ""), detail))
        }
    }
}
