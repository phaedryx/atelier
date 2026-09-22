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

    /// A board carrying one captioned image, for the caption-budget tests.
    private func captioned(_ caption: String) -> String {
        """
        {"type":"excalidraw","elements":[
        {"id":"i","type":"image","x":60,"y":620,"width":800,"height":450,"isDeleted":false,
         "fileId":"abc","customData":{"\(Whiteboard.Element.captionKey)":"\(caption)"}}]}
        """
    }

    func test_aRealisticTranscriptionIsNotCut() {
        // The regression. A caption is a transcription of pixels, written so a
        // later agent need not open the picture at all — and it used to go
        // through the LABEL cap of 240 bytes, which cut most of the
        // screenshots this feature is for. This one is 380 bytes: a settings
        // pane, which is the ordinary case rather than an extreme.
        let transcription = "Atelier Settings, Environment tab. Detected Tools: "
            + "git 2.51.0 at /opt/homebrew/bin/git (green check); tmux 3.5a at "
            + "/opt/homebrew/bin/tmux (green check); process-compose - not found (red x), "
            + "with an Install link beside it. Below: a Refresh button, and the note "
            + "'Atelier searches /opt/homebrew/bin, /usr/local/bin and ~/.local/bin.'"
        XCTAssertGreaterThan(transcription.utf8.count, 240, "no longer exercises the old cap")
        let text = digest(captioned(transcription))
        XCTAssertTrue(text.contains("caption: \"\(transcription)\""), text)
        XCTAssertFalse(text.contains("cut at"), text)
    }

    func test_aCaptionThatIsCutSaysSo_ratherThanEndingInAnEllipsis() {
        // The whole of finding 3. A cut transcription reported as if it were
        // whole is worse than a cut label: the reader was told it need not open
        // the picture. The marker is OUTSIDE the quotes, because inside it is
        // indistinguishable from a transcription of a screenshot that was
        // itself clipped.
        // Multi-byte on purpose: the cut has to land on a character boundary,
        // and "é" is the two-byte case the byte-array version of this loop
        // rendered as U+FFFD.
        let text = digest(captioned(String(repeating: "é", count: 5_000)))
        XCTAssertTrue(text.contains("\"\(String(repeating: "é", count: 600))…\""), text)
        XCTAssertTrue(text.contains("(cut at 1200 bytes"), text)
        XCTAssertTrue(text.contains("the rest is only in the image itself)"), text)
        XCTAssertFalse(text.contains("\u{FFFD}"), "cut mid-scalar")
    }

    func test_aLabelIsStillCutAtTheLabelBudget() {
        // The caption budget must not have widened the label one on its way
        // past. A label is what the user typed into the shape and the shape is
        // right there; the 240 is what stops one of them spending the digest.
        let label = String(repeating: "a", count: 600)
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"\(label)"}]}
        """)
        XCTAssertTrue(text.contains("\"\(String(repeating: "a", count: 240))…\""), text)
        XCTAssertFalse(text.contains("cut at"), "a label says nothing in words")
    }

    func test_anEnormousCaptionStillLeavesTheDigestInsideItsBudget() {
        // The invariant the 240 existed for, checked against the new cap: one
        // element's text must not silently starve the rest. It does not,
        // because the assembly loop is honest — the entry that does not fit is
        // counted into the overflow note rather than dropped.
        let text = digest(captioned(String(repeating: "a", count: 50_000)), budget: 900)
        XCTAssertLessThanOrEqual(text.utf8.count, 900)
        XCTAssertTrue(text.contains("more elements"), text)
        XCTAssertTrue(text.hasSuffix(Whiteboard.Digest.closingLine), text)
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

    func test_aNewlineInACaptionDoesNotBreakTheLineFormat() {
        // The label sibling below covers `quoted`; a caption goes through
        // `captionText`, which is a different function, so this path needs its
        // own pin rather than inheriting one.
        //
        // It is also the more load-bearing of the two. A transcription of
        // terminal output or a stack trace is FULL of newlines, where a label
        // rarely has one — and an element's entry is one line plus at most one
        // indented caption line, so a caption that kept its newlines would let
        // a transcription forge entries for elements that are not on the board.
        // That is the digest lying about the board, which is the one thing this
        // feature is organised around not doing.
        let text = digest(captioned("Failures:\\n  1) User#full_name\\n     expected: 'Ada'"))
        let captionLines = text
            .components(separatedBy: "\n")
            .filter { $0.contains("caption:") }
        XCTAssertEqual(captionLines.count, 1, text)
        XCTAssertTrue(captionLines[0].contains("Failures:   1) User#full_name"), text)
        // One element line and one caption line, and nothing else that could be
        // mistaken for an entry.
        let elementLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("i  ") }
        XCTAssertEqual(elementLines.count, 1, text)
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

    // MARK: - Quoting

    func test_aQuoteInALabelIsEscaped_soTheDelimitersStayUnambiguous() {
        // Unescaped, `He said "hello"` rendered as `"He said "hello""` and a
        // reader cannot tell where the user's text ends. Mild — the digest is
        // read by an LLM rather than parsed — but the whole format's claim is
        // that it is the half of the board that can be reasoned about exactly.
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"He said \\"hello\\" to it"}]}
        """)
        XCTAssertTrue(text.contains(#""He said \"hello\" to it""#), text)
        // The bare form is what the bug produced, and it must be gone.
        XCTAssertFalse(text.contains(#""He said "hello" to it""#), text)
    }

    func test_aQuoteInACaptionIsEscaped_becauseTheEscapingIsInTheSharedPath() {
        // A caption goes through `captionText` and a label through `quoted`.
        // Both delegate to `clipped`, which is where the escaping lives — so
        // this pins that the shared path really is shared rather than the two
        // agreeing by coincidence.
        let text = digest(captioned(#"He said \"hello\" to the dialog"#))
        XCTAssertTrue(text.contains(#"caption: "He said \"hello\" to the dialog""#), text)
    }

    func test_aBackslashIsEscapedToo_becauseTheQuoteIs() {
        // Escaping only the quote is the ambiguous-in-a-new-way variant: a
        // literal backslash before a quote renders `\\"`, which under the rules
        // the reader has just been given decodes as an escaped backslash and
        // then a TERMINATOR. The field ends early and the output looks fine.
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"C:\\\\Users\\\\tad"}]}
        """)
        XCTAssertTrue(text.contains(#""C:\\Users\\tad""#), text)
    }

    func test_theLabelBudgetCountsEscapeCharacters_soTheByteBoundStillHolds() {
        // THE clip-order decision, and the only test that discriminates it.
        // `clipped` escapes as it cuts, so a label of 240 quotes spends its
        // whole 240-byte cap on 120 escaped pairs. Escape-after-clip would keep
        // 240 quotes and render 480 bytes — `maxTextBytes` would go on saying
        // "one shape cannot spend the whole digest" while one did.
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"\(String(repeating: #"\""#, count: 240))"}]}
        """)
        let line = text.components(separatedBy: "\n").first { $0.hasPrefix("n  ") } ?? ""
        XCTAssertEqual(line.components(separatedBy: #"\""#).count - 1, 120, line)
        // And the rendered field is the cap plus its fixed decoration — two
        // quotes and the ellipsis — never a multiple of it.
        let field = line.components(separatedBy: "  ")[2]
        XCTAssertEqual(field.utf8.count, 240 + 5, field)
    }

    func test_aCutNeverLandsBetweenABackslashAndItsQuote() {
        // The escape is appended whole or not at all, exactly as a grapheme is.
        // A cut between the two halves leaves a dangling `\`, which reaches the
        // reader as an escape for whatever the template puts next — the same
        // malformed output as a U+FFFD, by a different route.
        //
        // The input is chosen to STRADDLE the boundary, which a label of
        // nothing but quotes cannot do: 239 plain bytes then one quote, so the
        // escape is the two bytes that do not fit in 240. An implementation
        // that escaped the whole string and then cut the result would keep the
        // `\` and drop its `"`.
        let label = String(repeating: "a", count: 239) + #"\""#
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"text":"\(label)"}]}
        """)
        let line = text.components(separatedBy: "\n").first { $0.hasPrefix("n  ") } ?? ""
        let field = line.components(separatedBy: "  ")[2]
        // Strip the surrounding quotes and the ellipsis to get the kept region.
        let kept = String(field.dropFirst().dropLast(2))
        XCTAssertFalse(kept.hasSuffix("\\"), "an escape was split: \(kept.suffix(8))")
        XCTAssertEqual(kept, String(repeating: "a", count: 239), kept)
    }

    func test_aQuoteHeavyCaptionIsStillCutAtItsOwnBudget_andSaysSo() {
        // The caption budget counts escape characters the same way, so the
        // "(cut at 1200 bytes" sentence names bytes of the escaped field. 700
        // quotes is 1400 escaped bytes, which is over the cap where 700 raw
        // ones would not have been — the honest half of the ordering trade.
        let text = digest(captioned(String(repeating: #"\""#, count: 700)))
        XCTAssertTrue(text.contains("(cut at 1200 bytes"), text)
        XCTAssertTrue(text.contains(#"\""#), text)
        XCTAssertFalse(text.contains("\u{FFFD}"), text)
    }

    func test_ordinaryTextIsUntouchedByTheEscaping() {
        // Very nearly every real board is this case, and it must render exactly
        // as it did before: the escaping is not allowed to cost the common path
        // a single byte.
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.contains("\"Auth service\""), text)
        XCTAssertTrue(text.contains("\"why is this sync?\""), text)
        XCTAssertFalse(text.contains("\\"), text)
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
