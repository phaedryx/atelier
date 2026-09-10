// ABOUTME: The app-level runner for the verify namespace, keyed by workstream.
// ABOUTME: One run per workstream at a time; one owner for the control server's teardown.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "verification")

extension Verification {
    /// Starts and tracks verification runs for every workstream.
    ///
    /// App-level rather than owned by the tab, for two reasons. A run an agent
    /// started through `start_verification` has to appear in the user's tab, and
    /// `<id>-verify.sock` admits exactly one server — so "one run per
    /// workstream" needs a single enforcement point rather than one in the tab
    /// and another in the IPC handler. `PhaseExecutor.run` calls `shutDown` at
    /// the top, so a second start would kill the first run mid-suite.
    @MainActor
    final class Runner: ObservableObject {
        @Published private(set) var runs: [UUID: Verification.Run] = [:]

        /// Issued ids, so "unique for the app's lifetime" is enforced rather
        /// than hoped for. Eight hex characters is short enough that a
        /// collision is a real if unlikely event, and a reissued id would make
        /// `run(id:)` answer about the wrong run.
        ///
        /// Unbounded deliberately: one entry per run for one app session is
        /// nothing, and a cap would reintroduce exactly the reuse it prevents.
        private var issuedRunIDs: Set<String> = []

        /// Runs that have been sealed. **This, and not `Run.isFinished`, is what
        /// "live" means to the runner**, and the difference is load-bearing:
        /// the run loop publishes each check's state as the poll sees it, so the
        /// moment the last check reports `Completed` the run's own
        /// `isFinished` is already true — while the spawn is still winding down
        /// and nothing has been sealed, persisted or reported. Keying liveness
        /// on that would make `seal` refuse the run it was called to seal, and
        /// would let a second `start` land on `<id>-verify.sock` while the first
        /// server is still there.
        ///
        /// Unbounded for the same reason `issuedRunIDs` is: one entry per run
        /// per session, and both are cleared by quitting.
        private var sealedRunIDs: Set<String> = []

        /// Whether a Stop was asked for, per workstream. Stop must not tear the
        /// server down itself — two teardowns racing on one socket is the
        /// hazard `shutDownWhenDone: false` exists to avoid — so it sets this
        /// and the run loop, the single owner, acts on it.
        private var stopRequested: Set<UUID> = []

        /// Fired once per finished run, on the main actor. The IPC layer's
        /// completion message hangs off this; nothing else may assume it is the
        /// only subscriber.
        var onFinish: ((Verification.Run) -> Void)?

        /// Everything one verify run needs from process-compose, resolved by
        /// `start` while every refusal is still available to it.
        ///
        /// A value rather than a pile of parameters because it crosses the spawn
        /// seam three times — spawn, control client, teardown — and all three
        /// have to be talking about the same socket.
        struct SpawnRequest: Sendable {
            let workstreamID: UUID
            let config: ProcessCompose.Config
            let binary: String
            let projectName: String
            let workstreamName: String
            let projectDirectory: String
            let worktreePath: String
            /// The resolved check names. Empty is never passed: `resolveChecks`
            /// turns "run everything" into the declared list, so the command
            /// always names what it starts.
            let checks: [String]

            var socketPath: String {
                ProcessCompose.PhaseRunner.socketPath(for: workstreamID, phase: .verify)
            }
        }

        /// The three things a run needs from a live process-compose, behind one
        /// seam so the run loop can be driven without a binary.
        ///
        /// One protocol rather than three, and modelled on
        /// `ProcessCompose.Controlling`: spawn, control client and teardown all
        /// address the same control server, and a stub has to be able to make
        /// them agree — that logs are readable *because* the spawn has not been
        /// torn down yet is the property under test.
        protocol Spawning: Sendable {
            /// Runs the `verify` namespace to completion and leaves its control
            /// server up. Returns when every process in the namespace has
            /// reached a terminal state, or the deadline passed.
            func run(_ request: SpawnRequest) async -> ProcessCompose.PhaseExecutor.Outcome

            /// A client for the control server `run` brings up.
            func controlClient(for request: SpawnRequest) -> ProcessCompose.Controlling

            /// Ends that control server. The run loop is its only caller.
            func shutDown(_ request: SpawnRequest) async
        }

