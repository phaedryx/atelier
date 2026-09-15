// ABOUTME: Conforms Verification.Runner to IPC.VerificationControlling for the agent tools.
// ABOUTME: Owns the projection, the per-run completion routing, and the staleness read.

import Foundation

extension IPC {
    /// The adapter between the two halves of the Verification feature: the
    /// runner that executes a check suite, and the two MCP tools that let an
    /// agent drive one.
    ///
    /// It exists because neither side should know the other's types. The runner
    /// deals in `Verification.Run`, which carries a `Date` and a git fingerprint;
    /// the tools deal in `IPC.VerificationRunInfo`, which describes seconds rather
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
    /// **`Runner.start` is the sole production entrance.** Its refusals are
    /// `LocalizedError`, and `IPC.Service` passes them to the agent verbatim
    /// rather than paraphrasing them. There is no approval gate to re-check here
    /// or anywhere: `verification.yaml` lives in the project directory, outside
    /// every work tree, so it cannot have arrived with the repository — the same
    /// location rule that leaves a project-directory process-compose config
    /// unasked-about.
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
        /// finished run's duration grow every time an agent looked at it. Runs do
        /// not survive a relaunch, so every run this can be asked about has an entry
        /// once it has finished.
        private var finishedAt: [String: Date] = [:]

        /// Which surface asked for each run, by run id. A run the user pressed has no
        /// entry; its notices carry a nil surface and the service addresses the Coding
        /// Agent tab.
        ///
        /// Dropped when the *run* finishes, not when a check does — a run has many checks
        /// and the last one must still be addressed.
        private var requesters: [String: String] = [:]

        /// The one per-check handler. See `observeCheckCompletions`.
        private var checkObserver: (@MainActor @Sendable (VerificationCheckNotice) -> Void)?

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
            runner.onCheckFinished = { [weak self] workstreamID, record, _ in
                self?.checkFinished(workstreamID: workstreamID, record: record)
            }
        }

        // MARK: - VerificationControlling

        func startVerification(
            workstreamID: UUID,
            checks: [String],
            requesterSurfaceID: String?,
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
                defaultBranch: target.defaultBranch,
                checks: checks.isEmpty ? nil : checks
            )
            register(runID: started.id, onFinish: onFinish)
            register(runID: started.id, requesterSurfaceID: requesterSurfaceID)

            return VerificationStart(runID: started.id, started: started.checks.map(\.name))
        }

        func verificationChecks(in workstreamID: UUID) async throws -> VerificationChecksInfo {
            // The same resolution a start does, and for the same reason: the
            // config is keyed by the *project* directory, which only
            // `WorkspaceActions` can reach from a workstream id.
            let target = try WorkspaceActions.shared.verificationTarget(workstreamID: workstreamID)
            let load = Verification.Config.load(projectDirectory: target.projectDirectory)
            return VerificationChecksInfo(
                configPath: load.config?.path,
                checks: load.config?.checks.map {
                    VerificationCheckDeclaration(name: $0.name, command: $0.command, shell: $0.shell)
                } ?? [],
                // Not paraphrased. `Load` is the availability decision, and this
                // is the same sentence the Verification tab shows the user, so
                // an agent and its human are never told different things about
                // the same file.
                unavailableReason: load.unavailableReason
            )
        }

        func observeCheckCompletions(_ handler: @escaping @MainActor @Sendable (VerificationCheckNotice) -> Void) {
            checkObserver = handler
        }

        func verificationRun(id: String, in workstreamID: UUID) async -> VerificationRunInfo? {
            // Every run of this session resolves, and none of an earlier one:
            // runs live in the runner's memory and are not persisted, because
            // what they used to carry across a restart — a check's output — now
            // lives in a terminal surface that does not survive one either.
            guard let run = runner.run(id: id), run.workstreamID == workstreamID else {
                return nil
            }
            return await projection(of: run)
        }

        // MARK: - Completion routing

        /// Registers the callback for a run an agent started.
        ///
        /// Internal rather than private so a test can drive the routing without
        /// starting a real check; `startVerification` is its only production
        /// caller.
        func register(runID: String, onFinish: @escaping @Sendable (VerificationRunInfo) -> Void) {
            completions[runID] = onFinish
        }

        /// Registers which surface, if any, asked for a run.
        ///
        /// Internal rather than private so a test can drive the routing without
        /// starting a real check; `startVerification` is its only production caller.
        func register(runID: String, requesterSurfaceID: String?) {
            requesters[runID] = requesterSurfaceID
        }

        private func checkFinished(workstreamID: UUID, record: Verification.CheckRecord) {
            guard let observer = checkObserver else { return }
            observer(
                VerificationCheckNotice(
                    runID: record.runID,
                    workstreamID: workstreamID.uuidString,
                    requesterSurfaceID: requesters[record.runID],
                    check: Self.projection(of: record)
                )
            )
        }

        private func runFinished(_ run: Verification.Run) {
            finishedAt[run.id] = Date()
            // Dropped here, before the early return below: a run the user started has
            // no completion entry and takes that return immediately, and a requester
            // entry dropped after it would leak forever for every such run.
            requesters.removeValue(forKey: run.id)
            // Removed as it fires: the runner promises once per run, and this
            // makes a second call inert on this side too. A run the user started
            // has no entry and finishes silently, which is the point of keying
            // this per run rather than subscribing wholesale.
            guard let completion = completions.removeValue(forKey: run.id) else { return }

            // The projection needs the staleness read, which is git work, so it
            // cannot happen inside this synchronous callback — the runner calls
            // it on the main actor from its completion pass.
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
                isStale: isStale(run)
            )
        }

        /// Whether this run's results still describe the worktree.
        ///
        /// **Four-plus git spawns, so it is skipped where it cannot say
        /// anything.** An empty stamp means the run's baseline was not captured,
        /// and there is then nothing to compare against — the same branch
        /// `verificationIsStale` takes.
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
        /// They answer different questions: `isLive` means "is anything running
        /// in this workstream", which stays true while another check keeps going
        /// — so a notice about the run that just finished would report it as
        /// still running whenever a sibling check outlived it.
        private static func state(of run: Verification.Run) -> VerificationRunState {
            if run.wasStopped {
                return .stopped
            }
            return run.isFinished ? .finished : .running
        }

        /// The same mapping `projection(of: CheckResult)` performs, over a record.
        ///
        /// Two overloads rather than a conversion, because the two inputs are genuinely
        /// different things — a row within one run, and one check's latest result — and
        /// funnelling one through the other would invent a `CheckResult` with no run to
        /// belong to.
        private static func projection(of record: Verification.CheckRecord) -> VerificationCheckInfo {
            let state: VerificationCheckState
            var exitCode: Int?
            switch record.state {
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
                name: record.name,
                state: state,
                exitCode: exitCode,
                durationSeconds: record.duration
            )
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
                durationSeconds: check.duration
            )
        }
    }
}
