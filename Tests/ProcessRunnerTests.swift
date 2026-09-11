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

    // MARK: - Standard input

    /// `atelier-hook` takes its whole payload on stdin, so a child that reads
    /// stdin has to be feedable. Without this the hook script's `INPUT=$(cat)`
    /// sees the app's own (closed) stdin and posts an empty body.
    func testWritesStandardInputToTheChild() {
        let data = ProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: Data("payload".utf8),
            timeout: 10
        )
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "payload")
    }

    /// A child reading stdin must see EOF, not a pipe that stays open: `cat`
    /// with an unclosed stdin never exits, and the call would only return when
    /// the deadline killed it.
    func testClosesStandardInputSoTheChildSeesEOF() {
        let started = Date()
        let data = ProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: Data("payload".utf8),
            timeout: 10
        )
        XCTAssertNotNil(data, "cat should have exited on EOF rather than being killed at the deadline")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the write end was left open")
    }

    /// The deadlock this type exists to prevent, on the input side: a payload
    /// past the pipe buffer blocks the writer until the child drains it, so the
    /// write cannot happen on the thread that later waits for the child.
    func testWritesAStandardInputPayloadLargerThanThePipeBuffer() {
        let payload = String(repeating: "x", count: 512 * 1024)
        let data = ProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: Data(payload.utf8),
            timeout: 20
        )
        XCTAssertEqual(data?.count, payload.utf8.count)
    }

    // MARK: - Drain threads and orphaned grandchildren

    /// A `sleep` duration no other test or tool on the machine uses, so the
    /// cleanup below cannot kill a bystander.
    private static let sentinelSleep = "98765"

    /// Enough leaky captures to exhaust libdispatch's global pool if each one
    /// parks its two drain threads permanently. The pool tops out around 64
    /// threads, so 50 captures (100 would-be parked threads) clears it with
    /// margin — the number is a libdispatch implementation detail, not a
    /// contract, which is why the assertion below is about a later capture
    /// working rather than about any thread count.
    private static let leakyCaptureCount = 50

    override func tearDown() {
        super.tearDown()
        killSentinelStrays()
    }

    private func killSentinelStrays() {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", "^sleep \(Self.sentinelSleep)"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
    }

    /// A capture whose grandchild holds the pipe open must not strand its drain
    /// threads. Each one that does parks two of libdispatch's global-pool
    /// threads forever, and a few dozen such calls starve the pool — after
    /// which *every* later `capture` times out, including ones whose child
    /// exits instantly. The child here exits immediately; only the backgrounded
    /// grandchild keeps the write end open.
    func testRepeatedCapturesWithAGrandchildHoldingThePipeDoNotStarveLaterCaptures() {
        for _ in 0 ..< Self.leakyCaptureCount {
            _ = ProcessRunner.capture(
                executable: "/bin/sh",
                arguments: ["-c", "sleep \(Self.sentinelSleep) &"],
                timeout: 0.25
            )
        }

        let started = Date()
        let output = ProcessRunner.capture(executable: "/usr/bin/true", arguments: [], timeout: 5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotNil(output, "a trivial capture timed out: the drain threads from the leaky captures are still parked")
        XCTAssertLessThan(elapsed, 5, "a trivial capture should return immediately, not burn its deadline")
    }
}
