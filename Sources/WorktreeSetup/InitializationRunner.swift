// ABOUTME: Actor that runs a project's initialization.yaml steps behind a new worktree.
// ABOUTME: The Coding Agent launches immediately; the project's own setup runs in the background.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "initialization")

extension Initialization {
    /// What initialization last reported for one workstream.
    ///
    /// Renamed from `AsyncSetupState` along with everything else in this
    /// vocabulary. The cases are unchanged: what a half-renamed vocabulary costs
    /// is a reader having to know that "bootstrap", "async setup" and
    /// "initialization" were all the same thing.
    enum State: Equatable {
        case idle
        case inProgress(step: String, progress: Double)
        case completed
        /// Initialization finished without doing anything, and the note says
        /// why: no `initialization.yaml`, a file that could not be read, a file
        /// declaring no steps, or a run an archive stopped. The worktree exists
        /// and is usable either way — this is deliberately neither `.completed`,
        /// which would claim work that never happened, nor `.failed`, which would
        /// claim a broken worktree.
        case completedWithNote(String)
        case failed(String)
    }
}

extension Initialization.State {
    /// A stable key naming this state, for a consumer that has to branch on it
    /// rather than read it.
    ///
    /// Separate from `detail` because the two answer different questions and
    /// only one of them may ever be reworded: the key is a wire value
    /// `get_initialization_state` puts in front of an agent, and the sentence is
    /// the user's copy.
    var key: String {
        switch self {
        case .idle: "idle"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .completedWithNote: "completed_with_note"
        case .failed: "failed"
        }
    }

    /// What this state says, in one sentence — the Info tab's Setup row, and
    /// the only wording `get_initialization_state` reports.
    ///
    /// It lives here rather than in the view because there are two consumers
    /// now and the *sentence* is what they must agree on. A second copy in the
    /// IPC handler would have drifted on exactly the case that matters: `.idle`
    /// speaks for the session and not for the worktree, and an agent told
    /// anything stronger than this would conclude setup never ran.
    /// `initializationRow(for:)` keeps the icon and the tint, which are the
    /// view's own and which no agent can read.
    var detail: String {
        switch self {
        case .idle:
            NSLocalizedString("Nothing reported this session.", comment: "")
        case let .inProgress(step, _):
            step
        case .completed:
            NSLocalizedString("Ran successfully.", comment: "")
        case let .completedWithNote(note):
            note
        case let .failed(detail):
            detail
        }
    }

    /// How far through the declared steps, while one is running. Nil otherwise —
    /// a finished run has no progress, and 1.0 would read as one.
    var progress: Double? {
        if case let .inProgress(_, progress) = self {
            return progress
        }
        return nil
    }
}

/// Notification posted on the main thread whenever initialization state changes.
/// `userInfo` contains "workstreamID" (UUID) and "state" (Initialization.State).
extension Notification.Name {
    static let initializationStateChanged = Notification.Name("atelier.initializationStateChanged")
}

