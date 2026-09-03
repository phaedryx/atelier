// ABOUTME: Tests for GitHub.PR JSON decoding, check rollup reduction, and status mapping.
// ABOUTME: Covers both statusCheckRollup shapes gh emits, which the live repo alone never exercises.

@testable import Atelier
import XCTest

final class GitHubPRTests: XCTestCase {
    // MARK: - Helpers

    /// Wraps PR fields in the array shape `gh pr list --json` returns.
    private func listJSON(_ objects: String...) -> Data {
        Data("[\(objects.joined(separator: ","))]".utf8)
    }

    private func pr(
        number: Int = 1,
        state: String = "OPEN",
        isDraft: Bool = false,
        reviewDecision: String = "",
        rollup: String = "[]"
    ) -> String {
        """
        {
          "number": \(number),
          "title": "Some title",
          "state": "\(state)",
          "headRefName": "feat/branch-\(number)",
          "url": "https://github.com/o/r/pull/\(number)",
          "isDraft": \(isDraft),
          "reviewDecision": "\(reviewDecision)",
          "statusCheckRollup": \(rollup)
        }
        """
    }

    private func checkRun(status: String, conclusion: String?) -> String {
        let conclusionField = conclusion.map { "\"\($0)\"" } ?? "null"
        return """
        {"__typename":"CheckRun","name":"build","status":"\(status)","conclusion":\(conclusionField)}
        """
    }

    private func statusContext(state: String) -> String {
        """
        {"__typename":"StatusContext","context":"ci/legacy","state":"\(state)"}
        """
    }

    // MARK: - Basic decoding

