// ABOUTME: The page-state decode behind `Host.liveState` — required fields, no guesses.
// ABOUTME: No webview: `decodeLiveState` takes the dictionary, the way `Bridge.handle` does.

@testable import Atelier
import XCTest

@MainActor
final class WhiteboardLiveStateTests: XCTestCase {
    private typealias Host = Whiteboard.Host
    private typealias Write = Whiteboard.Write

    /// Exactly the shape `window.__whiteboardState()` returns for a board with
    /// something on it, as `JSONSerialization` hands it over — every number an
    /// `NSNumber`, which is the guesswork `callJS`'s JSON round trip exists to
    /// keep out of the decode.
    private func pageState(
        ids: [String] = ["n1", "i1"],
        imageIDs: [String] = ["i1"],
        originX: Double = 40,
        nextY: Double = 500
    ) -> [String: Any] {
        [
            "ids": ids,
            "imageIDs": imageIDs,
            "originX": NSNumber(value: originX),
            "nextY": NSNumber(value: nextY),
        ]
    }

    private func assertNotReady(_ raw: [String: Any], _ message: String) {
        do {
            _ = try Host.decodeLiveState(raw)
            XCTFail("Expected .notReady: \(message)")
        } catch {
            XCTAssertEqual(error as? Host.WriteFailure, .notReady, message)
        }
    }

    // MARK: - What the page really sends

    func test_aFullPageStateDecodesWhole() throws {
        let live = try Host.decodeLiveState(pageState())
        XCTAssertEqual(live.ids, ["n1", "i1"])
        XCTAssertEqual(live.imageIDs, ["i1"])
        XCTAssertEqual(live.layout, Write.Layout(originX: 40, nextY: 500))
    }

    /// The page's own empty-board answer, which is the one case where its
    /// numbers coincide with `Layout.fallback` — and it arrives as an answer
    /// rather than as a guess, which is the whole distinction here.
    func test_anEmptyBoardDecodesRatherThanBeingTreatedAsNoAnswer() throws {
        let live = try Host.decodeLiveState(
            pageState(ids: [], imageIDs: [], originX: 100, nextY: 100)
        )
        XCTAssertTrue(live.ids.isEmpty)
        XCTAssertTrue(live.imageIDs.isEmpty)
        XCTAssertEqual(live.layout, Write.Layout(originX: 100, nextY: 100))
    }

    func test_aBoardWithNoImagesIsNotTheSameAsNoImageIDsField() throws {
        let live = try Host.decodeLiveState(pageState(ids: ["n1"], imageIDs: []))
        XCTAssertTrue(live.imageIDs.isEmpty)
        var missing = pageState(ids: ["n1"])
        missing["imageIDs"] = nil
        assertNotReady(missing, "an absent field is a protocol error, an empty list is a fact")
    }

    // MARK: - Every field is required

    func test_aStateMissingItsImageIDsIsRefusedRatherThanGuessed() {
        var raw = pageState()
        raw["imageIDs"] = nil
        assertNotReady(raw, "imageIDs is required")
    }

    func test_aStateMissingItsIDsIsRefused() {
        var raw = pageState()
        raw["ids"] = nil
        assertNotReady(raw, "ids is required")
    }

    func test_aStateMissingEitherLayoutFieldIsRefused() {
        for field in ["originX", "nextY"] {
            var raw = pageState()
            raw[field] = nil
            assertNotReady(raw, "\(field) is required")
        }
    }

    func test_aFieldOfTheWrongTypeIsRefused() {
        var raw = pageState()
        raw["imageIDs"] = "i1"
        assertNotReady(raw, "imageIDs must be a list of ids")
        raw = pageState()
        raw["originX"] = "40"
        assertNotReady(raw, "originX must be a number")
    }

    func test_anEmptyDictionaryIsRefused() {
        assertNotReady([:], "a page that answered nothing is not a page in a degraded state")
    }

    // MARK: - Why no fallback is available any more

    /// `imageIDs` used to fall back to *every* id, and this is what that value
    /// would now mean. The set is read in both directions:
    /// `captionNeedsImage` refuses a caption on a non-image, and
    /// `textNeedsCanvasText` refuses `text` on an image — so "every id is an
    /// image" passes every caption and refuses every `text`, while the "no
    /// images" reading it was chosen over does the exact opposite. Neither is a
    /// lenient value, which is why the field is required instead.
    func test_theOldEveryIDFallbackWouldHaveRefusedEveryTextUpdate() throws {
        let asFallenBack = Write.Live(
            ids: ["n1"],
            imageIDs: ["n1"], // what `?? Set(ids)` produced
            layout: Write.Layout(originX: 40, nextY: 500)
        )
        XCTAssertThrowsError(
            try Write.updatePlan(id: "n1", at: nil, text: "hi", color: nil, live: asFallenBack)
        ) {
            XCTAssertEqual($0 as? Write.Failure, .textNeedsCanvasText("n1"))
        }
        // And the reading it was chosen over refuses every caption, which is
        // the refusal the fallback existed to avoid.
        let asNoImages = Write.Live(
            ids: ["n1"],
            imageIDs: [],
            layout: Write.Layout(originX: 40, nextY: 500)
        )
        XCTAssertThrowsError(
            try Write.updatePlan(id: "n1", at: nil, text: nil, color: nil, caption: "a", live: asNoImages)
        ) {
            XCTAssertEqual($0 as? Write.Failure, .captionNeedsImage("n1"))
        }
    }
}
