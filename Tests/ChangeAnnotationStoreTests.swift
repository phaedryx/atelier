// ABOUTME: Tests for ChangeAnnotationStore: CRUD, mode scoping, and text sanitization.
// ABOUTME: Verifies comment anchoring, scoping by mode and file, and terminal-safe text handling.

import XCTest
@testable import Atelier

@MainActor
final class ChangeAnnotationStoreTests: XCTestCase {
    func testAddStoresSanitizedComment() throws {
        let store = ChangeAnnotationStore()
        let c = try XCTUnwrap(store.add(
            filePath: "Sources/A.swift", mode: .uncommitted, side: .new,
            line: 42, endLine: nil, lineText: "let x = 1",
            text: "why\tnot\u{07} a constant?"
        ))
        XCTAssertEqual(store.comments.count, 1)
        XCTAssertEqual(c.text, "why not a constant?")
        XCTAssertEqual(c.line, 42)
        XCTAssertNil(c.endLine)
        XCTAssertFalse(c.isOrphaned)
    }

    func testCommentsScopedByModeAndPath() {
        let store = ChangeAnnotationStore()
        store.add(filePath: "a.swift", mode: .uncommitted, side: .new, line: 1, endLine: nil, lineText: "x", text: "one")
        store.add(filePath: "a.swift", mode: .branch, side: .new, line: 2, endLine: nil, lineText: "y", text: "two")
        store.add(filePath: "b.swift", mode: .uncommitted, side: .new, line: 3, endLine: nil, lineText: "z", text: "three")

        XCTAssertEqual(store.comments(mode: .uncommitted).count, 2)
        XCTAssertEqual(store.comments(mode: .branch).count, 1)
        XCTAssertEqual(store.comments(for: "a.swift", mode: .uncommitted).map(\.text), ["one"])
    }

    func testUpdateTextSanitizes() throws {
        let store = ChangeAnnotationStore()
        let c = try XCTUnwrap(store.add(filePath: "a.swift", mode: .branch, side: .old, line: 5, endLine: 7, lineText: "old", text: "first"))
        store.updateText(id: c.id, text: "second\nline")
        XCTAssertEqual(store.comments.first?.text, "second line")
    }

    func testDeleteRemovesOnlyMatchingComment() throws {
        let store = ChangeAnnotationStore()
        let keep = try XCTUnwrap(store.add(filePath: "a.swift", mode: .branch, side: .new, line: 1, endLine: nil, lineText: "x", text: "keep"))
        let drop = try XCTUnwrap(store.add(filePath: "a.swift", mode: .branch, side: .new, line: 2, endLine: nil, lineText: "y", text: "drop"))
        store.delete(id: drop.id)
        XCTAssertEqual(store.comments.map(\.id), [keep.id])
    }

    func testClearRemovesOnlyGivenMode() {
        let store = ChangeAnnotationStore()
        store.add(filePath: "a.swift", mode: .uncommitted, side: .new, line: 1, endLine: nil, lineText: "x", text: "u")
        store.add(filePath: "a.swift", mode: .branch, side: .new, line: 1, endLine: nil, lineText: "x", text: "b")
        store.clear(mode: .uncommitted)
        XCTAssertEqual(store.comments.map(\.text), ["b"])
    }

    func testSanitizeStripsControlCharactersAndTrims() {
        // Tab and \n become spaces; ESC (C0), BEL (C0), CSI (C1) and \r are
        // stripped entirely — so "\r\n" collapses to ONE space.
        XCTAssertEqual(ChangeAnnotationStore.sanitize("  a\tb\u{1B}[31mc\r\nd  "), "a b[31mc d")
        XCTAssertEqual(ChangeAnnotationStore.sanitize("\u{07}\u{9B}plain"), "plain")
    }

    func testAddIgnoresEmptySanitizedText() {
        let store = ChangeAnnotationStore()
        let c = store.add(filePath: "a.swift", mode: .branch, side: .new, line: 1, endLine: nil, lineText: "x", text: " \u{07} ")
        XCTAssertNil(c)
        XCTAssertTrue(store.comments.isEmpty)
    }

    func testAddSanitizesAnchorLineText() throws {
        let store = ChangeAnnotationStore()
        let c = try XCTUnwrap(store.add(filePath: "a.swift", mode: .branch, side: .new, line: 1, endLine: nil, lineText: "  let x\u{1B}[31m = 1  ", text: "note"))
        XCTAssertEqual(c.lineText, "let x[31m = 1")
    }

    // MARK: - Re-anchoring

