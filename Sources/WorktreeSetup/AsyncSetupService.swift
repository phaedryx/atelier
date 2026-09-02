// ABOUTME: Actor that creates a worktree and runs its bootstrap phase with progress reporting.
// ABOUTME: Claude Code launches immediately; the project's own bootstrap runs in the background.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "vibe.asyncsetup")

/// Represents the current state of async worktree setup.
enum AsyncSetupState: Equatable {
    case idle
    case inProgress(step: String, progress: Double)
    case completed
    /// Setup finished without doing anything, and the note says why: the
    /// integration is off, no `process-compose.yaml` was found, the binary is
    /// missing, or the config declares no `bootstrap` processes. The worktree
    /// exists and is usable either way — this is deliberately neither
    /// `.completed`, which would claim work that never happened, nor
    /// `.failed`, which would claim a broken worktree.
    case completedWithNote(String)
    case failed(String)

    static func == (lhs: AsyncSetupState, rhs: AsyncSetupState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.completed, .completed): return true
        case let (.inProgress(ls, lp), .inProgress(rs, rp)): return ls == rs && lp == rp
        case let (.completedWithNote(l), .completedWithNote(r)): return l == r
        case let (.failed(l), .failed(r)): return l == r
        default: return false
        }
    }
}

/// Notification posted on the main thread whenever setup state changes.
/// `userInfo` contains "workstreamID" (UUID) and "state" (AsyncSetupState).
extension Notification.Name {
    static let asyncSetupStateChanged = Notification.Name("atelier.asyncSetupStateChanged")
}

