// ABOUTME: Runs a project's verification.yaml checks, one terminal surface each.
// ABOUTME: Checks are independent: any number at once, each with its own stop.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "verification")

extension Verification {
    /// Where a check's terminal comes from.
    ///
    /// A seam rather than a direct call into `TerminalSurfaceCache`, for two
    /// reasons. The cache lives in `Sources/Views` and this type lives in
    /// `Sources/Models`, so calling it directly would point the dependency the
    /// wrong way. And every ordering in this file — a spawn recorded before its
    /// surface exists, a stop that must outlive the surface — is only assertable
    /// against something a test can stand in for.
    @MainActor
    protocol SurfaceHosting: AnyObject {
        /// Create (or replace) the surface for this check and start its command.
        /// Returns false when no surface could be made, which the runner reports
        /// rather than swallowing: a check with no terminal never runs.
        func startSurface(
            id: UUID,
            command: String,
            workingDirectory: String,
            environment: [String: String]
        ) -> Bool

        /// Drop a check's surface. Called when a workstream is forgotten, never
        /// when a check merely finishes — a finished check's terminal is what the
        /// user reads its output from.
        func disposeSurface(id: UUID)
    }
}

extension Verification {
    /// The one place a verification check is started or stopped.
    ///
    /// **App-level, with two legal entrances** — the Verification tab and
    /// `IPC.VerificationRunnerBridge` — because a run an agent starts has to appear
    /// in the user's tab, and a check may be running only once at a time. Both go
    /// through `start`.
    ///
    /// **Checks are independent.** There is no run-wide server, no socket and no
    /// suite: each check is one terminal surface running one command, and starting,
    /// stopping or re-running one says nothing about any other. A `Run` survives
    /// only as the unit one *press* started, which is what `start_verification`
    /// answers with and `check_verification` resolves.
    @MainActor
    final class Runner: ObservableObject {
        /// Every check's latest result, by workstream and then by name. The rows
        /// render from this; it outlives the process that produced it and is
        /// persisted by `CheckStore`.
        @Published private(set) var checkRecords: [UUID: [String: CheckRecord]] = [:]

        /// The checks running right now, by workstream and then by name.
        @Published private(set) var running: [UUID: [String: LiveCheck]] = [:]

        /// One check in flight.
        struct LiveCheck: Equatable {
            let runID: String
            let startedAt: Date
            let spawn: Spawn
            /// Set by `stop`, so the completion pass can tell a check that was
            /// killed from one whose command died on its own. The wrapper writes
            /// no status file in either case — killing the group takes the wrapper
            /// with it — so this flag is the only discriminator there is.
            var stopRequested: Bool = false
        }

        /// Runs from this session, by id, newest last per workstream.
        ///
        /// **In memory only, and that is a change from the run this replaced.**
        /// A run used to be persisted so the newest id resolved across a restart.
        /// It no longer carries output — output lives in a surface and dies with
        /// the app — so the whole value of persisting one was resolving an id whose
        /// results are already in `checkRecords`. Every run of this session resolves
        /// instead of only the newest, which is what `check_verification` actually
        /// wanted; none survives a relaunch, which is honest about the output that
        /// does not either.
        private var runs: [String: Run] = [:]
        private var runIDsByWorkstream: [UUID: [String]] = [:]

        /// Fired as each check reaches a terminal state. `IPC.VerificationRunnerBridge`
        /// holds it and posts one mailbox notice per check.
        ///
        /// Fired from `recordCompletion` and nowhere else, which is what makes "one
        /// notice per check per run" structural rather than a property two call sites
        /// have to maintain.
        var onCheckFinished: ((UUID, CheckRecord, Run) -> Void)?

        /// Fired when the last check of a run reaches a terminal state.
        var onFinish: ((Run) -> Void)?

