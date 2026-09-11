// ABOUTME: Tests for the pure parts of the verification IPC tools — argument parsing, the
// ABOUTME: completion notice, and the bounding that keeps a suite's output deliverable.

@testable import Atelier
import XCTest

final class IPCVerificationSummaryTests: XCTestCase {
    // MARK: - Helpers

    private func check(
        _ name: String,
        _ state: IPC.VerificationCheckState,
        exitCode: Int? = nil,
        duration: Double? = nil,
        output: String? = nil,
        truncated: Bool = false
    ) -> IPC.VerificationCheckInfo {
        IPC.VerificationCheckInfo(
            name: name,
            state: state,
            exitCode: exitCode,
            durationSeconds: duration,
            outputTail: output,
            outputTruncated: truncated
        )
    }

    private func run(
        id: String = "v7f3a11",
        state: IPC.VerificationRunState = .finished,
        duration: Double? = 50,
        checks: [IPC.VerificationCheckInfo],
        isStale: Bool = false,
        failureDetail: String? = nil
    ) -> IPC.VerificationRunInfo {
        IPC.VerificationRunInfo(
            runID: id,
            workstreamID: UUID().uuidString,
            workstreamName: "wry-amber-lexer",
            state: state,
            startedSecondsAgo: 51,
            durationSeconds: duration,
            checks: checks,
            isStale: isStale,
            failureDetail: failureDetail
        )
    }

    // MARK: - Parsing the `checks` argument

    /// Every argument on this surface is a string — `IPC.Request.arguments` is
    /// `[String: String]` — so a list of checks arrives as text however the model
    /// spells it.
    func test_checks_parsesACommaSeparatedList() {
        XCTAssertEqual(IPC.VerificationSummary.checks(from: "rspec,rubocop"), ["rspec", "rubocop"])
        XCTAssertEqual(IPC.VerificationSummary.checks(from: "rspec, rubocop"), ["rspec", "rubocop"])
        XCTAssertEqual(IPC.VerificationSummary.checks(from: " rspec , rubocop "), ["rspec", "rubocop"])
    }

    func test_checks_acceptsTheShapesAModelActuallySends() {
        // A JSON array that reached the helper as a value it had to render, and a
        // whitespace-separated list. Both are what a plural argument named
        // `checks` invites, and neither is worth a refusal.
        XCTAssertEqual(IPC.VerificationSummary.checks(from: #"["rspec", "rubocop"]"#), ["rspec", "rubocop"])
        XCTAssertEqual(IPC.VerificationSummary.checks(from: "rspec rubocop"), ["rspec", "rubocop"])
    }

    func test_checks_absentOrEmptyMeansAllOfThem() {
        XCTAssertEqual(IPC.VerificationSummary.checks(from: nil), [])
        XCTAssertEqual(IPC.VerificationSummary.checks(from: ""), [])
        XCTAssertEqual(IPC.VerificationSummary.checks(from: "   "), [])
        XCTAssertEqual(IPC.VerificationSummary.checks(from: ",,"), [])
    }

    func test_checks_dropsDuplicatesAndKeepsTheOrderAsked() {
        XCTAssertEqual(IPC.VerificationSummary.checks(from: "rspec,rubocop,rspec"), ["rspec", "rubocop"])
    }

    // MARK: - The completion notice

    func test_message_leadsWithHowManyFailed() {
        let message = IPC.VerificationSummary.message(for: run(checks: [
            check("rubocop", .passed, duration: 1.9),
            check("rspec", .failed, exitCode: 1, duration: 48.1, output: "3 examples, 1 failure\n./spec/models/contact_spec.rb:42"),
        ]))

        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "run v7f3a11 finished in 50.0s — 1 of 2 checks failed")
        XCTAssertTrue(message.contains("✓ rubocop  1.9s"), message)
        XCTAssertTrue(message.contains("✗ rspec  48.1s  exit 1"), message)
        XCTAssertTrue(message.contains("    ./spec/models/contact_spec.rb:42"), message)
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
        XCTAssertTrue(message.contains("· tsc  skipped (a check it depends on failed)"), message)
        XCTAssertTrue(
            message.split(separator: "\n").first?.contains("1 of 2 checks failed") == true,
            "the skipped check is not a failure: \(message)"
        )
    }

    /// A spawn that never got far enough to report leaves every check
    /// `.notRun`, and the reason exists in exactly one place. Without it an
    /// agent gets a list of checks that all say "not run" and nothing to act on.
    func test_message_leadsWithARunLevelFailureAheadOfTheVerdicts() {
        let message = IPC.VerificationSummary.message(for: run(
            duration: 0.4,
            checks: [check("rspec", .notRun), check("rubocop", .notRun)],
            failureDetail: "process-compose: error parsing process-compose.yaml: line 12"
        ))

        let lines = message.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasPrefix("The run itself failed: "), message)
        XCTAssertTrue(lines[1].contains("line 12"), message)
        XCTAssertTrue(message.contains("· rspec  not run"), message)
    }

