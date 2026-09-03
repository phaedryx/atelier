// ABOUTME: Runs a child process with a hard deadline and returns its output.
// ABOUTME: Blocks the calling thread — call it off the main actor.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "process")

/// A `Process` wrapper that cannot hang the caller.
///
/// `Process.readDataToEndOfFile()` followed by `waitUntilExit()` blocks
/// forever if the child hangs — or if the child exits while a grandchild
/// still holds the write end of the pipe. Anything polling on a timer needs
/// a deadline instead, or one wedged child stalls every later call.
///
/// Two spawn sites deliberately stay outside this type, and say so where they
/// spawn: `BareRepoClone.run` and `QuickAction.Runner.runShellCommand`. Both run
/// work with no honest deadline — a clone, or the user's own command — and both
/// already offer the better answer, a cancellation the user drives. Everything
/// else that spawns a child goes through here.
enum ProcessRunner {
    /// How long to let a terminated child wind down before escalating to SIGKILL.
    private static let terminationGrace: TimeInterval = 2

    /// Deadline tiers. Named rather than inline so the choice at each call site
    /// is reviewable, and so "this is slow" can be fixed in one place.
    enum Timeout {
        /// Commands that only touch the local filesystem: git plumbing that
        /// reads, tmux bookkeeping, `--version` probes. Not for anything that
        /// writes a whole working tree — that scales with the user's repository.
        static let local: TimeInterval = 60
        /// Anything that can reach the network — fetch, pull, push, `gh`.
        /// Generous, because a slow link is not a hang.
        static let network: TimeInterval = 120
        /// Work whose size the user controls: a command from their own
        /// repository (`docker compose down`), or a copy of a directory they
        /// chose. Long by nature, so the bound only catches a true wedge.
        static let userCommand: TimeInterval = 300
        /// Dependency installs. A cold `npm install` on a large repository is
        /// legitimately minutes, so this is the loosest bound there is — it
        /// exists to break a wedge, not to enforce a pace.
        static let install: TimeInterval = 1800
    }

    /// A finished child: its exit status and both streams.
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var isSuccess: Bool {
            status == 0
        }

        /// stdout as trimmed UTF-8. Undecodable bytes yield an empty string.
        var stdoutText: String {
            String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        /// stderr as trimmed UTF-8. Undecodable bytes yield an empty string.
        var stderrText: String {
            String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Runs `executable` and returns its status and both streams, or nil if it
    /// could not be launched or outlived `timeout`.
    ///
    /// Use this when a failure's stderr matters. When only stdout-on-success
    /// does, `run` is the narrower form.
    static func capture(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Set before `run()`: this is the only way to wait on exit with a
        // deadline, since `waitUntilExit()` takes none.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            logger.warning("\(executable, privacy: .public) failed to launch: \(error, privacy: .public)")
            return nil
        }

        // Both pipes drain CONCURRENTLY, each on its own thread. Reading one to
        // EOF — which only happens when the child exits — while the other fills
        // is a deadlock: the child blocks writing to a full pipe while we block
        // reading the empty one. This is not hypothetical; `git fetch --all
        // --prune` on a fresh bare clone prints a " * [new branch]" line per
        // branch to *stderr*, hundreds of KB against a 16-64 KB pipe buffer.
        // Draining on separate threads is also what makes the deadline below
        // enforceable: the read is what blocks, not the wait.
        let outBox = DataBox()
        let errBox = DataBox()
        let outDrained = DispatchSemaphore(value: 0)
        let errDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            outBox.store(outPipe.fileHandleForReading.readDataToEndOfFile())
            outDrained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            errBox.store(errPipe.fileHandleForReading.readDataToEndOfFile())
            errDrained.signal()
        }

        // One absolute deadline covers all three waits. A drain thread may still
        // be parked on a pipe a grandchild holds open; it is abandoned rather
        // than waited on — leaking one thread beats wedging the caller. Neither
        // box is read on a failure path.
        let deadline = DispatchTime.now() + timeout
        let finished = outDrained.wait(timeout: deadline) == .success
            && errDrained.wait(timeout: deadline) == .success
            // EOF on the pipes is not exit: a child can write its output, close
            // both descriptors, and then hang in cleanup. Bound this wait too.
            && exited.wait(timeout: deadline) == .success
        guard finished else {
            // Logged, and distinguishable from a plain non-zero exit: a bare nil
            // at the call site is otherwise indistinguishable from "it failed".
            logger.warning(
                "\(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) exceeded its \(timeout, privacy: .public)s deadline; killing it"
            )
            kill(process)
            return nil
        }

        return Output(status: process.terminationStatus, stdout: outBox.take(), stderr: errBox.take())
    }

    /// Runs `executable` and returns its stdout, or nil if it could not be
    /// launched, exited non-zero, or outlived `timeout`.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) -> Data? {
        guard let output = capture(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: timeout
        ), output.isSuccess else { return nil }
        return output.stdout
    }

    /// Runs `executable` for its side effects, returning whether it exited zero.
    @discardableResult
    static func succeeds(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) -> Bool {
        capture(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: timeout
        )?.isSuccess ?? false
    }

    /// SIGTERM, then SIGKILL if the child is still alive after the grace period.
    private static func kill(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(terminationGrace)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        if process.isRunning {
            Foundation.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Handoff for a stream captured on a drain thread. Mirrors the locked-box
    /// pattern in `CommandLineTools`.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            defer { lock.unlock() }
            data = value
        }

        func take() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
