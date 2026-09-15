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
        case run(config: ProcessCompose.Config, binary: String)
        /// There is no phase to run, and this says why. The worktree still
        /// exists and is usable in every one of these cases.
        case nothingToDo(String)
    }

    /// Whether an unattended phase may run, and what to report when it may not.
    ///
    /// Shared by `bootstrap` at worktree creation and `dispose` at archive.
    /// Both run the project's processes with nobody watching, so both answer to
    /// the same two preconditions and there is deliberately only one copy of
    /// them: a second, inlined set in `Workstream.Archiver` could not be tested
    /// and would not follow a change made here.
    ///
    /// **There were three.** The third was approval of every repository-provided
    /// file process-compose would load, and it went with the worktree tiers it
    /// gated: `ProcessCompose.Config.locate` now reads `execution.process-compose.yaml`
    /// in the project directory and nowhere else, so a config cannot have arrived
    /// with a clone and there is nothing left to approve. Do not add a gate back
    /// here without first putting a work-tree tier back in `locate`, because
    /// location is the whole of the trust decision.
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
        // This is the only gate. Adding a second one in `AsyncSetupService` or
        // `Workstream.Archiver` would sit behind these guards and never be
        // reached.
        return .run(config: config, binary: binary)
    }

    /// How a finished phase is reported. `.skipped` is deliberately neither a
    /// success, which would claim work that never happened, nor a failure,
    /// which would claim a broken worktree.
    static func state(for outcome: ProcessCompose.PhaseExecutor.Outcome) -> AsyncSetupState {
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
