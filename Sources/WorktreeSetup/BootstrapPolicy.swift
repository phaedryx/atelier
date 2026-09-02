// ABOUTME: Decides whether a new worktree's bootstrap phase runs, and what to report.
// ABOUTME: Pure, so the branch order can be tested without an actor or a subprocess.

import Foundation

/// The two decisions around `bootstrap`: whether to run it, and what a finished
/// run means. They live outside `AsyncSetupService` because the actor's own
/// surface — a detached `Task`, a real worktree, a real process-compose — is
/// almost impossible to test, while these branches are the part that can
/// actually be got wrong.
enum BootstrapPolicy {
    /// What to do before running anything.
    enum Plan: Equatable {
        case run(config: ProcessComposeConfig, binary: String)
        /// There is no bootstrap to run, and this says why. The worktree still
        /// exists and is usable in every one of these cases.
        case nothingToDo(String)
    }

    /// - Parameter isApproved: whether the user has approved this config's
    ///   unattended phases. Passed in as a closure rather than a `Bool` so it is
    ///   only asked where a config exists, and so this stays testable without a
    ///   defaults store. No default value: every call site has to state its
    ///   policy, because the one that forgets is the one that runs a
    ///   repository's YAML unattended.
    static func plan(
        isEnabled: Bool,
        config: ProcessComposeConfig?,
        binary: String?,
        isApproved: (ProcessComposeConfig) -> Bool
    ) -> Plan {
        guard isEnabled else {
            return .nothingToDo(NSLocalizedString(
                "The process-compose integration is turned off, so no bootstrap ran.", comment: ""
            ))
        }
        guard let config else {
            return .nothingToDo(NSLocalizedString(
                "This project has no process-compose.yaml, so no bootstrap ran.", comment: ""
            ))
        }
        guard let binary else {
            return .nothingToDo(NSLocalizedString(
                "process-compose was not found, so no bootstrap ran.", comment: ""
            ))
        }
        // Fail closed. `bootstrap` executes commands that arrived with the
        // repository, unattended, the moment a workstream is created — the
        // exact thing `ScriptTrust` gates for `setup`, `run`, and `teardown`.
        // So a repository-provided config runs only once the user has approved
        // its contents. A config in the project directory was placed there by
        // hand, outside git, and is the user's own: nothing to approve.
        //
        // This is the only gate. Adding a second one in `AsyncSetupService`
        // would sit behind this guard and never be reached.
        //
        // Ordered after the binary check on purpose: when process-compose is
        // missing, nothing can run whatever the user approves, and saying so is
        // more actionable than asking for an approval that would change nothing.
        guard !config.isRepositoryProvided || isApproved(config) else {
            return .nothingToDo(NSLocalizedString(
                "This project's process-compose.yaml came with the repository and has not been approved, so no bootstrap ran.",
                comment: ""
            ))
        }
        return .run(config: config, binary: binary)
    }

    /// How a finished phase is reported. `.skipped` is deliberately neither a
    /// success, which would claim work that never happened, nor a failure,
    /// which would claim a broken worktree.
    static func state(for outcome: PhaseExecutor.Outcome) -> AsyncSetupState {
        switch outcome {
        case .succeeded:
            return .completed
        case .skipped:
            return .completedWithNote(NSLocalizedString(
                "This project declares no bootstrap processes, so nothing ran.", comment: ""
            ))
        case let .failed(detail):
            return .failed(String(format: NSLocalizedString("Bootstrap failed: %@", comment: ""), detail))
        }
    }
}
