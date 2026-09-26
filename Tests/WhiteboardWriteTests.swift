// ABOUTME: The pure half of the agent write path — validation and normalization.
// ABOUTME: No webview, no workstream, no board on disk.

@testable import Atelier
import XCTest

final class WhiteboardWriteTests: XCTestCase {
    private typealias Write = Whiteboard.Write

    private let empty = Write.Live(ids: [], imageIDs: [], layout: .fallback)

    private func live(_ ids: String...) -> Write.Live {
        Write.Live(ids: Set(ids), imageIDs: [], layout: Write.Layout(originX: 40, nextY: 500))
    }

    /// A board carrying images, for the caption tests.
    private func board(ids: [String], images: [String]) -> Write.Live {
        Write.Live(
            ids: Set(ids),
            imageIDs: Set(images),
            layout: Write.Layout(originX: 40, nextY: 500)
        )
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
        XCTAssertEqual(plan.map(\.id), ["id-1"])
        let skeleton = try XCTUnwrap(plan.first)
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
        let skeleton = try XCTUnwrap(plan.first)
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
        let customData = try XCTUnwrap(plan.first?.json["customData"] as? [String: Any])
        XCTAssertNil(customData[Whiteboard.Element.kindKey])
    }

    func test_aTextElementCarriesItsTextDirectlyAndHasNoSize() throws {
        let plan = try Write.addPlan(
            from: [["kind": "text", "text": "why is this sync?"]],
            live: empty,
            mint: minter()
        )
        let skeleton = try XCTUnwrap(plan.first)
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
        let label = try XCTUnwrap(plan.first?.json["label"] as? [String: Any])
        XCTAssertEqual(label["text"] as? String, "Auth service")
        XCTAssertNil(plan.first?.json["text"])
    }

