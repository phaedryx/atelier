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

    /// Matches the case rather than its sentence: the payload names which read
    /// failed and is copy, while the case is the contract — a decode failure is
    /// a page that was never written to, so it must not be the refusal that
    /// forbids a retry.
    private func assertNotReady(_ raw: [String: Any], _ message: String) {
        do {
            _ = try Host.decodeLiveState(raw)
            XCTFail("Expected .notReady: \(message)")
        } catch {
            guard case .notReady? = error as? Host.WriteFailure else {
                XCTFail("Expected .notReady, got \(error): \(message)")
                return
            }
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

    // MARK: - Which refusal a failed read is owed

    /// The bug this split fixes: every `decodeLiveState` failure happens before
    /// anything has been posted to the page, so the caller has drawn nothing
    /// and a retry is the action that works. It used to share a case — and
    /// therefore a sentence — with a write whose outcome is unknown, so an
    /// agent whose first call of the session met a slow cold page was told it
    /// might already have drawn something and must not try again.
    func test_aReadThatFailedBeforeAnythingWasSentInvitesTheRetryItIsSafeToMake() throws {
        let read = Host.WriteFailure.notReady("it answered with an incomplete state")
        let description = try XCTUnwrap(read.errorDescription)
        XCTAssertTrue(
            description.contains("safe to retry"),
            "a read that sent nothing must say so: \(description)"
        )
        XCTAssertFalse(
            description.contains("Do not retry"),
            "nothing was drawn, so nothing can be duplicated: \(description)"
        )
    }

    /// And the other half, which is what keeps the split honest: an operation
    /// that was posted and never answered for still forbids a retry, because a
    /// caller cannot tell a genuine failure from one its own retry caused.
    func test_aWriteWhoseOutcomeIsUnknownStillForbidsARetry() throws {
        let sent = Host.WriteFailure.outcomeUnknown("the page went away")
        let description = try XCTUnwrap(sent.errorDescription)
        XCTAssertTrue(
            description.contains("Do not retry"),
            "the op may have landed: \(description)"
        )
    }

    // MARK: - The log's audience is not the agent's

    /// `captureToBoard` reaches these failures from a button press, and logs
    /// them. The retry advice above is addressed to an agent holding an IPC
    /// call it could make again; there is no such call behind the capture
    /// button, so a log line telling a human to retry names an action they do
    /// not have and points them at `read_whiteboard`, which is not a thing a
    /// person can call.
    func test_theDiagnosticCarriesWhatFailedAndNoAdviceAboutIt() {
        for failure: Host.WriteFailure in [
            .notReady("it did not finish loading in time"),
            .outcomeUnknown("the page went away"),
            .refused("no reason given"),
            .unknownElements(["n1"]),
        ] {
            for advice in ["retry", "read_whiteboard"] {
                XCTAssertFalse(
                    failure.diagnostic.contains(advice),
                    "\(failure) tells a log reader to \(advice): \(failure.diagnostic)"
                )
            }
        }
    }

    /// And they are one string with advice appended, never two copies: a
    /// wording fix to what failed cannot land in the agent's sentence and miss
    /// the log's.
    func test_theAgentsSentenceIsTheDiagnosticPlusItsAdvice() throws {
        for failure: Host.WriteFailure in [
            .notReady("it did not finish loading in time"),
            .outcomeUnknown("the page went away"),
            .refused("no reason given"),
            .unknownElements(["n1"]),
        ] {
            let description = try XCTUnwrap(failure.errorDescription)
            XCTAssertTrue(
                description.hasPrefix(failure.diagnostic),
                "\(failure) says what failed twice over: \(description)"
            )
        }
    }

    /// A `WKWebView` error never passed through `WriteFailure`, and the log
    /// site cannot tell the two apart before it logs them.
    func test_anErrorThatIsNotAWriteFailureStillLogsItsOwnDescription() {
        struct Nothing: LocalizedError {
            var errorDescription: String? {
                "the webview went away"
            }
        }
        XCTAssertEqual(
            Host.WriteFailure.diagnostic(for: Nothing()),
            "the webview went away"
        )
        XCTAssertEqual(
            Host.WriteFailure.diagnostic(for: Host.WriteFailure.refused("no reason given")),
            "The whiteboard page refused the write: no reason given"
        )
    }

    // MARK: - The geometry a write answers with

    /// Exactly the shape the page sends a rectangle in, as `JSONSerialization`
    /// hands it over: every number an `NSNumber`. That is not pedantry — every
    /// coordinate on this board may be integral, and an integral JSON number
    /// bridges to an `NSNumber` that an `as? Double` cast misses entirely.
    /// `SceneLoad.number` documents the same trap on the read side.
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Any] {
        [
            "x": NSNumber(value: x), "y": NSNumber(value: y),
            "width": NSNumber(value: w), "height": NSNumber(value: h),
        ]
    }

    func test_aRectSurvivesIntegralNumbersFromThePage() {
        XCTAssertEqual(
            Host.decodeRect(rect(120, 80, 312, 90)),
            Write.Rect(x: 120, y: 80, width: 312, height: 90)
        )
    }

    /// **Dropped rather than guessed.** A rect is re-encoded into the answer and
    /// into a following call's `at`, where `Write.parsePosition` refuses a
    /// non-finite coordinate anyway — and a non-finite `Double` reaching
    /// `JSONSerialization` raises an Objective-C exception that kills the app.
    func test_aRectMissingOrNonFiniteIsNoRectAtAll() {
        XCTAssertNil(Host.decodeRect(nil))
        XCTAssertNil(Host.decodeRect(["x": 1, "y": 2, "width": 3]))
        XCTAssertNil(Host.decodeRect(rect(.infinity, 0, 10, 10)))
        XCTAssertNil(Host.decodeRect(rect(0, .nan, 10, 10)))
    }

    func test_rectsAreKeyedByTheIdThePageReported() {
        let decoded = Host.decodeRects([
            "n1": rect(0, 0, 10, 20),
            "n2": rect(5, 5, 30, 40),
        ])
        XCTAssertEqual(decoded["n1"], Write.Rect(x: 0, y: 0, width: 10, height: 20))
        XCTAssertEqual(decoded["n2"], Write.Rect(x: 5, y: 5, width: 30, height: 40))
    }

    /// **A missing measurement is a floor, not a failure** — the opposite of
    /// `decodeLiveState` above, and deliberately so. A size that does not arrive
    /// falls back to `boxSize`, which is a real size that draws a real box: the
    /// size every box was before auto-sizing. A coordinate that does not arrive
    /// has no such fallback, which is why that decode refuses instead.
    func test_anUnreadableSizeIsDroppedRatherThanRefusingTheWholeBatch() {
        let decoded = Host.decodeSizes([
            "good": ["width": NSNumber(value: 312), "height": NSNumber(value: 45)],
            "half": ["width": NSNumber(value: 312)],
            "wild": ["width": NSNumber(value: Double.infinity), "height": NSNumber(value: 45)],
            "junk": "not an object",
        ])
        XCTAssertEqual(decoded, ["good": Write.Size(width: 312, height: 45)])
    }
}