        /// How many lines of a failed check's log are kept.
        ///
        /// Agreed with the IPC half rather than picked here: it measured
        /// `IPC.Store`'s 65,536-byte-per-message cap, which *throws* rather than
        /// truncating — so an oversized completion notice is lost silently while
        /// an agent waits for it — and sized its own caps around this number.
        /// Changing one side alone breaks the other.
        private static let logTailLines = 200

        /// Gap between live-row polls. Matches `ProcessCompose.TableModel`'s
        /// cadence, which the Execution tab already runs beside a terminal.
        private static let defaultPollInterval = Duration.seconds(1)

        private let spawner: Spawning
        private let pollInterval: Duration

        /// The spawner is injected for the same reason `TableModel`'s client is:
        /// the ordering this loop exists to guarantee — logs fetched before the
        /// server goes away, one teardown, after sealing — is not observable
        /// from outside a real run.
        ///
        /// `pollInterval` is a parameter only so the loop's several passes can
        /// be exercised in milliseconds; production always takes the default.
        init(
            spawner: Spawning = Verification.PhaseSpawner(),
            pollInterval: Duration = Runner.defaultPollInterval
        ) {
            self.spawner = spawner
            self.pollInterval = pollInterval
        }

        enum Failure: Error, Equatable, LocalizedError {
            case alreadyRunning(String)
            case nothingDeclared
            case unavailable(String)
            case unknownChecks([String], valid: [String])

            var errorDescription: String? {
                switch self {
                case let .alreadyRunning(id):
                    String(format: NSLocalizedString(
                        "Verification run %@ is already running in this workstream.", comment: ""
                    ), id)
                case .nothingDeclared:
                    NSLocalizedString("This project declares no verify processes.", comment: "")
                case let .unavailable(reason):
                    reason
                case let .unknownChecks(unknown, valid):
                    String(format: NSLocalizedString(
                        "No such check: %@. This project declares: %@.", comment: ""
                    ), unknown.joined(separator: ", "), valid.joined(separator: ", "))
                }
            }
        }

        /// Eight lowercase hex characters, never reissued.
        ///
        /// Length is about collisions and mistaken ids, not secrecy — every
        /// process here runs as the user, and even the IPC token is documented
        /// as not being a boundary against the agent. `run(id:)` below scans
        /// every workstream's runs unscoped; it is the IPC handler that is
        /// meant to confine a caller to its own workstream, not this type.
        func makeRunID() -> String {
            while true {
                let candidate = String(
                    UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        .prefix(8).lowercased()
                )
                if issuedRunIDs.insert(candidate).inserted {
                    return candidate
                }
            }
        }

        /// Which checks a request resolves to, or why it cannot.
        ///
        /// Empty means all, matching the process-selection convention — but an
        /// empty *declared* list is a refusal rather than a run of everything,
        /// because `up -n verify` on a namespace with no processes never exits.
        ///
        /// Unknown names are refused rather than dropped: `PhaseRunner.command`
        /// filters trailing names beginning with `-` as a flag-injection guard,
        /// so an unvalidated name does not fail loudly, it silently vanishes and
        /// the run comes back missing a check nobody declined.
        static func resolveChecks(
            requested: [String], declared: [String]
        ) -> Result<[String], Failure> {
            guard !declared.isEmpty else { return .failure(.nothingDeclared) }
            guard !requested.isEmpty else { return .success(declared) }
            let unknown = requested.filter { !declared.contains($0) }
            guard unknown.isEmpty else {
                return .failure(.unknownChecks(unknown, valid: declared))
            }
            return .success(requested)
        }

        func run(id: String) -> Verification.Run? {
            runs.values.first { $0.id == id }
        }

        /// Test seam: the in-flight refusal is otherwise only reachable by
        /// spawning a real process-compose.
        func seedInFlightForTesting(workstreamID: UUID, runID: String) {
            runs[workstreamID] = Verification.Run(
                id: runID, workstreamID: workstreamID, startedAt: Date(), stamp: "",
                checks: [.init(name: "x", state: .running, duration: nil, output: nil)],
                wasStopped: false
            )
        }

