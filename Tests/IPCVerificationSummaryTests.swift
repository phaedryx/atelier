// ABOUTME: Tests for the pure parts of the verification IPC tools — argument parsing and
// ABOUTME: the completion notices, which carry verdicts and no output at all.

@testable import Atelier
import XCTest

final class IPCVerificationSummaryTests: XCTestCase {
    // MARK: - Helpers

    private func check(
        _ name: String,
        _ state: IPC.VerificationCheckState,
        exitCode: Int? = nil,
        duration: Double? = nil
    ) -> IPC.VerificationCheckInfo {
        IPC.VerificationCheckInfo(
            name: name,
            state: state,
            exitCode: exitCode,
            durationSeconds: duration
        )
    }

    private func run(
        id: String = "v7f3a11",
        state: IPC.VerificationRunState = .finished,
        duration: Double? = 50,
        checks: [IPC.VerificationCheckInfo],
        isStale: Bool = false
    ) -> IPC.VerificationRunInfo {
        IPC.VerificationRunInfo(
            runID: id,
            workstreamID: UUID().uuidString,
            workstreamName: "wry-amber-lexer",
            state: state,
            startedSecondsAgo: 51,
            durationSeconds: duration,
            checks: checks,
            isStale: isStale
        )
    }

    // MARK: - Parsing the `checks` argument

    /// Through the reader `startVerification` actually calls.
    ///
    /// `VerificationSummary.checks(from:)` was a one-line delegation to
    /// `ToolArguments.parseList` with no production caller left, kept alive only
    /// by these tests; the cases it covered are the ones a model really sends,
    /// so they moved onto the real path rather than going with it.
    private func checks(_ raw: String?) -> [String] {
        IPC.ToolArguments(
            tool: .startVerification,
            raw: raw.map { ["checks": $0] } ?? [:]
        ).list("checks")
    }

    /// Every argument on this surface is declared a string, so a list of checks
    /// arrives as text however the model spells it.
    func test_checks_parsesACommaSeparatedList() {
        XCTAssertEqual(checks("rspec,rubocop"), ["rspec", "rubocop"])
        XCTAssertEqual(checks("rspec, rubocop"), ["rspec", "rubocop"])
        XCTAssertEqual(checks(" rspec , rubocop "), ["rspec", "rubocop"])
    }