    func testDecodesCoreFields() {
        let prs = GitHub.PR.decode(listJSON(pr(number: 42)))
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].number, 42)
        XCTAssertEqual(prs[0].title, "Some title")
        XCTAssertEqual(prs[0].state, "OPEN")
        XCTAssertEqual(prs[0].branch, "feat/branch-42")
        XCTAssertEqual(prs[0].url, "https://github.com/o/r/pull/42")
    }

    func testMalformedJSONDecodesToEmpty() {
        XCTAssertTrue(GitHub.PR.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(GitHub.PR.decode(Data()).isEmpty)
    }

    func testEntryMissingRequiredFieldIsSkippedWithoutDroppingTheRest() {
        let json = Data("""
        [{"number":1},\(pr(number: 2))]
        """.utf8)
        let prs = GitHub.PR.decode(json)
        XCTAssertEqual(prs.map(\.number), [2])
    }

    /// Older callers request a narrower --json set; those fields must default rather than
    /// fail the whole entry.
    func testAbsentOptionalFieldsDefault() {
        let json = Data("""
        [{"number":7,"title":"t","state":"OPEN","headRefName":"b","url":"u"}]
        """.utf8)
        let prs = GitHub.PR.decode(json)
        XCTAssertEqual(prs.count, 1)
        XCTAssertFalse(prs[0].isDraft)
        XCTAssertNil(prs[0].reviewDecision)
        XCTAssertEqual(prs[0].checks, .none)
    }

    // MARK: - reviewDecision

    /// gh returns "" rather than null when no review is required. Left as-is it decodes to a
    /// non-nil empty string and renders a blank Review row.
    func testEmptyReviewDecisionNormalizesToNil() {
        let prs = GitHub.PR.decode(listJSON(pr(reviewDecision: "")))
        XCTAssertNil(prs[0].reviewDecision)
    }

    func testReviewDecisionPreserved() {
        let prs = GitHub.PR.decode(listJSON(pr(reviewDecision: "CHANGES_REQUESTED")))
        XCTAssertEqual(prs[0].reviewDecision, "CHANGES_REQUESTED")
    }

    // MARK: - Check rollup: CheckRun shape

    func testEmptyRollupIsNone() {
        let prs = GitHub.PR.decode(listJSON(pr(rollup: "[]")))
        XCTAssertEqual(prs[0].checks, .none)
    }

    func testAllSuccessfulCheckRunsArePassing() {
        let rollup = "[\(checkRun(status: "COMPLETED", conclusion: "SUCCESS"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .passing)
    }

    func testFailedCheckRunIsFailing() {
        let rollup = """
        [\(checkRun(status: "COMPLETED", conclusion: "SUCCESS")),\
        \(checkRun(status: "COMPLETED", conclusion: "FAILURE"))]
        """
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .failing)
    }

    func testInProgressCheckRunIsPending() {
        let rollup = """
        [\(checkRun(status: "COMPLETED", conclusion: "SUCCESS")),\
        \(checkRun(status: "IN_PROGRESS", conclusion: nil))]
        """
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .pending)
    }

    func testQueuedCheckRunIsPending() {
        let rollup = "[\(checkRun(status: "QUEUED", conclusion: nil))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .pending)
    }

    /// A failure outranks a still-running check: the run is already doomed.
    func testFailureOutranksPending() {
        let rollup = """
        [\(checkRun(status: "IN_PROGRESS", conclusion: nil)),\
        \(checkRun(status: "COMPLETED", conclusion: "FAILURE"))]
        """
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .failing)
    }

    func testTimedOutAndActionRequiredCountAsFailing() {
        for conclusion in ["TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"] {
            let rollup = "[\(checkRun(status: "COMPLETED", conclusion: conclusion))]"
            XCTAssertEqual(
                GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks,
                .failing,
                "\(conclusion) should be failing"
            )
        }
    }

    /// Matches GitHub's own rollup: these are not failures.
    func testSkippedNeutralAndCancelledAreNotFailures() {
        for conclusion in ["SKIPPED", "NEUTRAL", "CANCELLED"] {
            let rollup = """
            [\(checkRun(status: "COMPLETED", conclusion: "SUCCESS")),\
            \(checkRun(status: "COMPLETED", conclusion: conclusion))]
            """
            XCTAssertEqual(
                GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks,
                .passing,
                "\(conclusion) should not fail the rollup"
            )
        }
    }

    /// Only SKIPPED/NEUTRAL/CANCELLED with nothing else: there is no success to report.
    func testOnlyNonFailingNonSuccessConclusionsIsNone() {
        let rollup = "[\(checkRun(status: "COMPLETED", conclusion: "SKIPPED"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .none)
    }

    // MARK: - Check rollup: StatusContext shape

    /// StatusContext entries carry `state` and no `status`/`conclusion`. A reducer that only
    /// reads `status` treats every one of them as never-completed and reports pending forever.
    func testStatusContextSuccessIsPassing() {
        let rollup = "[\(statusContext(state: "SUCCESS"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .passing)
    }

    func testStatusContextFailureIsFailing() {
        let rollup = "[\(statusContext(state: "FAILURE"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .failing)
    }

    func testStatusContextErrorIsFailing() {
        let rollup = "[\(statusContext(state: "ERROR"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .failing)
    }

    func testStatusContextPendingIsPending() {
        let rollup = "[\(statusContext(state: "PENDING"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .pending)
    }

    func testStatusContextExpectedIsPending() {
        let rollup = "[\(statusContext(state: "EXPECTED"))]"
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .pending)
    }

    // MARK: - Check rollup: mixed shapes

    func testMixedShapesReduceTogether() {
        let rollup = """
        [\(checkRun(status: "COMPLETED", conclusion: "SUCCESS")),\
        \(statusContext(state: "FAILURE"))]
        """
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .failing)
    }

    func testMixedShapesAllPassing() {
        let rollup = """
        [\(checkRun(status: "COMPLETED", conclusion: "SUCCESS")),\
        \(statusContext(state: "SUCCESS"))]
        """
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .passing)
    }

    func testUnrecognizedRollupEntryIsIgnored() {
        let rollup = """
        [{"__typename":"SomethingNew","weird":true},\
        \(checkRun(status: "COMPLETED", conclusion: "SUCCESS"))]
        """
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(rollup: rollup)))[0].checks, .passing)
    }

    // MARK: - Status mapping

    func testDraftOutranksOpen() {
        let prs = GitHub.PR.decode(listJSON(pr(state: "OPEN", isDraft: true)))
        XCTAssertEqual(prs[0].status, .draft)
    }

    func testOpenStatus() {
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(state: "OPEN")))[0].status, .open)
    }

    func testMergedStatus() {
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(state: "MERGED")))[0].status, .merged)
    }

    func testClosedUnmergedStatus() {
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(state: "CLOSED")))[0].status, .closed)
    }

    /// A merged PR is never a draft, whatever the flag says.
    func testMergedIsNeverDraft() {
        let prs = GitHub.PR.decode(listJSON(pr(state: "MERGED", isDraft: true)))
        XCTAssertEqual(prs[0].status, .merged)
    }

    func testUnknownStateFallsBackToClosed() {
        XCTAssertEqual(GitHub.PR.decode(listJSON(pr(state: "BOGUS")))[0].status, .closed)
    }

    // MARK: - Branch tiebreak

    /// `gh pr list --state all` can return several PRs for one branch. Retaining CLOSED PRs
    /// means an abandoned one can now shadow the live PR, which the old filter hid.
    func testOpenBeatsClosedForSameBranch() {
        let older = pr(number: 1, state: "CLOSED")
        let newer = pr(number: 2, state: "OPEN")
        let prs = GitHub.PR.decode(Data("""
        [\(older.replacingOccurrences(of: "feat/branch-1", with: "shared")),\
        \(newer.replacingOccurrences(of: "feat/branch-2", with: "shared"))]
        """.utf8))
        XCTAssertEqual(GitHub.PR.byBranch(prs)["shared"]?.number, 2)
    }

    func testOpenBeatsMergedForSameBranch() {
        let merged = pr(number: 5, state: "MERGED").replacingOccurrences(of: "feat/branch-5", with: "shared")
        let open = pr(number: 3, state: "OPEN").replacingOccurrences(of: "feat/branch-3", with: "shared")
        let prs = GitHub.PR.decode(Data("[\(merged),\(open)]".utf8))
        XCTAssertEqual(GitHub.PR.byBranch(prs)["shared"]?.number, 3)
    }

    func testMergedBeatsClosedForSameBranch() {
        let closed = pr(number: 9, state: "CLOSED").replacingOccurrences(of: "feat/branch-9", with: "shared")
        let merged = pr(number: 4, state: "MERGED").replacingOccurrences(of: "feat/branch-4", with: "shared")
        let prs = GitHub.PR.decode(Data("[\(closed),\(merged)]".utf8))
        XCTAssertEqual(GitHub.PR.byBranch(prs)["shared"]?.number, 4)
    }

    /// Same status: the most recent PR wins, which is the highest number.
    func testHighestNumberWinsWithinSameStatus() {
        let a = pr(number: 10, state: "CLOSED").replacingOccurrences(of: "feat/branch-10", with: "shared")
        let b = pr(number: 20, state: "CLOSED").replacingOccurrences(of: "feat/branch-20", with: "shared")
        let prs = GitHub.PR.decode(Data("[\(a),\(b)]".utf8))
        XCTAssertEqual(GitHub.PR.byBranch(prs)["shared"]?.number, 20)
    }

    func testDistinctBranchesAreAllKept() {
        let prs = GitHub.PR.decode(listJSON(pr(number: 1), pr(number: 2)))
        let byBranch = GitHub.PR.byBranch(prs)
        XCTAssertEqual(byBranch.count, 2)
        XCTAssertEqual(byBranch["feat/branch-1"]?.number, 1)
        XCTAssertEqual(byBranch["feat/branch-2"]?.number, 2)
    }
}
