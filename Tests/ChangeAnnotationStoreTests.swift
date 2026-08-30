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
}
