// ABOUTME: Runs a child process with a hard deadline and returns its stdout.
// ABOUTME: Blocks the calling thread — call it off the main actor.

import Foundation

/// A `Process` wrapper that cannot hang the caller.
///
/// `Process.readDataToEndOfFile()` followed by `waitUntilExit()` blocks
/// forever if the child hangs — or if the child exits while a grandchild
/// still holds the write end of the pipe. Anything polling on a timer needs
/// a deadline instead, or one wedged child stalls every later call.
enum ProcessRunner {
    /// How long to let a terminated child wind down before escalating to SIGKILL.
    private static let terminationGrace: TimeInterval = 2

    /// Runs `executable` and returns its stdout, or nil if it could not be
    /// launched, exited non-zero, or outlived `timeout`.
    ///
    /// stderr is discarded: an unread pipe fills its buffer and deadlocks a
    /// chatty child.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout on another thread so the deadline below is enforceable:
        // the read itself is what blocks, not the wait.
        let box = OutputBox()
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            box.store(data)
            readFinished.signal()
        }

        guard readFinished.wait(timeout: .now() + timeout) == .success else {
            kill(process)
            // The drain thread may still be parked on a pipe a grandchild holds
            // open. It is abandoned rather than waited on — leaking one thread
            // beats wedging the caller. `box` is never read on this path.
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return box.take()
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

    /// Handoff for stdout captured on the drain thread. Mirrors the locked-box
    /// pattern in `CommandLineTools`.
    private final class OutputBox: @unchecked Sendable {
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
