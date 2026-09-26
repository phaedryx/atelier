// ABOUTME: The sentence `whiteboard_add` answers with, now that it carries geometry.
// ABOUTME: No webview and no board: the wording takes an `Added` and nothing else.

@testable import Atelier
import XCTest

@MainActor
final class WhiteboardAddAnswerTests: XCTestCase {
    private typealias Write = Whiteboard.Write

    private func added(
        arm: Whiteboard.Added.Arm,
        ids: [String],
        rects: [String: Write.Rect],
        extent: Write.Rect? = Write.Rect(x: 100, y: 100, width: 640, height: 420),
        nextY: Double? = 580,
        note: String? = nil
    ) -> Whiteboard.Added {
        Whiteboard.Added(
            arm: arm,
            applied: Whiteboard.Host.Applied(
                ids: ids, rects: rects, extent: extent, nextY: nextY, note: note
            )
        )
    }

    /// **The whole reason the answer grew.** A box is now drawn at the size of
    /// its label, so a caller told only the ids no longer knows how wide
    /// anything is — a known-bad constant traded for an unknown one. Naming each
    /// rectangle is what makes auto-sizing pay for itself.
    func test_theElementsArmNamesEachElementsOwnRectangle() {
        let text = IPC.Service.whiteboardAddText(added(
            arm: .elements,
            ids: ["atl-a", "atl-b"],
            rects: [
                "atl-a": Write.Rect(x: 120, y: 80, width: 312, height: 90),
                "atl-b": Write.Rect(x: 120, y: 230, width: 220, height: 90),
            ]
        ))
        XCTAssertTrue(text.contains("Added 2 elements"), text)
        XCTAssertTrue(text.contains("atl-a at 120,80, 312×90"), text)
        XCTAssertTrue(text.contains("atl-b at 120,230, 220×90"), text)
    }

    /// The rows follow `ids`, which is the order the caller wrote the batch in
    /// — a dictionary's own order would shuffle the answer between calls that
    /// asked for exactly the same thing.
    func test_theRowsFollowTheOrderTheIdsCameBackIn() {
        let text = IPC.Service.whiteboardAddText(added(
            arm: .elements,
            ids: ["atl-1", "atl-2", "atl-3"],
            rects: [
                "atl-3": Write.Rect(x: 0, y: 2, width: 1, height: 1),
                "atl-1": Write.Rect(x: 0, y: 0, width: 1, height: 1),
                "atl-2": Write.Rect(x: 0, y: 1, width: 1, height: 1),
            ]
        ))
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("  atl-") }
        XCTAssertEqual(rows.map { $0.split(separator: " ")[0] }, ["atl-1", "atl-2", "atl-3"])
    }

    /// **A mermaid caller named a diagram, not twenty nodes.** A line each for
    /// nodes it did not choose would spend the whole answer describing something
    /// nobody asked about, and bury the one number it wanted.
    func test_theMermaidArmReportsOneBoundingRectangleRatherThanEveryNode() {
        let text = IPC.Service.whiteboardAddText(added(
            arm: .mermaid,
            ids: ["a", "b", "c"],
            rects: [
                "a": Write.Rect(x: 100, y: 300, width: 120, height: 60),
                "b": Write.Rect(x: 400, y: 300, width: 120, height: 60),
                "c": Write.Rect(x: 220, y: 320, width: 180, height: 20),
            ]
        ))
        XCTAssertTrue(text.contains("a, b, c"), text)
        // 100..520 wide, 300..360 tall — the union of the three, not any one.
        XCTAssertTrue(text.contains("The diagram occupies 420×60 from 100,300."), text)
        XCTAssertFalse(text.contains("  a at"), "no per-node rows on this arm: \(text)")
    }

    /// The `read_whiteboard` round trip this retires: an agent adding a diagram
    /// and then wanting to put something under it had to re-read the board
    /// purely to learn how big the diagram came out.
    func test_everyAnswerSaysHowBigTheBoardIsAndWhereTheNextElementGoes() {
        let text = IPC.Service.whiteboardAddText(added(
            arm: .elements,
            ids: ["atl-a"],
            rects: ["atl-a": Write.Rect(x: 120, y: 80, width: 312, height: 90)]
        ))
        XCTAssertTrue(text.contains("The board now covers 100,100 to 740,520 (640×420)."), text)
        XCTAssertTrue(text.contains("goes at 100,580."), text)
    }

    /// **The ids are true whatever the geometry did.** An answer that withheld
    /// them because a measurement was missing would fail the caller over the
    /// part it did not ask about.
    func test_anAnswerWithNoGeometryStillNamesWhatItDrew() {
        let text = IPC.Service.whiteboardAddText(added(
            arm: .elements, ids: ["atl-a"], rects: [:], extent: nil, nextY: nil
        ))
        XCTAssertEqual(text, "Added 1 element: atl-a.")
    }
}
