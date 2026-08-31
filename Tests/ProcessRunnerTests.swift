// ABOUTME: Tests for ProcessRunner's deadline enforcement, exit-status handling,
// ABOUTME: and stdout capture.

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