/// Actor that orchestrates worktree setup asynchronously.
/// The key insight: Claude Code can start immediately after `git worktree add` completes.
/// The project's `bootstrap` namespace runs in the background behind it.
actor AsyncSetupService {
    /// Shared singleton for app-wide access.
    static let shared = AsyncSetupService()

    /// Track per-workstream setup state.
    private var states: [UUID: AsyncSetupState] = [:]

    /// Workstreams whose bootstrap is in flight right now.
    ///
    /// Not derived from `states`: a caller publishes `.inProgress` before the
    /// background work starts, so a state-based check could not tell "about to
    /// start" from "already running".
    ///
    /// `runBackgroundSetup` suspends at `withCheckedContinuation`, and an actor
    /// admits other calls across a suspension. Two concurrent bootstraps for one
    /// workstream would share `<id>-bootstrap.sock`, and `PhaseExecutor.run`
    /// shuts that socket down before spawning — so the second run would strand
    /// the first's control server with no way to reach it, exactly the case
    /// `PhaseRunner.socketPath` warns about. Reachable from revoke → Review →
    /// Approve, and from `setupExistingWorktree` firing on
    /// `workstreamWorktreeReady` while an approval press lands.
    private var runningBootstraps: Set<UUID> = []

    /// Get the current setup state for a workstream.
    func state(for workstreamID: UUID) -> AsyncSetupState {
        states[workstreamID] ?? .idle
    }

    /// Run the bootstrap phase after worktree creation.
    ///
    /// This used to be a fixed sequence Atelier invented on the project's
    /// behalf — rsync a seed directory, create symlinks, link Claude settings,
    /// install dependencies, run post-setup commands — with a hard-coded
    /// notion of what a worktree needs. It is now one step: run
    /// whatever the project declares in the `bootstrap` namespace of its own
    /// `process-compose.yaml`. A project that declares nothing gets nothing,
    /// which is the point.
    ///
    /// Nothing here can stop the worktree from being usable. It already exists
    /// by the time this runs, and every way of having no bootstrap to run —
    /// integration off, no config, no binary, config not approved, no
    /// `bootstrap` processes — reports `.completedWithNote` rather than
    /// `.failed`. `PhasePolicy` owns both of those decisions; this method
    /// is only the plumbing between them.
    private func runBackgroundSetup(
        workstreamID: UUID,
        projectName: String,
        workstreamName: String,
        projectPath: String,
        worktreePath: String
    ) async {
        // Checked and claimed without an intervening `await`, so two callers
        // cannot both pass it.
        guard !runningBootstraps.contains(workstreamID) else {
            logger.info("Bootstrap for \(worktreePath, privacy: .public) is already running; ignoring the second request")
            return
        }
        runningBootstraps.insert(workstreamID)
        defer { runningBootstraps.remove(workstreamID) }

        await updateState(
            for: workstreamID,
            to: .inProgress(step: NSLocalizedString("Running bootstrap", comment: ""), progress: 0.5)
        )

        let plan = PhasePolicy.plan(
            phase: .bootstrap,
            isEnabled: ProcessComposeSettings.isEnabled,
            config: ProcessComposeConfig.locate(worktree: worktreePath, projectDirectory: projectPath),
            binary: ProcessComposeSettings.resolveBinary(),
            isApproved: {
                ScriptTrust.isApproved(configFiles: $0.repositoryProvidedFiles, for: projectPath)
            }
        )
        // Exhaustive on purpose. A nested `guard case` would leave the
        // workstream reporting `.inProgress` forever if a third `Plan` case
        // were ever added; a `switch` cannot compile past one.
        let config: ProcessComposeConfig
        let binary: String
        switch plan {
        case let .run(planned, planBinary):
            config = planned
            binary = planBinary
        case let .nothingToDo(message):
            await updateState(for: workstreamID, to: .completedWithNote(message))
            logger.info("No bootstrap for \(worktreePath, privacy: .public): \(message, privacy: .public)")
            return
        }

        // `PhaseExecutor.run` blocks its thread for as long as bootstrap takes,
        // so it must not run on the actor. The environment is assembled inside
        // the same hop for the same reason: it reads `ports.yaml` and asks git
        // for the default branch, neither of which the actor should wait on.
        let outcome: PhaseExecutor.Outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Built here rather than inside `PhaseExecutor` so the phase
                // layer stays free of the project model. Without it bootstrap
                // would run with none of the `ATELIER_*` or `ports.yaml`
                // variables the same file's `prepare` and `execute` phases see.
                let environment = PhaseEnvironment.variables(
                    workstreamID: workstreamID,
                    projectName: projectName,
                    workstreamName: workstreamName,
                    projectDirectory: projectPath,
                    worktreePath: worktreePath,
                    defaultBranch: GitOperations.defaultBranch(at: projectPath)
                )
                continuation.resume(returning: PhaseExecutor.run(
                    phase: .bootstrap,
                    config: config,
                    binary: binary,
                    workstreamID: workstreamID,
                    workingDirectory: worktreePath,
                    environment: environment,
                    timeout: ProcessRunner.Timeout.install
                ))
            }
        }

        let state = PhasePolicy.state(for: outcome)
        await updateState(for: workstreamID, to: state)
        logger.info("Bootstrap for \(worktreePath, privacy: .public) finished: \(String(describing: state), privacy: .public)")
    }

    /// Update state and post notification to main thread.
    private func updateState(for workstreamID: UUID, to newState: AsyncSetupState) async {
        states[workstreamID] = newState
        let state = newState
        await MainActor.run {
            NotificationCenter.default.post(
                name: .asyncSetupStateChanged,
                object: nil,
                userInfo: ["workstreamID": workstreamID, "state": state]
            )
        }
    }

    /// Run bootstrap on a worktree that already exists.
    ///
    /// Two callers. The worktree was created by upstream `GitOperations` and
    /// only the project's own setup still has to run; or the first bootstrap
    /// was refused because the repository's config had not been approved, the
    /// user has now approved it, and this re-runs the plan against a worktree
    /// that already exists. The plan is recomputed from scratch here, which is
    /// what makes the second case work at all.
    func setupExistingWorktree(
        workstreamID: UUID,
        projectName: String,
        workstreamName: String,
        projectPath: String,
        worktreePath: String
    ) async {
        await updateState(for: workstreamID, to: .inProgress(step: "Setting up workspace", progress: 0.2))
        await runBackgroundSetup(
            workstreamID: workstreamID,
            projectName: projectName,
            workstreamName: workstreamName,
            projectPath: projectPath,
            worktreePath: worktreePath
        )
    }

    /// Remove tracked state for a workstream (cleanup after archiving).
    func clearState(for workstreamID: UUID) {
        states.removeValue(forKey: workstreamID)
    }
}