    func test_checks_acceptsTheShapesAModelActuallySends() {
        // A JSON array the model wrote out as text, and a whitespace-separated
        // list. Both are what a plural argument named `checks` invites, and
        // neither is worth a refusal. (A *real* JSON array is now flattened to
        // the comma form before it gets here — see `IPCToolRegistryTests`.)
        XCTAssertEqual(checks(#"["rspec", "rubocop"]"#), ["rspec", "rubocop"])
        XCTAssertEqual(checks("rspec rubocop"), ["rspec", "rubocop"])
    }

    func test_checks_absentOrEmptyMeansAllOfThem() {
        XCTAssertEqual(checks(nil), [])
        XCTAssertEqual(checks(""), [])
        XCTAssertEqual(checks("   "), [])
        XCTAssertEqual(checks(",,"), [])
    }

    func test_checks_dropsDuplicatesAndKeepsTheOrderAsked() {
        XCTAssertEqual(checks("rspec,rubocop,rspec"), ["rspec", "rubocop"])
    }

    // MARK: - The completion notice

    func test_message_leadsWithHowManyFailed() {
        let message = IPC.VerificationSummary.message(for: run(checks: [
            check("rubocop", .passed, duration: 1.9),
            check("rspec", .failed, exitCode: 1, duration: 48.1),
        ]))

        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "run v7f3a11 finished in 50.0s — 1 of 2 checks failed")
        XCTAssertTrue(message.contains("✓ rubocop  1.9s"), message)
        XCTAssertTrue(message.contains("✗ rspec  48.1s  exit 1"), message)
        XCTAssertTrue(
            message.contains(#"check_verification(run_id: "v7f3a11")"#),
            "a failing run must point at where the rest of the output is: \(message)"
        )
    }

    func test_message_saysAllPassedWhenNoneFailed() {
        let message = IPC.VerificationSummary.message(for: run(checks: [
            check("rubocop", .passed, duration: 1.9),
            check("rspec", .passed, duration: 48.1),
        ]))

        XCTAssertEqual(message.split(separator: "\n").first, "run v7f3a11 finished in 50.0s — all 2 checks passed")
    }

    /// The trap this exists to close. `up -n` on an empty namespace never exits,
    /// so `PhaseExecutor` returns `.skipped` without spawning, and an undecodable
    /// config yields no declared processes at all — either way a run can finish
    /// having run nothing. "0 of 0 failed" is true and reads as a green suite.
    func test_message_neverRendersARunThatRanNothingAsAPass() {
        let message = IPC.VerificationSummary.message(for: run(checks: []))

        XCTAssertFalse(message.lowercased().contains("passed"), "a run with no checks passed nothing: \(message)")
        XCTAssertTrue(message.contains("no checks"), message)
    }

    /// The same trap, the other shape: a spawn that dies before binding leaves every
    /// *declared* check present as a row, sealed `.notRun` — rows exist, `total > 0`, so
    /// the empty-`checks` guard above never fires. "0 of 3 failed" is exactly as true and
    /// exactly as green as "0 of 0 failed".
    func test_message_neverRendersARunWhoseRowsAreAllNotRunAsAPass() {
        let message = IPC.VerificationSummary.message(for: run(checks: [
            check("rspec", .notRun),
            check("rubocop", .notRun),
            check("tsc", .notRun),
        ]))

        XCTAssertFalse(message.lowercased().contains("passed"), "nothing ran, so nothing passed: \(message)")
        XCTAssertEqual(
            message.split(separator: "\n").first,
            "run v7f3a11 finished in 50.0s — declared 3 checks but none of them ran"
        )
    }

    func test_message_reportsAStoppedRunAsStoppedRatherThanFailed() {
        let message = IPC.VerificationSummary.message(for: run(state: .stopped, duration: 12, checks: [
            check("rspec", .stopped, duration: 12),
            check("vitest", .notRun),
        ]))

        let first = String(message.split(separator: "\n").first ?? "")
        XCTAssertTrue(
            first.hasPrefix("run v7f3a11 was stopped"),
            "a stopped run has to lead with that, not with a verdict the user caused: \(first)"
        )
        XCTAssertTrue(message.contains("· rspec  12.0s  stopped"), message)
        XCTAssertTrue(message.contains("· vitest  not run"), message)
    }

    /// A `Skipped` check carries exit 1 from process-compose. It must never read
    /// as a failure it never had.
    func test_message_distinguishesASkippedCheckFromAFailedOne() {
        let message = IPC.VerificationSummary.message(for: run(checks: [
            check("build-packages", .failed, exitCode: 2, duration: 3),
            check("tsc", .skipped),
        ]))

        XCTAssertTrue(message.contains("✗ build-packages  3.0s  exit 2"), message)
        XCTAssertTrue(message.contains("· tsc  skipped"), message)
        XCTAssertTrue(
            message.split(separator: "\n").first?.contains("1 of 2 checks failed") == true,
            "the skipped check is not a failure: \(message)"
        )
    }

    func test_message_saysWhenTheResultsNoLongerDescribeTheWorktree() {
        let message = IPC.VerificationSummary.message(for: run(checks: [check("rubocop", .passed, duration: 1)], isStale: true))

        XCTAssertTrue(message.contains("worktree has changed"), message)
    }

    func test_message_formatsLongDurationsInMinutes() {
        let message = IPC.VerificationSummary.message(for: run(duration: 1503.2, checks: [
            check("rspec", .passed, duration: 1503.2),
        ]))

        XCTAssertTrue(message.contains("25m 3.2s"), message)
    }

    // MARK: - The per-check notice

    private func notice(
        state: IPC.VerificationCheckState, exitCode: Int? = nil
    ) -> IPC.VerificationCheckNotice {
        IPC.VerificationCheckNotice(
            runID: "abcd1234", workstreamID: UUID().uuidString, requesterSurfaceID: nil,
            check: IPC.VerificationCheckInfo(
                name: "rspec", state: state, exitCode: exitCode, durationSeconds: 48.1
            )
        )
    }

    func test_checkMessage_namesTheCheckTheVerdictAndTheRun() {
        let message = IPC.VerificationSummary.checkMessage(
            for: notice(state: .failed, exitCode: 1)
        )

        XCTAssertTrue(message.contains("rspec"))
        XCTAssertTrue(message.contains("failed"))
        XCTAssertTrue(message.contains("abcd1234"))
    }

    /// `IPC.Store` refuses content over 64KB **outright** — it throws rather than
    /// truncating — so an oversized notice is lost, silently, exactly when the agent is
    /// waiting for it. A check name is user-authored and unbounded, which is the only
    /// thing here that can grow.
    func test_checkMessage_staysUnderTheCheckBudget() {
        let long = IPC.VerificationCheckNotice(
            runID: "abcd1234", workstreamID: UUID().uuidString, requesterSurfaceID: nil,
            check: IPC.VerificationCheckInfo(
                name: String(repeating: "x", count: 200_000),
                state: .failed, exitCode: 1, durationSeconds: 1
            )
        )
        let message = IPC.VerificationSummary.checkMessage(for: long)

        XCTAssertLessThanOrEqual(
            message.utf8.count, IPC.VerificationSummary.maxCheckMessageBytes
        )
    }

    /// Cutting a name to fit must not manufacture a replacement character.
    ///
    /// The cut lands wherever the trailer's length leaves it, so a multi-byte scalar
    /// straddling that point is the ordinary case rather than an exotic one. Four
    /// ASCII offsets against a 4-byte scalar put the boundary at every position
    /// inside a sequence, so no single arithmetic coincidence can make this pass.
    /// `U+FFFD` is three bytes where the scalar it replaces may have been one to
    /// four, so the budget is asserted alongside it — the same overshoot the
    /// truncation exists to prevent.
    func test_checkMessage_cutsANameOnAScalarBoundary() {
        for pad in 0 ... 3 {
            let name = String(repeating: "x", count: pad) + String(repeating: "😀", count: 2_000)
            let long = IPC.VerificationCheckNotice(
                runID: "abcd1234", workstreamID: UUID().uuidString, requesterSurfaceID: nil,
                check: IPC.VerificationCheckInfo(
                    name: name, state: .failed, exitCode: 1, durationSeconds: 1
                )
            )
            let message = IPC.VerificationSummary.checkMessage(for: long)

            XCTAssertFalse(
                message.contains("\u{FFFD}"),
                "pad \(pad): the cut landed mid-scalar and produced U+FFFD"
            )
            XCTAssertLessThanOrEqual(
                message.utf8.count, IPC.VerificationSummary.maxCheckMessageBytes,
                "pad \(pad): the notice overshot its budget"
            )
        }
    }

    /// Nothing may read as though the output could be fetched. It lives in the
    /// check's terminal surface and Atelier keeps no copy at all, so the tab and a
    /// re-run are the only two honest pointers.
    func test_checkMessage_pointsAtTheTabRatherThanPromisingALog() {
        let message = IPC.VerificationSummary.checkMessage(for: notice(state: .failed, exitCode: 1))

        XCTAssertTrue(message.contains("Verification tab"), message)
        XCTAssertFalse(message.lowercased().contains("fetch"), message)
    }

    /// A passing check gets a notice too — that is what makes an agent able to tell "the
    /// suite is green" from "the suite has not reported yet".
    func test_checkMessage_reportsAPassAsAPass() {
        let message = IPC.VerificationSummary.checkMessage(for: notice(state: .passed))

        XCTAssertTrue(message.contains("passed"))
    }

    // MARK: - Staying deliverable

    /// `IPC.Store` refuses content over 64KB outright, so an assembled notice that
    /// overshoots is not trimmed — it is *lost*, silently, exactly when the agent
    /// is waiting for it. With no output to carry, the list of verdicts is the only
    /// thing that can overshoot.
    func test_message_staysUnderTheCapForAnAbsurdNumberOfChecks() {
        let many = (0 ..< 500).map { check("check-\($0)", .failed, exitCode: 1, duration: 1) }
        let message = IPC.VerificationSummary.message(for: run(checks: many))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
        XCTAssertTrue(message.split(separator: "\n").first?.contains("500 of 500") == true, message)
        XCTAssertTrue(message.contains("more checks"), "the list was cut, so it has to say so: \(message)")
    }

    /// A cut list must say it was cut. "0 of 0 failed" over a truncated list reads
    /// as a complete one.
    func test_message_keepsEveryVerdictWhenTheyFit() {
        let checks = (0 ..< 10).map { check("check-\($0)", .failed, exitCode: 1, duration: 1) }
        let message = IPC.VerificationSummary.message(for: run(checks: checks))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
        for index in 0 ..< 10 {
            XCTAssertTrue(message.contains("✗ check-\(index)"), "check-\(index) is missing from: \(message)")
        }
        XCTAssertFalse(message.contains("more checks"), "nothing was cut, so nothing should claim it was")
    }
}
