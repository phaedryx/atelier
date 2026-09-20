// ABOUTME: Pins the digest an agent reads — ordering, opacity, budget, and the
// ABOUTME: three board states that must never share a sentence.

@testable import Atelier
import XCTest

final class WhiteboardDigestTests: XCTestCase {
    private func digest(
        _ json: String,
        render: Whiteboard.Digest.Render = .current(width: 1360, height: 1520, path: "/tmp/b/board.png"),
        updated: String = "14s ago",
        assets: [String: String] = [:],
        budget: Int = Whiteboard.Digest.maxBytes
    ) -> String {
        Whiteboard.Digest.text(
            load: Whiteboard.SceneLoad.parse(json),
            render: render,
            updated: updated,
            assets: assets,
            budget: budget
        )
    }

    /// A board of `count` labelled boxes, for the budget tests.
    private func crowded(_ count: Int) -> String {
        let elements = (0 ..< count).map {
            """
            {"id":"n\($0)","type":"rectangle","x":0,"y":0,"width":10,"height":10,
             "isDeleted":false,"text":"a reasonably long label number \($0)"}
            """
        }.joined(separator: ",")
        return "{\"type\":\"excalidraw\",\"elements\":[\(elements)]}"
    }

    // MARK: - The three states, which must never share a sentence

    func test_anEmptyBoardSaysItIsEmpty_andIsNotAnError() {
        let text = digest("""
        {"type":"excalidraw","elements":[]}
        """, render: .none)
        XCTAssertTrue(text.lowercased().contains("empty"))
        // Every workstream starts here. Nothing may suggest a fault.
        XCTAssertFalse(text.lowercased().contains("could not"))
        XCTAssertFalse(text.lowercased().contains("error"))
        // And no picture is worth pointing at for a board with nothing on it.
        XCTAssertFalse(text.contains("board.png"))
    }

    func test_anUnreadableBoardSaysSo_andNamesTheFile() {
        let text = digest("{not json", render: .none)
        XCTAssertTrue(text.contains("board.excalidraw"))
        XCTAssertTrue(text.lowercased().contains("could not be read"))
        // The one thing it must not say is the empty board's sentence: the two
        // send a reader to completely different places.
        XCTAssertFalse(text.lowercased().contains("nothing has been drawn"))
    }

    // MARK: - The board itself

    func test_elementsAppearInFileOrder_withTheirRealIDs() {
        let text = digest(WhiteboardSceneTests.fixture)
        let body = text
            .components(separatedBy: "\n")
            .filter { line in
                ["rectA", "rectB", "arrowA", "loose", "freeA", "imgA"].contains { line.hasPrefix($0) }
            }
        XCTAssertEqual(body.count, 6)
        XCTAssertTrue(body[0].hasPrefix("rectA"))
        XCTAssertTrue(body[2].hasPrefix("arrowA"))
        XCTAssertTrue(body[5].hasPrefix("imgA"))
    }