        /// **Strong, and that is the fix for a bug this shipped with for one
        /// round.** It was `weak`, on the reflex that a model holding a view-layer
        /// object is a cycle risk — but `VerificationSurfaceHost` is a stateless
        /// adapter that holds `TerminalSurfaceCache` itself, so nothing else has a
        /// reason to retain it, and `ContentView` constructs it inline. It
        /// deallocated on the next turn of the run loop and every check then failed
        /// with `.noSurface`: the whole feature, dead, from one keyword. There is no
        /// cycle to fear — the host does not reference the runner.
        private var surfaces: (any SurfaceHosting)?
        private let fingerprint: @Sendable (_ worktreePath: String, _ projectDirectory: String) -> String
        private let pollInterval: Duration
        /// Injected only by tests: a real grace is five seconds, and
        /// `VerificationRunnerTests`' two stop tests are timing tests that must
        /// not pay it.
        private let killGrace: Duration
        /// How long a check may go without a pid file before it is taken to have
        /// died on its way up. Injected only by tests, for the same reason
        /// `killGrace` is: the production value is a real wait no timing test
        /// should pay.
        private let startupGrace: Duration
        private var pollTask: Task<Void, Never>?

        /// How long after `SIGTERM` a check that has not died is killed outright.
        static let defaultKillGrace: Duration = .seconds(5)
        static let defaultPollInterval: Duration = .milliseconds(400)

        /// The upper bound on "still starting" — see `completionPass`.
        ///
        /// **Thirty seconds is a tradeoff between two costs, and it is worth
        /// naming both.** Too short and a machine slow enough to take that long
        /// over fork → `login` → bash → `sh` → `ps` gets a check killed off for
        /// being slow, which is the failure mode `completionPass`'s rule exists
        /// to prevent. Too long and the bound becomes the ceiling on
        /// `stopAndWait`, so archiving a workstream whose check was started a
        /// moment earlier hangs for it. The real path is milliseconds, so thirty
        /// seconds is three orders of magnitude of headroom on the first cost,
        /// and an archive that pauses for half a minute in the worst case is a
        /// bounded annoyance where the unbounded version was a workstream that
        /// could not be archived at all.
        static let defaultStartupGrace: Duration = .seconds(30)

        init(
            fingerprint: @escaping @Sendable (String, String) -> String = { worktreePath, projectDirectory in
                Git.Operations.diffFingerprint(
                    worktreePath: worktreePath, projectPath: projectDirectory, mode: "uncommitted"
                )
            },
            pollInterval: Duration = Runner.defaultPollInterval,
            killGrace: Duration = Runner.defaultKillGrace,
            startupGrace: Duration = Runner.defaultStartupGrace
        ) {
            self.fingerprint = fingerprint
            self.pollInterval = pollInterval
            self.killGrace = killGrace
            self.startupGrace = startupGrace
        }

        /// Installed once, by `ContentView`, with the adapter over
        /// `TerminalSurfaceCache`. **Retained** — see `surfaces`.
        func attach(surfaces: any SurfaceHosting) {
            self.surfaces = surfaces
        }

        enum Failure: Error, Equatable, LocalizedError {
            /// Every check this call named is already running. Per check, never
            /// per workstream: two different checks starting at once is the point,
            /// and a call naming one live check and one idle one starts the idle
            /// one rather than throwing. This is the whole-call refusal that is
            /// left — a start with nothing to start — and it names all of them,
            /// because naming only the first would leave the caller retrying into
            /// the second.
            case alreadyRunning([String])
            /// No `verification.yaml`, or one that could not be read.
            case unavailable(String)
            case unknownChecks([String], valid: [String])
            /// A surface could not be created, so nothing was started. Reported
            /// rather than swallowed: a check with no terminal never runs, and a
            /// silent no-op here reads on the row as a check that passed instantly.
            case noSurface(String)

            var errorDescription: String? {
                switch self {
                case let .alreadyRunning(names):
                    // The one-name wording is unchanged: it is what the
                    // Verification tab's row shows, and both UI callers name
                    // exactly one check.
                    names.count == 1
                        ? String(
                            format: NSLocalizedString(
                                "“%@” is already running.",
                                comment: "Verification: a check asked to start twice"
                            ),
                            names[0]
                        )
                        : String(
                            format: NSLocalizedString(
                                "Already running: %@.",
                                comment: "Verification: every check a start named was already running"
                            ),
                            names.joined(separator: ", ")
                        )
                case let .unavailable(reason):
                    reason
                case let .unknownChecks(names, valid):
                    String(
                        format: NSLocalizedString(
                            "No such check: %1$@. This project declares: %2$@.",
                            comment: "Verification: a check name that verification.yaml does not declare"
                        ),
                        names.joined(separator: ", "),
                        valid.isEmpty
                            ? NSLocalizedString("nothing", comment: "Verification: a project with no checks")
                            : valid.joined(separator: ", ")
                    )
                case let .noSurface(name):
                    String(
                        format: NSLocalizedString(
                            "“%@” could not be given a terminal to run in.",
                            comment: "Verification: surface creation failed"
                        ),
                        name
                    )
                }
            }
        }

