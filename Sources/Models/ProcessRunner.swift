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

        // Written on its own thread for the same reason the two output streams
        // drain concurrently below: a payload past the pipe buffer blocks the
        // writer until the child reads it, so writing here — on the thread that
        // goes on to wait for exit — deadlocks against a child that has not
        // started reading yet. Closing the handle is what gives the child EOF;
        // without it a child like `cat` never exits and only the deadline ends
        // the call.
        //
        // Still abandoned rather than waited on, and deliberately not rewritten
        // the way the read side below was. A child that never reads a payload
        // larger than the pipe buffer parks this thread for good — the same
        // shape of leak — but it takes a call site passing more than 64 KB to a
        // child that ignores it, and every `standardInput` today is a hook
        // payload of a few kilobytes. The read side had no such precondition:
        // it parked two threads per call for a reason entirely outside the call
        // site's control, which is what made it worth the machinery.
        if let inPipe, let standardInput {
            DispatchQueue.global(qos: .utility).async {
                let handle = inPipe.fileHandleForWriting
                // A child that exits without reading its input leaves this
                // write with nowhere to go; EPIPE arrives as an ObjC exception
                // through `write(contentsOf:)`, which would tear down the app.
                try? handle.write(contentsOf: standardInput)
                try? handle.close()
            }
        }

        // Both pipes drain CONCURRENTLY. Reading one to EOF while the other
        // fills is a deadlock: the child blocks writing to a full pipe while we
        // block reading the empty one. This is not hypothetical; `git fetch
        // --all --prune` on a fresh bare clone prints a " * [new branch]" line
        // per branch to *stderr*, hundreds of KB against a 16-64 KB pipe
        // buffer. Draining concurrently is also what makes the deadline below
        // enforceable: the read is what blocks, not the wait.
        //
        // They drain on dispatch *sources* rather than on two threads each
        // calling `readDataToEndOfFile()`, because EOF is not the child's to
        // give. EOF arrives when the last holder of the write end closes it,
        // and a grandchild the child left behind holds the same one — `sh -c
        // 'server &'` is an ordinary thing for a project's own command to be.
        // A thread blocked on that read never comes back: two per call, against
        // a libdispatch global pool that tops out around 64. A few dozen such
        // calls and every later capture times out waiting for a thread rather
        // than for its child, `/usr/bin/true` included. That was the bug, and
        // it is why the read side is worth this much machinery: a source
        // occupies no thread while it waits.
        let drainQueue = DispatchQueue.global(qos: .utility)
        let outDrain = PipeDrain(reading: outPipe.fileHandleForReading, on: drainQueue)
        let errDrain = PipeDrain(reading: errPipe.fileHandleForReading, on: drainQueue)
        guard let outDrain, let errDrain else {
            outDrain?.cancel()
            errDrain?.cancel()
            logger.warning("\(executable, privacy: .public) could not be drained: no descriptor to spare")
            kill(process)
            return nil
        }

        // One absolute deadline covers all three waits. A drain may still be
        // registered on a pipe a grandchild holds open; cancelling it below is
        // what releases that descriptor. Neither drain is read on a failure
        // path.
        let deadline = DispatchTime.now() + timeout
        let finished = outDrain.wait(until: deadline)
            && errDrain.wait(until: deadline)
            // EOF on the pipes is not exit: a child can write its output, close
            // both descriptors, and then hang in cleanup. Bound this wait too.
            && exited.wait(timeout: deadline) == .success
        // On both paths, not just the one that gave up: cancelling is what
        // closes the duplicated descriptors, and a success path that skipped it
        // would trade a thread leak for an fd leak.
        outDrain.cancel()
        errDrain.cancel()
        guard finished else {
            // Logged, and distinguishable from a plain non-zero exit: a bare nil
            // at the call site is otherwise indistinguishable from "it failed".
            logger.warning(
                "\(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) exceeded its \(timeout, privacy: .public)s deadline; killing it"
            )
            kill(process)
            return nil
        }

        return Output(status: process.terminationStatus, stdout: outDrain.data, stderr: errDrain.data)
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

    /// Reads one pipe to EOF without occupying a thread while it waits.
    ///
    /// The obvious shape — `readDataToEndOfFile()` on a dispatch thread — is
    /// what this replaced, and it blocks until every holder of the write end
    /// closes it. The child is not the only holder, so that wait has no bound
    /// the caller controls; see the comment in `capture`.
    ///
    /// `DispatchSource.makeReadSource` rather than
    /// `FileHandle.readabilityHandler`, deliberately. The handler form leaves
    /// EOF detection here anyway — a zero-length read is EOF, and a handler
    /// that does not clear itself there respins forever on a spent descriptor —
    /// and it reads through `availableData`, which raises an ObjC exception on
    /// a read error rather than returning one, the same hazard the stdin writer
    /// in `capture` documents. The source form is explicit about both, and it
    /// gives the descriptor question a clean answer: it reads a `dup` and
    /// closes that `dup` in its cancel handler, so the source owns exactly one
    /// descriptor and `Pipe`'s own `FileHandle` goes on owning the original.
    /// Handing both owners the same fd is a double close, and the second one
    /// lands on whatever number the kernel has since handed to someone else.
    private final class PipeDrain: @unchecked Sendable {
        private let fileDescriptor: Int32
        private let source: DispatchSourceRead
        private let completed = DispatchSemaphore(value: 0)
        private let box = DataBox()
        /// Reused across reads. The source delivers its handler serially, so
        /// nothing else is in here at the same time.
        private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        /// Begins draining immediately, or fails if the descriptor cannot be
        /// duplicated — which means the process is out of file descriptors, and
        /// silently capturing nothing would read at the call site as a child
        /// that printed nothing.
        init?(reading handle: FileHandle, on queue: DispatchQueue) {
            let duplicate = dup(handle.fileDescriptor)
            guard duplicate >= 0 else { return nil }
            // The source promises only that *some* bytes are readable, so the
            // read must not block asking for more than arrived — that would
            // park the very thread this type exists to keep free.
            let flags = fcntl(duplicate, F_GETFL)
            guard flags >= 0, fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                close(duplicate)
                return nil
            }
            fileDescriptor = duplicate
            source = DispatchSource.makeReadSource(fileDescriptor: duplicate, queue: queue)
            source.setEventHandler { [weak self] in
                // Promoted to a strong reference for the duration of the read,
                // so `scratch` cannot be deallocated underneath it.
                self?.readWhateverIsThere()
            }
            source.setCancelHandler { [completed] in
                // `duplicate` by value rather than `self.fileDescriptor`: the
                // close has to happen whether or not the drain is still around,
                // and this is the only place it happens.
                close(duplicate)
                completed.signal()
            }
            source.resume()
        }

        deinit {
            // Releasing a live source would strand the descriptor its cancel
            // handler closes. Cancelling twice is a no-op.
            source.cancel()
        }

        /// Everything read so far. Complete once `wait(until:)` has returned true.
        var data: Data {
            box.read()
        }

        /// Waits for EOF, or for a cancel, until `deadline`.
        func wait(until deadline: DispatchTime) -> Bool {
            completed.wait(timeout: deadline) == .success
        }

        /// Stops reading and releases the descriptor. Idempotent, and the only
        /// thing a caller that gave up has to do.
        func cancel() {
            source.cancel()
        }

        private func readWhateverIsThere() {
            while true {
                let count = scratch.withUnsafeMutableBytes { buffer in
                    read(fileDescriptor, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    box.append(scratch.prefix(count))
                    continue
                }
                if count == 0 {
                    // EOF: the last holder of the write end let go.
                    source.cancel()
                    return
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    // Drained for now. The source fires again when more lands.
                    // EWOULDBLOCK is the same value on Darwin.
                    return
                default:
                    source.cancel()
                    return
                }
            }
        }
    }

    /// Handoff for a stream a `PipeDrain` is reading. Mirrors the locked-box
    /// pattern in `CommandLineTools`.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: ArraySlice<UInt8>) {
            lock.lock()
            defer { lock.unlock() }
            data.append(contentsOf: bytes)
        }

        /// Reads; it does not take. See `ProcessCompose.PhaseExecutor.OutputBox.read()`
        /// — these two boxes cross-reference each other, so renaming one and not
        /// the other would put the misnomer straight back.
        func read() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
