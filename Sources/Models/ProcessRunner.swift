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
/// **A call occupies exactly one thread: the caller's.** Nothing here hands work
/// to a queue or a pool, so no number of concurrent captures can starve each
/// other — see `PipePump` for what that replaced and why it had to. The
/// consequence for callers is the one the ABOUTME states: the thread is blocked
/// for the child's whole life, so this belongs off the main actor and off any
/// pool whose width is small enough to matter.
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
        /// A project's own test or lint suite. `userCommand` is 300s, which a real
        /// suite exceeds; this exists to break a wedge, not to enforce a pace — the
        /// Verification tab's Stop button is the real escape.
        static let suite: TimeInterval = 1800
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
        standardInput: Data? = nil,
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
        let inPipe = standardInput.map { _ in Pipe() }
        if let inPipe {
            process.standardInput = inPipe
        }

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

        // stdin, stdout and stderr are pumped together, on **this** thread, by
        // one `poll(2)` loop. `PipePump`'s own doc carries the reasoning; the
        // short version is that all three streams have to move concurrently —
        // the child blocks writing to a full pipe while we sit on an empty one,
        // and a payload past the pipe buffer blocks the writer until the child
        // reads — and that a thread this call already owns is the only place
        // that concurrency can live without depending on a thread pool.
        let input: (handle: FileHandle, payload: Data)? = {
            guard let inPipe, let standardInput else { return nil }
            return (inPipe.fileHandleForWriting, standardInput)
        }()

        // One absolute deadline covers the pump and the exit wait below.
        let deadline = DispatchTime.now() + timeout
        guard let pumped = PipePump.run(
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading,
            stdin: input,
            until: deadline
        ) else {
            logger.warning("\(executable, privacy: .public) could not be drained: its pipes could not be opened")
            kill(process)
            return nil
        }

        // EOF on the pipes is not exit: a child can write its output, close both
        // descriptors, and then hang in cleanup. Bound this wait too.
        let finished = pumped.reachedEOF && exited.wait(timeout: deadline) == .success
        guard finished else {
            // Logged, and distinguishable from a plain non-zero exit: a bare nil
            // at the call site is otherwise indistinguishable from "it failed".
            logger.warning(
                "\(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) exceeded its \(timeout, privacy: .public)s deadline; killing it"
            )
            kill(process)
            return nil
        }

        return Output(status: process.terminationStatus, stdout: pumped.stdout, stderr: pumped.stderr)
    }

    /// Runs `executable` and returns its stdout, or nil if it could not be
    /// launched, exited non-zero, or outlived `timeout`.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval
    ) -> Data? {
        guard let output = capture(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            standardInput: standardInput,
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
        standardInput: Data? = nil,
        timeout: TimeInterval
    ) -> Bool {
        capture(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            standardInput: standardInput,
            timeout: timeout
        )?.isSuccess ?? false
    }

    /// SIGTERM, then SIGKILL if anything is still alive after the grace period.
    ///
    /// Signals the process *group*, not only the child. `Process` spawns each
    /// child as its own group leader — `pgid == pid`, measured, not assumed —
    /// and a grandchild the child backgrounds inherits that group. So for a
    /// command shaped like `sh -c 'server &'`, which is an ordinary thing for a
    /// project's own command to be, the shell has exited and been reaped long
    /// before the deadline fires: `terminate()` has nothing left to signal, and
    /// the server goes on running and holding the pipe. The group is the only
    /// handle left on it.
    ///
    /// Signalling a group whose leader has already been reaped is safe because
    /// the kernel will not reissue a pid that is still live as a group id.
    /// Measured rather than recalled, because the failure mode if it were wrong
    /// is signalling a stranger's process group: a group was orphaned, then
    /// ~98,000 forks drove the pid counter a full lap past it, and the number
    /// was never allocated. When the group is empty the signal fails with
    /// ESRCH and nothing happens.
    ///
    /// A daemon is still out of reach, and deliberately so — anything that
    /// calls `setsid` leaves the group by definition. That is the behaviour you
    /// want: the tmux server is exactly such a child (verified — it lands in
    /// its own group and survives this), and it is meant to outlive the client
    /// command that started it.
    private static func kill(_ process: Process) {
        let pid = process.processIdentifier
        // `kill` reads a non-positive pid as "my own group" (0) or "everything
        // I may signal" (-1), and a `Process` that never launched reports 0.
        // This guard is the difference between killing a child and killing
        // Atelier.
        guard pid > 1 else { return }

        // `terminate()` first, so Foundation's own bookkeeping runs. While the
        // child is alive it already reaches the group; the explicit group
        // signal is for the case it cannot, where only an orphan is left.
        process.terminate()
        Foundation.kill(-pid, SIGTERM)

        let deadline = Date().addingTimeInterval(terminationGrace)
        while process.isRunning || groupIsAlive(pid), Date() < deadline {
            usleep(20000)
        }
        if process.isRunning {
            Foundation.kill(pid, SIGKILL)
        }
        Foundation.kill(-pid, SIGKILL)
        process.waitUntilExit()
    }

    /// Whether any process is left in `pid`'s group. Signal 0 asks whether a
    /// signal *could* be delivered without delivering one.
    private static func groupIsAlive(_ pid: pid_t) -> Bool {
        Foundation.kill(-pid, 0) == 0
    }

    /// Moves a child's three pipes at once, on the **calling** thread, until both
    /// output streams reach EOF and any payload has been written — or until the
    /// deadline passes.
    ///
    /// All three have to move concurrently, and each for its own reason. Reading
    /// stdout to EOF while stderr fills is a deadlock: the child blocks writing
    /// to a full pipe while the reader blocks on an empty one. `git fetch --all
    /// --prune` on a fresh bare clone prints a " * [new branch]" line per branch
    /// to *stderr*, hundreds of KB against a 16-64 KB pipe buffer, so this is
    /// routine rather than exotic. And a payload past that same buffer blocks
    /// the writer until the child reads it, so stdin cannot be written by a
    /// thread that afterwards waits for the child.
    ///
    /// **What is deliberate here is that none of that concurrency costs a
    /// thread.** Two earlier shapes both bought it with threads, and both
    /// starved a pool:
    ///
    /// - `readDataToEndOfFile()` on two dispatch threads parked both of them for
    ///   good whenever a grandchild held the write end open — EOF is not the
    ///   child's to give, and `sh -c 'server &'` is an ordinary thing for a
    ///   project's own command to be. At two per call against libdispatch's
    ///   ~64-thread global pool, a few dozen such calls starved it.
    /// - Replacing those with `DispatchSource` read sources fixed the *leak* but
    ///   not the dependency: the waiter still blocked a thread while the source's
    ///   event handler needed one of its own to deliver EOF. When the callers are
    ///   Swift `Task`s the pool in question is the cooperative one, `hw.ncpu`
    ///   wide rather than 64, and the waiters consumed the very threads that
    ///   would have completed them. Measured in the shipped app: 14 of 14
    ///   cooperative threads parked in `capture`, every child killed at its
    ///   deadline — `tmux -V` among them, which is the tell, since nothing about
    ///   that child is slow.
    ///
    /// `poll(2)` on the calling thread has no such failure mode to have. The
    /// thread doing the waiting is the thread doing the reading, it is one the
    /// caller already owns, and no pool is consulted at any point — so this is
    /// immune by construction rather than by having enough threads.
    ///
    /// The descriptors belong to the `Pipe`s that own them and are never closed
    /// here, with one exception: the stdin write end, whose close is what gives
    /// the child EOF. Without it a child like `cat` never exits and only the
    /// deadline ends the call.
    private enum PipePump {
        struct Result {
            var stdout = Data()
            var stderr = Data()
            /// Both output streams reached EOF, and any payload was written,
            /// inside the deadline.
            var reachedEOF = false
        }

        /// One pipe buffer's worth, so a readable descriptor is usually emptied
        /// in a single `read`.
        private static let bufferSize = 64 * 1024

        /// Pumps until EOF on both output streams or `deadline`, whichever comes
        /// first. Nil only when a descriptor could not be prepared, which is a
        /// different failure from a deadline and is reported as one.
        static func run(
            stdout outHandle: FileHandle,
            stderr errHandle: FileHandle,
            stdin input: (handle: FileHandle, payload: Data)?,
            until deadline: DispatchTime
        ) -> Result? {
            let outFD = outHandle.fileDescriptor
            let errFD = errHandle.fileDescriptor
            let inFD = input?.handle.fileDescriptor
            guard makeNonBlocking(outFD), makeNonBlocking(errFD),
                  inFD.map(makeNonBlocking) ?? true
            else { return nil }
            if let inFD {
                // A child that exits without reading leaves the write below with
                // nowhere to go. Ask for EPIPE rather than SIGPIPE, whose default
                // disposition would take the app down with it.
                _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
            }

            var result = Result()
            var outOpen = true
            var errOpen = true
            var inOpen = inFD != nil
            var writeOffset = 0
            let payload = input.map { [UInt8]($0.payload) } ?? []
            var scratch = [UInt8](repeating: 0, count: bufferSize)

            func closeInput() {
                inOpen = false
                if let handle = input?.handle {
                    try? handle.close()
                }
            }
            // Nothing to send: the child still needs the EOF.
            if inOpen, payload.isEmpty {
                closeInput()
            }

            while outOpen || errOpen || inOpen {
                guard let remaining = millisecondsRemaining(until: deadline) else { return result }

                var fds: [pollfd] = []
                if outOpen {
                    fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0))
                }
                if errOpen {
                    fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0))
                }
                if inOpen, let inFD {
                    fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0))
                }

                let ready = poll(&fds, nfds_t(fds.count), remaining)
                if ready < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return result
                }
                // Zero is the deadline; `result` carries whatever arrived first.
                if ready == 0 {
                    return result
                }

                // `revents` is checked rather than `POLLIN`/`POLLOUT` alone: a
                // hangup arrives as `POLLHUP`, often alongside data still sitting
                // in the pipe, so the only honest test is to attempt the transfer
                // and let `read`/`write` say what is left.
                for entry in fds where entry.revents != 0 {
                    switch entry.fd {
                    case outFD:
                        outOpen = drain(entry.fd, into: &result.stdout, scratch: &scratch)
                    case errFD:
                        errOpen = drain(entry.fd, into: &result.stderr, scratch: &scratch)
                    default:
                        let written = payload.withUnsafeBytes { buffer in
                            write(
                                entry.fd,
                                buffer.baseAddress!.advanced(by: writeOffset),
                                payload.count - writeOffset
                            )
                        }
                        if written > 0 {
                            writeOffset += written
                            if writeOffset == payload.count {
                                closeInput()
                            }
                        } else if written < 0, errno != EINTR, errno != EAGAIN {
                            // EPIPE and friends: there is nowhere left to put the
                            // payload, which is the child's business and not a
                            // failure of this call.
                            closeInput()
                        }
                    }
                }
            }

            result.reachedEOF = true
            return result
        }

        /// Reads everything currently available. Returns whether the stream is
        /// still open — false on EOF or on an error there is no recovering from.
        private static func drain(_ fd: Int32, into data: inout Data, scratch: inout [UInt8]) -> Bool {
            while true {
                let count = scratch.withUnsafeMutableBytes { buffer in
                    read(fd, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    data.append(contentsOf: scratch.prefix(count))
                    continue
                }
                if count == 0 {
                    // EOF: the last holder of the write end let go.
                    return false
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    // Drained for now; `poll` says when more lands. EWOULDBLOCK
                    // is the same value on Darwin.
                    return true
                default:
                    return false
                }
            }
        }

        /// The descriptor must not block: `poll` promises only that *some* bytes
        /// are readable, and a blocking read asking for a whole buffer would park
        /// the one thread this type exists to keep moving.
        private static func makeNonBlocking(_ fd: Int32) -> Bool {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0 else { return false }
            return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
        }

        /// Whole milliseconds left, rounded up so a sub-millisecond remainder
        /// still polls once rather than degenerating into a spin. Nil once the
        /// deadline has passed.
        private static func millisecondsRemaining(until deadline: DispatchTime) -> Int32? {
            let now = DispatchTime.now().uptimeNanoseconds
            let end = deadline.uptimeNanoseconds
            guard end > now else { return nil }
            return Int32(clamping: (end - now + 999_999) / 1_000_000)
        }
    }
}