    func test_aBoxCarriesItsLabelAndItsGeometry() {
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.contains("box"), text)
        XCTAssertTrue(text.contains("\"Auth service\""), text)
        XCTAssertTrue(text.contains("at 120,80"), text)
        XCTAssertTrue(text.contains("240×90"), text)
    }

    func test_anArrowNamesTheElementsItJoins() {
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.contains("rectA → rectB"), text)
        XCTAssertTrue(text.contains("\"issues\""), text)
    }

    func test_aStrokeIsABoundingBoxAndNothingMore() throws {
        let text = digest(WhiteboardSceneTests.fixture)
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("freeA") })
        XCTAssertTrue(line.contains("stroke"), line)
        XCTAssertTrue(line.contains("4 pts"), line)
        XCTAssertTrue(line.contains("bbox 100,400 → 380,560"), line)
    }

    func test_anImageIsPointedAtByAnAbsolutePath() {
        // The board lives in the cache directory and the agent's cwd is its
        // worktree, so a relative `assets/<id>` is unopenable from where the
        // agent stands — and it is shaped like a path, so an agent wanting a
        // closer look would try it and get nothing.
        let text = digest(
            WhiteboardSceneTests.fixture,
            assets: ["spikeasset0001": "/tmp/b/assets/spikeasset0001.png"]
        )
        XCTAssertTrue(text.contains("/tmp/b/assets/spikeasset0001.png"), text)
    }

    func test_anImageWithNoFileOnDiskSaysSo_ratherThanNamingAPathThatWouldNotOpen() {
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.contains("fileId=spikeasset0001"), text)
        XCTAssertTrue(text.contains("no file in assets/"), text)
        // Nothing that reads as an openable path.
        XCTAssertFalse(text.contains("assets/spikeasset0001.png"), text)
    }

    func test_anAgentAuthoredElementIsMarked() {
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "text":"check the TTL",
         "customData":{"\(Whiteboard.Element.authorKey)":"\(Whiteboard.Element.agentAuthorValue)"}}]}
        """)
        XCTAssertTrue(text.contains("(agent)"), text)
    }

    func test_aUserAuthoredElementIsNotMarked() {
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertFalse(text.contains("(agent)"), text)
    }

    func test_anImagesCaptionIsRenderedUnderIt() {
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"i","type":"image","x":60,"y":620,"width":800,"height":450,"isDeleted":false,
         "fileId":"abc","customData":{"\(Whiteboard.Element.captionKey)":"Settings pane, Environment tab"}}]}
        """)
        XCTAssertTrue(text.contains("caption: \"Settings pane, Environment tab\""), text)
    }

    // MARK: - The closing line

    func test_theClosingLineIsAlwaysThereForABoardWithContent() {
        // Without it an agent reads five boxes and concludes that is the whole
        // board. It is the load-bearing sentence of this format, not a footer.
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.hasSuffix(Whiteboard.Digest.closingLine), text)
        XCTAssertTrue(Whiteboard.Digest.closingLine.contains("board.png"))
    }

    func test_theClosingLineSurvivesTruncation() {
        // The failure this prevents: a digest cut to fit, losing the one line
        // that tells the reader it is not looking at everything.
        let text = digest(crowded(500), budget: 1200)
        XCTAssertTrue(text.hasSuffix(Whiteboard.Digest.closingLine), text)
    }

    // MARK: - The budget

    func test_aTruncatedDigestSaysSo_andCountsWhatItLeftOut() {
        // A silently truncated digest is the failure where an agent reasons
        // confidently about a board it half saw. Following VerificationSummary.
        let text = digest(crowded(500), budget: 1200)
        XCTAssertTrue(text.contains("more elements"), text)
        XCTAssertTrue(text.contains("board.png"), text)
    }

    func test_aTruncatedDigestStaysUnderItsBudget() {
        let text = digest(crowded(500), budget: 1200)
        XCTAssertLessThanOrEqual(text.utf8.count, 1200)
    }

    func test_aDigestThatFitsSaysNothingAboutTruncation() {
        let text = digest(crowded(3))
        XCTAssertFalse(text.contains("more elements"), text)
    }

    func test_theOmittedCountIsTheRealOne() {
        // "… and N more" has to be the number actually left out. A count taken
        // from the wrong side of the loop reads as authoritative and is not.
        let text = digest(crowded(500), budget: 1200)
        let listed = text
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("n") && $0.contains("box") }
            .count
        XCTAssertTrue(text.contains("and \(500 - listed) more elements"), text)
    }

    func test_oneEnormousLabelDoesNotBlowTheBudget() {
        // Element text is the user's and nothing bounds it. A 200KB label in a
        // single shape is the whiteboard's version of `verification.yaml`'s
        // 200KB check name, and it has to be cut on a UTF-8 boundary.
        let huge = String(repeating: "é", count: 100_000)
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"\(huge)"}]}
        """, budget: 900)
        XCTAssertLessThanOrEqual(text.utf8.count, 900)
        XCTAssertFalse(text.contains("\u{FFFD}"), "cut mid-scalar")
        XCTAssertTrue(text.hasSuffix(Whiteboard.Digest.closingLine), text)
    }

    func test_aNewlineInALabelDoesNotBreakTheLineFormat() {
        // Each element is one line, and a reader counting lines has to be right.
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"first\\nsecond"}]}
        """)
        let elementLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("n  ") }
        XCTAssertEqual(elementLines.count, 1, text)
    }

    // MARK: - The render line

    func test_aCurrentRenderIsPointedAtByItsAbsolutePath() {
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.contains("/tmp/b/board.png"), text)
        XCTAssertTrue(text.contains("1360×1520"), text)
    }

    func test_aStaleRenderSaysTheDigestIsCurrentAndThePictureIsNot() {
        // The specified failure behaviour: never let an agent read a stale
        // picture as fresh.
        let text = digest(WhiteboardSceneTests.fixture, render: .stale(path: "/tmp/b/board.png"))
        XCTAssertTrue(text.lowercased().contains("earlier version"), text)
        XCTAssertTrue(text.lowercased().contains("digest below is current"), text)
    }

    func test_noRenderYetSaysSo_ratherThanPointingAtNothing() {
        let text = digest(WhiteboardSceneTests.fixture, render: .none)
        XCTAssertFalse(text.contains("/tmp/b/board.png"))
        XCTAssertTrue(text.lowercased().contains("no board.png"), text)
    }

    func test_theHeaderCountsLogicalElements_notRawOnes() {
        // Nine raw elements in the fixture, six the user would count. A header
        // saying nine over a list of six is the digest contradicting itself.
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.contains("6 elements"), text)
        XCTAssertTrue(text.contains("updated 14s ago"), text)
    }

    // MARK: - the note kind

    func test_aNoteRendersAsNote_andNotAsBox() {
        // An annotation and a diagram node are different things, and the digest
        // reporting them differently is what lets an agent re-read its own
        // board and tell its commentary apart from the structure it drew.
        let text = digest("""
        {"type":"excalidraw","elements":[
          {"id":"n1","type":"rectangle","x":640,"y":200,"width":200,"height":80,
           "text":"check the TTL","customData":{"atelierKind":"note","atelierAuthor":"agent"}}]}
        """)
        XCTAssertTrue(text.contains("n1  note"), text)
        XCTAssertFalse(text.contains("n1  box"), text)
        XCTAssertTrue(text.contains("(agent)"), text)
    }
}