        /// Test seam: a pending run of named checks, as `start` would have left
        /// it just before the spawn. What makes `seal` and the run loop
        /// reachable without a config, a binary or a subprocess.
        func seedRunForTesting(workstreamID: UUID, runID: String, checks: [String]) {
            runs[workstreamID] = Verification.Run(
                id: runID, workstreamID: workstreamID, startedAt: Date(), stamp: "",
                checks: checks.map { .init(name: $0, state: .pending, duration: nil, output: nil) },
                wasStopped: false
            )
        }

        // MARK: - Stop

        /// Ask the live run in this workstream to stop.
        ///
        /// Sets a flag and does nothing else, deliberately. Calling
        /// `PhaseExecutor.shutDown` here would put two teardowns on one socket —
        /// this one and the run loop's — which is the hazard
        /// `shutDownWhenDone: false` exists to avoid. Nor does it stop the
        /// individual processes through the control API: a check killed that way
        /// reports `Completed` with a non-zero code and would seal as a failure
        /// the user caused on purpose. The loop takes a final snapshot with those
        /// rows still `Running`, seals them as `.stopped`, and *then* tears the
        /// server down, which is what ends the processes.
        func stop(workstreamID: UUID) {
            guard let live = runs[workstreamID], !sealedRunIDs.contains(live.id) else { return }
            stopRequested.insert(workstreamID)
        }

        // MARK: - Sealing

        /// Turn a final `processes()` read into the run's authoritative result.
        ///
        /// Sealed from `[ProcessEntry]` rather than from `PhaseExecutor`'s
        /// internal name/exit-code pairs, which carry no `status` and so cannot
        /// tell `Skipped`(exit 1) from a real failure.
        ///
        /// Returns nil for a run that has already been sealed — see
        /// `sealedRunIDs` for why that is not the same as an already-*finished*
        /// one — which is what makes `onFinish` fire exactly once when a Stop
        /// lands as the poll completes.
        ///
        /// Whatever the loop captured before teardown is preserved: only `state`
        /// is written here, so `output` and `duration` survive.
        @discardableResult
        func seal(
            runID: String,
            from entries: [ProcessCompose.ProcessEntry],
            stopped: Bool
        ) -> Verification.Run? {
            guard let workstreamID = runs.first(where: { $0.value.id == runID })?.key,
                  var run = runs[workstreamID], !sealedRunIDs.contains(runID)
            else { return nil }

            let byName = Dictionary(
                entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
            )
            run.checks = run.checks.map { check in
                var sealed = check
                if let entry = byName[check.name] {
                    sealed.state = .init(entry: entry)
                } else {
                    // A check the server never reported did not run. Not a
                    // failure: nothing failed.
                    sealed.state = .notRun
                }
                if stopped {
                    switch sealed.state {
                    case .running: sealed.state = .stopped
                    case .pending: sealed.state = .notRun
                    default: break
                    }
                }
                return sealed
            }
            run.wasStopped = stopped
            runs[workstreamID] = run
            sealedRunIDs.insert(runID)
            stopRequested.remove(workstreamID)
            Verification.Store.save(run)
            onFinish?(run)
            return run
        }

        // MARK: - Starting

