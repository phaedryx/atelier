// ABOUTME: End-to-end tests for QuickAction.Runner's shell spawn, which really runs a child.
// ABOUTME: Covers a non-zero exit and a shell that is not on disk, the launch failure that crashed.

@testable import Atelier
import XCTest

/// `QuickAction.Runner.runShellCommand` is one of the two sites deliberately
/// exempt from `ProcessRunner` (see the comment at its spawn site), so nothing
/// else in the app covers what it does with a child that fails.
///
/// The second test is a regression test for a crash, not a niceness: reading
/// `terminationStatus` on a `Process` that never launched raises
/// `NSInvalidArgumentException`, which Swift cannot catch — so before the fix
/// this file does not fail, it takes the test process down with it.
@MainActor
final class QuickActionRunnerTests: XCTestCase {
    /// The runner records what happened on the main actor, from a detached task,
    /// so the assertion has to wait for that hop rather than for the child.
    ///
    /// Waits on the *log entry* rather than on `state`, because the log is the
    /// durable artifact: `scheduleDismiss` puts `state` back to `.idle` three
    /// seconds later, while the entry stays. `state` is written in the same
    /// main-actor block as the entry's exit code, so asserting it the moment the
    /// entry lands is inside that window.
    private func waitForCompletedLogEntry(
        _ runner: QuickAction.Runner,
        timeout: TimeInterval = 10
    ) async throws -> QuickAction.LogEntry {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = runner.log.last, entry.exitCode != nil {
                return entry
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // A failure and never a skip: a runner that reports nothing is the
        // regression this file exists to catch — a crash is one way to report
        // nothing, and a hang is another — and a skipped test is green.
        XCTFail("the quick action never reported a result within \(timeout)s")
        throw NeverReported()
    }

    private struct NeverReported: Error {}

    func test_runShellCommand_recordsANonZeroExit() async throws {
        let runner = QuickAction.Runner()
        var succeeded: [QuickAction] = []
        runner.onSuccess = { succeeded.append($0) }

        runner.runShellCommand(
            action: .commit,
            shell: "/bin/sh",
            arguments: ["-c", "echo hello; exit 3"],
            workingDirectory: NSTemporaryDirectory()
        )

        let entry = try await waitForCompletedLogEntry(runner)
        XCTAssertEqual(entry.exitCode, 3)
        XCTAssertTrue(entry.output.contains("hello"), "the child's output is kept: \(entry.output)")
        XCTAssertEqual(runner.state, .failed(.commit))
        XCTAssertEqual(succeeded, [], "a non-zero exit is not a success")
    }

    /// The failure this file exists for: `$SHELL` naming a binary that is gone —
    /// an uninstalled fish, a Homebrew shell moved by an upgrade — so
    /// `process.run()` throws and nothing was ever launched.
    func test_runShellCommand_reportsAShellThatIsNotOnDisk() async throws {
        let missingShell = NSTemporaryDirectory() + "atelier-missing-shell-\(UUID().uuidString)"
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingShell),
            "the test needs a path that really is absent"
        )

        let runner = QuickAction.Runner()
        var succeeded: [QuickAction] = []
        runner.onSuccess = { succeeded.append($0) }

        runner.runShellCommand(
            action: .commit,
            shell: missingShell,
            arguments: ["-lic", "true"],
            workingDirectory: NSTemporaryDirectory()
        )

        let entry = try await waitForCompletedLogEntry(runner)
        XCTAssertTrue(
            entry.output.hasPrefix("Failed to launch:"),
            "the failure is reported rather than swallowed: \(entry.output)"
        )
        XCTAssertEqual(entry.exitCode, 1, "a launch that never happened has no status of its own")
        XCTAssertEqual(runner.state, .failed(.commit))
        XCTAssertEqual(succeeded, [], "nothing ran, so nothing succeeded")
    }
}
