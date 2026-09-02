// ABOUTME: Runs a headless process-compose phase and waits for it to finish.
// ABOUTME: Used for bootstrap at worktree creation and dispose at archive.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "phase-executor")

/// Runs one process-compose namespace to completion and reports whether the
/// work in it actually succeeded.
///
/// The hard part is that last clause. `process-compose up` exits 0 whatever its
/// processes did, unless the config opts each one into `availability.restart:
/// exit_on_failure` or `exit_on_end` — so a bootstrap whose `pnpm install`
/// failed would look identical to one that worked, and the built-in setup
/// sequence this replaces *did* report that failure. The exit code alone is
/// therefore not enough.
///
/// `--keep-project` is what makes it enough: the control server stays up after
/// every process has finished, so their real exit codes can be read from
/// `GET /processes` before it is shut down. That turns the run into: spawn,
/// poll until nothing is pending or running, collect exit codes, shut down.
enum PhaseExecutor {
    enum Outcome: Equatable {
        case succeeded
        /// The phase ran and something in it failed. Carries whatever the
        /// output said, because a bare exit code tells the user nothing.
        case failed(String)
        /// Nothing to do — the config has no processes in this namespace.
        case skipped
    }

    /// How much of the tail of a phase's output is kept for a failure message.
    /// A bootstrap that installs dependencies prints megabytes; the interesting
    /// part is always at the end.
    private static let detailLimit = 2000

    /// Gap between `GET /processes` calls. Short enough that a fast bootstrap is
    /// not padded, long enough that a slow one is not a busy-wait.
    private static let pollInterval: TimeInterval = 0.2

    /// How long an unparseable config's namespace may report zero processes
    /// before it is called empty. Only applies when the YAML could not be read,
    /// so this grace is the only evidence available; see `run`.
    private static let emptyNamespaceGrace: TimeInterval = 5

    /// How long to wait for the spawned `up` to notice `down` and exit.
    private static let shutdownGrace: TimeInterval = 15

    /// Statuses that mean a process has not reached its end yet. Written as a
    /// list of the *unfinished* states rather than the finished ones on
    /// purpose: a status this list has never heard of is far more likely to be
    /// a new terminal state than a new pending one, and `isRunning` already
    /// covers anything actually executing. Erring the other way would make a
    /// future process-compose poll to the deadline and report a timeout for a
    /// run that finished.
    private static let unfinishedStatuses: Set<String> = [
        "Pending", "Launching", "Running", "Restarting", "Terminating",
    ]

    /// Run one namespace to completion.
    ///
    /// - Parameter environment: the workstream's own variables — `ATELIER_*`
    ///   and everything `ports.yaml` declares. No default value: a call site
    ///   that omitted them would run the project's own YAML under an
    ///   environment the interactive phases of the same file never see, which
    ///   is the bug `PhaseEnvironment` exists to close.
    /// - Parameter timeout: how long the processes themselves get. It bounds
    ///   the spawned command and the poll loop, and nothing else. Both
    ///   `shutDown` calls sit outside it — the pre-spawn one before the clock
    ///   starts, the post-poll one after — and each is bounded by
    ///   `Timeout.local`, so with `shutdownGrace` the wall-clock worst case
    ///   from entry is `timeout` + 135s. Capped at
    ///   `ProcessRunner.Timeout.userCommand` when the config could not be
    ///   parsed, because then it is not known that the namespace exists at all,
    ///   and process-compose does not exit when told to run one that does
    ///   not — it idles.
    static func run(
        phase: ProcessComposePhase,
        config: ProcessComposeConfig,
        binary: String,
        workstreamID: UUID,
        workingDirectory: String,
        environment: [String: String],
        timeout: TimeInterval
    ) -> Outcome {
        let presence = config.namespacePresence(phase.namespace)
        // Nothing declared: return without spawning anything. This is the
        // cheap path and also the safe one — `up -n` on a namespace with no
        // processes never exits.
        if presence == .empty {
            return .skipped
        }

        // `.unknown` means Yams could not decode a file process-compose might
        // still accept. The phase runs, because refusing would silently skip
        // work the project may really have declared, but on a shorter leash and
        // with the empty-namespace check below as the way out.
        let budget = presence == .unknown ? min(timeout, ProcessRunner.Timeout.userCommand) : timeout

        guard let shellPath = CommandLineTools.path(for: "zsh") ?? CommandLineTools.path(for: "bash") else {
            logger.warning("No shell found to run \(phase.namespace, privacy: .public)")
            return .failed(NSLocalizedString("No shell was available to run the phase.", comment: ""))
        }

        PhaseRunner.ensureSocketDirectory()
        let socketPath = PhaseRunner.socketPath(for: workstreamID, phase: phase)
        // An earlier run that was killed rather than shut down can leave both a
        // socket file and, worse, the server behind it. process-compose rebinds
        // over the file rather than refusing, which would strand that server
        // unreachable, so ask it to leave first.
        shutDown(binary: binary, socketPath: socketPath, workingDirectory: workingDirectory)

        let command = PhaseRunner.command(
            phase: phase, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: [], keepProject: true
        )
        // zsh or bash with `-c`, not `$SHELL -lic`: `PhaseRunner.command` quotes
        // with POSIX rules, which fish cannot parse, and an interactive shell
        // mixes its greeting into the output this reports on failure. The login
        // PATH is injected instead, so the phase's own processes still find
        // tools installed by version managers — a GUI app inherits only
        // launchd's minimal PATH.
        let childEnv = childEnvironment(
            workstreamEnvironment: environment,
            loginPath: CommandLineTools.loginShellPath(shell: CommandBuilder.userShell)
        )

        // `capture` on its own thread rather than a bare `Process`: with
        // `--keep-project` the child only exits once it is told to, so the
        // caller cannot simply wait on it — but `ProcessRunner` still enforces
        // `budget` as a hard kill, which is what bounds the orphan window if
        // shutdown does not take.
        let finished = DispatchSemaphore(value: 0)
        let captured = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            captured.store(ProcessRunner.capture(
                executable: shellPath,
                arguments: ["-c", command],
                environment: childEnv,
                currentDirectory: URL(fileURLWithPath: workingDirectory),
                timeout: budget
            ))
            finished.signal()
        }

