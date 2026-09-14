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

        /// Every workstream's per-check results, as the tab renders them.
        ///
        /// **The tab reads this; it is not a subscriber to `onCheckFinished`.** A callback
        /// into the view would be a second thing to keep in step with `CheckStore`, and
        /// `runs` already establishes that the view observes this object rather than being
        /// called by it.
        @Published private(set) var checkRecords: [UUID: [String: Verification.CheckRecord]] = [:]

        /// Fired once per *check* that reaches a terminal state, on the main actor.
        ///
        /// **One slot, and `IPC.VerificationRunnerBridge` holds it** — the same constraint
        /// `onFinish` carries and for the same reason: constructing a second subscriber
        /// silently unsubscribes the first, so `ContentView` builds exactly one bridge.
        /// Fires for the user's own presses too; routing a notice to the right inbox is the
        /// bridge's job, not this one's.
        var onCheckFinished: ((UUID, Verification.CheckRecord) -> Void)?

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
        /// **One slot, and `IPC.VerificationRunnerBridge` holds it** — which is
        /// why that type routes completions per run id rather than assuming
        /// every finish is one an agent asked about: this fires for the user's
        /// own presses too. Constructing a second bridge silently unsubscribes
        /// the first, so `ContentView` builds exactly one. The tab is not a
        /// subscriber; it reads `runs` directly and needs no callback.
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
        ///
        /// Not private: `VerificationTabView`'s live log window asks for the
        /// same number of lines through `liveLog`, so what a user watches
        /// scroll past while a check runs is exactly what `captureFailedOutput`
        /// keeps if it fails. Two numbers would make the window silently
        /// shorten or lengthen at the moment the run sealed.
        static let logTailLines = 200

        /// Gap between live-row polls. Matches `ProcessCompose.TableModel`'s
        /// cadence, which the Execution tab already runs beside a terminal.
        private static let defaultPollInterval = Duration.seconds(1)

        /// The live run's control client, per workstream. Set at the top of
        /// `execute` and cleared only after `spawner.shutDown` has returned.
        ///
        /// **This is a second *reader* of the one-shot log window, and it owns
        /// none of it.** The window — the stretch between the namespace
        /// finishing and the teardown, held open by `shutDownWhenDone: false`
        /// — exists so `captureFailedOutput` can keep a failed check's tail
        /// before the output stops existing. Nothing here changes that: this
        /// map never calls `shutDown`, never touches `sealedRunIDs`,
        /// `tearingDown` or `stopRequested`, and grants no way to reach
        /// `execute`. The teardown still has exactly one owner, and it is still
        /// the run loop.
        ///
        /// Cleared beside `stopRequested` and `tearingDown`, after the teardown,
        /// for the same reason they are: `isLive` is true for the whole
        /// teardown, so a reader may still arrive during it and must get the
        /// client whose server is going away — which answers `.notRunning` and
        /// becomes nil — rather than nothing at all, which would be
        /// indistinguishable from a run that was never live.
        private var liveClients: [UUID: ProcessCompose.Controlling] = [:]

        private let spawner: Spawning
        private let pollInterval: Duration

        /// The staleness baseline, as a function, so `captureStamp` can be held
        /// to running it off the main actor.
        ///
        /// Injected the same way `IPC.VerificationRunnerBridge` injects its own
        /// `currentStamp`, and for a reason that is not about stubbing out git:
        /// a fingerprint computed on the actor and one computed off it return
        /// the same string, so *where* it ran is only observable from inside.
        private let fingerprint: @Sendable (_ worktreePath: String, _ projectDirectory: String) -> String

        /// The spawner is injected for the same reason `TableModel`'s client is:
        /// the ordering this loop exists to guarantee — logs fetched before the
        /// server goes away, one teardown, after sealing — is not observable
        /// from outside a real run.
        ///
        /// `pollInterval` is a parameter only so the loop's several passes can
        /// be exercised in milliseconds; production always takes the default.
        init(
            spawner: Spawning = Verification.PhaseSpawner(),
            pollInterval: Duration = Runner.defaultPollInterval,
            fingerprint: @escaping @Sendable (String, String) -> String = { worktreePath, projectDirectory in
                Git.Operations.diffFingerprint(
                    worktreePath: worktreePath, projectPath: projectDirectory, mode: "uncommitted"
                )
            }
        ) {
            self.spawner = spawner
            self.pollInterval = pollInterval
            self.fingerprint = fingerprint
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
                    // The shared copy, not a second spelling of it — see
                    // `unrunnableChecksMessage`.
                    Runner.unrunnableChecksMessage(names)
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
                let candidate = runIDCandidate()
                if issuedRunIDs.insert(candidate).inserted {
                    return candidate
                }
            }
        }

        /// Where a candidate id comes from, before `issuedRunIDs` has had its
        /// say. A test seam, the same kind as `seedRunForTesting`.
        ///
        /// The redraw above is otherwise unreachable: eight hex characters is
        /// 2^32 candidates, so a natural collision does not happen inside a
        /// test, and drawing ids until two match tests `UUID`'s randomness
        /// rather than this type's promise not to reissue one. Driving the
        /// source is the only way the dedup set is observable.
        ///
        /// Not `@Sendable`: a test's generator is a queue it mutates, and this
        /// is only ever called on the actor.
        var runIDCandidate: () -> String = {
            String(
                UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    .prefix(8).lowercased()
            )
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
            // four times before the invariant moved to the consumer.
            // `start_verification` reaches this through `start`, which does
            // wrap its own `declared` — but the guarantee must not rest on
            // every caller having remembered to, which is the shape that was
            // reopened four times.
            let runnable = runnableChecks(declared)
            // **"Declares nothing" and "declares nothing runnable" are not the
            // same refusal.** A namespace whose every process is named like a
            // flag declares checks — they are in the YAML, the user can grep
            // them — so reporting "declares no verify processes" sends them
            // looking for a namespace they already wrote. The filter is
            // unchanged and nothing flag-shaped is ever started; only the
            // wording of the refusal distinguishes the two cases.
            guard !runnable.isEmpty else {
                return .failure(declared.isEmpty ? .nothingDeclared : .unrunnableChecks(declared))
            }
            guard !requested.isEmpty else { return .success(runnable) }
            let unknown = requested.filter { !runnable.contains($0) }
            guard unknown.isEmpty else {
                return .failure(.unknownChecks(unknown, valid: runnable))
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

        /// The one copy of the wording for declared names process-compose
        /// cannot start.
        ///
        /// Two paths reach this situation and they must say the same thing.
        /// `Failure.unrunnableChecks` reports it for a name a *request* asked
        /// for; `verificationUnavailableReason` reports it for a project whose
        /// `verify` namespace declares nothing else, where there is no request
        /// to refuse — the checklist is empty and Run is disabled, so that tab
        /// used to claim "This project declares no verify checks", which is
        /// untrue and leaves the user nothing to act on. A second sentence
        /// written beside this one would drift from it; this is the one the
        /// request path already got right.
        nonisolated static func unrunnableChecksMessage(_ names: [String]) -> String {
            String(format: NSLocalizedString(
                "process-compose cannot start a check whose name begins with \"-\": %@. Rename it in process-compose.yaml.",
                comment: "Verification: a declared check named like a flag, which cannot be run"
            ), names.joined(separator: ", "))
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
        /// **Unscoped, and its caller is what scopes it.**
        /// `IPC.VerificationRunnerBridge.verificationRun(id:in:)` is that
        /// caller — it is where `check_verification` is confined to its own
        /// workstream, and see `makeRunID` on why that confinement is not this
        /// type's job. The tab never comes through here; it looks runs up by
        /// workstream.
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

        /// The tail of one live check's log, or nil when there is none to read.
        ///
        /// **Read-only, and deliberately the weakest possible handle on the log
        /// window.** Per-check output lives in the control server and nowhere
        /// else, and `execute` is the one thing that ends that server; this
        /// borrows the same client for the length of a single `GET` and can
        /// neither extend the window nor close it. Every failure — no live run,
        /// a server that has already gone, a check the run does not own — is one
        /// nil, because a caller can do nothing different with any of them: the
        /// honest answer in all three cases is "there is no live output for
        /// this", and the run's own sealed result is the report on why.
        ///
        /// The check is scoped to this workstream's current run, for the reason
        /// `check_verification`'s scope check exists rather than as a security
        /// boundary — every process here runs as the user. A name that is not
        /// this run's would otherwise fetch whatever the control server happens
        /// to hold under it, which for a `verify` socket is another namespace's
        /// process.
        ///
        /// - Returns: the last `tail` lines, newest last; nil when nothing can
        ///   be read. An empty array means the check has genuinely produced no
        ///   output yet, which is a different fact and is rendered as one.
        func liveLog(workstreamID: UUID, check: String, tail: Int = logTailLines) async -> [String]? {
            guard isLive(workstreamID), let client = liveClients[workstreamID],
                  runs[workstreamID]?.checks.contains(where: { $0.name == check }) == true
            else { return nil }
            do {
                return try await client.logs(name: check, tail: tail)
            } catch {
                // Swallowed for the reason `verifyProcesses` swallows its own:
                // before the namespace binds every read throws `.notRunning`,
                // and after the teardown every read throws again. Neither is
                // this function's to report, and a live view polling once a
                // second would otherwise log at 1Hz for the whole run.
                return nil
            }
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

        /// How long `stopAndWait` waits before reporting that the run is still
        /// live.
        ///
        /// `ProcessRunner.Timeout.userCommand`, and it has to be at least that
        /// tier. The wait covers two things this layer cannot bound itself: the
        /// window before `up` binds its control socket, which is a shell spawn
        /// plus whatever the project's own `verify` processes do before they
        /// report; and the run loop's teardown, which is a repository-authored
        /// `down` already bounded by `Timeout.local` (60s). So `local` is
        /// structurally too tight — the teardown alone may use all of it — and
        /// `userCommand` is the next tier, the same bound `runDispose` uses for
        /// the very next step of the same purge.
        ///
        /// **Not `Timeout.suite`.** That bounds a suite running to *completion*,
        /// and this wait is for one being *stopped*. Blocking an archive for
        /// half an hour is worse than the hazard the wait exists to close.
        static let stopWaitTimeout = Duration.seconds(ProcessRunner.Timeout.userCommand)

        /// Ask this workstream's run to stop, and wait until nothing of it is
        /// live. Returns whether it got there before `timeout`.
        ///
        /// **This adds no second teardown, and that is the whole shape of it.**
        /// It calls `stop`, which sets a flag, and then polls `isLive` — so the
        /// run loop remains the single owner of `shutDown`, and every ordering
        /// that loop guarantees (final snapshot, log capture, seal, *then*
        /// teardown) happens exactly once, in that order, however this is
        /// called. `Workstream.Archiver.purge` is the caller this exists for:
        /// it used to reach past the runner to `PhaseExecutor.shutDown`, which
        /// **no-ops when the socket file is not there yet**, so a purge landing
        /// during the binding window went on to `dispose` and `git worktree
        /// remove --force` while a suite was still coming up in that tree.
        ///
        /// It composes with `shouldStop` rather than working around it. That
        /// guard withholds a pending Stop until the control server has answered
        /// once, for the same reason: a teardown ordered before the socket
        /// exists does nothing while the suite keeps running. So a run still
        /// binding is not stopped *yet* — it is stopped as soon as it can be,
        /// and this waits for that rather than assuming it.
        ///
        /// `isLive`, not `Run.isFinished`: a run's rows are all terminal for the
        /// last stretch of its life, and the socket is not released until the
        /// teardown returns.
        ///
        /// **The bound is real and the caller must handle `false`.** A spawn
        /// that never binds is only bounded by `Timeout.suite`, far past
        /// anything an archive can wait for, so on expiry this reports the truth
        /// and lets the caller decide. For `purge` that decision is to proceed:
        /// a workstream stranded half-archived is worse than cleanup that did
        /// not happen.
        @discardableResult
        func stopAndWait(
            workstreamID: UUID, timeout: Duration = Runner.stopWaitTimeout
        ) async -> Bool {
            stop(workstreamID: workstreamID)
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while isLive(workstreamID) {
                guard ContinuousClock.now < deadline else { return false }
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    // Cancelled. Report what is true rather than spinning on a
                    // sleep that will now throw immediately every time.
                    return !isLive(workstreamID)
                }
            }
            return true
        }

        // MARK: - Forgetting a workstream

        /// Drop what this type remembers about a workstream that no longer
        /// exists.
        ///
        /// `Workstream.Archiver.purge` is the production caller. Without it
        /// `runs[workstreamID]` held a sealed run for a destroyed workstream for
        /// the rest of the session — the same one-entry-per-archive leak
        /// `AsyncSetupService.clearState` was added to close.
        ///
        /// Called after `stopAndWait`, so on the ordinary path the loop has
        /// already sealed and torn down and there is nothing in flight. On the
        /// expired-wait path the loop is still running, and forgetting *first*
        /// is what makes that safe: `seal`, `apply` and `captureFailedOutput`
        /// all guard on finding the run, so each becomes a no-op — no
        /// `Store.save` for a workstream being deleted, and no `onFinish`, which
        /// would otherwise post an `atelier/verification` completion notice
        /// about a workstream that is being destroyed as it is written.
        ///
        /// **Deliberately not `tearingDown`.** The run loop owns that set and
        /// removes its own entry on the way out; clearing it here would report
        /// `isLive == false` while the socket is still being released, which is
        /// the one thing it exists to prevent. `issuedRunIDs` and `sealedRunIDs`
        /// are left alone too — they are keyed by run id and exist so an id is
        /// never reused, which outliving one workstream is the point of.
        func forget(workstreamID: UUID) {
            runs.removeValue(forKey: workstreamID)
            stopRequested.remove(workstreamID)
        }

        // MARK: - Per-check records

        /// Record one check's completion: persist it, publish it, mirror it onto the run's
        /// own row, and announce it. **The sole writer of a `CheckRecord`, and the only
        /// caller of `onCheckFinished`.**
        ///
        /// Both producers go through here — the poll loop's completion-edge detector, and
        /// `seal` for the checks no edge covered (`.stopped`, and a check whose server died
        /// between polls). One writer is what makes "exactly once per check per run"
        /// structural rather than a property two call sites have to maintain: the guard
        /// below is keyed on `(runID, name)`, so a check reported terminal on three
        /// consecutive polls, and then again by `seal`, still writes and announces once.
        ///
        /// Keyed on the pair rather than the name, because a *later* run of the same check
        /// must replace the record and fire again — the ordinary case every time a row's
        /// Re-run is pressed.
        ///
        /// **It mutates `runs[workstreamID]`.** Any caller holding a local copy of the run
        /// must re-read it afterwards or it will persist a row without the output this just
        /// attached — see `seal`, which does exactly that.
        func recordCompletion(
            workstreamID: UUID,
            runID: String,
            name: String,
            state: Verification.CheckResult.State,
            duration: TimeInterval?,
            output: String?,
            outputTruncated: Bool,
            stamp: String
        ) {
            var records = checkRecords[workstreamID] ?? Verification.CheckStore.records(for: workstreamID)
            if records[name]?.runID == runID {
                return
            }
            let record = Verification.CheckRecord(
                name: name, state: state, duration: duration, output: output,
                outputTruncated: outputTruncated, stamp: stamp, runID: runID, completedAt: Date()
            )
            records[name] = record
            checkRecords[workstreamID] = records
            Verification.CheckStore.save(records, for: workstreamID)

            // Mirrored onto the run's own row as well as stored per check.
            // `Verification.Run` is still what `check_verification` projects from and what
            // survives a restart, so dropping `output` here would take an agent's only view
            // of a failure with it — this is what `captureFailedOutput` used to do, narrowed
            // to one check and moved to the moment it completed.
            if var run = runs[workstreamID], run.id == runID {
                run.checks = run.checks.map { check in
                    guard check.name == name else { return check }
                    var updated = check
                    updated.output = output
                    updated.outputTruncated = outputTruncated
                    return updated
                }
                runs[workstreamID] = run
            }

            onCheckFinished?(workstreamID, record)
        }

        /// Hydrate a workstream's records from the store.
        ///
        /// Called by the tab on appear, so a row drawn before this session has run anything
        /// still shows the last session's verdict. A no-op once the workstream has an
        /// in-memory entry, so it cannot overwrite a live run's records with the store's
        /// older copy.
        func loadCheckRecords(for workstreamID: UUID) {
            guard checkRecords[workstreamID] == nil else { return }
            checkRecords[workstreamID] = Verification.CheckStore.records(for: workstreamID)
        }

        /// Drop a workstream's in-memory records. Called by `forget`, beside the run.
        func forgetCheckRecords(for workstreamID: UUID) {
            checkRecords[workstreamID] = nil
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
            // `declared` goes in **as parsed**, and that does not weaken the
            // filter: `resolveChecks` applies `runnableChecks` to it itself —
            // documented there as being self-sufficient rather than trusting a
            // caller — and refuses a flag-shaped `requested` name before it
            // looks at `declared` at all. Pre-filtering here threw the
            // distinction away instead: a namespace whose every check is named
            // like a flag arrived as an empty list and was refused as "declares
            // no verify processes", which is untrue and unactionable.
            let resolved = try Self.resolveChecks(
                requested: checks, declared: declared
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
        /// `start` answers the three preconditions — a located config, a
        /// resolvable binary, and approval of every repository-provided
        /// file — and hands the results here in a `SpawnRequest`. Every
        /// caller **must enter through `start`** —
        /// `IPC.VerificationRunnerBridge` does, which is why the IPC half
        /// adds no gate of its own; calling this directly runs a
        /// repository's YAML unattended and ungated, which is exactly what
        /// that one gate exists to prevent.
        ///
        /// Internal rather than private so a test can drive it with a seeded run
        /// and a stub spawner; `start` is its only production caller.
        func execute(_ request: SpawnRequest, runID: String) async {
            let workstreamID = request.workstreamID
            let client = spawner.controlClient(for: request)
            // Published for the tab's live log windows before anything else
            // happens, so a check expanded the instant Run is pressed has a
            // client to poll rather than having to wait out the git hop below.
            // Reads through it are bounded by `isLive`; see `liveClients`.
            liveClients[workstreamID] = client
            let state = RunLoopState()

            // The staleness baseline, taken here rather than in `start`: it is
            // four-plus serial git spawns and `start` is synchronous on the
            // main actor. Awaited — not fired and forgotten — for two reasons:
            // it lands before the spawn, so a check that writes to the tree
            // cannot be folded into the baseline it will be measured against;
            // and it lands before `seal`, so the persisted run carries the
            // stamp rather than racing it. Milliseconds after the press, which
            // is still "the moment the run started" for staleness.
            let stamp = await captureStamp(
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
            // Replaces `captureFailedOutput`. Same window — the server is held open until
            // after `seal` — but every check, not only the failures, and through the one
            // writer so a check already recorded mid-run is not fetched or announced twice.
            await recordCompletions(from: entries, runID: runID, client: client, state: state)
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
            //
            // **The mixed case keeps the text and loses only the headline.**
            // Some checks reported and the rest died with a config error is a
            // real shape, and this gate is right to refuse it the headline
            // above — but the executor's own explanation was dropped with it,
            // which left the run's only account of why those rows say "not run"
            // nowhere at all. `unstartedChecksDetail` carries it under its own
            // wording. The discriminator is a row the server never mentioned,
            // still `.pending` here because `seal` has not run yet; a suite
            // where every check reported still sets neither field, so an
            // ordinary failure is still explained by the failing check alone.
            if let outcome = state.outcome, let detail = Self.failureDetail(for: outcome) {
                let checks = runs[workstreamID]?.checks ?? []
                if !Self.serverReportedAnyCheck(checks) {
                    runs[workstreamID]?.failureDetail = detail
                } else if Self.someCheckNeverStarted(checks) {
                    runs[workstreamID]?.unstartedChecksDetail = detail
                }
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
            // After the teardown, with the two flags above, because `isLive`
            // is true for its whole length and a reader arriving during it
            // should meet the dying server rather than an absent client. By
            // here the server is gone, so every later `liveLog` is nil — which
            // is what makes a sealed run's groups fall back to what was
            // captured.
            liveClients[workstreamID] = nil

            // Only now, and only to log it: on the stop path the spawn is still
            // in flight until the teardown above ends its project, and leaving
            // the task unawaited would let it outlive the run it belongs to.
            await spawned.value
            if let outcome = state.outcome, outcome != .succeeded {
                logger.info("verify run \(runID, privacy: .public): \(String(describing: outcome), privacy: .public)")
            }
        }

        /// `fingerprint` — `Git.Operations.diffFingerprint` unless a test said
        /// otherwise — off the main actor.
        ///
        /// The same hop `PhaseSpawner.run` uses, and for the same reason: this
        /// is `git rev-parse`, `git diff --stat`, `git ls-files` and batched
        /// `git hash-object`, which `VerificationTabView.refreshStaleness`
        /// already refuses to run on the actor. See `fingerprint` for why that
        /// placement is injectable rather than merely written down here.
        private func captureStamp(
            worktreePath: String, projectDirectory: String
        ) async -> String {
            let compute = fingerprint
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: compute(worktreePath, projectDirectory)
                    )
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

        /// Whether a check the control server never mentioned is left behind.
        ///
        /// The other side of `serverReportedAnyCheck`, asked of the same rows at
        /// the same moment and for the same reason: `.pending` is exactly "never
        /// seen", because `apply` leaves a name the server has not mentioned
        /// alone and a run is seeded entirely `.pending`. Asked **before**
        /// `seal`, which is what relabels those rows `.notRun` — afterwards the
        /// distinction between "never reported" and "reported as not run" is
        /// gone.
        ///
        /// Not a liveness test and not a terminal-states test: a run the
        /// executor's own deadline ended leaves its rows `.running`, which is
        /// *reported*, so neither this nor `serverReportedAnyCheck` fires a
        /// banner over a suite that simply ran out of time with everything
        /// started.
        static func someCheckNeverStarted(_ checks: [Verification.CheckResult]) -> Bool {
            checks.contains { $0.state == .pending }
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
            // After `apply`, so the duration the record carries is the one the poll just
            // computed rather than the previous poll's.
            await recordCompletions(from: entries, runID: runID, client: client, state: state)
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

        /// Fetch and record every check that has just reached a terminal state.
        ///
        /// **Mid-run, and read-only.** The tail comes through the control client this loop
        /// already holds — the same borrow `liveLog` makes — while the server is still up.
        /// It neither extends nor ends the log window, so the single-owner teardown rule is
        /// untouched: `execute` still calls `shutDown` exactly once, after `seal`.
        ///
        /// Every check's output is captured, pass or fail, which is the retirement of
        /// `captureFailedOutput`'s failures-only rule. The fetch happens anyway for the
        /// mailbox notice, so keeping the result costs a dictionary entry rather than a
        /// round trip — and it is what lets a passing row's Output group show anything at
        /// all.
        private func recordCompletions(
            from entries: [ProcessCompose.ProcessEntry], runID: String,
            client: ProcessCompose.Controlling, state: RunLoopState
        ) async {
            guard let workstreamID = runs.first(where: { $0.value.id == runID })?.key,
                  let run = runs[workstreamID], !sealedRunIDs.contains(runID)
            else { return }

            let ours = Dictionary(
                run.checks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
            )
            for entry in entries {
                guard let check = ours[entry.name], !state.recorded.contains(entry.name) else { continue }
                let entryState = Verification.CheckResult.State(entry: entry)
                guard Self.isTerminal(entryState) else { continue }
                state.recorded.insert(entry.name)

                var output: String?
                var truncated = false
                do {
                    let lines = try await client.logs(name: entry.name, tail: Self.logTailLines)
                    output = lines.joined(separator: "\n")
                    // At the limit the honest answer is "possibly truncated": a tail cannot
                    // reveal whether anything preceded it. The flag means there was more at
                    // capture time, never that a fuller copy can be fetched.
                    truncated = lines.count >= Self.logTailLines
                } catch {
                    // A warning, not a debug line: this loss is permanent by design — the
                    // window is one-shot and the server goes away when the run seals, so
                    // this check ends up with no explanation anywhere.
                    logger.warning(
                        "verify logs for \(entry.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }

                recordCompletion(
                    workstreamID: workstreamID, runID: runID, name: entry.name,
                    state: entryState, duration: check.duration, output: output,
                    outputTruncated: truncated, stamp: run.stamp
                )
            }
        }

        /// Whether a state means the check is done for this run.
        ///
        /// `.stopped` is terminal but is never reached mid-run — `Runner.stop` deliberately
        /// does not stop individual checks, so a stopped row is still `.running` until
        /// `seal` relabels it. It is listed here because `seal` asks the same question of
        /// its already-relabelled rows.
        ///
        /// `.notRun` is deliberately **not** terminal: a check that never started has no
        /// result to report, its row must offer Run rather than Re-run, and the surviving
        /// run-level mailbox notice is discriminated on exactly this producing no records.
        static func isTerminal(_ state: Verification.CheckResult.State) -> Bool {
            switch state {
            case .passed, .failed, .skipped, .stopped: true
            case .notRun, .pending, .running: false
            }
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

            /// Checks already fetched this run, so a terminal state seen on several
            /// consecutive polls is fetched from the server once rather than once a second.
            ///
            /// `recordCompletion` is the real idempotence guard; this is the cheaper one in
            /// front of it, and it is what stops a 200-line `logs` request per poll for a
            /// check that finished thirty seconds ago.
            var recorded: Set<String> = []

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