extension Initialization {
    /// Runs a project's declared setup steps against a new worktree.
    ///
    /// The key insight is unchanged from the `bootstrap` namespace this replaced:
    /// the Coding Agent can start the moment `git worktree add` returns, and the
    /// project's own setup runs in the background behind it.
    ///
    /// What changed is the vehicle. Setup used to be `process-compose up -n
    /// bootstrap` against a namespace of the project's `process-compose.yaml`,
    /// which meant four preconditions before anything could run (a config
    /// located, a binary found, repository files approved, the namespace
    /// non-empty), a control socket, a `--keep-project` poll to discover whether
    /// the processes had actually succeeded, and a namespace that idles forever
    /// rather than failing when nobody declares it. Setup is an ordered list of
    /// commands; `initialization.yaml` says that and this runs it.
    actor Runner {
        /// Shared singleton for app-wide access.
        static let shared = Runner()

        /// Track per-workstream state.
        private var states: [UUID: Initialization.State] = [:]

        /// Workstreams whose initialization is in flight right now, and the
        /// handle that stops each one.
        ///
        /// Not derived from `states`: a caller publishes `.inProgress` before the
        /// background work starts, so a state-based check could not tell "about
        /// to start" from "already running". Two concurrent runs for one
        /// workstream would run the project's setup commands twice over one
        /// directory — reachable from `.workstreamWorktreeReady` landing while a
        /// manual rerun is in flight.
        private var running: [UUID: ProcessRunner.Cancellation] = [:]

        /// Get the current state for a workstream.
        func state(for workstreamID: UUID) -> Initialization.State {
            states[workstreamID] ?? .idle
        }

        /// Run the project's initialization steps against a worktree that exists.
        ///
        /// Nothing here can stop the worktree from being usable. It already
        /// exists by the time this runs, and every way of having nothing to run —
        /// no file, an unreadable file, a file declaring no steps — reports
        /// `.completedWithNote` rather than `.failed`. `Initialization.Run` owns
        /// both of those decisions; this method is only the plumbing between them.
        func run(
            workstreamID: UUID,
            projectName: String,
            workstreamName: String,
            projectPath: String,
            worktreePath: String
        ) async {
            // Checked and claimed without an intervening `await`, so two callers
            // cannot both pass it.
            guard running[workstreamID] == nil else {
                logger.info("Initialization for \(worktreePath, privacy: .public) is already running; ignoring the second request")
                return
            }
            let cancellation = ProcessRunner.Cancellation()
            running[workstreamID] = cancellation
            defer { running.removeValue(forKey: workstreamID) }

            await updateState(
                for: workstreamID,
                to: .inProgress(step: NSLocalizedString("Reading initialization.yaml", comment: ""), progress: 0)
            )

            let load = Initialization.Config.load(projectDirectory: projectPath)
            let steps = load.steps
            guard !steps.isEmpty else {
                // Only asked when there is nothing to run, because the answer is
                // only ever used to explain that silence — and it parses the
                // project's execution config.
                let stranded = ProcessCompose.Config.locate(projectDirectory: projectPath)?
                    .namespacePresence("bootstrap") == .present
                let note = Initialization.Run.nothingToDoNote(
                    load: load, declaresBootstrapNamespace: stranded
                )
                await updateState(for: workstreamID, to: .completedWithNote(note))
                logger.info("No initialization for \(worktreePath, privacy: .public): \(note, privacy: .public)")
                return
            }

            // Progress crosses back from the worker thread through a stream
            // rather than a `Task` per step, and that is not tidiness.
            // `Task { await updateState(...) }` per report has no ordering
            // against the final `updateState` below, so a late one overwrites
            // `.completed` and the Info row sticks on "Running “assets” (2 of
            // 2)" for a run that finished. A stream is ordered, and `finish()`
            // plus awaiting the consumer is what makes "every progress update
            // has been applied" a thing this method can wait for.
            let (progress, report) = AsyncStream<Initialization.Run.Progress>.makeStream()
            let reporter = Task { [weak self] in
                for await step in progress {
                    await self?.updateState(
                        for: workstreamID,
                        to: .inProgress(step: step.detail, progress: step.fraction)
                    )
                }
            }

            // `ProcessRunner.capture` blocks its thread for each step's whole
            // life, so the loop must not run on the actor. The environment is
            // assembled inside the same hop for the same reason: it reads
            // `ports.yaml` and asks git for the default branch, neither of which
            // the actor should wait on.
            let outcome: Initialization.Run.Outcome = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    // Assembled here rather than inside `Initialization.Run` so
                    // the loop stays free of the project model. Without it a step
                    // would run with none of the `ATELIER_*` or `ports.yaml`
                    // variables the same worktree's terminals see.
                    let environment = ProcessCompose.PhaseEnvironment.childEnvironment(
                        workstreamEnvironment: ProcessCompose.PhaseEnvironment.variables(
                            workstreamID: workstreamID,
                            projectName: projectName,
                            workstreamName: workstreamName,
                            projectDirectory: projectPath,
                            worktreePath: worktreePath,
                            defaultBranch: Git.Operations.defaultBranch(at: projectPath)
                        ),
                        loginPath: CommandLineTools.loginShellPath(shell: CommandBuilder.userShell)
                    )
                    let result = Initialization.Run.drive(
                        steps: steps,
                        isCancelled: { cancellation.cancelled },
                        report: { report.yield($0) },
                        execute: { step in
                            Self.execute(
                                step,
                                worktreePath: worktreePath,
                                environment: environment,
                                cancellation: cancellation
                            )
                        }
                    )
                    continuation.resume(returning: result)
                }
            }

            // Both, in this order, before the final state is published: the
            // stream has to end for the consumer to return, and the consumer has
            // to return for its last `.inProgress` to be known applied.
            report.finish()
            await reporter.value

