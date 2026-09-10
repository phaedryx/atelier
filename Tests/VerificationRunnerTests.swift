// ABOUTME: Tests for the verification runner's gate and its refusals.
// ABOUTME: Covers only what is reachable without spawning process-compose; Task 8 adds the rest.

@testable import Atelier
import XCTest

@MainActor
final class VerificationRunnerTests: XCTestCase {
    /// resolveChecks is pure, so every refusal branch is testable without a
    /// config, a binary, or a subprocess.
    func test_resolveChecks_emptyMeansAll() throws {
        let resolved = try Verification.Runner
            .resolveChecks(requested: [], declared: ["rspec", "rubocop"]).get()
        XCTAssertEqual(resolved, ["rspec", "rubocop"])
    }

    func test_resolveChecks_neverReturnsEmptyForAnEmptyRequest() {
        // Empty in, empty declared: a refusal, not a run of nothing.
        // `up -n verify` on a namespace with no processes never exits.
        switch Verification.Runner.resolveChecks(requested: [], declared: []) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure): XCTAssertEqual(failure, .nothingDeclared)
        }
    }

    func test_resolveChecks_refusesUnknownNamesAndListsTheValidOnes() {
        switch Verification.Runner.resolveChecks(
            requested: ["rspec", "typo"], declared: ["rspec", "rubocop"]
        ) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unknownChecks(["typo"], valid: ["rspec", "rubocop"]))
        }
    }

    /// PhaseRunner.command silently drops a trailing name beginning with "-" as
    /// a flag-injection guard. Refusing here is what stops that becoming a run
    /// that quietly omits a check.
    func test_resolveChecks_refusesFlagShapedNames() {
        switch Verification.Runner.resolveChecks(requested: ["-n"], declared: ["rspec"]) {
        case let .success(names): XCTFail("expected a refusal, got \(names)")
        case let .failure(failure):
            XCTAssertEqual(failure, .unknownChecks(["-n"], valid: ["rspec"]))
        }
    }

    func test_start_refusesWhileARunIsInFlight() {
        let runner = Verification.Runner()
        let id = UUID()
        runner.seedInFlightForTesting(workstreamID: id, runID: "abcd1234")
        XCTAssertThrowsError(
            try runner.start(
                workstreamID: id, worktreePath: "/tmp", projectDirectory: "/tmp", checks: []
            )
        ) { error in
            XCTAssertEqual(error as? Verification.Runner.Failure, .alreadyRunning("abcd1234"))
        }
    }

    func test_runID_isEightLowercaseHexCharacters() {
        let id = Verification.Runner().makeRunID()
        XCTAssertEqual(id.count, 8)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, id)
    }

    /// "Unique for the app's lifetime" is enforced, not hoped for.
    func test_runID_neverReissuesAnId() {
        let runner = Verification.Runner()
        var seen: Set<String> = []
        for _ in 0 ..< 2000 {
            XCTAssertTrue(seen.insert(runner.makeRunID()).inserted)
        }
    }
}