        // MARK: - Reading

        /// Whether anything is running for this workstream.
        ///
        /// What the purge path waits on and what the tab's staleness refresh
        /// suppresses itself for. **Not** a gate on starting a check: that is
        /// `isRunning(_:check:)`, because two checks running at once is the design.
        func isLive(_ workstreamID: UUID) -> Bool {
            !(running[workstreamID]?.isEmpty ?? true)
        }

        func isRunning(_ workstreamID: UUID, check: String) -> Bool {
            running[workstreamID]?[check] != nil
        }

        /// The state a row should draw for one check: the live one if it is
        /// running, the stored record otherwise, and `.notRun` when there is
        /// neither.
        func state(_ workstreamID: UUID, check: String) -> CheckResult.State {
            if isRunning(workstreamID, check: check) {
                return .running
            }
            return checkRecords[workstreamID]?[check]?.state ?? .notRun
        }

        /// How long the running check has been going, for the row's timer.
        func elapsed(_ workstreamID: UUID, check: String, now: Date = Date()) -> TimeInterval? {
            guard let live = running[workstreamID]?[check] else { return nil }
            return now.timeIntervalSince(live.startedAt)
        }

        /// The surface a check's output is in, or nil when it has not run this
        /// session. Nil is what the row renders "there is nothing to show" for.
        func surfaceID(_ workstreamID: UUID, check: String) -> UUID? {
            if let live = running[workstreamID]?[check] {
                return live.spawn.surfaceID
            }
            return startedSurfaces[workstreamID]?[check]
        }

        /// Surfaces created this session, kept past the check's completion so its
        /// output stays readable. Cleared only by `forget`.
        private var startedSurfaces: [UUID: [String: UUID]] = [:]

        func run(id: String) -> Run? {
            runs[id]
        }

        // MARK: - Starting

        /// Start one or more checks.
        ///
        /// Each named check is started independently and the returned `Run` is the
        /// set that this call started — the unit `start_verification` answers with.
        /// A check already running is refused by name and the rest still start,
        /// because refusing the whole call would make an agent's re-request of two
        /// checks fail for the one that is already going. The refused names come
        /// back on `Run.refused`, and they are in no `checks` row: they belong to
        /// the run that started them.
        ///
        /// **The whole call is refused only when there is nothing left to start**,
        /// which is `Failure.alreadyRunning` naming every one of them. That is what
        /// keeps the two UI callers — the row's button and the palette command,
        /// each naming exactly one check — throwing exactly as they did, and it is
        /// the same rule the seam states: refuse rather than mint a run that cannot
        /// report.
        @discardableResult
        func start(
            workstreamID: UUID,
            projectName: String,
            workstreamName: String,
            worktreePath: String,
            projectDirectory: String,
            defaultBranch: String,
            checks requested: [String]?
        ) throws -> Run {
            let config = try loadConfig(projectDirectory: projectDirectory)

            let names: [String]
            if let requested {
                let unknown = requested.filter { config.check(named: $0) == nil }
                guard unknown.isEmpty else {
                    throw Failure.unknownChecks(unknown, valid: config.checkNames)
                }
                names = requested
            } else {
                names = config.checkNames
            }
            guard !names.isEmpty else {
                throw Failure.unavailable(NSLocalizedString(
                    "This project declares no checks.",
                    comment: "Verification: verification.yaml exists but is empty"
                ))
            }
            // Filtered rather than set-differenced, so both halves keep the order
            // the caller asked in — which for the implicit all-checks case is
            // verification.yaml's own order, the one every other surface uses.
            let refused = names.filter { isRunning(workstreamID, check: $0) }
            let startable = names.filter { !isRunning(workstreamID, check: $0) }
            guard !startable.isEmpty else {
                throw Failure.alreadyRunning(refused)
            }

            guard let surfaces else {
                throw Failure.noSurface(startable.joined(separator: ", "))
            }

            // Computed once for the whole press rather than per check: it is four
            // git spawns and every check in one press sees the same worktree.
            let stamp = fingerprint(worktreePath, projectDirectory)
            let environment = ProcessCompose.PhaseEnvironment.variables(
                workstreamID: workstreamID,
                projectName: projectName,
                workstreamName: workstreamName,
                projectDirectory: projectDirectory,
                worktreePath: worktreePath,
                defaultBranch: defaultBranch
            )

            Verification.Spawn.ensureStateDirectory()
            let runID = UUID().uuidString
            var started: [CheckResult] = []
            var failures: [String] = []

            for name in startable {
                guard let check = config.check(named: name) else { continue }
                let spawn = Verification.Spawn.build(check: check, workstreamID: workstreamID)
                // Before the surface, never after: a status file left by the
                // previous run of this check would be read as this one finishing
                // the instant it started.
                spawn.clearState()
                guard surfaces.startSurface(
                    id: spawn.surfaceID,
                    command: spawn.command,
                    workingDirectory: worktreePath,
                    environment: environment
                ) else {
                    failures.append(name)
                    continue
                }
                running[workstreamID, default: [:]][name] = LiveCheck(
                    runID: runID, startedAt: Date(), spawn: spawn
                )
                startedSurfaces[workstreamID, default: [:]][name] = spawn.surfaceID
                started.append(CheckResult(name: name, state: .running))
            }

            guard !started.isEmpty else {
                throw Failure.noSurface(failures.joined(separator: ", "))
            }
            if !failures.isEmpty {
                logger.warning(
                    "Verification checks with no surface: \(failures.joined(separator: ", "), privacy: .public)"
                )
            }

            let run = Run(
                id: runID,
                workstreamID: workstreamID,
                startedAt: Date(),
                stamp: stamp,
                checks: started,
                wasStopped: false,
                refused: refused
            )
            runs[runID] = run
            runIDsByWorkstream[workstreamID, default: []].append(runID)
            trimRuns(for: workstreamID)
            ensurePolling()
            return run
        }