    func test_anUnknownKindIsRefusedAndNamesTheLegalKinds() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [["kind": "cylinder"]], live: empty, mint: minter())
        ) { error in
            let message = (error as? Write.Failure)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("cylinder"), message)
            for kind in ["box", "note", "text", "arrow", "mermaid"] {
                XCTAssertTrue(message.contains(kind), message)
            }
        }
    }

    func test_aKindIsReadCaseInsensitivelyAndTrimmed() throws {
        let plan = try Write.addPlan(from: [["kind": "  BOX "]], live: empty, mint: minter())
        XCTAssertEqual(plan.first?.type, "rectangle")
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
        XCTAssertNil(plan.first?.label)
    }

    // MARK: - Arrows

    func test_anArrowMayNameABoxCreatedBesideItInTheSameBatch() throws {
        // The reason `add` takes a list at all: a whole diagram is one call.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "A"],
            ["kind": "box", "text": "B"],
            ["kind": "arrow", "from": "id-1", "to": "id-2", "text": "issues"],
        ], live: empty, mint: minter())
        let arrow = try XCTUnwrap(plan.last)
        XCTAssertEqual(arrow.type, "arrow")
        XCTAssertEqual(arrow.from, "id-1")
        XCTAssertEqual(arrow.to, "id-2")
        XCTAssertEqual(arrow.label, "issues")
        XCTAssertEqual(plan.map(\.id), ["id-1", "id-2", "id-3"])
    }

    func test_anArrowMayNameAnElementAlreadyOnTheBoard() throws {
        let plan = try Write.addPlan(
            from: [["kind": "arrow", "from": "old-1", "to": "old-2"]],
            live: live("old-1", "old-2"),
            mint: minter()
        )
        XCTAssertEqual(plan.first?.from, "old-1")
        XCTAssertEqual(plan.first?.to, "old-2")
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

    /// **The test that was missing, and the one the feature exists for.**
    ///
    /// No injected minter — `addPlan` mints `atl-<uuid>`, which is what a real
    /// caller faces. Every other arrow test here hands out `id-1`, `id-2`,
    /// `id-3` and so pins a batch no agent can compose: the affordance the tool
    /// advertises was asserted in four places and reachable from none of them,
    /// because the id of a box created in the same call cannot be known before
    /// the call returns.
    func test_anArrowBindsToABoxCreatedInTheSameBatchByRef_withNoInjectedMinter() throws {
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "Auth service", "ref": "auth"],
            ["kind": "box", "text": "Token store", "ref": "tokens"],
            ["kind": "arrow", "from": "auth", "to": "tokens", "text": "issues"],
        ], live: empty)

        let arrow = try XCTUnwrap(plan.last)
        XCTAssertEqual(arrow.from, plan[0].id)
        XCTAssertEqual(arrow.to, plan[1].id)
        // The ids are the real minted ones, which is the half a test with an
        // injected minter cannot see.
        XCTAssertTrue(plan[0].id.hasPrefix("atl-"), plan[0].id)
        // And the ref itself never reaches the page. An endpoint left
        // unresolved would be an arrow bound to nothing, which the digest
        // reports as an endpoint id appearing nowhere else on the board.
        XCTAssertNotEqual(arrow.from, "auth")
        XCTAssertNotEqual(arrow.to, "tokens")
        XCTAssertNil(arrow.json["ref"])
    }

    func test_anArrowMayStillNameAnElementAlreadyOnTheBoardWhenTheBatchUsesRefs() throws {
        // The two vocabularies coexist in one batch: a real board id on one end
        // and a batch-local name on the other.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "new", "ref": "fresh"],
            ["kind": "arrow", "from": "old-1", "to": "fresh"],
        ], live: live("old-1"))
        let arrow = try XCTUnwrap(plan.last)
        XCTAssertEqual(arrow.from, "old-1")
        XCTAssertEqual(arrow.to, plan[0].id)
    }

    func test_anArrowCannotNameARefDeclaredLaterInTheSameBatch() {
        // The forward-reference rule, on the path that can actually be reached:
        // resolving this would make a batch's meaning depend on a reading order
        // nothing states. The existing test above pins the same rule for a
        // minted id, which no real caller can write.
        XCTAssertThrowsError(
            try Write.addPlan(from: [
                ["kind": "arrow", "from": "auth", "to": "tokens"],
                ["kind": "box", "text": "Auth service", "ref": "auth"],
                ["kind": "box", "text": "Token store", "ref": "tokens"],
            ], live: empty)
        ) { XCTAssertEqual($0 as? Write.Failure, .unknownElement("auth")) }
    }

    func test_anArrowCannotNameItsOwnRef() {
        // A ref is registered only once its element is made, so this falls out
        // of the forward-reference rule rather than needing one of its own —
        // the same way `test_anArrowMayNotNameItself` does for a minted id.
        XCTAssertThrowsError(
            try Write.addPlan(
                from: [["kind": "arrow", "from": "self", "to": "self", "ref": "self"]],
                live: empty
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .unknownElement("self")) }
    }

    // MARK: - Refs

    func test_aRefThatIsAlreadyAnIDOnTheBoardIsRefused() {
        // Resolvable either way round, which is exactly why it is refused: an
        // arrow naming it would mean two things and a rule picking one draws
        // the arrow to the wrong end of the board — which reads fine in the
        // digest.
        XCTAssertThrowsError(
            try Write.addPlan(from: [
                ["kind": "box", "text": "A", "ref": "old-1"],
            ], live: live("old-1"))
        ) { error in
            XCTAssertEqual(error as? Write.Failure, .refCollidesWithElement("old-1"))
            XCTAssertTrue(
                (error as? Write.Failure)?.errorDescription?.contains("old-1") == true,
                "the refusal has to name the ref"
            )
        }
    }

    func test_twoEntriesDeclaringTheSameRefAreRefused() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [
                ["kind": "box", "text": "A", "ref": "node"],
                ["kind": "box", "text": "B", "ref": "node"],
            ], live: empty)
        ) { XCTAssertEqual($0 as? Write.Failure, .duplicateRef("node")) }
    }

    func test_aRefCollisionIsRefusedWhereverInTheBatchItSits() {
        // Scanned up front, so the answer does not depend on batch order — a
        // refusal an agent fixes by shuffling entries is one it never
        // understood. Pinned in both directions, and with the collision after a
        // valid arrow, where a scan done as the batch is walked would have let
        // the arrow bind first.
        for batch in [
            [
                ["kind": "box", "text": "A", "ref": "old-1"],
                ["kind": "box", "text": "B"],
            ],
            [
                ["kind": "box", "text": "B"],
                ["kind": "box", "text": "A", "ref": "old-1"],
            ],
        ] {
            XCTAssertThrowsError(try Write.addPlan(from: batch, live: live("old-1"))) {
                XCTAssertEqual($0 as? Write.Failure, .refCollidesWithElement("old-1"))
            }
        }
    }

    func test_theRefScanIsRefusedAheadOfAnUnknownKindInTheSameBatch() {
        // A consequence of scanning up front, pinned rather than left to be
        // discovered by whoever reorders these two checks.
        XCTAssertThrowsError(
            try Write.addPlan(from: [
                ["kind": "cylinder"],
                ["kind": "box", "text": "A", "ref": "old-1"],
            ], live: live("old-1"))
        ) { XCTAssertEqual($0 as? Write.Failure, .refCollidesWithElement("old-1")) }
    }

    func test_anEmptyOrNullRefIsNotADeclaration() throws {
        // A serializer that writes every key of its struct sends `"ref": ""` or
        // `null` on every entry, and reading those as declarations would refuse
        // the batch for a duplicate name nobody wrote. The same trap
        // `asks(_:for:)` documents for the mermaid arm, and this side has to
        // fall the same way for the same bytes.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "A", "ref": ""],
            ["kind": "box", "text": "B", "ref": NSNull()],
            ["kind": "box", "text": "C", "ref": ""],
        ], live: empty)
        XCTAssertEqual(plan.count, 3)
    }

    func test_aRefOnANonArrowIsNotCarriedIntoTheSkeleton() throws {
        // Parse-time only: the page is handed real ids and nothing else, so
        // there is still one id vocabulary and no mapping table for the two
        // ends to drift apart on.
        let plan = try Write.addPlan(
            from: [["kind": "box", "text": "A", "ref": "auth"]],
            live: empty
        )
        let json = try XCTUnwrap(plan.first?.json)
        XCTAssertNil(json["ref"])
        XCTAssertFalse("\(json)".contains("auth"))
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
        XCTAssertEqual(plan[0].x, 40)
        XCTAssertEqual(plan[0].y, 500)
        XCTAssertEqual(plan[1].y, 500 + Write.rowStep)
    }

    func test_theColumnStartsBelowWhatTheSameBatchPlacesByHand() throws {
        // Otherwise an agent that places two boxes and adds an unplaced note
        // gets the note dropped on top of them. Invisible in the digest — the
        // coordinates read fine — and it ruins the picture, which is the half
        // of the read path that exists to corroborate the other.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "placed", "at": "120,80"],
            ["kind": "note", "text": "stacked"],
        ], live: empty, mint: minter())
        XCTAssertEqual(plan[0].y, 80)
        XCTAssertEqual(plan[1].y, 80 + Write.boxSize.height + Write.layoutGap)
    }

    func test_theColumnIsScannedUpFront_soOrderInTheBatchDoesNotChangeIt() throws {
        // The unplaced element comes FIRST here and must still clear the box
        // placed after it.
        let plan = try Write.addPlan(from: [
            ["kind": "note", "text": "stacked"],
            ["kind": "box", "text": "placed", "at": "120,80"],
        ], live: empty, mint: minter())
        XCTAssertEqual(plan[0].y, 80 + Write.boxSize.height + Write.layoutGap)
    }

    /// **The column scan and the batch loop have to read a kind the same way.**
    ///
    /// They did not: the loop trimmed and lowercased, the scan only lowercased.
    /// So `"box "` was a box to the loop and nothing to the scan, whose floor
    /// then left out the box's own height — and the next unplaced element
    /// landed on top of it. Invisible in the digest, because both sets of
    /// coordinates read exactly as asked, and wrong only in the picture: the
    /// half of the read path that exists to corroborate the other, and the
    /// exact failure the up-front scan was written to prevent.
    func test_thePaddedKindRaisesTheColumnFloorTheSameWayATrimmedOneDoes() throws {
        for spelling in ["box", "box ", " BOX", "\tnote\n"] {
            let plan = try Write.addPlan(from: [
                ["kind": spelling, "text": "placed", "at": "120,80"],
                ["kind": "box", "text": "stacked"],
            ], live: empty, mint: minter())
            XCTAssertEqual(
                plan[1].y,
                80 + Write.boxSize.height + Write.layoutGap,
                "kind = \(spelling.debugDescription)"
            )
        }
    }

    func test_theBoardsOwnExtentStillWinsWhenItIsLower() throws {
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "placed", "at": "0,0"],
            ["kind": "box", "text": "stacked"],
        ], live: live("old-1"), mint: minter())
        // live()'s layout says 500, which is below the placed box's bottom.
        XCTAssertEqual(plan[1].y, 500)
    }

    func test_anExplicitPositionDoesNotConsumeAColumnSlot() throws {
        // Otherwise two placed elements would leave a gap in the stack of the
        // ones that were not placed.
        let plan = try Write.addPlan(from: [
            ["kind": "box", "text": "placed", "at": "900,900"],
            ["kind": "box", "text": "stacked"],
        ], live: empty, mint: minter())
        XCTAssertEqual(plan[0].x, 900)
        XCTAssertEqual(plan[0].y, 900)
        // One column slot, not two: the placed element took none of them. Its
        // own extent still raises the floor, which is a different rule.
        XCTAssertEqual(plan[1].y, 900 + Write.boxSize.height + Write.layoutGap)
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
        XCTAssertEqual(plan.first?.x, -40)
        XCTAssertEqual(plan.first?.y, -12.5)
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
        XCTAssertEqual(plan.first?.strokeColor, Write.palette["red"])
    }

    func test_aHexColourIsAcceptedAndLowercased() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "color": "#AABBCC"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.first?.strokeColor, "#aabbcc")
    }

    func test_aShortHexIsExpanded() throws {
        let plan = try Write.addPlan(
            from: [["kind": "box", "color": "#0af"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan.first?.strokeColor, "#00aaff")
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
        XCTAssertEqual(plan.first?.strokeColor, Write.palette["red"])
        XCTAssertEqual(plan.first?.backgroundColor, Write.noteBackground)
    }

    func test_noColourLeavesExcalidrawsOwnDefault() throws {
        let plan = try Write.addPlan(from: [["kind": "box"]], live: empty, mint: minter())
        XCTAssertNil(plan.first?.strokeColor)
        XCTAssertNil(plan.first?.json["strokeColor"])
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

    // MARK: - Positions that are numbers and still not coordinates

    /// **A non-finite coordinate is a crash, not a misplacement.**
    ///
    /// `Double(String)` accepts all three of these, and the value then survives
    /// every guard between here and `Host.apply`, where `JSONSerialization`
    /// raises `NSInvalidArgumentException` for a non-finite `Double` — an
    /// Objective-C exception no `try?` on the Swift side can catch, so the app
    /// dies rather than refusing. `1e999` is the one an agent reaches without
    /// meaning to, by arithmetic rather than by typing a word.
    func test_aNonFinitePositionIsRefusedRatherThanReachingJSONSerialization() {
        for raw in ["inf", "nan", "1e999", "-inf", "infinity"] {
            for spelling in ["\(raw),0", "0,\(raw)", "\(raw),\(raw)"] {
                XCTAssertThrowsError(
                    try Write.parsePosition(spelling),
                    "expected \(spelling) to be refused"
                ) { XCTAssertEqual($0 as? Write.Failure, .invalidPosition(spelling)) }
            }
        }
    }

    /// Through `plan`, because the column pre-scan in `addPlan` reads `at`
    /// under `try?` — a guard at a call site rather than inside `parsePosition`
    /// would have left that path carrying the value into `nextRow`.
    func test_aNonFinitePositionIsRefusedThroughTheWholeAddPath() {
        XCTAssertThrowsError(
            try Write.plan(
                from: [["kind": "box", "text": "Auth", "at": "1e999,0"]],
                live: empty,
                mint: minter()
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .invalidPosition("1e999,0")) }
    }

    func test_aNonFinitePositionIsRefusedOnAMermaidEntryToo() {
        XCTAssertThrowsError(
            try Write.plan(
                from: [["kind": "mermaid", "text": flowchart, "at": "0,nan"]],
                live: empty,
                mint: minter()
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .invalidPosition("0,nan")) }
    }

    func test_anOrdinaryLargeCoordinateIsStillAccepted() throws {
        // The guard is on finiteness and nothing else: a board really can be
        // scrolled a long way from the origin.
        let position = try Write.parsePosition("1e30,-1e30")
        XCTAssertEqual(position.x, 1e30)
        XCTAssertEqual(position.y, -1e30)
    }

    // MARK: - update: captions

    func test_updateCarriesACaptionForAnImage() throws {
        let op = try Write.updatePlan(
            id: "i1", at: nil, text: nil, color: nil,
            caption: "Settings pane, Environment tab, process-compose row red",
            live: board(ids: ["i1"], images: ["i1"])
        )
        XCTAssertEqual(
            op["caption"] as? String,
            "Settings pane, Environment tab, process-compose row red"
        )
    }

    func test_theCaptionKeyTravelsWithTheCaption() throws {
        // The page must never spell a customData key. It cannot import
        // `Element`, so a literal there could not be tied back to the one place
        // these keys live — and a rename in Swift would leave the page writing
        // the old key, putting the caption on the board and out of the digest.
        let op = try Write.updatePlan(
            id: "i1", at: nil, text: nil, color: nil, caption: "x",
            live: board(ids: ["i1"], images: ["i1"])
        )
        XCTAssertEqual(op["captionKey"] as? String, Whiteboard.Element.captionKey)
    }

    func test_anUpdateThatIsNotACaptionCarriesNoCaptionKey() throws {
        let op = try Write.updatePlan(
            id: "i1", at: "1,2", text: nil, color: nil,
            live: board(ids: ["i1"], images: ["i1"])
        )
        XCTAssertNil(op["captionKey"])
    }

    func test_aCaptionAloneIsEnoughOfAChange() throws {
        XCTAssertNoThrow(
            try Write.updatePlan(
                id: "i1", at: nil, text: nil, color: nil, caption: "a screenshot",
                live: board(ids: ["i1"], images: ["i1"])
            )
        )
    }

    func test_aCaptionMayBeClearedWithTheEmptyString() throws {
        // The same rule `text` follows, and for the same reason: clearing a
        // transcription is a real edit, and "" is how it is asked for. Checked
        // for nil rather than for emptiness.
        let op = try Write.updatePlan(
            id: "i1", at: nil, text: nil, color: nil, caption: "",
            live: board(ids: ["i1"], images: ["i1"])
        )
        XCTAssertEqual(op["caption"] as? String, "")
    }

    func test_aWhitespaceOnlyCaptionClearsRatherThanStoringBlankWords() throws {
        // The page removes the key rather than storing "" because the digest
        // renders a caption line for anything it finds, so an empty string
        // would leave a blank line under the image forever. A caption of three
        // spaces renders that same blank line while reading, in the file, as a
        // transcription that exists — so it is normalized to the clear the
        // agent meant. Trimmed HERE and not also in the page: one copy, and
        // this is the half that is testable with no board on disk.
        for blank in [" ", "   ", "\n", "\t  \n"] {
            let op = try Write.updatePlan(
                id: "i1", at: nil, text: nil, color: nil, caption: blank,
                live: board(ids: ["i1"], images: ["i1"])
            )
            XCTAssertEqual(op["caption"] as? String, "", "for \(blank.debugDescription)")
        }
    }

    func test_aCaptionKeepsItsOwnWhitespaceWhenItHasWordsInIt() throws {
        // Only a caption that is ENTIRELY whitespace is a clear. One with words
        // is a transcription and is stored exactly as sent — a screenshot of
        // indented code is the ordinary case, and trimming it would silently
        // rewrite what the agent read off the pixels.
        let op = try Write.updatePlan(
            id: "i1", at: nil, text: nil, color: nil, caption: "  def run\n    ok\n  end  ",
            live: board(ids: ["i1"], images: ["i1"])
        )
        XCTAssertEqual(op["caption"] as? String, "  def run\n    ok\n  end  ")
    }

    func test_aCaptionOnSomethingThatIsNotAnImageIsRefused() {
        // A caption is an agent's transcription of pixels nothing else can
        // read. On a box it would be a second, invisible text channel: present
        // in the digest and absent from the picture, which is the disagreement
        // this whole feature is organized around not producing.
        XCTAssertThrowsError(
            try Write.updatePlan(
                id: "n1", at: nil, text: nil, color: nil, caption: "x",
                live: board(ids: ["n1", "i1"], images: ["i1"])
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .captionNeedsImage("n1")) }
    }

    func test_theCaptionRefusalNamesTheAlternative() {
        // Naming `text` is what stops an agent retrying the same call: the
        // refusal is the whole of what it has to work from.
        let message = Write.Failure.captionNeedsImage("n1").errorDescription ?? ""
        XCTAssertTrue(message.contains("n1"), message)
        XCTAssertTrue(message.contains("`text`"), message)
    }

    func test_aCaptionForAnIDThatIsNotOnTheBoardIsRefusedAsUnknown() {
        // Unknown beats not-an-image: the id being absent is the more useful
        // thing to be told, and `imageIDs` cannot contain it either.
        XCTAssertThrowsError(
            try Write.updatePlan(
                id: "ghost", at: nil, text: nil, color: nil, caption: "x",
                live: board(ids: ["i1"], images: ["i1"])
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .unknownElement("ghost")) }
    }

    func test_textOnAnImageIsRefusedAndNamesCaption() {
        // The most likely wrong first move an agent makes, and it used to be
        // answered with a lie: an image carries no text on the canvas, so
        // `textTargetFor` found nothing to change and the call still reported
        // "Updated i1." A silent success teaches an agent the caption landed.
        XCTAssertThrowsError(
            try Write.updatePlan(
                id: "i1", at: nil, text: "Settings pane", color: nil,
                live: board(ids: ["i1"], images: ["i1"])
            )
        ) { error in
            XCTAssertEqual(error as? Write.Failure, .textNeedsCanvasText("i1"))
            let message = (error as? Write.Failure)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("i1"), message)
            XCTAssertTrue(message.contains("`caption`"), message)
        }
    }

    func test_clearingTextOnAnImageIsRefusedTheSameWay() {
        // "" is a real edit for anything that carries words, so it cannot be
        // waved through here either — there is still nothing to clear.
        XCTAssertThrowsError(
            try Write.updatePlan(
                id: "i1", at: nil, text: "", color: nil,
                live: board(ids: ["i1"], images: ["i1"])
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .textNeedsCanvasText("i1")) }
    }

    func test_movingAnImageWithoutTextIsStillFine() throws {
        XCTAssertNoThrow(
            try Write.updatePlan(
                id: "i1", at: "10,20", text: nil, color: nil,
                live: board(ids: ["i1"], images: ["i1"])
            )
        )
    }

    func test_textOnSomethingThatIsNotAnImageIsUntouched() throws {
        let op = try Write.updatePlan(
            id: "n1", at: nil, text: "still fine", color: nil,
            live: board(ids: ["n1", "i1"], images: ["i1"])
        )
        XCTAssertEqual(op["text"] as? String, "still fine")
    }

    func test_nothingToUpdateNamesCaptionAsAField() {
        // The refusal is the agent's only map of what this tool takes.
        let message = Write.Failure.nothingToUpdate.errorDescription ?? ""
        XCTAssertTrue(message.contains("caption"), message)
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

    // MARK: - The JSON the tool argument carries

    func test_aJSONArrayIsParsedIntoAPlan() throws {
        let plan = try Write.plan(
            fromJSON: #"[{"kind": "box", "text": "Auth service", "at": "120,80"}]"#,
            live: empty,
            mint: minter()
        )
        guard case let .elements(skeletons) = plan else {
            return XCTFail("expected an elements plan, got \(plan)")
        }
        XCTAssertEqual(skeletons.map(\.id), ["id-1"])
        XCTAssertEqual(skeletons.first?.label, "Auth service")
        XCTAssertEqual(skeletons.first?.x, 120)
    }

    func test_malformedJSONIsRefusedWithAWorkedExample() {
        // The argument crosses IPC as a string, so a model writing the array by
        // hand is the ordinary case and the refusal has to show the shape.
        for bad in ["not json", "{\"kind\":\"box\"}", "", "[", "42"] {
            XCTAssertThrowsError(
                try Write.plan(fromJSON: bad, live: empty, mint: minter()),
                "expected \(bad) to be refused"
            ) { error in
                XCTAssertEqual(error as? Write.Failure, .malformedJSON)
                XCTAssertTrue(
                    (error as? Write.Failure)?.errorDescription?.contains("\"kind\"") == true
                )
            }
        }
    }

    func test_anEmptyJSONArrayIsTheEmptyBatchRefusal_notAParseFailure() {
        // Different mistakes, different sentences: one is a malformed argument,
        // the other is a well-formed call that asks for nothing.
        XCTAssertThrowsError(try Write.plan(fromJSON: "[]", live: empty, mint: minter())) {
            XCTAssertEqual($0 as? Write.Failure, .emptyBatch)
        }
    }

    // MARK: - Mermaid

    //
    // A mermaid diagram is the one kind Swift cannot expand or even validate:
    // the page parses the definition with Excalidraw's own converter. Swift
    // decides only the things it can — that the diagram stands alone in its
    // call, where it goes, and that nothing was asked for that it cannot honour.

    private let flowchart = "graph LR; A[Auth] --> B[Token store]"

    func test_aMermaidDiagramAloneBecomesAMermaidPlanAtItsPosition() throws {
        let plan = try Write.plan(
            from: [["kind": "mermaid", "text": flowchart, "at": "100,100"]],
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan, .mermaid(Write.Mermaid(definition: flowchart, x: 100, y: 100)))
    }

    func test_anUnplacedMermaidDiagramLandsAtTheColumn() throws {
        let plan = try Write.plan(
            from: [["kind": "mermaid", "text": flowchart]],
            live: live("n1"),
            mint: minter()
        )
        XCTAssertEqual(plan, .mermaid(Write.Mermaid(definition: flowchart, x: 40, y: 500)))
    }

    func test_ordinaryKindsStillPlanAsElements() throws {
        let plan = try Write.plan(
            from: [["kind": "box", "text": "Auth service", "at": "120,80"]],
            live: empty,
            mint: minter()
        )
        guard case let .elements(skeletons) = plan else {
            return XCTFail("expected an elements plan, got \(plan)")
        }
        XCTAssertEqual(skeletons.map(\.id), ["id-1"])
        XCTAssertEqual(skeletons.first?.label, "Auth service")
    }

    func test_aMermaidDiagramIsParsedFromTheJSONArgument() throws {
        let plan = try Write.plan(
            fromJSON: #"[{"kind": "mermaid", "text": "graph TD; A --> B", "at": "10,20"}]"#,
            live: empty,
            mint: minter()
        )
        XCTAssertEqual(plan, .mermaid(Write.Mermaid(definition: "graph TD; A --> B", x: 10, y: 20)))
    }

    func test_aMermaidDiagramWithNoDefinitionIsRefused() {
        for entry in [["kind": "mermaid"], ["kind": "mermaid", "text": ""]] {
            XCTAssertThrowsError(try Write.plan(from: [entry], live: empty, mint: minter())) {
                XCTAssertEqual($0 as? Write.Failure, .textRequired(kind: "mermaid"))
            }
        }
    }

    /// The page decides the diagram's height only after it has parsed it, so
    /// the column layout for anything after it would be a guess — and a guess
    /// drops the next element on top of the diagram, invisibly in the digest.
    func test_aMermaidDiagramMayNotShareACallWithAnythingElse() {
        let mermaid: [String: Any] = ["kind": "mermaid", "text": flowchart]
        let box: [String: Any] = ["kind": "box", "text": "beside it"]
        for batch in [[mermaid, box], [box, mermaid], [mermaid, mermaid]] {
            XCTAssertThrowsError(try Write.plan(from: batch, live: empty, mint: minter())) {
                XCTAssertEqual($0 as? Write.Failure, .mermaidStandsAlone)
            }
        }
    }

    /// Refused rather than ignored: an agent that asked for a red diagram and
    /// got a black one has been taught that `color` does nothing.
    func test_aMermaidDiagramRefusesTheFieldsItCannotHonour() {
        // `ref` is in the list for the same reason: a mermaid entry stands
        // alone in its call, so nothing can ever name it, and an alias that
        // silently does nothing is the failure this refusal exists for.
        for field in ["color", "from", "to", "ref"] {
            var entry: [String: Any] = ["kind": "mermaid", "text": flowchart]
            entry[field] = "red"
            XCTAssertThrowsError(try Write.plan(from: [entry], live: empty, mint: minter())) {
                XCTAssertEqual($0 as? Write.Failure, .mermaidFieldRefused(field))
            }
        }
    }

    /// **The refusal has to name what actually works, and it used to not.**
    ///
    /// It said "colour and connections belong in the definition itself". For a
    /// node that is true; for an EDGE it is false, and an agent following it
    /// wrote `linkStyle`, got a black arrow and had no recourse inside mermaid
    /// — a silent success reached by following a refusal, which is the shape
    /// this subsystem is organized against. Measured against
    /// @excalidraw/mermaid-to-excalidraw 2.2.2 by `feat-whiteboard-layout-tool`.
    ///
    /// Pinned here as the *string*, because the split itself is the converter's
    /// behaviour and only reachable through the page — `Tests/Harnesses/README.md`
    /// carries the measurement. What this guards is that a later rewrite cannot
    /// re-broaden the advice back to the claim that was wrong.
    func test_theMermaidRefusalNamesWhatSurvivesTheConverterAndWhatDoesNot() throws {
        let message = try XCTUnwrap(Write.Failure.mermaidFieldRefused("color").errorDescription)
        // What works for a node.
        for survivor in ["classDef", "style", "class"] {
            XCTAssertTrue(message.contains(survivor), message)
        }
        // What works for an edge, which is syntax and not styling.
        XCTAssertTrue(message.contains("-.->"), message)
        XCTAssertTrue(message.contains("==>"), message)
        // And the part that does not survive at all, named rather than left to
        // be discovered as a black arrow.
        XCTAssertTrue(message.contains("linkStyle"), message)
        XCTAssertTrue(message.contains("dropped"), message)
        // A refusal that names no way out is one an agent retries verbatim.
        XCTAssertTrue(message.contains("whiteboard_update"), message)
    }

    /// **A `null` and an empty string are not asking for the field.**
    ///
    /// `JSONSerialization` hands a JSON `null` back as `NSNull`, which is not
    /// nil, so a serializer that writes every key of its struct had a mermaid
    /// entry refused for a `color` it never set — while the elements arm
    /// accepts exactly those two from exactly that serializer, since
    /// `normalizedColor` returns nil for an empty string and `from`/`to` are
    /// read as non-empty strings. One serializer, one answer.
    func test_aMermaidDiagramIgnoresAFieldThatIsNullOrEmpty() throws {
        for field in ["color", "from", "to"] {
            for absent in [NSNull(), "" as Any] {
                var entry: [String: Any] = ["kind": "mermaid", "text": flowchart, "at": "10,20"]
                entry[field] = absent
                let plan = try Write.plan(from: [entry], live: empty, mint: minter())
                XCTAssertEqual(
                    plan,
                    .mermaid(Write.Mermaid(definition: flowchart, x: 10, y: 20)),
                    "\(field) = \(absent)"
                )
            }
        }
    }

    /// The other half of the same rule: the elements arm really does accept
    /// what the mermaid arm now stops refusing.
    func test_theElementsArmAcceptsTheSameNullAndEmptyFields() throws {
        let plan = try Write.plan(
            from: [["kind": "box", "text": "Auth", "at": "10,20", "color": "", "from": NSNull()]],
            live: empty,
            mint: minter()
        )
        guard case let .elements(skeletons) = plan else {
            return XCTFail("expected an elements plan, got \(plan)")
        }
        XCTAssertNil(skeletons.first?.strokeColor)
    }

    func test_aMermaidDiagramWithAMalformedPositionIsRefused() {
        XCTAssertThrowsError(
            try Write.plan(
                from: [["kind": "mermaid", "text": flowchart, "at": "here"]],
                live: empty,
                mint: minter()
            )
        ) { XCTAssertEqual($0 as? Write.Failure, .invalidPosition("here")) }
    }

    /// The page stamps every element the diagram expands to, and it cannot
    /// spell a `customData` key — so the marker travels on the op, the way
    /// `captionKey` travels with a caption. The caption key rides along for the
    /// diagram types the converter renders as an image: that image's caption
    /// is the definition, so the digest is not blind to it.
    func test_theMermaidOpCarriesTheDefinitionTheOriginTheAuthorMarkerAndTheCaptionKey() {
        let op = Write.Mermaid(definition: flowchart, x: 100, y: 200).op
        XCTAssertEqual(op["kind"] as? String, "mermaid")
        XCTAssertEqual(op["definition"] as? String, flowchart)
        XCTAssertEqual(op["x"] as? Double, 100)
        XCTAssertEqual(op["y"] as? Double, 200)
        let customData = op["customData"] as? [String: Any]
        XCTAssertEqual(
            customData?[Whiteboard.Element.authorKey] as? String,
            Whiteboard.Element.agentAuthorValue
        )
        XCTAssertNil(customData?[Whiteboard.Element.kindKey])
        XCTAssertEqual(op["captionKey"] as? String, Whiteboard.Element.captionKey)
    }

    /// `addPlan` is the elements arm and must not quietly draw a mermaid entry
    /// as something else if a caller reaches it directly.
    func test_addPlanRefusesAMermaidEntryRatherThanDrawingIt() {
        XCTAssertThrowsError(
            try Write.addPlan(from: [["kind": "mermaid", "text": flowchart]], live: empty, mint: minter())
        ) { XCTAssertEqual($0 as? Write.Failure, .mermaidStandsAlone) }
    }
}
