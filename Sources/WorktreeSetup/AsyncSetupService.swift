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

    /// Get the current setup state for a workstream.
    func state(for workstreamID: UUID) -> AsyncSetupState {
        states[workstreamID] ?? .idle
    }

    /// Run the full async setup for a new vibe workstream.
    ///
    /// This method:
    /// 1. Creates the git worktree (blocking — must complete before anything else)
    /// 2. Returns the worktree path immediately so the caller can launch Claude Code
    /// 3. Kicks off the project's `bootstrap` phase in the background
    ///
    /// - Parameters:
    ///   - workstreamID: The UUID of the workstream being set up
    ///   - projectPath: Path to the main project/repo root
    ///   - projectName: Name of the project
    ///   - workstreamName: Name for the new workstream/branch
    /// - Returns: The worktree path if worktree creation succeeded, nil otherwise.
    func setup(
        workstreamID: UUID,
        projectPath: String,
        projectName: String,
        workstreamName: String
    ) async -> String? {
        // Step 1: Create worktree (must complete first)
        await updateState(for: workstreamID, to: .inProgress(step: "Creating worktree", progress: 0.1))

        let worktreePath: String? = await withCheckedContinuation { continuation in
            // Run git worktree add on a background thread since it's a blocking Process call
            DispatchQueue.global(qos: .userInitiated).async {
                let path = GitOperations.createWorktree(
                    projectPath: projectPath,
                    projectName: projectName,
                    workstreamName: workstreamName
                )
                continuation.resume(returning: path)
            }
        }

        guard let worktreePath else {
            logger.warning("Failed to create worktree for \(workstreamName, privacy: .public)")
            await updateState(for: workstreamID, to: .failed("Failed to create git worktree"))
            return nil
        }

        logger.info("Worktree created at \(worktreePath, privacy: .public), starting background setup")

        // Step 2: Terminal launch happens in the caller — we just report progress.
        await updateState(for: workstreamID, to: .inProgress(step: "Terminal ready", progress: 0.2))

        // Step 3: Bootstrap — fire and forget from the caller's perspective.
        // The caller gets the worktree path back immediately.
        Task {
            await runBackgroundSetup(
                workstreamID: workstreamID,
                projectPath: projectPath,
                worktreePath: worktreePath
            )
        }

        return worktreePath
    }

    /// Run the bootstrap phase after worktree creation.
    ///
    /// This used to be a fixed sequence Atelier invented on the project's
    /// behalf — copy the seed directory, create symlinks, link Claude
    /// settings, install dependencies, run post-setup commands — with a
    /// hard-coded notion of what a worktree needs. It is now one step: run
    /// whatever the project declares in the `bootstrap` namespace of its own
    /// `process-compose.yaml`. A project that declares nothing gets nothing,
    /// which is the point.
    ///
    /// Nothing here can stop the worktree from being usable. It already
    /// exists by the time this runs, and every way of having no bootstrap to
    /// run — the integration turned off, no config, no binary, no `bootstrap`
    /// processes — reports `.completedWithNote` rather than `.failed`.
    private func runBackgroundSetup(
        workstreamID: UUID,
        projectPath: String,
        worktreePath: String
    ) async {
        await updateState(
            for: workstreamID,
            to: .inProgress(step: NSLocalizedString("Running bootstrap", comment: ""), progress: 0.5)
        )

        guard ProcessComposeSettings.isEnabled else {
            await note(
                for: workstreamID,
                NSLocalizedString("The process-compose integration is turned off, so no bootstrap ran.", comment: "")
            )
            return
        }
        guard let config = ProcessComposeConfig.locate(worktree: worktreePath, projectDirectory: projectPath) else {
            await note(
                for: workstreamID,
                NSLocalizedString("This project has no process-compose.yaml, so no bootstrap ran.", comment: "")
            )
            return
        }
        guard let binary = ProcessComposeSettings.resolveBinary() else {
            await note(
                for: workstreamID,
                NSLocalizedString("process-compose was not found, so no bootstrap ran.", comment: "")
            )
            return
        }

        // NOT YET GATED. `bootstrap` runs commands that arrived with the
        // repository, and every other such path checks `ScriptTrust.isApproved`
        // first. The config-file approval API and its pane land alongside
        // `dispose`; until they do, a repository-provided config's bootstrap
        // runs unattended at worktree creation. The check belongs here, at the
        // policy site, not inside `PhaseExecutor`.
        //
        // `PhaseExecutor.run` blocks its thread for as long as bootstrap takes,
        // so it must not run on the actor.
        let outcome: PhaseExecutor.Outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: PhaseExecutor.run(
                    phase: .bootstrap,
                    config: config,
                    binary: binary,
                    workstreamID: workstreamID,
                    workingDirectory: worktreePath,
                    timeout: ProcessRunner.Timeout.install
                ))
            }
        }

        switch outcome {
        case .succeeded:
            await updateState(for: workstreamID, to: .completed)
            logger.info("Bootstrap completed for \(worktreePath, privacy: .public)")
        case .skipped:
            await note(
                for: workstreamID,
                NSLocalizedString("This project declares no bootstrap processes, so nothing ran.", comment: "")
            )
        case let .failed(detail):
            let message = String(format: NSLocalizedString("Bootstrap failed: %@", comment: ""), detail)
            await updateState(for: workstreamID, to: .failed(message))
            logger.warning("Bootstrap failed for \(worktreePath, privacy: .public): \(detail, privacy: .public)")
        }
    }

    /// Finish having run nothing, saying why.
    private func note(for workstreamID: UUID, _ message: String) async {
        await updateState(for: workstreamID, to: .completedWithNote(message))
        logger.info("No bootstrap for \(workstreamID, privacy: .public): \(message, privacy: .public)")
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

    /// Run bootstrap on a worktree that was already created externally.
    /// Use this when the worktree was created by upstream GitOperations
    /// and only the project's own setup still has to run.
    func setupExistingWorktree(
        workstreamID: UUID,
        projectPath: String,
        worktreePath: String
    ) async {
        await updateState(for: workstreamID, to: .inProgress(step: "Setting up workspace", progress: 0.2))
        await runBackgroundSetup(
            workstreamID: workstreamID,
            projectPath: projectPath,
            worktreePath: worktreePath
        )
    }

    /// Log a pointed warning when a project still keeps `.env` files at its root
    /// but has no seed directory. Before the seed model those files were found by
    /// a recursive scan and copied automatically; now they are simply not copied,
    /// and without this the only symptom is a worktree that quietly has no env.
    private func warnIfProjectHasUnseededEnvFiles(projectPath: String, seedDirectory: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projectPath)) ?? []
        let envFiles = names.filter { $0.hasPrefix(".env") }
        guard !envFiles.isEmpty else { return }
        logger.warning("""
        Project \(projectPath, privacy: .public) has env file(s) \
        \(envFiles.joined(separator: ", "), privacy: .public) but no seed directory at \
        \(seedDirectory, privacy: .public). New worktrees will not receive them — move them into \
        the seed directory, or set "seed" in .atelier.json.
        """)
    }

    /// Remove tracked state for a workstream (cleanup after archiving).
    func clearState(for workstreamID: UUID) {
        states.removeValue(forKey: workstreamID)
    }
}