        /// **`Load.unavailableReason` is the wording, never a second set here.**
        /// The doc comment on that property claims the runner refuses on the same
        /// three cases the tab draws, and for two of them it did not: `.missing`
        /// threw "This project has no verification.yaml." where the tab says "Add
        /// a verification.yaml to this project's directory to declare checks.",
        /// and `.invalid` threw the bare parse reason where the tab wraps it as
        /// "This project's verification.yaml could not be read: …". An agent
        /// reading a refusal and a user reading the tab were told different
        /// things about one file.
        ///
        /// The empty-checks case deliberately does **not** come through here: it
        /// is refused at the call site, which also has to refuse an explicit
        /// empty `checks:` list, and those are different sentences.
        private func loadConfig(projectDirectory: String) throws -> Verification.Config {
            let load = Verification.Config.load(projectDirectory: projectDirectory)
            guard let config = load.config else {
                throw Failure.unavailable(load.unavailableReason ?? "")
            }
            return config
        }

        /// Runs are small now — no output rides on them — but a long session with a
        /// busy agent should still not accumulate without bound.
        private static let runsKeptPerWorkstream = 50

        private func trimRuns(for workstreamID: UUID) {
            guard var ids = runIDsByWorkstream[workstreamID],
                  ids.count > Self.runsKeptPerWorkstream
            else { return }
            let dropped = ids.prefix(ids.count - Self.runsKeptPerWorkstream)
            // Never drop a run that still has a check in flight, however old: its
            // completion has to find it.
            let live = Set((running[workstreamID] ?? [:]).values.map(\.runID))
            for id in dropped where !live.contains(id) {
                runs[id] = nil
                ids.removeAll { $0 == id }
            }
            runIDsByWorkstream[workstreamID] = ids
        }

        // MARK: - Stopping

