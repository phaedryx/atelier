// ABOUTME: Tests for ChangeReviewFormatter: the [Code Review] text block sent to the agent.
// ABOUTME: Covers header labels per mode, file/line sorting, ranges, and orphaned comments.

@testable import Atelier
import XCTest

final class ChangeReviewFormatterTests: XCTestCase {
    private func comment(
        path: String, side: DiffSide = .new, line: Int, endLine: Int? = nil,
        lineText: String = "let x = 1", text: String, orphaned: Bool = false,
        mode: ChangesMode = .uncommitted
    ) -> ReviewComment {
        ReviewComment(
            id: UUID(), filePath: path, mode: mode, side: side, line: line,
            endLine: endLine, lineText: lineText, text: text, isOrphaned: orphaned
        )
    }

    func testSingleFileUncommittedPayload() {
        let payload = ChangeReviewFormatter.payload(
            comments: [
                comment(path: "Sources/A.swift", line: 42, text: "use the cached bridge"),
                comment(path: "Sources/A.swift", line: 10, endLine: 15, text: "collapse into one guard"),
                comment(path: "Sources/A.swift", side: .old, line: 88, text: "why was this removed?"),
            ],
            mode: .uncommitted,
            branch: "change-annotation",
            baseBranch: "main"
        )
        XCTAssertEqual(payload, """
        [Code Review] change-annotation (uncommitted changes)

        Sources/A.swift
          L10-L15 (new): collapse into one guard
          L42 (new): use the cached bridge
          L88 (old): why was this removed?
        """)
    }

    func testMultiFileSortedByPathAndLine() {
        let payload = ChangeReviewFormatter.payload(
            comments: [
                comment(path: "b.swift", line: 5, text: "second file"),
                comment(path: "a.swift", line: 9, text: "first file late"),
                comment(path: "a.swift", line: 2, text: "first file early"),
            ],
            mode: .branch,
            branch: "change-annotation",
            baseBranch: "main"
        )
        XCTAssertEqual(payload, """
        [Code Review] change-annotation (vs main)

        a.swift
          L2 (new): first file early
          L9 (new): first file late

        b.swift
          L5 (new): second file
        """)
    }

    func testOrphanedCommentShowsFormerLineText() {
        let payload = ChangeReviewFormatter.payload(
            comments: [comment(path: "a.swift", line: 7, lineText: "let store = x", text: "still relevant?", orphaned: true)],
            mode: .uncommitted,
            branch: "change-annotation",
            baseBranch: nil
        )
        XCTAssertTrue(payload.contains("L7 (orphaned, was: \"let store = x\"): still relevant?"), payload)
    }

    func testNilBranchAndBaseFallBack() {
        let payload = ChangeReviewFormatter.payload(
            comments: [comment(path: "a.swift", line: 1, text: "x", mode: .branch)],
            mode: .branch, branch: nil, baseBranch: nil
        )
        XCTAssertTrue(payload.hasPrefix("[Code Review] worktree (vs base)"), payload)
    }
}