        /// Start a run, or refuse before anything is spawned.
        ///
        /// - Parameters:
        ///   - projectName: for `ATELIER_PROJECT_NAME`. Required, with no
        ///     default, for the reason `PhaseExecutor.run`'s `environment` has
        ///     none: a caller that omitted it would run the project's own YAML
        ///     under an environment the same file's other namespaces all see.
        ///   - workstreamName: likewise, for `ATELIER_WORKSTREAM_NAME`.
        ///
        /// Returns as soon as the run is recorded; the work happens in the loop
        /// this hands off to, and its result arrives through `runs` and
        /// `onFinish`.
        func start(
            workstreamID: UUID,
            projectName: String,
            workstreamName: String,
            worktreePath: String,
            projectDirectory: String,
            checks: [String]
        ) throws -> (runID: String, started: [String]) {
            // Liveness is `sealedRunIDs`, not `Run.isFinished`: live rows make a
            // run's checks terminal before the run is over, and a start admitted
            // in that window would rebind `<id>-verify.sock` under the running
            // one — `PhaseExecutor.run` shuts the socket down at the top.
            if let live = runs[workstreamID], !sealedRunIDs.contains(live.id) {
                throw Failure.alreadyRunning(live.id)
            }

            // The one gate. Identical to bootstrap's and dispose's, and
            // deliberately the same copy: captured output means nobody is
            // watching a TTY, so the argument that leaves `execute` ungated
            // does not apply — to a user press or to an agent call.
            let plan = PhasePolicy.plan(
                phase: .verify,
                isEnabled: ProcessCompose.Settings.isEnabled,
                config: ProcessCompose.Config.locate(
                    worktree: worktreePath, projectDirectory: projectDirectory
                ),
                binary: ProcessCompose.Settings.resolveBinary(),
                isApproved: {
                    ScriptTrust.isApproved(
                        configFiles: $0.repositoryProvidedFiles, for: projectDirectory
                    )
                }
            )
            let config: ProcessCompose.Config
            let binary: String
            switch plan {
            case let .run(planConfig, planBinary):
                config = planConfig
                binary = planBinary
            case let .nothingToDo(reason):
                throw Failure.unavailable(reason)
            }

            // `declaredProcesses` returns nil when a file could not be parsed —
            // never fold that into an empty list. Doing so would report a
            // malformed process-compose.yaml as "this project declares no verify
            // processes", the same message a project with genuinely no verify
            // checks gets, which is false and the only diagnostic this path gives.
            guard let declared = config.declaredProcesses(
                in: ProcessCompose.Phase.verify.namespace
            ) else {
                throw Failure.unavailable(NSLocalizedString(
                    "This project's process-compose files could not be parsed, so its verify checks are unknown.",
                    comment: ""
                ))
            }
            let resolved = try Self.resolveChecks(requested: checks, declared: declared).get()

            let runID = makeRunID()
            let stamp = Git.Operations.diffFingerprint(
                worktreePath: worktreePath, projectPath: projectDirectory, mode: "uncommitted"
            )
            runs[workstreamID] = Verification.Run(
                id: runID, workstreamID: workstreamID, startedAt: Date(), stamp: stamp,
                checks: resolved.map {
                    .init(name: $0, state: .pending, duration: nil, output: nil)
                },
                wasStopped: false
            )
            let request = SpawnRequest(
                workstreamID: workstreamID,
                config: config,
                binary: binary,
                projectName: projectName,
                workstreamName: workstreamName,
                projectDirectory: projectDirectory,
                worktreePath: worktreePath,
                checks: resolved
            )
            Task { await execute(request, runID: runID) }
            return (runID, resolved)
        }

        // MARK: - The run loop

        /// Spawn the namespace, publish rows while it runs, then seal and tear
        /// the control server down — **in that order, and it is the invariant
        /// this whole type is shaped around.**
        ///
        /// Per-check output lives in the control server and nowhere else, and
        /// `shutDown` ends that server. So the window between the namespace
        /// finishing and the teardown — the window `shutDownWhenDone: false` and
        /// `--keep-project` exist to hold open — is the *only* chance to read a
        /// failed check's log. There is no later opportunity, for the tab or for
        /// an agent: after this function returns, the only output that exists
        /// anywhere is what it captured.
        ///
        /// `shutDown` is called exactly once, from here, after `seal` has
        /// returned. Not from `stop(workstreamID:)`, which would race this one
        /// on a single socket, and not from a `defer`, which on the stop path
        /// would run before the log fetch and leave `seal` nothing to record.
        /// Nothing between the poll loop and that call may `return`, which is
        /// why every failure in the tail is swallowed into a default rather than
        /// guarded against.
        ///
        /// Internal rather than private so a test can drive it with a seeded run
        /// and a stub spawner; `start` is its only production caller.
        func execute(_ request: SpawnRequest, runID: String) async {
            let workstreamID = request.workstreamID
            let client = spawner.controlClient(for: request)
            let state = RunLoopState()

            // The spawn blocks a background thread for the length of the suite,
            // so it runs as its own task and the loop below asks whether it has
            // finished rather than awaiting it. Awaiting it here instead would
            // mean no live rows at all.
            let spawned = Task { [spawner] in
                state.outcome = await spawner.run(request)
            }

            while state.outcome == nil, !stopRequested.contains(workstreamID) {
                await refreshLiveRows(runID: runID, client: client, state: state)
                guard state.outcome == nil, !stopRequested.contains(workstreamID) else { break }
                try? await Task.sleep(for: pollInterval)
            }

            let stopped = stopRequested.contains(workstreamID)
            // One final read, in the window the held-open server provides. On the
            // stop path the running checks are still `Running` here, which is
            // exactly what `seal` relabels as `.stopped` — the reason Stop does
            // not stop the processes itself.
            let entries = await verifyProcesses(client: client)
            apply(entries, runID: runID, state: state)
            await captureFailedOutput(from: entries, runID: runID, client: client)
            seal(runID: runID, from: entries, stopped: stopped)
            await spawner.shutDown(request)

            // Only now, and only to log it: on the stop path the spawn is still
            // in flight until the teardown above ends its project, and leaving
            // the task unawaited would let it outlive the run it belongs to.
            await spawned.value
            if let outcome = state.outcome, outcome != .succeeded {
                logger.info("verify run \(runID, privacy: .public): \(String(describing: outcome), privacy: .public)")
            }
        }