        /// Ask one check to stop.
        ///
        /// Kills the wrapper's **process group**, which is the whole tree the check
        /// spawned: Ghostty's child calls `setsid` and every exec in its chain keeps
        /// the pid, so the `sh` whose pid the wrapper wrote is the session leader.
        /// The same group kill `ProcessRunner` documents and has measured, and the
        /// reason the wrapper writes a pid at all — Ghostty exposes none.
        ///
        /// The row does not go `.stopped` here. It goes `.stopped` when the process
        /// is actually gone, which the completion pass observes; declaring it
        /// stopped on the request would let a purge proceed to
        /// `git worktree remove --force` with the command still running in that tree.
        ///
        /// **The kill after the grace is keyed to the *run*, not to the check.**
        /// `isRunning(_:check:)` answers "is *a* run of this check going", which is
        /// a different question once a stop and a re-run happen inside five seconds:
        /// stop at t=0, the user presses Run again at t=2, and the stale task fires
        /// at t=5 into a check that is running for the second time. Capturing the
        /// `Spawn` does not save you — `Verification.Spawn.fileStem` is derived from
        /// the workstream and the check's name and carries no run id, so both runs
        /// share one pid file and the stale task reads the *new* group out of it.
        /// The new `LiveCheck` has `stopRequested` false and the killed wrapper
        /// writes no status, so the completion pass records `.failed(-1)`: the row
        /// reads as the check crashing, with nothing tying it to a Stop press two
        /// runs ago. The run id is what tells the two apart, so the task re-reads
        /// the live check and fires only when it is still the same run.
        func stop(workstreamID: UUID, check: String) {
            guard var live = running[workstreamID]?[check] else { return }
            live.stopRequested = true
            running[workstreamID]?[check] = live
            signal(live.spawn, SIGTERM)
            let runID = live.runID
            let grace = killGrace
            Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard let self,
                      let live = running[workstreamID]?[check],
                      live.runID == runID
                else { return }
                signal(live.spawn, SIGKILL)
            }
        }

        func stopAll(workstreamID: UUID) {
            for name in (running[workstreamID] ?? [:]).keys {
                stop(workstreamID: workstreamID, check: name)
            }
        }

        private func signal(_ spawn: Spawn, _ code: Int32) {
            guard let pid = spawn.recordedPID else {
                // The wrapper has not written its pid yet, which is a window of
                // milliseconds at the very start of a check. Nothing to signal —
                // but the stop flag is already set and the grace's `SIGKILL`
                // re-reads this file, so a wrapper that comes up between the two
                // is still killed. One that never comes up is bounded instead, by
                // `completionPass`'s startup grace, which is what stops a stop
                // from silently doing nothing forever.
                logger.info("Verification stop found no pid yet for \(spawn.statusPath, privacy: .public)")
                return
            }
            kill(-pid, code)
        }

        /// Stop everything for a workstream and wait for it to be gone.
        ///
        /// `Workstream.Archiver.purge` calls this before it destroys the worktree.
        /// The bound is `ProcessRunner.Timeout.userCommand`, the same tier the very
        /// next step of a purge uses, and on expiry the caller logs and proceeds:
        /// a workstream stranded half-archived is worse than cleanup that did not
        /// happen. Returns whether everything really stopped.
        ///
        /// **A check that can never report does not reach that bound**, because
        /// the loop drives `completionPass`, which retires a check with no pid
        /// file once its startup grace expires. Before that grace existed such a
        /// check was unstoppable and unobservable, so this waited out the whole
        /// `userCommand` timeout and came back false every time.
        @discardableResult
        func stopAndWait(
            workstreamID: UUID,
            timeout: TimeInterval = ProcessRunner.Timeout.userCommand,
            poll: Duration = .milliseconds(100)
        ) async -> Bool {
            guard isLive(workstreamID) else { return true }
            stopAll(workstreamID: workstreamID)
            let deadline = Date().addingTimeInterval(timeout)
            while isLive(workstreamID) {
                if Date() >= deadline {
                    return false
                }
                await completionPass()
                try? await Task.sleep(for: poll)
            }
            return true
        }

        /// Drop everything Atelier remembers about a workstream's checks, and its
        /// check surfaces with it.
        ///
        /// **Both archive paths call this, not just `purge`.** `purge` calls it
        /// before the destructive work, so a check that outlives an expired
        /// `stopAndWait` finishes into nothing rather than posting a completion
        /// notice about a worktree being deleted. `remove` calls it because a check
        /// surface is not reachable by `TerminalSurfaceCache.removeWorkstreamSurfaces`
        /// — that sweep enumerates ids derived from `WorkspaceModel`'s counters, and
        /// a check's surface id comes from `Verification.Spawn.surfaceID` instead. A
        /// workstream removed with rspec running would otherwise leave that terminal,
        /// and its process, alive for the rest of the session with nothing able to
        /// reach either.
        ///
        /// `stop` is *not* called here: `purge` has already quiesced through
        /// `stopAndWait`, and `disposeSurface` destroys the surface, which takes its
        /// process with it.
        func forget(workstreamID: UUID) {
            running[workstreamID] = nil
            checkRecords[workstreamID] = nil
            for id in runIDsByWorkstream[workstreamID] ?? [] {
                runs[id] = nil
            }
            runIDsByWorkstream[workstreamID] = nil
            for surface in (startedSurfaces[workstreamID] ?? [:]).values {
                surfaces?.disposeSurface(id: surface)
            }
            startedSurfaces[workstreamID] = nil
        }

