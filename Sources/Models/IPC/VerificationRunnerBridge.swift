// ABOUTME: Conforms Verification.Runner to IPC.VerificationControlling for the agent tools.
// ABOUTME: Owns the projection, the per-run completion routing, and the staleness read.

import Foundation

extension IPC {
    /// The adapter between the two halves of the Verification feature: the
    /// runner that executes a check suite, and the two MCP tools that let an
    /// agent drive one.
    ///
    /// It exists because neither side should know the other's types. The runner
    /// deals in `Verification.Run`, which carries a `Date`, a git fingerprint
    /// and a whole suite's captured output; the tools deal in
    /// `IPC.VerificationRunInfo`, which is bounded and describes seconds rather
    /// than instants. One mapping, in one place, is the whole job — plus two
    /// things that are not mapping and are the reason this is a type rather
    /// than a function.
    ///
    /// **It routes completions per run.** `Runner.onFinish` is a single slot
    /// that fires for *every* run the app performs, including the ones the user
    /// pressed Run for. An agent must only be told about the run it started, so
    /// this holds the callback `start_verification` was given, keyed by run id,
    /// and a run nobody asked about finishes silently.
    ///
    /// **It never calls `Runner.execute` directly.** `start` is the sole
    /// production entrance, and it is where `ProcessCompose.PhasePolicy.plan`
    /// runs — the one gate for repository-provided commands with no TTY. Its
    /// refusals are `LocalizedError`, and `IPC.Service` passes them to the agent
    /// verbatim rather than paraphrasing them.
    @MainActor
    final class VerificationRunnerBridge: VerificationControlling {
        private let runner: Verification.Runner
        /// Computes the worktree's current diff fingerprint. Injected so the
        /// staleness comparison is testable without a git repository — it is
        /// four-plus git spawns, and the production value is the same one
        /// `VerificationTabView` and `Runner.execute` use.
        private let currentStamp: @Sendable (_ worktreePath: String, _ projectDirectory: String) -> String

        /// Callbacks for runs an agent asked for, by run id.
        ///
        /// Entries are removed as they fire, and a run the user started never
        /// has one.
        private var completions: [String: @Sendable (VerificationRunInfo) -> Void] = [:]

        /// When each run this bridge saw finish did so.
        ///
        /// `Verification.Run` records `startedAt` and nothing else, so this is
        /// the only source of a run's *duration* — and it is deliberately not
        /// "now minus `startedAt`" computed at read time, which would have a
        /// finished run's duration grow every time an agent looked at it. A run
        /// restored from `Verification.Store` after a restart has no entry, and
        /// reports no duration rather than an invented one.
        private var finishedAt: [String: Date] = [:]

        init(
            runner: Verification.Runner,
            currentStamp: @escaping @Sendable (String, String) -> String = { worktreePath, projectDirectory in
                Git.Operations.diffFingerprint(
                    worktreePath: worktreePath, projectPath: projectDirectory, mode: "uncommitted"
                )
            }
        ) {
            self.runner = runner
            self.currentStamp = currentStamp
            runner.onFinish = { [weak self] run in
                self?.runFinished(run)
            }
        }

        // MARK: - VerificationControlling

        func startVerification(
            workstreamID: UUID,
            checks: [String],
            onFinish: @escaping @Sendable (VerificationRunInfo) -> Void
        ) async throws -> VerificationStart {
            let target = try WorkspaceActions.shared.verificationTarget(workstreamID: workstreamID)

            // Nothing may `await` between these two statements. `Runner.start`
            // hands off to a `Task`, so the earliest its completion can fire is
            // the next turn of this actor — but only while this stays one
            // synchronous stretch. An await in the middle would let a fast
            // failure fire `onFinish` before the callback was registered, and
            // the agent would wait forever for a notice that had already been
            // discarded.
            let started = try runner.start(
                workstreamID: workstreamID,
                projectName: target.projectName,
                workstreamName: target.workstreamName,
                worktreePath: target.worktreePath,
                projectDirectory: target.projectDirectory,
                checks: checks
            )
            register(runID: started.runID, onFinish: onFinish)

            return VerificationStart(runID: started.runID, started: started.started)
        }