    private func addComment(
        _ store: ChangeAnnotationStore, path: String = "a.swift", side: DiffSide = .new,
        line: Int, endLine: Int? = nil, lineText: String, mode: ChangesMode = .uncommitted
    ) -> ReviewComment {
        store.add(filePath: path, mode: mode, side: side, line: line, endLine: endLine, lineText: lineText, text: "note")!
    }

    func testReanchorExactHoldKeepsLine() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 2, lineText: "beta")
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "alpha\nbeta\ngamma")], presentPaths: ["a.swift"])
        XCTAssertEqual(store.comments.first?.line, 2)
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorMatchesLineWithInteriorTab() {
        // The anchor is sanitized on add (tabs collapsed to spaces); the
        // re-anchor haystack must normalize the same way or every line with
        // an interior tab falsely orphans on refresh.
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 2, lineText: "case 1:\tprint(x)")
        store.reanchor(
            mode: .uncommitted,
            texts: ["a.swift": (original: "", modified: "first\ncase 1:\tprint(x)\n")],
            presentPaths: ["a.swift"]
        )
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorFollowsMovedLineAndShiftsRange() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 2, endLine: 3, lineText: "beta")
        // Two lines inserted above: beta moved from 2 to 4.
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "new1\nnew2\nalpha\nbeta\ngamma")], presentPaths: ["a.swift"])
        XCTAssertEqual(store.comments.first?.line, 4)
        XCTAssertEqual(store.comments.first?.endLine, 5)
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorTieBreaksToEarlierLine() {
        // "dup" appears at equal distance before and after the old anchor: earlier wins.
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 3, lineText: "dup")
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "x\ndup\nmoved\ndup\ny")], presentPaths: ["a.swift"])
        XCTAssertEqual(store.comments.first?.line, 2)
    }

    func testReanchorOldSideMatchesAgainstOriginalText() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, side: .old, line: 1, lineText: "removed line")
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "header\nremoved line", modified: "header")], presentPaths: ["a.swift"])
        XCTAssertEqual(store.comments.first?.line, 2)
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorOrphansWhenLineVanishes() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 2, lineText: "beta")
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "alpha\ngamma")], presentPaths: ["a.swift"])
        XCTAssertTrue(store.comments.first!.isOrphaned)
        XCTAssertEqual(store.comments.first?.line, 2) // line kept for the payload
    }

    func testReanchorOrphansWhenFileLeavesDiff() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 1, lineText: "x")
        store.reanchor(mode: .uncommitted, texts: [:], presentPaths: [])
        XCTAssertTrue(store.comments.first!.isOrphaned)
    }

    func testReanchorUnorphansWhenLineReturns() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 1, lineText: "back")
        store.reanchor(mode: .uncommitted, texts: [:], presentPaths: [])
        XCTAssertTrue(store.comments.first!.isOrphaned)
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "back")], presentPaths: ["a.swift"])
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorLeavesFileWithoutTextsAlone() {
        // Present in the diff but deferred/binary (no texts): leave the comment untouched.
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 9, lineText: "x")
        store.reanchor(mode: .uncommitted, texts: [:], presentPaths: ["a.swift"])
        XCTAssertEqual(store.comments.first?.line, 9)
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorOnlyTouchesGivenMode() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 1, lineText: "gone", mode: .branch)
        store.reanchor(mode: .uncommitted, texts: [:], presentPaths: [])
        XCTAssertFalse(store.comments.first!.isOrphaned)
    }

    func testReanchorBlankAnchorOnlyHoldsExactPosition() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 2, lineText: "")
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "a\n\nb")], presentPaths: ["a.swift"])
        XCTAssertFalse(store.comments.first!.isOrphaned)
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "a\nb")], presentPaths: ["a.swift"])
        XCTAssertTrue(store.comments.first!.isOrphaned)
    }

    func testMatchLineRespectsWindow() {
        let lines = Array(repeating: "filler", count: 120) + ["needle"]
        XCTAssertNil(ChangeAnnotationStore.matchLine(anchor: "needle", near: 1, in: lines, window: 50))
        XCTAssertEqual(ChangeAnnotationStore.matchLine(anchor: "needle", near: 100, in: lines, window: 50), 121)
    }

    func testReanchorIgnoresPhantomLineFromTrailingNewline() {
        let store = ChangeAnnotationStore()
        _ = addComment(store, line: 3, lineText: "")
        // File has 2 real lines + trailing newline; line 3 must NOT hold on the phantom "".
        store.reanchor(mode: .uncommitted, texts: ["a.swift": (original: "", modified: "alpha\nbeta\n")], presentPaths: ["a.swift"])
        XCTAssertTrue(store.comments.first!.isOrphaned)
    }
}
