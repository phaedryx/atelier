// ABOUTME: Tests for ReviewCommentEvent.parse — the JS->Swift comment message decoding.
// ABOUTME: Covers added/edited/deleted bodies, optional fields, and malformed-input rejection.

import XCTest
@testable import Atelier

final class ReviewCommentEventTests: XCTestCase {
    func testParseAdded() {
        let event = ReviewCommentEvent.parse([
            "type": "commentAdded", "filePath": "a.swift", "side": "new",
            "line": 4, "endLine": 6, "lineText": "let x", "text": "note",
        ])
        XCTAssertEqual(event, .added(filePath: "a.swift", side: .new, line: 4, endLine: 6, lineText: "let x", text: "note"))
    }

    func testParseAddedWithoutEndLineOrLineText() {
        let event = ReviewCommentEvent.parse([
            "type": "commentAdded", "filePath": "a.swift", "side": "old", "line": 9, "text": "note",
        ])
        XCTAssertEqual(event, .added(filePath: "a.swift", side: .old, line: 9, endLine: nil, lineText: "", text: "note"))
    }

    func testParseEdited() {
        let id = UUID()
        let event = ReviewCommentEvent.parse(["type": "commentEdited", "id": id.uuidString, "text": "revised"])
        XCTAssertEqual(event, .edited(id: id, text: "revised"))
    }

    func testParseDeleted() {
        let id = UUID()
        let event = ReviewCommentEvent.parse(["type": "commentDeleted", "id": id.uuidString])
        XCTAssertEqual(event, .deleted(id: id))
    }

    func testParseRejectsMalformedBodies() {
        XCTAssertNil(ReviewCommentEvent.parse(["type": "commentAdded"])) // no path/line/text
        XCTAssertNil(ReviewCommentEvent.parse(["type": "commentAdded", "filePath": "a", "side": "sideways", "line": 1, "text": "x"]))
        XCTAssertNil(ReviewCommentEvent.parse(["type": "commentEdited", "id": "not-a-uuid", "text": "x"]))
        XCTAssertNil(ReviewCommentEvent.parse(["type": "somethingElse"]))
    }
}