        /// One live poll: read the namespace and publish what it says.
        private func refreshLiveRows(
            runID: String, client: ProcessCompose.Controlling, state: RunLoopState
        ) async {
            let entries = await verifyProcesses(client: client)
            apply(entries, runID: runID, state: state)
        }

        /// The `verify` namespace's rows, or none.
        ///
        /// Every failure is swallowed, because none of them is this loop's to
        /// report: before the server binds, every poll throws `.notRunning`, and
        /// after it goes away the run's own result is the report. Returning
        /// nothing rather than throwing is also what keeps the tail of `execute`
        /// free of a `return` that would skip the teardown.
        private func verifyProcesses(client: ProcessCompose.Controlling) async -> [ProcessCompose.ProcessEntry] {
            do {
                return try await client.processes()
                    .filter { $0.namespace == ProcessCompose.Phase.verify.namespace }
            } catch ProcessCompose.Client.ClientError.notRunning {
                return []
            } catch {
                logger.debug("verify poll failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }

        /// Write the poll's answer onto the run's rows.
        ///
        /// A check with no entry is left alone rather than reset: the server
        /// reports a process once it exists, and a name it has not mentioned yet
        /// is still pending. `seal` is where a name never reported becomes
        /// `.notRun`.
        private func apply(
            _ entries: [ProcessCompose.ProcessEntry], runID: String, state: RunLoopState
        ) {
            guard let workstreamID = runs.first(where: { $0.value.id == runID })?.key,
                  var run = runs[workstreamID], !sealedRunIDs.contains(runID)
            else { return }

            let byName = Dictionary(
                entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
            )
            run.checks = run.checks.map { check in
                guard let entry = byName[check.name] else { return check }
                var updated = check
                updated.state = .init(entry: entry)
                state.recordTiming(for: &updated)
                return updated
            }
            if runs[workstreamID] != run {
                runs[workstreamID] = run
            }
        }

        /// Fetch and attach the tail of every failed check's log.
        ///
        /// **Failed checks only.** A skipped check never ran, and a passing one
        /// would put a 200-line tail per check into UserDefaults through
        /// `Verification.Store` for output nobody asked for. The consequence is
        /// deliberate and worth stating plainly: a passing check's warnings are
        /// not kept, and re-running that check is the only way to see them.
        private func captureFailedOutput(
            from entries: [ProcessCompose.ProcessEntry],
            runID: String,
            client: ProcessCompose.Controlling
        ) async {
            guard let workstreamID = runs.first(where: { $0.value.id == runID })?.key,
                  let run = runs[workstreamID], !sealedRunIDs.contains(runID)
            else { return }

            let ours = Set(run.checks.map(\.name))
            let failed = entries.filter { entry in
                guard ours.contains(entry.name) else { return false }
                if case .failed = Verification.CheckResult.State(entry: entry) {
                    return true
                }
                return false
            }.map(\.name)
            guard !failed.isEmpty else { return }

            var captured: [String: (text: String, truncated: Bool)] = [:]
            for name in failed {
                do {
                    let lines = try await client.logs(name: name, tail: Self.logTailLines)
                    // At the limit the honest answer is "possibly truncated": a
                    // tail cannot reveal whether anything preceded it. The flag
                    // means there was more *at capture time*, never that a fuller
                    // copy can be fetched — by the time anything reads it the
                    // server that held the log is gone.
                    captured[name] = (
                        lines.joined(separator: "\n"), lines.count >= Self.logTailLines
                    )
                } catch {
                    logger.debug(
                        "verify logs for \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            guard !captured.isEmpty, var updated = runs[workstreamID], updated.id == runID else { return }
            updated.checks = updated.checks.map { check in
                guard let output = captured[check.name] else { return check }
                var withOutput = check
                withOutput.output = output.text
                withOutput.outputTruncated = output.truncated
                return withOutput
            }
            runs[workstreamID] = updated
        }

        /// One run loop's own scratch state.
        ///
        /// Main-actor isolated and local to a run, so nothing here outlives the
        /// loop or has to be cleaned up after it.
        @MainActor
        final class RunLoopState {
            /// Set once the spawn returns. The loop reads it without awaiting,
            /// which is what lets one linear function both publish live rows and
            /// own the teardown.
            var outcome: ProcessCompose.PhaseExecutor.Outcome?

            /// When each check was first *seen* running.
            private var startedAt: [String: Date] = [:]

            /// Time a check from the poll that first saw it running to the poll
            /// that first saw it end.
            ///
            /// Sampled at the poll interval, so it is approximate by up to that
            /// much either way, and nil where the transition was never seen — a
            /// check that starts and finishes between two polls has no duration
            /// rather than a wrong one. A stopped check has none either: it never
            /// completed, and inventing a number for how long it got before the
            /// user gave up would read as a runtime.
            func recordTiming(for check: inout Verification.CheckResult) {
                switch check.state {
                case .running:
                    if startedAt[check.name] == nil {
                        startedAt[check.name] = Date()
                    }
                case .passed, .failed:
                    if let began = startedAt[check.name], check.duration == nil {
                        check.duration = Date().timeIntervalSince(began)
                    }
                case .notRun, .pending, .skipped, .stopped:
                    break
                }
            }
        }
    }

    /// The real spawn seam: one `verify` namespace, run headless with its control
    /// server held open.
    ///
    /// A struct with no state, because the socket, the config and the binary all
    /// come from the request — one run's server is addressed the same way by all
    /// three of these calls.
    struct PhaseSpawner: Verification.Runner.Spawning {
        func run(_ request: Verification.Runner.SpawnRequest) async -> ProcessCompose.PhaseExecutor.Outcome {
            await withCheckedContinuation { continuation in
                // `PhaseExecutor.run` blocks its thread for as long as the suite
                // takes, so it never runs on the actor. The environment is
                // assembled in the same hop for the reason `AsyncSetupService`
                // does it there: it reads `ports.yaml` and asks git for the
                // default branch.
                DispatchQueue.global(qos: .userInitiated).async {
                    let environment = ProcessCompose.PhaseEnvironment.variables(
                        workstreamID: request.workstreamID,
                        projectName: request.projectName,
                        workstreamName: request.workstreamName,
                        projectDirectory: request.projectDirectory,
                        worktreePath: request.worktreePath,
                        defaultBranch: Git.Operations.defaultBranch(at: request.projectDirectory)
                    )
                    continuation.resume(returning: ProcessCompose.PhaseExecutor.run(
                        phase: .verify,
                        config: request.config,
                        binary: request.binary,
                        workstreamID: request.workstreamID,
                        workingDirectory: request.worktreePath,
                        environment: environment,
                        timeout: ProcessRunner.Timeout.suite,
                        selectedProcesses: request.checks,
                        // False, so the control server outlives the namespace and
                        // the run loop can read final states and per-check logs
                        // from it. The loop is then the one caller of `shutDown`.
                        shutDownWhenDone: false
                    ))
                }
            }
        }

        func controlClient(for request: Verification.Runner.SpawnRequest) -> ProcessCompose.Controlling {
            ProcessCompose.Client(socketPath: request.socketPath)
        }

        func shutDown(_ request: Verification.Runner.SpawnRequest) async {
            await withCheckedContinuation { continuation in
                // `down` spawns a child under `Timeout.local`; off the actor for
                // the same reason the spawn is.
                DispatchQueue.global(qos: .utility).async {
                    ProcessCompose.PhaseExecutor.shutDown(
                        binary: request.binary,
                        socketPath: request.socketPath,
                        workingDirectory: request.worktreePath
                    )
                    continuation.resume()
                }
            }
        }
    }
}