            let state = Initialization.Run.state(for: outcome)
            await updateState(for: workstreamID, to: state)
            logger.info("Initialization for \(worktreePath, privacy: .public) finished: \(String(describing: state), privacy: .public)")
        }

        /// How much of a failing step's output is kept for the Info row. A setup
        /// step that installs dependencies prints megabytes; the interesting part
        /// is always at the end.
        private static let detailLimit = 600

        /// Run one step's command and say whether it worked.
        ///
        /// **`-lc`, not the `-lic` a verification check gets, and the difference
        /// is the terminal.** A check runs in a Ghostty surface, so `-i` is
        /// honest and is what makes a zsh user's `.zshrc` PATH apply. A step here
        /// has no tty, and an interactive shell without one prints job-control
        /// warnings to stderr before the command runs — which is exactly the
        /// stream a failure's message is read from. The PATH `-i` was there for
        /// arrives another way: `childEnvironment` injects the login shell's own
        /// PATH, which `CommandLineTools.loginShellPath` resolves by asking it
        /// interactively once per launch.
        private static func execute(
            _ step: Initialization.Config.Step,
            worktreePath: String,
            environment: [String: String],
            cancellation: ProcessRunner.Cancellation
        ) -> Initialization.Run.StepResult {
            let shell = CommandBuilder.resolveShell(step.shell) ?? CommandBuilder.userShell
            guard let output = ProcessRunner.capture(
                executable: shell,
                arguments: ["-lc", step.command],
                environment: environment,
                currentDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true),
                timeout: ProcessRunner.Timeout.install,
                cancellation: cancellation
            ) else {
                // nil is the deadline or a shell that would not launch. Both are
                // failures the user has to be told about, and neither has output
                // to quote.
                return .failed(detail: NSLocalizedString(
                    "The command could not be run, or exceeded its deadline.",
                    comment: "initialization: capture returned nil"
                ))
            }
            guard !output.isSuccess else { return .succeeded }

            // stderr first, because that is where a failing command explains
            // itself; stdout is the fallback for the ones that do not.
            let said = output.stderrText.isEmpty ? output.stdoutText : output.stderrText
            let detail = said.isEmpty
                ? String(format: NSLocalizedString(
                    "exited %d with no output", comment: "initialization: a silent failure"
                ), Int(output.status))
                : String(said.suffix(detailLimit))
            return .failed(detail: detail)
        }

        /// Update state and post the notification on the main thread.
        private func updateState(for workstreamID: UUID, to newState: Initialization.State) async {
            states[workstreamID] = newState
            let state = newState
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .initializationStateChanged,
                    object: nil,
                    userInfo: ["workstreamID": workstreamID, "state": state]
                )
            }
        }

        /// Why `cancel` stopped waiting. Reported rather than only logged,
        /// because "initialization stopped" and "we gave up on it" are different
        /// answers to the archive that asked.
        enum CancelOutcome: Equatable {
            /// Nothing was in flight.
            case notRunning
            /// The running step was killed and the run let go.
            case stopped
            /// The task waiting was cancelled.
            case cancelled
            /// Still running when the wait ran out; the archive proceeds anyway.
            case timedOut
        }

        /// Stop an in-flight initialization for this workstream and wait for it
        /// to let go.
        ///
        /// A purge has to do this before it removes the worktree. `git worktree
        /// remove --force` deleting the tree out from under a running `pnpm
        /// install` is the case: the command keeps writing into a directory that
        /// no longer belongs to the repository, and nothing would stop it until
        /// its half-hour deadline.
        ///
        /// Cancelling terminates the step's process *group* — `ProcessRunner`'s
        /// own kill, so a step that backgrounded a server goes with it — which
        /// makes `capture` return and the loop finish as `.cancelled`. The poll
        /// below watches for the `Cancellation` it fired leaving `running`, which
        /// the `defer` in `run` clears, so it observes the real end of the work
        /// rather than the signal.
        ///
        /// **It waits on that run's identity, not on the slot being free**, and
        /// the difference is a new run claiming the slot the moment the old one
        /// lets go — a manual Rerun from the Info tab, or a late
        /// `.workstreamWorktreeReady` racing the purge. Waiting on presence left
        /// this polling a run whose handle it had never fired, for the whole 30s,
        /// and then reporting `.timedOut` for a run that had already finished —
        /// which sent the archive on to `git worktree remove --force` believing
        /// the opposite of the truth. What this method answers is "the run you
        /// asked me to stop has let go", and only identity answers it.
        @discardableResult
        func cancel(for workstreamID: UUID, worktreePath: String) async -> CancelOutcome {
            guard let cancellation = running[workstreamID] else { return .notRunning }
            logger.info("Archive is waiting for initialization of \(worktreePath, privacy: .public)")
            cancellation.cancel()
            // Capped, because a step wedged in a way SIGKILL cannot reach — a
            // process in an uninterruptible kernel wait — must not block the
            // archive forever. Proceeding is then the lesser evil: the user asked
            // for this worktree to go.
            for _ in 0 ..< 300 {
                // `===`, so a run that claimed the slot after this one let go is
                // not mistaken for the one being waited on. It is deliberately
                // not cancelled either: it is nobody's business but its own
                // caller's, and chasing claimants would put the exit condition
                // back on the slot being empty.
                guard running[workstreamID] === cancellation else { return .stopped }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    // Not `try?`: that swallowed `CancellationError`, which makes
                    // every remaining sleep return instantly — so a cancelled wait
                    // spun through all 300 iterations as fast as the CPU allowed.
                    return .cancelled
                }
            }
            logger.warning("Initialization for \(worktreePath, privacy: .public) did not stop; archiving anyway")
            return .timedOut
        }

        /// Test seam. `running` is otherwise only reachable by launching a real
        /// initialization, which needs a worktree and a project that declares
        /// steps.
        ///
        /// Returns the handle it claimed the slot with, because identity is what
        /// `cancel` waits on: a test for the reclaimed-slot race has to be able
        /// to tell the run it cancelled from the one that replaced it.
        @discardableResult
        func _markRunning(_ workstreamID: UUID) -> ProcessRunner.Cancellation {
            let cancellation = ProcessRunner.Cancellation()
            running[workstreamID] = cancellation
            return cancellation
        }

        /// Remove tracked state for a workstream (cleanup after archiving).
        func clearState(for workstreamID: UUID) {
            states.removeValue(forKey: workstreamID)
        }
    }
}