    func test_message_boundsARunLevelFailureLikeEverythingElse() {
        let message = IPC.VerificationSummary.message(for: run(
            checks: [check("rspec", .notRun)],
            failureDetail: String(repeating: "spew ", count: 50_000)
        ))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
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

    // MARK: - Staying deliverable

    /// `IPC.Store` refuses content over 64KB outright, so an assembled notice
    /// that overshoots is not trimmed — it is *lost*, silently, exactly when the
    /// agent is waiting for it. Bounding the per-check tails is not enough; the
    /// assembled result is what has to fit.
    func test_message_staysUnderTheStoresContentCapForOneEnormousFailure() {
        let huge = (0 ..< 200_000).map { "line \($0) of a very chatty test runner" }.joined(separator: "\n")
        let message = IPC.VerificationSummary.message(for: run(checks: [
            check("rspec", .failed, exitCode: 1, duration: 48, output: huge),
        ]))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
        XCTAssertTrue(message.contains("line 199999"), "a tail keeps the END of the output, which is where the failure is")
        XCTAssertFalse(message.contains("line 0 of"), "the head of a 200k-line log is not the useful part")
    }

    func test_message_staysUnderTheCapForAnAbsurdNumberOfChecks() {
        let many = (0 ..< 500).map { check("check-\($0)", .failed, exitCode: 1, duration: 1, output: "boom") }
        let message = IPC.VerificationSummary.message(for: run(checks: many))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
        XCTAssertTrue(message.split(separator: "\n").first?.contains("500 of 500") == true, message)
        XCTAssertTrue(message.contains("more checks"), "the list was cut, so it has to say so: \(message)")
    }

    func test_message_keepsEveryChecksVerdictWhenOnlyTheOutputIsTooBig() {
        let checks = (0 ..< 10).map { index in
            check("check-\(index)", .failed, exitCode: 1, duration: 1, output: String(repeating: "z", count: 50_000))
        }
        let message = IPC.VerificationSummary.message(for: run(checks: checks))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
        for index in 0 ..< 10 {
            XCTAssertTrue(message.contains("✗ check-\(index)"), "check-\(index) is missing from: \(message)")
        }
    }

    /// An even share below the floor used to mean nobody got output at all —
    /// a cliff rather than a degradation, one failing check either side of it.
    func test_message_givesOutputToAsManyFailuresAsTheBudgetAllows() {
        let many = (0 ..< 31).map { index in
            check("check-\(index)", .failed, exitCode: 1, duration: 1, output: "boom \(index)\nstack line for \(index)")
        }
        let message = IPC.VerificationSummary.message(for: run(checks: many))

        XCTAssertLessThanOrEqual(message.utf8.count, IPC.VerificationSummary.maxMessageBytes)
        XCTAssertTrue(message.contains("    boom 0"), "the first failure's output should still be there: \(message)")
        for index in 0 ..< 31 {
            XCTAssertTrue(message.contains("✗ check-\(index)"), "check-\(index)'s verdict is missing")
        }
    }

    // MARK: - Bounding the read

    func test_bounded_trimsEachChecksOutputAndSaysThatItDid() {
        let bounded = IPC.VerificationSummary.bounded(run(checks: [
            check("rspec", .failed, exitCode: 1, duration: 48, output: String(repeating: "a\n", count: 100_000)),
        ]))

        let tail = try? XCTUnwrap(bounded.checks.first?.outputTail)
        XCTAssertNotNil(tail)
        XCTAssertLessThanOrEqual(tail?.utf8.count ?? .max, IPC.VerificationSummary.maxReadTailBytesPerCheck)
        XCTAssertEqual(bounded.checks.first?.outputTruncated, true)
    }

    func test_bounded_leavesSmallOutputExactlyAsItWas() {
        let bounded = IPC.VerificationSummary.bounded(run(checks: [
            check("rspec", .failed, exitCode: 1, duration: 48, output: "3 examples, 1 failure"),
        ]))

        XCTAssertEqual(bounded.checks.first?.outputTail, "3 examples, 1 failure")
        XCTAssertEqual(bounded.checks.first?.outputTruncated, false)
    }

    func test_bounded_keepsTheRunnersOwnTruncationFlag() {
        // The runner fetches a bounded tail from the control API in the first
        // place. If it already trimmed, this must not report the result as whole.
        let bounded = IPC.VerificationSummary.bounded(run(checks: [
            check("rspec", .failed, exitCode: 1, output: "tail", truncated: true),
        ]))

        XCTAssertEqual(bounded.checks.first?.outputTruncated, true)
    }

    func test_bounded_boundsTheWholeAnswerNotJustEachCheck() {
        let checks = (0 ..< 20).map { index in
            check("check-\(index)", .failed, exitCode: 1, duration: 1, output: String(repeating: "q", count: 40_000))
        }
        let bounded = IPC.VerificationSummary.bounded(run(checks: checks))

        let total = bounded.checks.compactMap(\.outputTail).reduce(0) { $0 + $1.utf8.count }
        XCTAssertLessThanOrEqual(total, IPC.VerificationSummary.maxReadOutputBytes)
        XCTAssertEqual(bounded.checks.count, 20, "bounding output must not drop a check's verdict")
    }
}