        func verificationRun(id: String, in workstreamID: UUID) async -> VerificationRunInfo? {
            // In memory first: a live run is only there, and it is the one an
            // agent polls. The store holds the workstream's most recent run and
            // is how an id stays resolvable across a restart — but it is a
            // *stale copy* while a run is live, because it is written at seal.
            if let live = runner.run(id: id) {
                return await projection(of: live)
            }
            guard let stored = Verification.Store.latest(for: workstreamID), stored.id == id else {
                return nil
            }
            return await projection(of: stored)
        }

        // MARK: - Completion routing

        /// Registers the callback for a run an agent started.
        ///
        /// Internal rather than private so a test can drive the routing without
        /// a process-compose binary; `startVerification` is its only production
        /// caller.
        func register(runID: String, onFinish: @escaping @Sendable (VerificationRunInfo) -> Void) {
            completions[runID] = onFinish
        }

        private func runFinished(_ run: Verification.Run) {
            finishedAt[run.id] = Date()
            // Removed as it fires: `Runner.seal` promises once per run, and this
            // makes a second call inert on this side too. A run the user started
            // has no entry and finishes silently, which is the point of keying
            // this per run rather than subscribing wholesale.
            guard let completion = completions.removeValue(forKey: run.id) else { return }

            // The projection needs the staleness read, which is git work, so it
            // cannot happen inside this synchronous callback — `Runner.seal`
            // calls it on the main actor with a teardown still to run.
            Task { [weak self] in
                guard let self else { return }
                await completion(projection(of: run))
            }
        }

        // MARK: - Projection

        private func projection(of run: Verification.Run) async -> VerificationRunInfo {
            let now = Date()
            let finished = finishedAt[run.id]
            return await VerificationRunInfo(
                runID: run.id,
                workstreamID: run.workstreamID.uuidString,
                workstreamName: try? WorkspaceActions.shared
                    .verificationTarget(workstreamID: run.workstreamID).workstreamName,
                state: Self.state(of: run),
                startedSecondsAgo: Int(now.timeIntervalSince(run.startedAt)),
                durationSeconds: finished.map { $0.timeIntervalSince(run.startedAt) },
                checks: run.checks.map(Self.projection(of:)),
                isStale: isStale(run),
                failureDetail: run.failureDetail
            )
        }

        /// Whether this run's results still describe the worktree.
        ///
        /// **Four-plus git spawns, so it is skipped where it cannot say
        /// anything.** An empty stamp means the run's own baseline has not been
        /// captured yet — `Runner.start` leaves it empty and `Runner.execute`
        /// fills it milliseconds later — and there is then nothing to compare
        /// against, which is the same branch `verificationIsStale` takes.
        private func isStale(_ run: Verification.Run) async -> Bool {
            guard !run.stamp.isEmpty else { return false }
            guard let target = try? WorkspaceActions.shared.verificationTarget(workstreamID: run.workstreamID) else {
                // The workstream is gone. Its result cannot be checked against a
                // worktree that is not there, and `verificationIsStale` reads an
                // uncomputable fingerprint as a reason to distrust the result.
                return true
            }
            let compute = currentStamp
            let stamp = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: compute(target.worktreePath, target.projectDirectory))
                }
            }
            return verificationIsStale(run: run, currentStamp: stamp)
        }

        /// **Read from the run's own rows, never from `Runner.isLive`.**
        ///
        /// They answer different questions and the difference bites exactly
        /// here: `isLive` means "may a new run start on this workstream's
        /// socket", and it stays true through sealing and teardown — so the
        /// completion notice, which is built from inside `seal`, would report
        /// the run it is announcing as still running.
        private static func state(of run: Verification.Run) -> VerificationRunState {
            if run.wasStopped {
                return .stopped
            }
            return run.isFinished ? .finished : .running
        }

        private static func projection(of check: Verification.CheckResult) -> VerificationCheckInfo {
            let state: VerificationCheckState
            var exitCode: Int?
            switch check.state {
            case .notRun: state = .notRun
            case .pending: state = .pending
            case .running: state = .running
            case .passed: state = .passed
            case let .failed(code):
                state = .failed
                exitCode = code
            case .skipped: state = .skipped
            case .stopped: state = .stopped
            }
            return VerificationCheckInfo(
                name: check.name,
                state: state,
                exitCode: exitCode,
                durationSeconds: check.duration,
                outputTail: check.output,
                outputTruncated: check.outputTruncated
            )
        }
    }
}