        // MARK: - Completion

        /// One poll loop for the whole app, alive only while something is running.
        ///
        /// Polling rather than Ghostty's `GHOSTTY_ACTION_SHOW_CHILD_EXITED`, which
        /// does fire but cannot answer the question that matters: its `exit_code` is
        /// unreliable on macOS by Ghostty's own account (`ghostty/src/Surface.zig:1208`),
        /// so the status file has to be read either way. A handful of `stat` calls
        /// at this cadence is cheaper than the C plumbing a second, redundant signal
        /// would need.
        private func ensurePolling() {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while let self, anythingRunning {
                    await completionPass()
                    try? await Task.sleep(for: pollInterval)
                }
                self?.pollTask = nil
            }
        }

        private var anythingRunning: Bool {
            running.values.contains { !$0.isEmpty }
        }

        /// Look at every running check once and record the ones that have finished.
        ///
        /// Two ways a check ends, and both have to be handled here because only one
        /// of them leaves evidence:
        ///
        /// - **The command exited.** The wrapper wrote its status file, and that
        ///   number is the exit code.
        /// - **The process is gone with no status file.** Either Atelier killed the
        ///   group — which takes the wrapper with it before it can write anything —
        ///   or the surface was destroyed under it. `stopRequested` is the only
        ///   thing that can tell those apart, which is why `stop` sets it.
        func completionPass() async {
            let now = Date()
            for (workstreamID, checks) in running {
                for (name, live) in checks {
                    if let status = live.spawn.recordedStatus {
                        finish(
                            workstreamID: workstreamID,
                            name: name,
                            live: live,
                            state: status == 0 ? .passed : .failed(status)
                        )
                        continue
                    }
                    guard let pid = live.spawn.recordedPID else {
                        // **A check with no pid file yet is starting, never
                        // finished.** The wrapper writes its group id as its first
                        // act, so this is a window of milliseconds — and reading a
                        // missing pid as "gone" would record every check as
                        // finished the instant the first pass looked at it, before
                        // it had run anything.
                        //
                        // **But the window is bounded, because nothing else
                        // bounds it.** `startSurface` returning true is not the
                        // wrapper having run: a surface can fail to spawn its
                        // child, or be torn down before exec. Then the pid file
                        // never arrives, and "starting" is a state the check
                        // cannot leave — the row shows Running for the rest of the
                        // session, `stop` has no group to signal so it no-ops, the
                        // grace's `SIGKILL` no-ops with it, and `stopAndWait`
                        // burns the whole of `ProcessRunner.Timeout.userCommand`
                        // before an archive may proceed. Past the grace the pid
                        // file is not late, it is never coming, so this is the
                        // same case as the branch below: a process that is gone
                        // with no status file.
                        if now.timeIntervalSince(live.startedAt) >= startupGraceSeconds {
                            logger.warning(
                                "Verification check \(name, privacy: .public) wrote no pid within its startup grace"
                            )
                            finish(
                                workstreamID: workstreamID,
                                name: name,
                                live: live,
                                state: live.stopRequested ? .stopped : .failed(-1)
                            )
                        }
                        continue
                    }
                    guard !isAlive(pid) else { continue }
                    finish(
                        workstreamID: workstreamID,
                        name: name,
                        live: live,
                        state: live.stopRequested ? .stopped : .failed(-1)
                    )
                }
            }
        }

        /// `startupGrace` as the seconds `completionPass` compares dates in.
        /// `Duration` is what the other two knobs are spelled as, and what
        /// `Task.sleep` wants; nothing converts it for free.
        private var startupGraceSeconds: TimeInterval {
            let parts = startupGrace.components
            return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        }

        /// `kill(-pgid, 0)` asks whether a process group still exists without
        /// touching it. `ESRCH` is the answer that means gone; `EPERM` means it is
        /// there and not ours, which cannot happen for a group Atelier created but
        /// must not be read as absence.
        ///
        /// Safe against reaching a stranger for the reason `ProcessRunner.kill`
        /// states: a pid live as a group id is never reissued, so a group id
        /// Atelier recorded can only ever name the group Atelier created — an
        /// emptied one answers ESRCH and this reports it gone, which is the truth.
        private func isAlive(_ pgid: pid_t) -> Bool {
            if kill(-pgid, 0) == 0 {
                return true
            }
            return errno == EPERM
        }

        private func finish(
            workstreamID: UUID,
            name: String,
            live: LiveCheck,
            state: CheckResult.State
        ) {
            running[workstreamID]?[name] = nil
            if running[workstreamID]?.isEmpty ?? false {
                running[workstreamID] = nil
            }
            recordCompletion(
                workstreamID: workstreamID,
                runID: live.runID,
                name: name,
                state: state,
                duration: Date().timeIntervalSince(live.startedAt)
            )
        }

        /// The single writer of a `CheckRecord`, and the only caller of
        /// `onCheckFinished`.
        ///
        /// One notice per check per run is structural because of that, rather than
        /// a property two call sites have to maintain.
        ///
        /// Internal rather than private so a test can drive a completion without a
        /// real process; `finish` is its only production caller.
        func recordCompletion(
            workstreamID: UUID,
            runID: String,
            name: String,
            state: CheckResult.State,
            duration: TimeInterval
        ) {
            guard var run = runs[runID] else { return }
            let record = CheckRecord(
                name: name,
                state: state,
                duration: duration,
                stamp: run.stamp,
                runID: runID,
                completedAt: Date()
            )
            var records = checkRecords[workstreamID] ?? [:]
            records[name] = record
            checkRecords[workstreamID] = records
            CheckStore.save(records, for: workstreamID)

            if let index = run.checks.firstIndex(where: { $0.name == name }) {
                run.checks[index].state = state
                run.checks[index].duration = duration
            }
            if state == .stopped {
                run.wasStopped = true
            }
            runs[runID] = run

            onCheckFinished?(workstreamID, record, run)
            if run.isFinished {
                onFinish?(run)
            }
        }

        // MARK: - Records

        /// Load a workstream's stored records into memory. Called when the tab
        /// appears, so a relaunch shows the last session's verdicts.
        func loadRecords(for workstreamID: UUID) {
            guard checkRecords[workstreamID] == nil else { return }
            checkRecords[workstreamID] = CheckStore.records(for: workstreamID)
        }

        /// The records a row reads its verdict, duration and stamp from.
        func records(for workstreamID: UUID) -> [String: CheckRecord] {
            checkRecords[workstreamID] ?? [:]
        }

        // MARK: - Test seams

        /// Registers a run with every check `.running`, without spawning anything.
        ///
        /// The alternative is a fake `SurfaceHosting` plus a fake process per check,
        /// which would test Ghostty's absence rather than the routing these seams
        /// exist for. `start` is covered separately, against a host stub.
        func seedRunForTesting(workstreamID: UUID, runID: String, checks: [String], stamp: String = "") {
            let run = Run(
                id: runID,
                workstreamID: workstreamID,
                startedAt: Date(),
                stamp: stamp,
                checks: checks.map { CheckResult(name: $0, state: .running) },
                wasStopped: false
            )
            runs[runID] = run
            runIDsByWorkstream[workstreamID, default: []].append(runID)
        }

        /// Marks one check of a seeded run as running against `spawn`, without a
        /// surface or a process.
        ///
        /// The completion pass reads the world through `spawn`'s two files, so a
        /// test drives a check's whole life by writing them: no status file and no
        /// pid file is a check still coming up, a pid file naming a dead process is
        /// a check that died, and a status file is a check that exited. That is the
        /// same evidence production reads, which is what makes these tests about the
        /// runner rather than about a stub's manners.
        func seedRunningForTesting(
            workstreamID: UUID, runID: String, check: String, spawn: Spawn
        ) {
            running[workstreamID, default: [:]][check] = LiveCheck(
                runID: runID, startedAt: Date(), spawn: spawn
            )
            startedSurfaces[workstreamID, default: [:]][check] = spawn.surfaceID
            ensurePolling()
        }
    }
}
