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

        /// Workstreams whose run is sealed but whose teardown has not returned.
        ///
        /// **`isLive` has to stay true across this window, and the reason is a
        /// socket, not a nicety.** `seal` inserts into `sealedRunIDs`, so
        /// without this the Run button re-enables while `execute` is still
        /// awaiting `spawner.shutDown` — and that teardown is `down -u <socket>`
        /// at `Timeout.local` followed by unlinking the socket *file*. On the
        /// Stop path `down` has live checks to terminate, so it is slow enough
        /// for a second `start` — `PhaseEnvironment` (which shells out to git),
        /// its own pre-spawn `down`, a shell spawn — to bind the same path
        /// first. The old `removeItem` then deletes the new run's socket from
        /// under its living server: every poll throws `.notRunning` so no rows
        /// and no logs ever appear, `PhaseExecutor` waits out its whole budget
        /// or calls it `.serverGone`, the loop's own teardown early-returns on
        /// the missing file, and `stopAllServers` enumerates socket *files* at
        /// quit so it cannot find it either — a suite left running against the
        /// worktree's ports until `Timeout.suite` kills it, while the tab says
        /// the run failed to start its checks.
        ///
        /// The cost is a Run button disabled for the length of the teardown
        /// after results are already on screen. That is the trade, and it is
        /// the cheap side of it. **Not** a second `shutDown` call: this type has
        /// exactly one, in `execute`, and the single-owner rule is what the
        /// `shouldStop` doc and three loop tests defend.
        private var tearingDown: Set<UUID> = []

        /// Fired once per finished run, on the main actor. The IPC layer's
        /// completion message hangs off this; nothing else may assume it is the
        /// only subscriber.
        ///
        /// Reserved, not dead: nothing on this branch sets it. Its consumer is
        /// the `VerificationControlling` adapter owned by the
        /// `verification-ipc-tools` branch, which is not merged — the tab reads
        /// `runs` directly and needs no callback.
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
            /// Names process-compose cannot start, however they were asked
            /// for. Separate from `unknownChecks` because "No such check: -n"
            /// is a lie when the YAML genuinely declares one — a user would
            /// grep, find it, and have nowhere to go.
            case unrunnableChecks([String])

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
                case let .unrunnableChecks(names):
                    String(format: NSLocalizedString(
                        "process-compose cannot start a check whose name begins with \"-\": %@. Rename it in process-compose.yaml.",
                        comment: "Verification: a declared check named like a flag, which cannot be run"
                    ), names.joined(separator: ", "))
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
        ///
        /// **That filter and "not declared" did not compose, and the flag-shaped
        /// guard below is half of closing it.** A check genuinely named `-n` is
        /// legal YAML, so it was declared, offered in the checklist, and passed
        /// this function — and then dropped by `PhaseRunner.command` on its way
        /// to the shell. One of several, it sealed `.notRun` for no stated
        /// reason. The *only* selection, the filtered list was empty,
        /// `selectedProcesses.isEmpty` became true, and `up -n verify` ran the
        /// **whole namespace** — the exact inversion of the user's selection,
        /// through a guard that exists for security.
        ///
        /// The other half is `runnableChecks`, which keeps such a name out of
        /// `declared` in the first place, so this guard only ever answers a
        /// caller that named one explicitly: a stale stored selection, or an
        /// agent through the IPC handler. Refusing rather than dropping is the
        /// point — the caller asked for something by name.
        static func resolveChecks(
            requested: [String], declared: [String]
        ) -> Result<[String], Failure> {
            // Before the unknown-name filter, so a declared `-n` is told what
            // is actually wrong with it rather than that it does not exist.
            let unrunnable = requested.filter(isFlagShaped)
            guard unrunnable.isEmpty else {
                return .failure(.unrunnableChecks(unrunnable))
            }
            // Filtered here too, so this function is self-sufficient rather
            // than relying on every caller having remembered to wrap its own
            // `declared` — the "guard the precondition at each call site" shape
            // `ProcessCompose.RunCommandPlan`'s note records being reopened
            // four times before the invariant moved to the consumer. The
            // parked `start_verification` handler is the next caller, and would
            // plausibly hand `declaredProcesses` straight through.
            let declared = runnableChecks(declared)
            guard !declared.isEmpty else { return .failure(.nothingDeclared) }
            guard !requested.isEmpty else { return .success(declared) }
            let unknown = requested.filter { !declared.contains($0) }
            guard unknown.isEmpty else {
                return .failure(.unknownChecks(unknown, valid: declared))
            }
            return .success(requested)
        }

        /// The declared checks a run may actually address, with the ones
        /// process-compose cannot start dropped.
        ///
        /// **One copy, called from both `start` and `verificationAvailability`.**
        /// The checklist offering a check the runner would silently drop is the
        /// disagreement this exists to prevent, and two independent filters
        /// would recreate it. `PhaseRunner.command` drops a trailing process
        /// name beginning with `-` before it reaches the shell — a load-bearing
        /// flag-injection guard shared with `execute`, and not the place to fix
        /// this — and process-compose could not start such a process by name
        /// anyway, so nothing runnable is withheld.
        nonisolated static func runnableChecks(_ declared: [String]) -> [String] {
            declared.filter { !isFlagShaped($0) }
        }

        /// Whether `PhaseRunner.command` would drop this name.
        ///
        /// Matches that filter exactly: a leading `-`, which is what
        /// process-compose's own argument parser would read as a flag.
        private nonisolated static func isFlagShaped(_ name: String) -> Bool {
            name.hasPrefix("-")
        }

        /// The run with this id, whichever workstream it belongs to.
        ///
        /// Reserved, not dead: nothing on this branch calls it in production.
        /// It exists for `check_verification`, whose handler lives on the
        /// unmerged `verification-ipc-tools` branch and is where the caller is
        /// confined to its own workstream — see `makeRunID` on why that scoping
        /// is not this type's. The tab looks runs up by workstream instead.
        func run(id: String) -> Verification.Run? {
            runs.values.first { $0.id == id }
        }

        /// Whether this workstream has a run that has not been sealed, **or one
        /// that is sealed and still tearing its control server down**.
        ///
        /// **The only correct answer to "is a run live here", and the reason it
        /// is exported.** `Run.isFinished` is not that answer: the run loop
        /// publishes each check's state as the poll sees it, so a run's rows are
        /// all terminal for the last stretch of its life — a Run button keyed on
        /// `isFinished` would re-enable mid-suite and let a second `up` rebind
        /// `<id>-verify.sock` under the first. Everything that gates on liveness
        /// — this type's own refusals, the tab's Run button, the IPC handler —
        /// reads this.
        ///
        /// The second clause is the same property one step later in the run's
        /// life: sealing is not the end of the socket's life, only of the
        /// result's, so a run that has been sealed still owns
        /// `<id>-verify.sock` until its teardown returns. See `tearingDown` for
        /// what a start admitted in that window does to the run that follows it.
        func isLive(_ workstreamID: UUID) -> Bool {
            if tearingDown.contains(workstreamID) {
                return true
            }
            guard let run = runs[workstreamID] else { return false }
            return !sealedRunIDs.contains(run.id)
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
            guard isLive(workstreamID) else { return }
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
                }
                // **No `else`, and its absence is the fix.** A check missing
                // from this read keeps whatever the live polls established,
                // because "the final read said nothing about it" and "the final
                // read failed" are the same value by the time they get here:
                // `execute` passes `await verifyProcesses(client:) ?? []`, so a
                // server that has gone away arrives as an empty list.
                //
                // It goes away routinely. `PhaseExecutor.PollResult.serverGone`
                // records that a project may shut itself down — `restart:
                // exit_on_failure` does exactly that, **even with
                // `--keep-project`** — which is a plausible thing for a verify
                // namespace to want. Writing `.notRun` here discarded the
                // `.failed(1)` the user had just watched arrive, and the
                // `exit_on_end` shape lost a whole passing suite the same way.
                //
                // The live rows are the last non-empty snapshot; nothing else
                // needs to be kept for this. A check that never reached a
                // terminal state is still `.pending` or `.running` at this
                // point, and the switch below is what turns those into
                // `.notRun` and `.stopped` — so a name the server genuinely
                // never reported still seals `.notRun`.
                // A sealed run is over — the teardown that ends its processes
                // is the next thing the run loop does — so a row still
                // reporting live work is relabelled whatever ended the run, not
                // only a Stop. **The other way here is the executor's own
                // deadline**: `PhaseExecutor.run` returns `.failed` with the
                // checks still executing, so persisting `.running` would claim a
                // check is running that was killed a line later, and would
                // leave a run whose rows never reach a terminal state at all.
                // `wasStopped` is what still tells a user Stop from a timeout,
                // at the level where that distinction is true — the run.
                switch sealed.state {
                case .running: sealed.state = .stopped
                case .pending: sealed.state = .notRun
                default: break
                }
                return sealed
            }
            run.wasStopped = stopped
            runs[workstreamID] = run
            sealedRunIDs.insert(runID)
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
            // `isLive`, not `Run.isFinished`: live rows make a run's checks
            // terminal before the run is over, and a start admitted in that
            // window would rebind `<id>-verify.sock` under the running one —
            // `PhaseExecutor.run` shuts the socket down at the top.
            if let live = runs[workstreamID], isLive(workstreamID) {
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

            // `declaredProcesses` returns nil when one of the loaded files could
            // not be read or decoded — never fold that into an empty list. Doing
            // so would report a malformed process-compose.yaml as "this project
            // declares no verify processes", the same message a project with
            // genuinely no verify checks gets, which is false and the only
            // diagnostic this path gives.
            //
            // nil is narrower than it looks, and deliberately so: a file with no
            // `processes:` key is skipped rather than making the whole config
            // unknown, because an override setting only `environment:` or
            // `version:` is legal process-compose and `namespacePresence` calls
            // such a config `.present`. This guard used to refuse an ordinary
            // base-plus-override pair outright.
            guard let declared = config.declaredProcesses(
                in: ProcessCompose.Phase.verify.namespace
            ) else {
                throw Failure.unavailable(NSLocalizedString(
                    "This project's process-compose files could not be parsed, so its verify checks are unknown.",
                    comment: ""
                ))
            }
            // Filtered here and in `verificationAvailability`, through the one
            // shared function, so the checks the checklist offers and the
            // checks a run can address are the same set — see `runnableChecks`.
            let resolved = try Self.resolveChecks(
                requested: checks, declared: Self.runnableChecks(declared)
            ).get()

            let runID = makeRunID()
            // Empty, and filled by `execute` before it spawns anything.
            // `diffFingerprint` spawns `git rev-parse`, `git diff --stat`, `git
            // ls-files` and batched `git hash-object`; this function is
            // synchronous on the main actor — for the reason its own refusals
            // are, a second Run press must find `runs[workstreamID]` already
            // written — so computing it here stalled the UI on four-plus serial
            // process spawns every time Run was pressed. The tab's own
            // `refreshStaleness` has always done this off the main actor.
            runs[workstreamID] = Verification.Run(
                id: runID, workstreamID: workstreamID, startedAt: Date(), stamp: "",
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
        /// The teardown is also the reason `isLive` stays true past `seal`:
        /// `tearingDown` is inserted before sealing and removed after
        /// `shutDown` returns, so nothing can be admitted onto this socket
        /// while it is still being released. That is bookkeeping only — it adds
        /// no second teardown.
        ///
        /// **This function performs no gate of its own.** It spawns
        /// repository-provided process-compose commands with captured output
        /// and no TTY, and the only thing standing between that and
        /// `PhasePolicy.plan` is that `start` is its sole production caller:
        /// `start` answers the four preconditions — integration enabled, a
        /// located config, a resolvable binary, approval of every
        /// repository-provided file — and hands the results here in a
        /// `SpawnRequest`. Any future caller, the parked IPC adapter included,
        /// **must enter through `start`**; calling this directly runs a
        /// repository's YAML unattended and ungated, which is exactly what that
        /// one gate exists to prevent.
        ///
        /// Internal rather than private so a test can drive it with a seeded run
        /// and a stub spawner; `start` is its only production caller.
        func execute(_ request: SpawnRequest, runID: String) async {
            let workstreamID = request.workstreamID
            let client = spawner.controlClient(for: request)
            let state = RunLoopState()

            // The staleness baseline, taken here rather than in `start`: it is
            // four-plus serial git spawns and `start` is synchronous on the
            // main actor. Awaited — not fired and forgotten — for two reasons:
            // it lands before the spawn, so a check that writes to the tree
            // cannot be folded into the baseline it will be measured against;
            // and it lands before `seal`, so the persisted run carries the
            // stamp rather than racing it. Milliseconds after the press, which
            // is still "the moment the run started" for staleness.
            let stamp = await Self.captureStamp(
                worktreePath: request.worktreePath, projectDirectory: request.projectDirectory
            )
            if runs[workstreamID]?.id == runID {
                runs[workstreamID]?.stamp = stamp
            }

            // The spawn blocks a background thread for the length of the suite,
            // so it runs as its own task and the loop below asks whether it has
            // finished rather than awaiting it. Awaiting it here instead would
            // mean no live rows at all.
            let spawned = Task { [spawner] in
                state.outcome = await spawner.run(request)
            }

            while state.outcome == nil, !shouldStop(state, workstreamID) {
                await refreshLiveRows(runID: runID, client: client, state: state)
                guard state.outcome == nil, !shouldStop(state, workstreamID) else { break }
                try? await Task.sleep(for: pollInterval)
            }

            let stopped = stopRequested.contains(workstreamID)
            // One final read, in the window the held-open server provides. On the
            // stop path the running checks are still `Running` here, which is
            // exactly what `seal` relabels as `.stopped` — the reason Stop does
            // not stop the processes itself.
            let entries = await verifyProcesses(client: client) ?? []
            apply(entries, runID: runID, state: state)
            await captureFailedOutput(from: entries, runID: runID, client: client)
            // Set on the stored run *before* `seal`, so `seal`'s own copy —
            // `var run = runs[workstreamID]` — carries it into both the
            // published run and `Verification.Store.save`. Only when the server was
            // never heard from about any check: a row a poll reported on
            // already explains itself — `.passed`, `.failed`, `.skipped`, or
            // still `.running` when the executor's own deadline ended the run —
            // and duplicating the same fact up here would misdescribe an
            // ordinary test failure, or a timeout, as the run failing to start. That matters beyond the obvious "a check
            // genuinely failed" case: process-compose reports a `Skipped`
            // check (one whose `depends_on` failed) with `exit_code: 1`, which
            // alone is enough to make `PhaseExecutor` call the whole namespace
            // `.failed` — and that must not read as the run breaking when the
            // row itself already says `.skipped`.
            //
            // **Asked of the rows, not of `entries`.** The test used to be
            // `entries.isEmpty`, which was the same question only while an
            // empty final read also meant empty rows. Now that `seal`
            // preserves what the live polls established, a namespace that shut
            // itself down after a failure — `restart: exit_on_failure`, see
            // `seal` — arrives here with an empty `entries` and a row that
            // says `.failed(1)`, and claiming "the run itself failed to start
            // its checks" over a suite that ran and failed is exactly the lie
            // being fixed. A spawn that never bound a socket still leaves
            // every row `.pending`, so it still gets its detail.
            if !Self.serverReportedAnyCheck(runs[workstreamID]?.checks ?? []),
               let outcome = state.outcome, let detail = Self.failureDetail(for: outcome)
            {
                runs[workstreamID]?.failureDetail = detail
            }
            // Before `seal`, because `seal` is what makes `isLive` false by
            // inserting into `sealedRunIDs` — and this workstream's socket is
            // still this run's until the teardown below returns. See
            // `tearingDown`. Still exactly one `shutDown` call, still this
            // loop's, and still after `seal`.
            tearingDown.insert(workstreamID)
            seal(runID: runID, from: entries, stopped: stopped)
            await spawner.shutDown(request)
            // Both cleared after the teardown rather than inside `seal`: a
            // `seal` that returns nil would otherwise leave `stopRequested`
            // set and the workstream's *next* run would break out of its poll
            // loop on its first pass. After, not before, because `isLive` is
            // true for the whole teardown, so `stop` can still be admitted
            // while it runs and must not leave a flag behind either. Nothing
            // reads `stopRequested` between here and the final snapshot above.
            stopRequested.remove(workstreamID)
            tearingDown.remove(workstreamID)

            // Only now, and only to log it: on the stop path the spawn is still
            // in flight until the teardown above ends its project, and leaving
            // the task unawaited would let it outlive the run it belongs to.
            await spawned.value
            if let outcome = state.outcome, outcome != .succeeded {
                logger.info("verify run \(runID, privacy: .public): \(String(describing: outcome), privacy: .public)")
            }
        }

        /// `Git.Operations.diffFingerprint`, off the main actor.
        ///
        /// The same hop `PhaseSpawner.run` uses, and for the same reason: this
        /// is `git rev-parse`, `git diff --stat`, `git ls-files` and batched
        /// `git hash-object`, which `VerificationTabView.refreshStaleness`
        /// already refuses to run on the actor.
        private static func captureStamp(
            worktreePath: String, projectDirectory: String
        ) async -> String {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Git.Operations.diffFingerprint(
                        worktreePath: worktreePath, projectPath: projectDirectory,
                        mode: "uncommitted"
                    ))
                }
            }
        }

        /// Whether the control server was ever heard from about any check.
        ///
        /// The question the `failureDetail` banner needs, and deliberately not
        /// "did any check finish": the banner's headline is *"the run itself
        /// failed to start its checks"*, so the only fact that falsifies it is
        /// a poll having reported on one. `.pending` is exactly "never seen" —
        /// `apply` leaves a name the server has not mentioned alone, and a run
        /// is seeded entirely `.pending`.
        ///
        /// **A narrower predicate gets the executor's own deadline wrong.**
        /// `PhaseExecutor.run` returns `.failed` with the checks still
        /// executing, so every row is `.running` when the gate is asked; a test
        /// for terminal states alone would fire the banner over a suite that
        /// ran for its whole timeout — the same lie this gate was changed to
        /// fix, pointed the other way.
        static func serverReportedAnyCheck(_ checks: [Verification.CheckResult]) -> Bool {
            checks.contains { $0.state != .pending }
        }

        /// What `Run.failureDetail` should say for a non-`.succeeded` outcome,
        /// or nil for `.succeeded`. `.failed` already carries the output that
        /// explains itself; `.skipped` — the namespace turned out to declare no
        /// processes after all — gets a sentence of its own, since there is no
        /// output to quote.
        private static func failureDetail(for outcome: ProcessCompose.PhaseExecutor.Outcome) -> String? {
            switch outcome {
            case .succeeded:
                nil
            case let .failed(detail):
                detail
            case .skipped:
                NSLocalizedString("This project's verify namespace declared no processes to run.", comment: "")
            }
        }

        /// Whether the loop should stop polling and seal a stopped run.
        ///
        /// **A Stop is not acted on until the control server has answered at
        /// least once**, and that condition is load-bearing rather than
        /// defensive. `PhaseExecutor.shutDown` returns immediately when the
        /// socket file is not there yet, so a Stop observed before the namespace
        /// binds would make the loop's teardown a no-op while the run was
        /// already sealed: `isLive` would report false with the suite genuinely
        /// running, a second `start` would be admitted, and that second run
        /// would poll and publish the *first* suite's rows until its own
        /// pre-spawn `shutDown` killed the first suite mid-flight. In the narrow
        /// case where the socket has just appeared it is worse — `down` against
        /// a half-started server, then the socket file unlinked, stranding a
        /// server even `stopAllServers` can no longer reach.
        ///
        /// The wait is bounded: the spawn either binds, or fails and returns
        /// through `pollToCompletion`'s `.serverGone` path, and the loop's other
        /// exit condition is exactly that.
        private func shouldStop(_ state: RunLoopState, _ workstreamID: UUID) -> Bool {
            state.sawServer && stopRequested.contains(workstreamID)
        }

        /// One live poll: read the namespace and publish what it says.
        private func refreshLiveRows(
            runID: String, client: ProcessCompose.Controlling, state: RunLoopState
        ) async {
            guard let entries = await verifyProcesses(client: client) else { return }
            state.sawServer = true
            apply(entries, runID: runID, state: state)
        }

        /// The `verify` namespace's rows, or **nil when the server did not
        /// answer at all** — which is a different fact from "answered with
        /// nothing", and the one `shouldStop` needs.
        ///
        /// Every failure is swallowed, because none of them is this loop's to
        /// report: before the server binds, every poll throws `.notRunning`, and
        /// after it goes away the run's own result is the report. Returning
        /// nothing rather than throwing is also what keeps the tail of `execute`
        /// free of a `return` that would skip the teardown.
        private func verifyProcesses(client: ProcessCompose.Controlling) async -> [ProcessCompose.ProcessEntry]? {
            do {
                return try await client.processes()
                    .filter { $0.namespace == ProcessCompose.Phase.verify.namespace }
            } catch ProcessCompose.Client.ClientError.notRunning {
                return nil
            } catch {
                logger.debug("verify poll failed: \(error.localizedDescription, privacy: .public)")
                return nil
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
                    // A warning, not a debug line: unlike the poll's swallowed
                    // `.notRunning`, this loss is permanent by design — the
                    // window is one-shot and the output stops existing a few
                    // lines below, so a failed check ends up with no explanation
                    // anywhere.
                    logger.warning(
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

            /// Whether the control server has answered a poll yet. What gates
            /// acting on a Stop; see `shouldStop`.
            var sawServer = false

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
