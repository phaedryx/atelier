// ABOUTME: Tests for the Verification tab's extracted decisions: Run's gate, staleness, glyphs.
// ABOUTME: Follows ExecutionTabViewTests' precedent — free functions, no view tree.

@testable import Atelier
import XCTest

final class VerificationTabViewTests: XCTestCase {
    // MARK: - Run's gate

    /// Gated on the runner's liveness, never on `Run.isFinished` — see
    /// VerificationRunner.swift's own doc on `isLive`. A run whose rows have
    /// all gone terminal is still live until it seals, and a button that
    /// re-enabled there would let a second `up` rebind a live socket.
    func test_canRun_isFalseWhileTheRunnerReportsLive() {
        XCTAssertFalse(verificationCanRun(isLive: true))
    }

    func test_canRun_isTrueWhenNothingIsLive() {
        XCTAssertTrue(verificationCanRun(isLive: false))
    }

    // MARK: - Staleness

    func test_isStale_comparesTheStamp() {
        let run = Verification.Run(
            id: "abcd1234", workstreamID: UUID(), startedAt: Date(), stamp: "head|10|aaaa",
            checks: [], wasStopped: false
        )
        XCTAssertFalse(verificationIsStale(run: run, currentStamp: "head|10|aaaa"))
        XCTAssertTrue(verificationIsStale(run: run, currentStamp: "head|11|bbbb"))
        // No stamp to compare against is not evidence of freshness.
        XCTAssertTrue(verificationIsStale(run: run, currentStamp: nil))
    }

    // MARK: - Row glyphs

    func test_rowGlyph_distinguishesEveryState() {
        let states: [Verification.CheckResult.State] =
            [.notRun, .pending, .running, .passed, .failed(1), .skipped, .stopped]
        let glyphs = states.map(verificationRowGlyph)
        // A skipped check must not look like a failure, and a not-run one must not
        // look like a pass.
        XCTAssertEqual(Set(glyphs).count, glyphs.count, "\(glyphs)")
    }

    /// The associated exit code must not affect which glyph a failure gets —
    /// every failure reads the same regardless of what code produced it.
    func test_rowGlyph_ignoresTheFailedExitCode() {
        XCTAssertEqual(verificationRowGlyph(.failed(1)), verificationRowGlyph(.failed(137)))
    }

    // MARK: - The unavailable state

    /// Reads the same four preconditions `PhasePolicy.plan` evaluates, in the
    /// same order, so the *decision* is one copy with that gate and only the
    /// *rendering* is separate. `PhasePolicy`'s own strings are past tense
    /// ("so no `verify` ran"); this tab has not run anything yet, so none of
    /// these may read as a report on a run that already happened.
    func test_unavailableReason_isNilOnceEveryPreconditionHolds() {
        XCTAssertNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: true,
            declared: ["rspec", "rubocop"]
        ))
    }

    func test_unavailableReason_reportsTheIntegrationSwitch() {
        let reason = verificationUnavailableReason(
            isEnabled: false, hasConfig: true, hasBinary: true, isApproved: true, declared: ["rspec"]
        )
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.contains("ran") ?? true, "must not read as a report on a run that already happened: \(reason ?? "")")
    }

    func test_unavailableReason_reportsAMissingConfig() {
        XCTAssertNotNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: false, hasBinary: true, isApproved: true, declared: nil
        ))
    }

    func test_unavailableReason_reportsAMissingBinary() {
        XCTAssertNotNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: false, isApproved: true, declared: nil
        ))
    }

    func test_unavailableReason_reportsAnUnapprovedConfig() {
        XCTAssertNotNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: false, declared: nil
        ))
    }

    /// `declared == nil` is a parse failure, distinct from a config that
    /// parsed and named nothing — both are unavailable, but they are not the
    /// same fact and must not collapse to the same nil-vs-empty confusion the
    /// runner itself refuses to make (see `Verification.Runner.start`, which
    /// never folds an unparseable config into "declares no verify processes").
    func test_unavailableReason_distinguishesParseFailureFromNoChecksDeclared() {
        let parseFailure = verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: true, declared: nil
        )
        let noneDeclared = verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: true, declared: []
        )
        XCTAssertNotNil(parseFailure)
        XCTAssertNotNil(noneDeclared)
        XCTAssertNotEqual(parseFailure, noneDeclared)
    }
}
