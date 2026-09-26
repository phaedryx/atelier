// ABOUTME: Pins the digest an agent reads — ordering, opacity, budget, and the
// ABOUTME: three board states that must never share a sentence.

@testable import Atelier
import XCTest

final class WhiteboardDigestTests: XCTestCase {
    /// The render every test gets unless it says otherwise, and the closing
    /// line that goes with it. Bound together so a test asserting the closing
    /// line cannot be asserting one for a different state than it rendered.
    private static let currentRender = Whiteboard.Digest.Render.current(
        width: 1360,
        height: 1520,
        path: "/tmp/b/board.png"
    )
    private static let currentClosingLine = Whiteboard.Digest.closingLine(for: currentRender)

    private func digest(
        _ json: String,
        render: Whiteboard.Digest.Render = WhiteboardDigestTests.currentRender,
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
        XCTAssertTrue(text.hasSuffix(Self.currentClosingLine), text)
    }

    // MARK: - The closing line

    func test_theClosingLineIsAlwaysThereForABoardWithContent() {
        // Without it an agent reads five boxes and concludes that is the whole
        // board. It is the load-bearing sentence of this format, not a footer.
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.hasSuffix(Self.currentClosingLine), text)
        XCTAssertTrue(text.contains("board.png"), text)
    }

    func test_theClosingLineSurvivesTruncation() {
        // The failure this prevents: a digest cut to fit, losing the one line
        // that tells the reader it is not looking at everything.
        let text = digest(crowded(500), budget: 1200)
        XCTAssertTrue(
            text.hasSuffix(
                Self.currentClosingLine
            ),
            text
        )
    }

    func test_withNoRenderTheClosingLineDoesNotSendTheAgentToOpenOne() {
        // The bug: a constant closing line told the agent to go and open
        // board.png two lines under a header saying none had been rendered.
        // Asserting the function was called would pass for that wording too, so
        // what is pinned is the contradiction being gone.
        let text = digest(WhiteboardSceneTests.fixture, render: .none)
        XCTAssertTrue(text.lowercased().contains("no board.png"), text)
        XCTAssertFalse(text.lowercased().contains("open it"), text)
    }

    func test_withAStaleRenderTheClosingLineSaysThePictureIsOfAnEarlierBoard() {
        // Milder version of the same fault: the picture exists, so "open it" is
        // right, and leaving it at that presents an earlier board as current.
        let text = digest(WhiteboardSceneTests.fixture, render: .stale(path: "/tmp/b/board.png"))
        XCTAssertTrue(text.lowercased().contains("open it"), text)
        XCTAssertTrue(text.lowercased().hasSuffix("earlier version of this board."), text)
    }

    func test_withACurrentRenderTheClosingLineStillSaysToOpenIt() {
        // The state the sentence was written for, unchanged: a picture that is
        // current is one the agent should go and read.
        let text = digest(WhiteboardSceneTests.fixture)
        XCTAssertTrue(text.hasSuffix("They are in board.png — open it."), text)
        XCTAssertTrue(text.hasSuffix(Self.currentClosingLine), text)
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
        XCTAssertTrue(text.hasSuffix(Self.currentClosingLine), text)
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

    // MARK: - identifiers, which are columns rather than prose

    /// A board of one element, with every identifier under the test's control.
    ///
    /// The forgery tests compare a hostile board against a benign one of the
    /// same shape rather than against a hardcoded line count, so they keep
    /// their teeth if the digest's surrounding lines ever change.
    private func oneElement(
        id: String = "n1",
        type: String = "rectangle",
        extra: String = ""
    ) -> String {
        """
        {"type":"excalidraw","elements":[
        {"id":"\(id)","type":"\(type)","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false\(extra)}]}
        """
    }

    private func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    func test_aNewlineInAnElementsIDCannotForgeASecondEntry() {
        // `id` is FIRST on every line, so a newline there hands the forger the
        // whole of the injected line. This is the one the digest's "an element
        // is one line, and the reader counts lines" claim rests on.
        let forged = digest(oneElement(id: #"n1\nn9  box  at 640,480  200×80"#))
        XCTAssertEqual(lineCount(forged), lineCount(digest(oneElement())), forged)
        XCTAssertFalse(
            forged.components(separatedBy: "\n").contains { $0.hasPrefix("n9") },
            forged
        )
    }

    func test_aNewlineInAnUnknownKindCannotForgeASecondEntry() {
        let forged = digest(oneElement(type: #"frame\nn9  box  at 640,480  200×80"#))
        XCTAssertEqual(lineCount(forged), lineCount(digest(oneElement())), forged)
    }

    func test_aNewlineInAFileIDCannotForgeASecondEntry() {
        let forged = digest(oneElement(
            type: "image",
            extra: #","fileId":"abc\nn9  box  at 640,480  200×80""#
        ))
        XCTAssertEqual(lineCount(forged), lineCount(digest(oneElement())), forged)
    }

    func test_aNewlineInAnArrowsBindingCannotForgeASecondEntry() {
        let forged = digest(oneElement(
            type: "arrow",
            extra: #","startBinding":{"elementId":"a\nn9  box  at 640,480  200×80"}"#
        ))
        XCTAssertEqual(lineCount(forged), lineCount(digest(oneElement())), forged)
    }

    // MARK: - the forgery a newline rule does NOT catch

    func test_anUnknownKindCannotForgeThisElementsGeometryAndAuthorship() {
        // THE TEST THAT PICKS THE DESIGN. Nothing here crosses a line, so
        // flattening alone leaves it untouched: the entry stays one line and
        // the line-counting reader is satisfied, while the columns after the
        // kind now read as a box at a position the user never put it, marked
        // as drawn by an agent. The digest asserting authorship it invented is
        // worse than an extra line, because nothing about it looks wrong.
        let forged = digest(oneElement(type: #"box  at 999,999  50×50  (agent)"#))
        XCTAssertFalse(forged.contains("(agent)"), forged)
        XCTAssertFalse(forged.contains("at 999,999"), forged)
    }

    func test_aFileIDCannotForgeColumnsWithinItsOwnLine() {
        let forged = digest(oneElement(
            type: "image",
            extra: #","fileId":"abc  at 999,999  50×50  (agent)""#
        ))
        XCTAssertFalse(forged.contains("(agent)"), forged)
        XCTAssertFalse(forged.contains("at 999,999"), forged)
    }

    func test_anArrowsBindingCannotForgeColumnsWithinItsOwnLine() {
        let forged = digest(oneElement(
            type: "arrow",
            extra: #","startBinding":{"elementId":"a  at 999,999  50×50  (agent)"}"#
        ))
        XCTAssertFalse(forged.contains("(agent)"), forged)
        XCTAssertFalse(forged.contains("at 999,999"), forged)
    }

    // MARK: - the bound, and the markers

    func test_anIdentifierIsBounded_andTheCutIsMarked() {
        // Nothing bounds these fields at the scene layer, so one element can
        // otherwise spend the digest the way an unbounded label used to.
        let long = String(repeating: "a", count: 4_000)
        let text = digest(oneElement(id: long))
        XCTAssertFalse(text.contains(String(repeating: "a", count: 100)), "not bounded")
        XCTAssertTrue(text.contains("…"), text)
    }

    func test_everyMarkerTheDigestAddsIsOutsideWhatAnIdentifierMayContain() {
        // The property that makes an unquoted column readable: the cut marker
        // and the substitution marker cannot be content, so a reader seeing
        // one knows the digest put it there. It is the inverse of the
        // delimiter ambiguity #204 closed for quoted text.
        // An identifier carrying the cut marker as content, short enough that
        // nothing is cut. One element well inside the budget, so `overflowNote`
        // — the digest's only other producer of this character — cannot fire.
        let text = digest(oneElement(id: #"a…b"#))
        XCTAssertFalse(text.contains("…"), text)
        XCTAssertFalse(text.contains("a…b"), text)
    }

    func test_theSubstitutionMarkerCannotItselfBeMistakenForAnIdentifier() {
        // The half of the property a cut-marker test cannot reach. If the
        // marker were an admissible character, an id of one inadmissible
        // character would render as a perfectly plausible real id — the digest
        // silently presenting its own substitution as the board's content,
        // which is the ambiguity this design replaces escaping to avoid.
        let text = digest(oneElement(id: #"\u2026\u2026\u2026"#))
        let rendered = text
            .components(separatedBy: "\n")
            .first { $0.contains("  box  ") }
            .map { String($0.prefix(while: { $0 != " " })) }
        XCTAssertNotNil(rendered, text)
        XCTAssertFalse(rendered?.isEmpty ?? true, text)
        XCTAssertFalse(
            rendered?.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber
                        || character == "-" || character == "_")
            } ?? true,
            "rendered as \(rendered ?? "nil"), which reads as an ordinary id"
        )
    }

    func test_anEmptyIdentifierIsNamedRatherThanVanishing() {
        // Every one of the five is a plain `as? String`, so "" reaches all of
        // them, and an absent column silently moves every column after it one
        // place to the left — the same misread-by-position as an injected
        // one, arrived at by omission. Handled uniformly, so there is no
        // per-field rule to remember.
        XCTAssertFalse(digest(oneElement(type: "")).contains("n1    at"), "kind")
        XCTAssertTrue(digest(oneElement(type: "")).contains("(none)"), "kind")
        XCTAssertTrue(digest(oneElement(id: "")).contains("(none)"), "id")
        XCTAssertTrue(
            digest(oneElement(type: "arrow", extra: #","startBinding":{"elementId":""}"#))
                .contains("(none)"),
            "binding"
        )
        XCTAssertTrue(
            digest(oneElement(type: "image", extra: #","fileId":"""#)).contains("(none)"),
            "fileId"
        )
    }

    /// **A namespace frame reads as a named element, not as a bare rectangle
    /// of dimensions.** A mermaid class diagram with a `namespace` block draws
    /// one, so this is what an agent re-reading its own diagram sees. The name
    /// rides in the text slot, which puts it through the ordinary label arm.
    func test_aFrameRendersItsNameTheWayALabelledShapeDoes() {
        let line = digest("""
        {"elements":[
          {"id":"f1","type":"frame","name":"Auth","x":10,"y":20,
           "width":400,"height":300}]}
        """)
        XCTAssertTrue(line.contains("frame"), line)
        XCTAssertTrue(line.contains("\"Auth\""), line)
        // And not through `.other`'s self-naming path, which would have printed
        // the raw type with no name beside it.
        XCTAssertFalse(line.contains("f1  frame  at"), line)
    }

    func test_anUnboundArrowEndIsStillDistinctFromOneBoundToANamelessElement() {
        // The one place empty and absent must NOT collapse. `?` means there is
        // no binding; an empty `elementId` means there is a binding whose
        // target has no id. Rendering both as `?` would have the digest report
        // a structural fact it does not have.
        let empty = digest(oneElement(type: "arrow", extra: #","startBinding":{"elementId":""}"#))
        XCTAssertTrue(empty.contains("(none) → ?"), empty)
    }

    // MARK: - What the cut drops, and what it may never drop

    /// A board of `count` elements built from the JSON each index maps to.
    private func board(_ count: Int, _ element: (Int) -> String) -> String {
        "{\"type\":\"excalidraw\",\"elements\":[\((0 ..< count).map(element).joined(separator: ","))]}"
    }

    private func labelledBox(_ index: Int, x: Int = 0, y: Int = 0) -> String {
        """
        {"id":"p\(index)","type":"rectangle","x":\(x),"y":\(y),"width":10,"height":10,
         "isDeleted":false,"text":"padding label number \(index)"}
        """
    }

    private func stroke(_ index: Int) -> String {
        """
        {"id":"s\(index)","type":"freedraw","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"points":[[0,0],[1,1]]}
        """
    }

    func test_anArrowIsNeverListedWithoutTheEndpointsItNames() {
        // The bug positional truncation produced on any board big enough to
        // cut: the arrow fits, the box it points at does not, and the digest
        // prints `a → z` with no `z` anywhere in it — an id that appears
        // nowhere else, which is the same lie an arrow left bound to a deleted
        // element tells. The endpoints are LAST in file order on purpose, which
        // is where the old loop lost them.
        let padding = (0 ..< 200).map { labelledBox($0) }.joined(separator: ",")
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"x1","type":"arrow","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "text":"flows into",
         "startBinding":{"elementId":"a"},"endBinding":{"elementId":"z"}},
        \(padding),
        {"id":"a","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false},
        {"id":"z","type":"rectangle","x":900,"y":900,"width":10,"height":10,"isDeleted":false}]}
        """, budget: 1000)

        XCTAssertTrue(text.contains("more elements"), "the board has to be cut for this to mean anything")
        XCTAssertTrue(text.contains("x1  arrow  a → z"), text)
        XCTAssertTrue(text.contains("\na  box  at"), text)
        XCTAssertTrue(text.contains("\nz  box  at"), text)
    }

    func test_anArrowThatCannotBringItsEndpointsIsNotListedEither() {
        // The other side of the bundle. When there is no room for the unit, the
        // arrow goes too — un-listing it is the only answer that keeps the
        // invariant, and the alternative is printing the dangling id the whole
        // scheme exists to prevent.
        //
        // The arrow is labelled and first in file order, so it is the very
        // first thing the cut reaches, and its own entry is about twenty bytes
        // against a budget with room for a two-hundred-byte box. It is left out
        // anyway, and that is the bundle rule rather than the arrow running out
        // of room: `a` is listed, so there plainly was room.
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"x1","type":"arrow","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "text":"via",
         "startBinding":{"elementId":"a"},"endBinding":{"elementId":"z"}},
        {"id":"a","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "text":"\(String(repeating: "a", count: 200))"},
        {"id":"z","type":"rectangle","x":900,"y":900,"width":10,"height":10,"isDeleted":false,
         "text":"\(String(repeating: "z", count: 200))"}]}
        """, budget: 760)

        XCTAssertTrue(text.contains("more elements"), text)
        XCTAssertFalse(text.contains("x1  arrow"), text)
        XCTAssertTrue(text.contains("\na  box"), text)
    }

    func test_anArrowBoundToAnotherArrowDragsThatArrowsEndpointsInToo() {
        // Excalidraw lets an arrow bind to an arrow, so the bundle has to be
        // transitive. Pulling `x2` in for `x1` and stopping there charges
        // nothing for `x2`'s own endpoints, and `x2` lands in the digest
        // printing the dangling id the bundle exists to prevent — the same
        // failure, one hop further out. `x1` carries the label, so it is what
        // the cut reaches for first.
        let padding = (0 ..< 200).map { labelledBox($0) }.joined(separator: ",")
        let text = digest("""
        {"type":"excalidraw","elements":[
        {"id":"x1","type":"arrow","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "text":"via",
         "startBinding":{"elementId":"a"},"endBinding":{"elementId":"x2"}},
        \(padding),
        {"id":"x2","type":"arrow","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "startBinding":{"elementId":"a"},"endBinding":{"elementId":"z"}},
        {"id":"a","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false},
        {"id":"z","type":"rectangle","x":900,"y":900,"width":10,"height":10,"isDeleted":false}]}
        """, budget: 1000)

        XCTAssertTrue(text.contains("more elements"), "the board has to be cut for this to mean anything")
        XCTAssertTrue(text.contains("x1  arrow  a → x2"), text)
        XCTAssertTrue(text.contains("x2  arrow  a → z"), text)
        XCTAssertTrue(text.contains("\na  box  at"), text)
        XCTAssertTrue(text.contains("\nz  box  at"), text)
    }

    func test_freehandIsWhatATruncatedDigestDropsFirst() {
        // Ordering by value rather than by file position. A stroke renders as a
        // point count and a box, and the closing line already says it is only
        // in board.png — so it is the one entry whose loss the overflow note
        // answers for honestly. Interleaved with the boxes so file order cannot
        // be what produces the result. The budget is wide enough for every
        // labelled box and only some of the strokes, so what the cut reaches
        // for is the whole of what this observes.
        let text = digest(board(60) { $0.isMultiple(of: 2) ? self.stroke($0) : self.labelledBox($0) },
                          budget: 2200)

        XCTAssertTrue(text.contains("more elements"), text)
        XCTAssertTrue(text.contains("stroke"), "strokes are what should have gone")
        for index in stride(from: 1, to: 60, by: 2) {
            XCTAssertTrue(text.contains("\np\(index)  box"), "dropped a labelled box before a stroke")
        }
    }

    func test_anUncaptionedImageOutranksAStroke() {
        // Deliberately not grouped with freehand, though neither carries
        // anything this file may transcribe. An image's id is the entry point
        // for whiteboard_update(caption:) — the agent reads the id here, opens
        // the picture and writes back what it says — so an image the digest
        // leaves out is one that can never be captioned, on exactly the boards
        // that arm is for.
        let strokes = (0 ..< 60).map { stroke($0) }.joined(separator: ",")
        let text = digest("""
        {"type":"excalidraw","elements":[
        \(strokes),
        {"id":"i1","type":"image","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "fileId":"abc"}]}
        """, budget: 900)

        XCTAssertTrue(text.contains("more elements"), text)
        XCTAssertTrue(text.contains("i1  image"), text)
    }

    // MARK: - Saying what cannot be seen

    func test_theHeaderCountsTheWholeBoardAndGivesItsExtentEvenWhenCut() {
        // The two facts that stay true of the whole board when the list below
        // is only part of it. Without them a truncated digest says how many
        // elements it left out and nothing about where they are.
        let text = digest(board(200) { self.labelledBox($0, x: $0 * 10, y: $0 * 5) }, budget: 1000)

        XCTAssertTrue(text.contains("# Whiteboard — 200 elements"), text)
        XCTAssertTrue(text.contains("extent 0,0 → 2000,1005"), text)
        XCTAssertTrue(text.contains("more elements"), text)
    }

    func test_theExtentIsThereOnABoardThatFitsWholeToo() {
        // Unconditional on purpose. A line that appears only on large boards is
        // one an agent learns to read only on large boards, and placing the
        // next element is a question a complete digest gets asked as well.
        let text = digest(oneElement())
        XCTAssertFalse(text.contains("more elements"), text)
        XCTAssertTrue(text.contains("extent 0,0 → 10,10"), text)
    }

    func test_theOverflowNoteNamesTheKindsItLeftOut() {
        let text = digest(board(60) { $0.isMultiple(of: 2) ? self.stroke($0) : self.labelledBox($0) },
                          budget: 1200)
        XCTAssertTrue(text.contains("size budget: "), text)
        XCTAssertTrue(text.range(of: #"budget: \d+ stroke"#, options: .regularExpression) != nil, text)
    }

    func test_theOverflowNoteBucketsUnknownKindsRatherThanNamingEachOne() {
        // The reserve's worst case is the note with every element omitted, so a
        // bucket named by the raw type would let a board of distinct unknown
        // types write a note longer than the whole budget: nothing listed, and
        // an overshoot of the cap the cut was performed to respect.
        let text = digest(board(300) { index in
            """
            {"id":"u\(index)","type":"kind\(index)","x":0,"y":0,"width":10,"height":10,
             "isDeleted":false}
            """
        }, budget: 1200)

        XCTAssertLessThanOrEqual(text.utf8.count, 1200)
        XCTAssertTrue(text.contains("more elements"), text)
        XCTAssertFalse(text.contains("kind250"), "a raw type reached the breakdown")
        XCTAssertTrue(text.range(of: #"budget: \d+ other"#, options: .regularExpression) != nil, text)
    }

    // MARK: - The raised cap

    func test_aTwoHundredElementBoardIsListedWhole() {
        // The regression the raise is for. At 8,000 this board reported its
        // last hundred-odd elements as "not listed" and sent the reader to a
        // board.png capped at 1,600px on its long edge — both halves of the
        // read path degrading together, exactly as the board got big enough to
        // be worth checking.
        let text = digest(board(200) { self.labelledBox($0, x: $0 * 10) })
        XCTAssertFalse(text.contains("more elements"), text)
        XCTAssertLessThanOrEqual(text.utf8.count, Whiteboard.Digest.maxBytes)
    }

    func test_theBudgetIsACeilingAndNotATarget() {
        // The question a 4x raise has to answer, and the measurement the whole
        // choice of default rests on: does a small board now cost what a large
        // one does? It does not — nothing pads, and the assembly spends exactly
        // what the elements are worth. A thirty-element board measures under
        // 4KB against a 32,000-byte cap, and every board that
        // fitted inside the old 8,000 returns byte-identical output, so the
        // raise costs those calls nothing. `read_whiteboard` is on a hot path
        // and this is the property that keeps the raise off it.
        let small = digest(board(30) { self.labelledBox($0, x: $0 * 260) })
        XCTAssertFalse(small.contains("more elements"), small)
        XCTAssertLessThan(small.utf8.count, 4_000, small)
        // And the same board asked for under the old cap is the same bytes.
        XCTAssertEqual(digest(board(30) { self.labelledBox($0, x: $0 * 260) }, budget: 8_000), small)
    }
}
