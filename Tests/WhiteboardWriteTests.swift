// ABOUTME: The pure half of the agent write path — validation and normalization.
// ABOUTME: No webview, no workstream, no board on disk.

@testable import Atelier
import XCTest

final class WhiteboardWriteTests: XCTestCase {
    private typealias Write = Whiteboard.Write

    private let empty = Write.Live(ids: [], layout: .fallback)

    private func live(_ ids: String...) -> Write.Live {
        Write.Live(ids: Set(ids), layout: Write.Layout(originX: 40, nextY: 500))
    }

    /// Deterministic ids, so a test can assert the answer rather than its shape.
    private func minter() -> () -> String {
        var n = 0
        return {
            n += 1
            return "id-\(n)"
        }
    }

    // MARK: - The four kinds

    func test_aBoxBecomesARectangleCarryingTheAuthorMarker() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "text": "Auth service", "at": "120,80"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.ids, ["id-1"])
        let skeleton = try XCTUnwrap(plan.skeletons.first)
        XCTAssertEqual(skeleton.type, "rectangle")
        XCTAssertEqual(skeleton.label, "Auth service")
        XCTAssertEqual(skeleton.x, 120)
        XCTAssertEqual(skeleton.y, 80)
        XCTAssertFalse(skeleton.isNote)
        let customData = try XCTUnwrap(skeleton.json["customData"] as? [String: Any])
        XCTAssertEqual(
            customData[Whiteboard.Element.authorKey] as? String,
            Whiteboard.Element.agentAuthorValue
        )
    }

    func test_aNoteIsARectangleCarryingTheNoteMarkerAndItsOwnBackground() throws {
        let plan = try Write.addPlan(
            from: [["kind": "note", "text": "check the TTL"]],
            live: empty,
            mint: minter()
        )
        let skeleton = try XCTUnwrap(plan.skeletons.first)
        XCTAssertEqual(skeleton.type, "rectangle")
        XCTAssertTrue(skeleton.isNote)
        XCTAssertEqual(skeleton.backgroundColor, Write.noteBackground)
        let customData = try XCTUnwrap(skeleton.json["customData"] as? [String: Any])
        XCTAssertEqual(
            customData[Whiteboard.Element.kindKey] as? String,
            Whiteboard.Element.noteKindValue
        )
    }

    func test_aBoxDoesNotCarryTheNoteMarker() throws {
        // The reader promotes a rectangle to a note on this key alone, so a box
        // that carried it would read back as a note.
        let plan = try Write.addPlan(from: [["kind": "box"]], live: empty, mint: minter())
        let customData = try XCTUnwrap(plan.skeletons.first?.json["customData"] as? [String: Any])
        XCTAssertNil(customData[Whiteboard.Element.kindKey])
    }

    func test_aTextElementCarriesItsTextDirectlyAndHasNoSize() throws {
        let plan = try Write.addPlan(
            from: [["kind": "text", "text": "why is this sync?"]],
            live: empty,
            mint: minter()
        )
        let skeleton = try XCTUnwrap(plan.skeletons.first)
        XCTAssertEqual(skeleton.type, "text")
        XCTAssertNil(skeleton.width)
        XCTAssertNil(skeleton.height)
        // A bare text element carries its own text. Every other kind carries it
        // as a bound label, which Excalidraw expands into a separate element.
        XCTAssertEqual(skeleton.json["text"] as? String, "why is this sync?")
        XCTAssertNil(skeleton.json["label"])
    }

    func test_aBoxCarriesItsTextAsABoundLabel() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "text": "Auth service"]],
            live: empty,
            mint: minter()
        )
        let label = try XCTUnwrap(plan.skeletons.first?.json["label"] as? [String: Any])
        XCTAssertEqual(label["text"] as? String, "Auth service")
        XCTAssertNil(plan.skeletons.first?.json["text"])
    }

    func test_anUnknownKindIsRefusedAndNamesTheLegalFour() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [["kind": "cylinder"]], live: empty, mint: minter())
        ) { error in
            let message = (error as? Write.Failure)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("cylinder"), message)
            for kind in ["box", "note", "text", "arrow"] {
                XCTAssertTrue(message.contains(kind), message)
            }
        }
    }

    func test_aKindIsReadCaseInsensitivelyAndTrimmed() throws {
        let plan = try Write.addPlan(from: [["kind": "  BOX "]], live: empty, mint: minter())
        XCTAssertEqual(plan.skeletons.first?.type, "rectangle")
    }

    func test_aMissingKindIsRefused() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [["text": "orphan"]], live: empty, mint: minter())
        )
    }

    func test_aTextElementWithNoTextIsRefused() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [["kind": "text"]], live: empty, mint: minter())
        ) { XCTAssertEqual($0 as? Write.Failure, .textRequired(kind: "text")) }
    }

    func test_anUnlabelledBoxIsFine() throws {
        let plan = try Write.addPlan(from: [["kind": "box"]], live: empty, mint: minter())
        XCTAssertNil(plan.skeletons.first?.label)
    }

    // MARK: - Arrows

    func test_anArrowMayNameABoxCreatedBesideItInTheSameBatch() throws {
        // The reason `add` takes a list at all: a whole diagram is one call.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "A"],
            ["kind": "box", "text": "B"],
            ["kind": "arrow", "from": "id-1", "to": "id-2", "text": "issues"],
        ], live: empty, mint: minter())
        let arrow = try XCTUnwrap(plan.skeletons.last)
        XCTAssertEqual(arrow.type, "arrow")
        XCTAssertEqual(arrow.from, "id-1")
        XCTAssertEqual(arrow.to, "id-2")
        XCTAssertEqual(arrow.label, "issues")
        XCTAssertEqual(plan.ids, ["id-1", "id-2", "id-3"])
    }

    func test_anArrowMayNameAnElementAlreadyOnTheBoard() throws {
        let plan = try Write.addPlan(
            from: [["kind": "arrow", "from": "old-1", "to": "old-2"]],
            live: live("old-1", "old-2"),
            mint: minter()
        )
        XCTAssertEqual(plan.skeletons.first?.from, "old-1")
        XCTAssertEqual(plan.skeletons.first?.to, "old-2")
    }

    func test_anArrowEndpointThatDoesNotExistIsRefusedAndNamesTheID() {
        XCTAssertThrowsError(
            try Write.addPlan(
                from: [["kind": "arrow", "from": "id-1", "to": "ghost-9"]],
                live: live("id-1"),
                mint: minter()
            )
        ) { error in
            XCTAssertEqual(error as? Write.Failure, .unknownElement("ghost-9"))
            XCTAssertTrue(
                (error as? Write.Failure)?.errorDescription?.contains("ghost-9") == true,
                "the refusal has to name the id"
            )
        }
    }

    func test_anArrowMissingAnEndpointIsRefused() {
        XCTAssertThrowsError(
            try Write.addPlan(
                from: [["kind": "arrow", "from": "a"]],
                live: live("a"),
                mint: minter()
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .arrowNeedsEndpoints) }
    }

    func test_anArrowCannotNameAnEndpointCreatedLaterInTheSameBatch() {
        // Forward references would be resolvable, but they make a batch's
        // meaning depend on a reading order nothing states. Refused, naming the
        // id, so the fix is obvious: put the box first.
        XCTAssertThrowsError(
            try Write.addPlan(from: [
                ["kind": "arrow", "from": "id-2", "to": "id-3"],
                ["kind": "box", "text": "A"],
                ["kind": "box", "text": "B"],
            ], live: empty, mint: minter())
        ) { XCTAssertEqual($0 as? Write.Failure, .unknownElement("id-2")) }
    }

    func test_anArrowMayNotNameItself() {
        // Its own id is minted after its endpoints are checked, so this falls
        // out of the rule above rather than needing one of its own — pinned
        // because it is the shape a retry loop produces.
        XCTAssertThrowsError(
            try Write.addPlan(
                from: [["kind": "arrow", "from": "id-1", "to": "id-1"]],
                live: empty,
                mint: minter()
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .unknownElement("id-1")) }
    }

    // MARK: - Positions

    func test_anElementWithNoPositionIsLaidOutBelowWhatIsAlreadyThere() throws {
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "A"],
            ["kind": "box", "text": "B"],
        ], live: live("old-1"), mint: minter())
        XCTAssertEqual(plan.skeletons[0].x, 40)
        XCTAssertEqual(plan.skeletons[0].y, 500)
        XCTAssertEqual(plan.skeletons[1].y, 500 + Write.rowStep)
    }

    func test_anExplicitPositionDoesNotConsumeAColumnSlot() throws {
        // Otherwise two placed elements would leave a gap in the stack of the
        // ones that were not placed.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "placed", "at": "900,900"],
            ["kind": "box", "text": "stacked"],
        ], live: empty, mint: minter())
        XCTAssertEqual(plan.skeletons[0].x, 900)
        XCTAssertEqual(plan.skeletons[0].y, 900)
        XCTAssertEqual(plan.skeletons[1].y, Write.Layout.fallback.nextY)
    }

    func test_aMalformedPositionIsRefusedRatherThanReadAsTheOrigin() {
        // A typo silently placing an element at 0,0 is the same class of bug as
        // open_editor's line number scrolling to the top of the file.
        for bad in ["120", "120,", ",80", "a,b", "120;80", "", "1,2,3"] {
            XCTAssertThrowsError(
                try Write.addPlan(
                    from: [["kind": "box", "at": bad]],
                    live: empty,
                    mint: minter()
                ),
                "expected \"\(bad)\" to be refused"
            )
        }
    }

    func test_aPositionToleratesSpacesAndNegativesAndDecimals() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "at": " -40 , -12.5 "]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.skeletons.first?.x, -40)
        XCTAssertEqual(plan.skeletons.first?.y, -12.5)
    }

    // MARK: - Colours

    func test_aNamedColourIsNormalizedToHex() throws {
        // An agent asked to "colour it red" writes `red`. Refusing that over
        // punctuation makes a tool not worth reaching for.
        let plan = try Write.addPlan(
            from: [["kind": "box", "color": "RED"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.skeletons.first?.strokeColor, Write.palette["red"])
    }

    func test_aHexColourIsAcceptedAndLowercased() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "color": "#AABBCC"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.skeletons.first?.strokeColor, "#aabbcc")
    }

    func test_aShortHexIsExpanded() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "color": "#0af"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.skeletons.first?.strokeColor, "#00aaff")
    }

    func test_anOutOfRangeColourIsRefusedAndNamesTheValueAndTheNames() {
        for bad in ["chartreuse", "#12", "#12345", "#gggggg", "rgb(1,2,3)"] {
            XCTAssertThrowsError(
                try Write.addPlan(
                    from: [["kind": "box", "color": bad]],
                    live: empty,
                    mint: minter()
                ),
                "expected \"\(bad)\" to be refused"
            ) { error in
                let message = (error as? Write.Failure)?.errorDescription ?? ""
                XCTAssertTrue(message.contains(bad), message)
                XCTAssertTrue(message.contains("red"), message)
            }
        }
    }

    func test_aColourOnANoteRecolorsTheStrokeAndLeavesTheNoteBackground() throws {
        // The background is what makes a note look like a note; `color` is the
        // outline, consistently across all four kinds.
        let plan = try Write.addPlan(
            from: [["kind": "note", "text": "x", "color": "red"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.skeletons.first?.strokeColor, Write.palette["red"])
        XCTAssertEqual(plan.skeletons.first?.backgroundColor, Write.noteBackground)
    }

    func test_noColourLeavesExcalidrawsOwnDefault() throws {
        let plan = try Write.addPlan(from: [["kind": "box"]], live: empty, mint: minter())
        XCTAssertNil(plan.skeletons.first?.strokeColor)
        XCTAssertNil(plan.skeletons.first?.json["strokeColor"])
    }

    // MARK: - The batch itself

    func test_anEmptyBatchIsRefused() {
        XCTAssertThrowsError(try Write.addPlan(from: [], live: empty, mint: minter())) {
            XCTAssertEqual($0 as? Write.Failure, .emptyBatch)
        }
    }

    func test_anOversizedBatchIsRefusedAndNamesTheLimit() {
        let many = (0 ... Write.maxBatch).map { _ in ["kind": "box"] }
        XCTAssertThrowsError(try Write.addPlan(from: many, live: empty, mint: minter())) { error in
            XCTAssertEqual(error as? Write.Failure, .batchTooLarge(Write.maxBatch + 1))
            XCTAssertTrue(
                (error as? Write.Failure)?.errorDescription?.contains("\(Write.maxBatch)") == true
            )
        }
    }

    func test_aBatchAtTheLimitIsFine() {
        let many = (0 ..< Write.maxBatch).map { _ in ["kind": "box"] }
        XCTAssertNoThrow(try Write.addPlan(from: many, live: empty, mint: minter()))
    }

    func test_anEntryThatIsNotAnObjectIsRefusedAndNamesItsPosition() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [["kind": "box"], "box"], live: empty, mint: minter())
        ) { XCTAssertEqual($0 as? Write.Failure, .malformedEntry(1)) }
    }

    func test_mintedIDsAreUniqueAndSafeEverywhereTheyTravel() {
        // Through JSON, through Excalidraw's own maps, and past the digest.
        let ids = (0 ..< 500).map { _ in Write.mintID() }
        XCTAssertEqual(Set(ids).count, 500)
        for id in ids {
            XCTAssertTrue(
                id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") },
                id
            )
        }
    }

    // MARK: - update

    func test_updateBuildsAnOperationCarryingOnlyWhatWasAsked() throws {
        let op = try Write.updatePlan(
            id: "e1", at: "10,20", text: nil, color: "blue", live: live("e1")
        )
        XCTAssertEqual(op["kind"] as? String, "update")
        XCTAssertEqual(op["id"] as? String, "e1")
        XCTAssertEqual(op["x"] as? Double, 10)
        XCTAssertEqual(op["y"] as? Double, 20)
        XCTAssertEqual(op["strokeColor"] as? String, Write.palette["blue"])
        XCTAssertNil(op["text"])
    }

    func test_updateOfAnElementThatDoesNotExistIsRefusedAndNamesTheID() {
        XCTAssertThrowsError(
            try Write.updatePlan(id: "ghost", at: "1,2", text: nil, color: nil, live: live("e1"))
        ) { error in
            XCTAssertEqual(error as? Write.Failure, .unknownElement("ghost"))
            XCTAssertTrue((error as? Write.Failure)?.errorDescription?.contains("ghost") == true)
        }
    }

    func test_updateWithNothingToChangeIsRefused() {
        // An update naming no field is an agent that meant something, and
        // succeeding silently teaches it the call worked.
        XCTAssertThrowsError(
            try Write.updatePlan(id: "e1", at: nil, text: nil, color: nil, live: live("e1"))
        ) { XCTAssertEqual($0 as? Write.Failure, .nothingToUpdate) }
    }

    func test_updateMayClearTextToTheEmptyString() throws {
        // Clearing a label is a real edit, and "" is how it is asked for — so
        // this one field is checked for nil rather than for emptiness.
        let op = try Write.updatePlan(id: "e1", at: nil, text: "", color: nil, live: live("e1"))
        XCTAssertEqual(op["text"] as? String, "")
    }

    func test_updateRefusesAMalformedPosition() {
        XCTAssertThrowsError(
            try Write.updatePlan(id: "e1", at: "nope", text: nil, color: nil, live: live("e1"))
        ) { XCTAssertEqual($0 as? Write.Failure, .invalidPosition("nope")) }
    }

    // MARK: - delete

    func test_deleteBuildsAnOperationOverTheIDsGiven() throws {
        let op = try Write.deletePlan(ids: ["a", "b"])
        XCTAssertEqual(op["kind"] as? String, "delete")
        XCTAssertEqual(op["ids"] as? [String], ["a", "b"])
    }

    func test_deleteDoesNotCheckThatTheIDsExist() {
        // A gone id is success, and that is exactly what makes the tool safe to
        // replay after a lost connection. Checking here would turn a replay
        // into a refusal about a fact that is merely no longer true.
        XCTAssertNoThrow(try Write.deletePlan(ids: ["never-existed"]))
    }

    func test_deleteWithNoIDsIsRefused() {
        XCTAssertThrowsError(try Write.deletePlan(ids: [])) {
            XCTAssertEqual($0 as? Write.Failure, .emptyBatch)
        }
    }
}
