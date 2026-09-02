// ABOUTME: Runs a headless process-compose phase and waits for it to finish.
// ABOUTME: Used for bootstrap at worktree creation and dispose at archive.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "phase-executor")

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

    /// Run one namespace to completion.
    ///
    /// process-compose exits on its own once every process in the namespace has
    /// finished, so this is a bounded wait rather than a supervised session.
    ///
    /// **The exit code only reports a failure when the config asks it to.**
    /// `process-compose up` exits 0 even when a process in the namespace exits
    /// non-zero, unless that process sets `availability.restart:
    /// exit_on_failure` or `availability.exit_on_end: true`. There is no
    /// after-the-fact query — the server dies with the run — so a project that
    /// wants a broken bootstrap reported has to say so in its own YAML.
    /// `PhaseExecutorTests` pins both halves of this.
    static func run(
        phase: ProcessComposePhase,
        config: ProcessComposeConfig,
        binary: String,
        workstreamID: UUID,
        workingDirectory: String,
        timeout: TimeInterval
    ) -> Outcome {
        // Asked to run a namespace it declares nothing for, process-compose does
        // not exit — it idles forever — so this check is what keeps the phase
        // bounded, not just tidy. It fails open (a config that cannot be read or
        // parsed counts as "not empty") so a parse bug can never silently skip a
        // phase the project really declared; the cost of failing open here is
        // that such a config idles until `timeout`, reported as a timeout.
        guard !config.namespaceIsConfidentlyEmpty(phase.namespace) else {
            return .skipped
        }

        // zsh or bash with `-c`, not `$SHELL -lic`: `PhaseRunner.command` quotes
        // with POSIX rules, which fish cannot parse, and an interactive shell
        // mixes its greeting into the output this reports on failure. The login
        // PATH is injected instead, so the phase's own processes still find
        // tools installed by version managers — a GUI app inherits only
        // launchd's minimal PATH.
        guard let shellPath = CommandLineTools.path(for: "zsh") ?? CommandLineTools.path(for: "bash") else {
            logger.warning("No shell found to run \(phase.namespace, privacy: .public)")
            return .failed(NSLocalizedString("No shell was available to run the phase.", comment: ""))
        }
        var environment: [String: String]?
        if let resolvedPath = CommandLineTools.loginShellPath(shell: CommandBuilder.userShell) {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = resolvedPath
            environment = env
        }

        PhaseRunner.ensureSocketDirectory()
        let command = PhaseRunner.command(
            phase: phase, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        // `capture` rather than `run`: `run` returns stdout and nil on any
        // failure, which cannot distinguish a timeout from a non-zero exit, and
        // discards stderr.
        let output = ProcessRunner.capture(
            executable: shellPath,
            arguments: ["-c", command],
            environment: environment,
            currentDirectory: URL(fileURLWithPath: workingDirectory),
            timeout: timeout
        )

        guard let output else {
            logger.warning("\(phase.namespace, privacy: .public) exceeded its deadline")
            return .failed(String(
                format: NSLocalizedString("The %@ phase did not finish in time.", comment: ""),
                phase.namespace
            ))
        }
        guard output.isSuccess else {
            // process-compose writes every process's output to its own stdout,
            // including what the process sent to stderr, and keeps its stderr
            // for its own errors — so stdout is the usual source here.
            let detail = detail(from: output)
            logger.warning("\(phase.namespace, privacy: .public) failed: \(detail, privacy: .public)")
            return .failed(detail.isEmpty
                ? String(format: NSLocalizedString("%@ failed.", comment: ""), phase.namespace)
                : detail)
        }
        return .succeeded
    }

    /// The tail of whichever stream said something, cleaned up enough to show.
    private static func detail(from output: ProcessRunner.Output) -> String {
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
                if character != "\u{1B}" { result.append(character) }
                continue
            }
            switch introducer {
            case "]":
                // OSC: arbitrary text until BEL, or until a string terminator
                // (ESC followed by one more byte).
                while let next = iterator.next() {
                    if next == "\u{07}" { break }
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
}