        let poll = pollToCompletion(
            socketPath: socketPath,
            presence: presence,
            deadline: Date().addingTimeInterval(budget),
            upFinished: finished
        )

        shutDown(binary: binary, socketPath: socketPath, workingDirectory: workingDirectory)
        // Best effort. If the child ignores `down`, `capture`'s own deadline
        // kills it; the window is bounded by `budget`, not open-ended.
        if finished.wait(timeout: .now() + shutdownGrace) == .timedOut {
            logger.warning("\(phase.namespace, privacy: .public) did not exit after down; it will be killed at its deadline")
        }

        return outcome(for: phase, poll: poll, output: captured.take())
    }

    // MARK: - Environment

    /// The child's environment, in three layers: the app's own, then the
    /// workstream's variables, then the login `PATH`.
    ///
    /// The order is the whole content. The workstream's variables go *over* the
    /// inherited ones, so a `ports.yaml` that declares `ATELIER_PORT` means what
    /// the project says rather than what the app happened to launch with. `PATH`
    /// goes last and unconditionally, because it is the one variable the
    /// workstream layer must not be able to set: a phase whose PATH came from a
    /// declaration would resolve tools from somewhere the user never chose, and
    /// nothing in `WorkstreamEnvironment` produces a `PATH` for it to have meant.
    ///
    /// Internal, and taking its base environment as a parameter, so the layering
    /// can be tested without spawning anything or reading the host's real
    /// environment.
    static func childEnvironment(
        workstreamEnvironment: [String: String],
        loginPath: String?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        environment.merge(workstreamEnvironment) { _, workstream in workstream }
        if let loginPath {
            environment["PATH"] = loginPath
        }
        return environment
    }

    // MARK: - Polling

    /// What the poll loop concluded before shutdown.
    ///
    /// Internal rather than private, with `outcome(for:poll:output:)`, so the
    /// mapping from evidence to report can be tested directly. Reporting a
    /// successful phase as a failure is the bug this whole round exists to fix,
    /// and it lives entirely in that mapping.
    enum PollResult: Equatable {
        /// Every process in the namespace reached a terminal state. Carries the
        /// ones that ended badly, in the order the API reported them.
        case finished([(name: String, exitCode: Int)])
        /// The server never appeared, or went away. Either the project shut
        /// itself down (`restart: exit_on_failure` does exactly this, even with
        /// `--keep-project`), or `up` never got far enough to listen. The
        /// spawned command's own exit status decides.
        case serverGone
        /// The config could not be parsed and the running project turned out to
        /// declare nothing in this namespace after all.
        case namespaceEmpty
        /// The budget ran out with work still in flight.
        case timedOut

        static func == (lhs: PollResult, rhs: PollResult) -> Bool {
            switch (lhs, rhs) {
            case let (.finished(l), .finished(r)):
                l.count == r.count && zip(l, r).allSatisfy { $0.name == $1.name && $0.exitCode == $1.exitCode }
            case (.serverGone, .serverGone), (.namespaceEmpty, .namespaceEmpty), (.timedOut, .timedOut):
                true
            default:
                false
            }
        }
    }

    private static func pollToCompletion(
        socketPath: String,
        presence: ProcessComposeConfig.NamespacePresence,
        deadline: Date,
        upFinished: DispatchSemaphore
    ) -> PollResult {
        let client = ProcessComposeClient(socketPath: socketPath)
        var sawServer = false
        var firstEmptyReading: Date?

        while Date() < deadline {
            // Checked every pass, before the request: a config error or a
            // refused bind makes `up` exit at once and no socket ever appears,
            // and waiting out the whole budget for that would turn the fastest
            // failure there is into the slowest.
            if upFinished.wait(timeout: .now()) == .success {
                upFinished.signal()
                if !sawServer {
                    return .serverGone
                }
            }

            guard let processes = try? client.processesSync() else {
                // Before the server is up this is just "not yet"; after it has
                // answered once, it means the project ended on its own.
                if sawServer {
                    return .serverGone
                }
                Thread.sleep(forTimeInterval: pollInterval)
                continue
            }
            sawServer = true

            if processes.isEmpty {
                // Only trusted when the YAML gave no answer. A `.present`
                // config has already said the namespace has processes, so an
                // empty list is a contradiction, not evidence — treating it as
                // "done" would silently run nothing, which is the exact failure
                // the namespace check exists to prevent.
                guard presence == .unknown else {
                    Thread.sleep(forTimeInterval: pollInterval)
                    continue
                }
                let since = firstEmptyReading ?? Date()
                firstEmptyReading = since
                if Date().timeIntervalSince(since) >= emptyNamespaceGrace {
                    return .namespaceEmpty
                }
                Thread.sleep(forTimeInterval: pollInterval)
                continue
            }
            firstEmptyReading = nil

            let unfinished = processes.contains { $0.isRunning || unfinishedStatuses.contains($0.status) }
            if !unfinished {
                return .finished(processes.filter { $0.exitCode != 0 }.map { ($0.name, $0.exitCode) })
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return .timedOut
    }

    // MARK: - Reporting

    static func outcome(
        for phase: ProcessComposePhase,
        poll: PollResult,
        output: ProcessRunner.Output?
    ) -> Outcome {
        switch poll {
        case .namespaceEmpty:
            return .skipped

        case .timedOut:
            logger.warning("\(phase.namespace, privacy: .public) exceeded its deadline")
            return .failed(String(
                format: NSLocalizedString("The %@ phase did not finish in time.", comment: ""),
                phase.namespace
            ))

        case let .finished(failures):
            guard failures.isEmpty else {
                return report(phase: phase, failures: failures, output: output)
            }
            // The poll is the authoritative evidence here: it watched every
            // process in the namespace reach a terminal state with exit code
            // zero. A nil `output` at this point means only that `down` did not
            // land inside `shutdownGrace` — reporting that as "did not finish in
            // time" would call a bootstrap that demonstrably succeeded a
            // failure. So a missing status is ignored, and only a status that
            // actually says something (process-compose refusing the config,
            // say) can overturn the poll.
            guard let output, !output.isSuccess else { return .succeeded }
            return report(phase: phase, failures: [], output: output)

        case .serverGone:
            // The project shut itself down before, or instead of, answering.
            // `restart: exit_on_failure` does this and propagates the code, so
            // the command's own status is the whole of what is known.
            return spawnFailure(phase: phase, output: output) ?? .succeeded
        }
    }

    /// A failure derived from the spawned command, or nil if it exited cleanly.
    ///
    /// Only used where the command's status is the *only* evidence there is —
    /// the server went away before it could be asked. Where the poll saw the
    /// processes finish, it outranks this.
    private static func spawnFailure(phase: ProcessComposePhase, output: ProcessRunner.Output?) -> Outcome? {
        guard let output else {
            return .failed(String(
                format: NSLocalizedString("The %@ phase did not finish in time.", comment: ""),
                phase.namespace
            ))
        }
        guard !output.isSuccess else { return nil }
        return report(phase: phase, failures: [], output: output)
    }

    /// Name what failed, then show the tail of the output that explains it.
    private static func report(
        phase: ProcessComposePhase,
        failures: [(name: String, exitCode: Int)],
        output: ProcessRunner.Output?
    ) -> Outcome {
        var lines: [String] = failures.map {
            String(
                format: NSLocalizedString("%1$@ exited with code %2$d.", comment: ""),
                $0.name, $0.exitCode
            )
        }
        if let text = output.map(Self.detail(from:)), !text.isEmpty {
            lines.append(text)
        }
        let message = lines.isEmpty
            ? String(format: NSLocalizedString("%@ failed.", comment: ""), phase.namespace)
            : lines.joined(separator: "\n")
        logger.warning("\(phase.namespace, privacy: .public) failed: \(message, privacy: .public)")
        return .failed(message)
    }

    /// The tail of whichever stream said something, cleaned up enough to show.
    private static func detail(from output: ProcessRunner.Output) -> String {
        // process-compose writes every process's output to its own stdout,
        // including what the process sent to stderr, and keeps its stderr for
        // its own errors — so stdout is the usual source here.
        let text = output.stderrText.isEmpty ? output.stdoutText : output.stderrText
        let stripped = stripTerminalEscapes(text)
        guard stripped.count > detailLimit else { return stripped }
        return "…" + stripped.suffix(detailLimit)
    }

    /// Drop ANSI escape sequences. process-compose sets the terminal title even
    /// with the TUI disabled, so its output starts with an OSC sequence that
    /// would otherwise be pasted into an error message verbatim.
    private static func stripTerminalEscapes(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}", let introducer = iterator.next() else {
                if character != "\u{1B}" {
                    result.append(character)
                }
                continue
            }
            switch introducer {
            case "]":
                // OSC: arbitrary text until BEL, or until a string terminator
                // (ESC followed by one more byte).
                while let next = iterator.next() {
                    if next == "\u{07}" {
                        break
                    }
                    if next == "\u{1B}" {
                        _ = iterator.next()
                        break
                    }
                }
            case "[":
                // CSI: parameter bytes, then exactly one final byte in @–~.
                while let next = iterator.next(), !("@" ... "~").contains(next) {
                    continue
                }
            default:
                // A two-character escape; the introducer is the whole of it.
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shutdown

    /// Ask the server on this socket to stop, and clear the path either way.
    ///
    /// Called before spawning as well as after, because the state this cleans
    /// up is exactly what a killed run leaves behind. A failure is expected and
    /// unremarkable — most of the time there is nothing listening.
    static func shutDown(binary: String, socketPath: String, workingDirectory: String) {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        _ = ProcessRunner.capture(
            executable: binary,
            arguments: ["down", "-u", socketPath],
            currentDirectory: URL(fileURLWithPath: workingDirectory),
            timeout: ProcessRunner.Timeout.local
        )
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Stop every phase server this user has left listening.
    ///
    /// `up --keep-project` outlives its processes on purpose — that is how the
    /// poll can read a final exit code — so a run that is never shut down
    /// leaves a server holding the worktree's ports until its deadline. Quit
    /// used to kill tmux only, so quitting mid-run stranded one per phase.
    ///
    /// Bounded and concurrent because this runs as the app is terminating: a
    /// serial sweep of N sockets at `Timeout.local` each would visibly hang
    /// quit. Anything still listening after the cap is left to its own
    /// deadline, which is the situation before this existed.
    static func stopAllServers(binary: String, timeout: TimeInterval = 3) {
        let directory = PhaseRunner.socketDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let sockets = names.filter { $0.hasSuffix(".sock") }.map { directory.appendingPathComponent($0).path }
        guard !sockets.isEmpty else { return }

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for socket in sockets {
            group.enter()
            queue.async {
                defer { group.leave() }
                // The working directory only has to exist; `down` addresses the
                // server by socket.
                shutDown(
                    binary: binary,
                    socketPath: socket,
                    workingDirectory: FileManager.default.temporaryDirectory.path
                )
            }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Handoff for the spawned command's result, written on one thread and read
    /// on another. Mirrors `ProcessRunner`'s own locked box.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProcessRunner.Output?

        func store(_ output: ProcessRunner.Output?) {
            lock.lock()
            defer { lock.unlock() }
            value = output
        }

        func take() -> ProcessRunner.Output? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
