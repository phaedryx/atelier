@testable import Atelier
import XCTest

final class VerificationResultTests: XCTestCase {
    private func entry(
        _ name: String, status: String, isRunning: Bool, exitCode: Int
    ) -> ProcessCompose.ProcessEntry {
        ProcessCompose.ProcessEntry(
            name: name, namespace: "verify", status: status, isReady: "",
            hasReadyProbe: false, restarts: 0, exitCode: exitCode,
            pid: 0, isRunning: isRunning
        )
    }

    /// Measured trap 1: a Pending check is byte-identical to a pass on exitCode.
    func test_state_pendingIsNotAPass() {
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("rspec", status: "Pending", isRunning: false, exitCode: 0)
            ), .pending
        )
    }

    /// Measured trap 2: Skipped carries exit 1 and is not a failure.
    func test_state_skippedIsNotAFailure() {
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("vitest", status: "Skipped", isRunning: false, exitCode: 1)
            ), .skipped
        )
    }

    func test_state_completedIsQualifiedByExitCode() {
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("rubocop", status: "Completed", isRunning: false, exitCode: 0)
            ), .passed
        )
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("rspec", status: "Completed", isRunning: false, exitCode: 4)
            ), .failed(4)
        )
    }

    func test_state_running() {
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("tsc", status: "Running", isRunning: true, exitCode: 0)
            ), .running
        )
    }

    /// An unrecognised status must never become a pass — that is the one answer
    /// that would let a red suite render green.
    func test_state_unknownStatusIsNeverAPass() {
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("x", status: "Terminating", isRunning: true, exitCode: 0)
            ), .running
        )
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("x", status: "Error", isRunning: false, exitCode: 9)
            ), .failed(9)
        )
        XCTAssertEqual(
            Verification.CheckResult.State(
                entry: entry("x", status: "Disabled", isRunning: false, exitCode: 0)
            ), .notRun
        )
    }

    func test_run_failedNamesListsOnlyFailures() {
        let run = Verification.Run(
            id: "abcd1234", workstreamID: UUID(), startedAt: Date(), stamp: "s",
            checks: [
                .init(name: "rubocop", state: .passed, duration: 1.9, output: nil),
                .init(name: "rspec", state: .failed(1), duration: 48.1, output: "3 failures"),
                .init(name: "vitest", state: .skipped, duration: nil, output: nil),
            ],
            wasStopped: false
        )
        XCTAssertEqual(run.failedNames, ["rspec"])
        XCTAssertTrue(run.isFinished)
    }

    func test_run_isNotFinishedWhileAnyCheckIsLiveOrPending() {
        for live in [Verification.CheckResult.State.running, .pending] {
            let run = Verification.Run(
                id: "abcd1234", workstreamID: UUID(), startedAt: Date(), stamp: "s",
                checks: [
                    .init(name: "rubocop", state: .passed, duration: 1.9, output: nil),
                    .init(name: "rspec", state: live, duration: nil, output: nil),
                ],
                wasStopped: false
            )
            XCTAssertFalse(run.isFinished, "\(live)")
        }
    }
}
