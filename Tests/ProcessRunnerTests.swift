// ABOUTME: Tests for ProcessRunner's deadline enforcement, exit-status handling,
// ABOUTME: and concurrent capture of stdout and stderr.

@testable import Atelier
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStandardOutputOnSuccess() {
        let data = ProcessRunner.run(executable: "/bin/echo", arguments: ["hello"], timeout: 10)
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "hello\n")
    }

    func testReturnsNilOnNonZeroExit() {
        XCTAssertNil(ProcessRunner.run(executable: "/usr/bin/false", arguments: [], timeout: 10))
    }

    func testReturnsNilWhenExecutableIsMissing() {
        XCTAssertNil(ProcessRunner.run(executable: "/nonexistent/binary", arguments: [], timeout: 10))
    }

    /// The regression this type exists for: a child that never exits must not
    /// block the caller past the deadline.
    func testKillsAndReturnsNilWhenTheChildOutlivesTheDeadline() {
        let started = Date()
        let data = ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(data)
        XCTAssertLessThan(elapsed, 10, "run() should return near the deadline, not wait for the child")
    }

    /// EOF on stdout is not the same as exit: a child can write its output,
    /// close the descriptor, and then hang. The deadline must cover that too.
    func testKillsAndReturnsNilWhenTheChildClosesStdoutThenHangs() {
        let started = Date()
        let data = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo hi; exec 1>&-; sleep 30"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(data)
        XCTAssertLessThan(elapsed, 10, "run() should not wait on exit without a deadline")
    }

    /// Capturing stderr is what makes the two-pipe deadlock reachable: draining
    /// stdout to EOF — which only happens when the child exits — while stderr
    /// fills wedges the child on a full pipe. Both streams here are ~3x the
    /// 64 KB pipe buffer, and the child writes them concurrently, so a
    /// sequential drain cannot finish either one.
    func testCapturesBothStreamsWhenEachOutgrowsThePipeBuffer() throws {
        let bytes = 200_000
        let started = Date()
        let output = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "yes err | head -c \(bytes) >&2 & yes out | head -c \(bytes); wait"],
            timeout: 30
        ), "capture() deadlocked on a child that fills both pipes")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.count, bytes)
        XCTAssertEqual(output.stderr.count, bytes)
        XCTAssertLessThan(elapsed, 30, "capture() should finish well inside its deadline")
    }

    func testCaptureReportsStderrAndStatusOnFailure() throws {
        let output = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "echo boom >&2; exit 3"],
            timeout: 10
        ))

        XCTAssertEqual(output.status, 3)
        XCTAssertFalse(output.isSuccess)
        XCTAssertEqual(output.stderrText, "boom")
        XCTAssertEqual(output.stdoutText, "")
    }

    func testCaptureReturnsNilWhenTheChildOutlivesTheDeadline() {
        let started = Date()
        XCTAssertNil(ProcessRunner.capture(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testSucceedsReflectsExitStatus() {
        XCTAssertTrue(ProcessRunner.succeeds(executable: "/usr/bin/true", arguments: [], timeout: 10))
        XCTAssertFalse(ProcessRunner.succeeds(executable: "/usr/bin/false", arguments: [], timeout: 10))
        XCTAssertFalse(ProcessRunner.succeeds(executable: "/nonexistent/binary", arguments: [], timeout: 10))
    }

    func testPassesEnvironmentToTheChild() {
        let data = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$ATELIER_TEST_VAR\""],
            environment: ["ATELIER_TEST_VAR": "probe"],
            timeout: 10
        )
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "probe")
    }
}
