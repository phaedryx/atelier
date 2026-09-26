// ABOUTME: The three closed layouts — placement, the budget, and the refusals.
// ABOUTME: Pure: no webview, no workstream, no board on disk.

@testable import Atelier
import XCTest

final class WhiteboardArrangementTests: XCTestCase {
    private typealias Arrangement = Whiteboard.Arrangement
    private typealias Write = Whiteboard.Write

    private let empty = Write.Live(ids: [], imageIDs: [], layout: .fallback)

    private func minter() -> () -> String {
        var n = 0
        return {
            n += 1
            return "id-\(n)"
        }
    }

    private func plan(_ layout: String, _ content: [String: Any]) throws -> [Write.Skeleton] {
        let data = try JSONSerialization.data(withJSONObject: content)
        return try Arrangement.plan(
            layout: layout,
            content: String(decoding: data, as: UTF8.self),
            live: empty,
            mint: minter()
        )
    }

    // MARK: - The collision invariant

    /// The rect a container may **grow into**, which is the one that matters.
    ///
    /// **This file proves half of the collision claim and the harness proves
    /// the other half.** Here: planned rects, measured at their grown height,
    /// never overlap. In `Tests/Harnesses/whiteboard-harness.swift` section 12:
    /// a label at the cap, in a container of `columnWidth`, really does come
    /// back within that grown height, against the built bundle. Neither half is
    /// the claim on its own — this one would pass against a wrong constant, and
    /// that one says nothing about placement. If you change `maxLabelHeight`,
    /// `labelCap` or `columnWidth`, both halves have to move together.
    ///
    /// Not the supplied height. Height is `max(supplied, needed)` — measured —
    /// so a container handed 90 comes back 110 for a four-line label. Asserting
    /// against the supplied 90 would pass while the picture collided, which is
    /// precisely the digest-and-picture disagreement this feature is organized
    /// around not having.
    private func grownRect(_ skeleton: Write.Skeleton) -> CGRect {
        CGRect(
            x: skeleton.x,
            y: skeleton.y,
            width: skeleton.width ?? 0,
            height: max(skeleton.height ?? 0, Arrangement.maxLabelHeight)
        )
    }

    private func assertNoOverlap(
        _ skeletons: [Write.Skeleton],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Arrows are excluded: the page computes their geometry from the
        // bindings, so the coordinates here are a placeholder it overwrites.
        let boxes = skeletons.filter { $0.type == "rectangle" }
        for (i, a) in boxes.enumerated() {
            for b in boxes[(i + 1)...] {
                XCTAssertFalse(
                    grownRect(a).intersects(grownRect(b)),
                    "\(a.label ?? a.id) at \(a.x),\(a.y) overlaps \(b.label ?? b.id) "
                        + "at \(b.x),\(b.y)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func bounds(_ skeletons: [Write.Skeleton]) -> CGRect {
        skeletons
            .filter { $0.type == "rectangle" }
            .reduce(CGRect.null) { $0.union(grownRect($1)) }
    }

    /// **A refusal is a pass.** The invariant is "if it draws, it does not
    /// collide" — an arrangement that will not fit the budget is *supposed* to
    /// refuse, and a sweep that treats that as a failure would push the next
    /// person to widen the budget to make the test green. What must never
    /// happen is a drawn arrangement whose containers overlap.
    private func sweep(
        _ layout: String,
        _ content: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try assertNoOverlap(plan(layout, content), file: file, line: line)
        } catch let failure as Arrangement.Failure {
            switch failure {
            case .tooManyFrames, .tooManySteps, .columnTooTall:
                break // refused for size, which is the other correct answer
            default:
                XCTFail("unexpected refusal: \(failure)", file: file, line: line)
            }
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    func test_smallMultiplesNeverCollides() {
        for nodeCount in 1 ... 6 {
            for frameCount in 1 ... 8 {
                sweep("small_multiples", [
                    "nodes": (1 ... nodeCount).map { "node \($0)" },
                    "frames": (1 ... frameCount).map {
                        ["title": "step \($0)", "highlight": "node 1"]
                    },
                ])
            }
        }
    }

    func test_lanesNeverCollidesAcrossBands() {
        for actorCount in 1 ... 5 {
            for stepCount in 1 ... 12 {
                sweep("lanes", [
                    "actors": (1 ... actorCount).map { "actor \($0)" },
                    "steps": (1 ... stepCount).map {
                        ["actor": "actor \(($0 - 1) % actorCount + 1)", "text": "step \($0)"]
                    },
                ])
            }
        }
    }

    func test_beforeAfterNeverCollides() {
        for nodeCount in 1 ... 12 {
            sweep("before_after", [
                "before": ["title": "Today", "nodes": (1 ... nodeCount).map { "was \($0)" }],
                "after": [
                    "title": "Proposed",
                    "nodes": (1 ... nodeCount).map { "now \($0)" },
                    "highlight": ["now 1"],
                ],
            ])
        }
    }

    // MARK: - The budget

    /// **The claim is about the arrangement, not about the board.** A layout is
    /// placed below whatever is already there, so it adds to the board's
    /// height; nothing here can promise `board.png` renders unscaled. What it
    /// can promise is that what it places is itself within the budget.
    func test_noArrangementExceedsTheBudgetOnEitherEdge() throws {
        let cases: [(String, [String: Any])] = [
            // Each one is the largest that layout accepts, so the budget is
            // asserted at the edge rather than somewhere comfortably inside it.
            ("small_multiples", [
                "nodes": (1 ... 3).map { "node \($0)" },
                "frames": (1 ... 8).map { ["title": "frame \($0)"] },
            ]),
            ("lanes", [
                "actors": (1 ... 4).map { "actor \($0)" },
                "steps": (1 ... 10).map { ["actor": "actor 1", "text": "step \($0)"] },
            ]),
            ("before_after", [
                "before": ["nodes": (1 ... 10).map { "a \($0)" }],
                "after": ["nodes": (1 ... 10).map { "b \($0)" }],
            ]),
        ]
        for (layout, content) in cases {
            let box = try bounds(plan(layout, content))
            XCTAssertLessThanOrEqual(box.width, Arrangement.maxEdge, layout)
            XCTAssertLessThanOrEqual(box.height, Arrangement.maxEdge, layout)
        }
    }

    /// The motivating case: four actors by eight steps. It must not refuse —
    /// a tool that refuses its own worked example is not a tool.
    func test_lanesDrawsFourActorsByEightSteps() throws {
        let skeletons = try plan("lanes", [
            "actors": ["Agent", "Swift", "Page", "User"],
            "steps": (1 ... 8).map { ["actor": "Swift", "text": "step \($0)"] },
        ])
        assertNoOverlap(skeletons)
        XCTAssertLessThanOrEqual(bounds(skeletons).width, Arrangement.maxEdge)
    }

    // MARK: - Banding

    func test_lanesRepeatsItsLaneLabelsInEveryBand() throws {
        let skeletons = try plan("lanes", [
            "actors": ["Agent", "Swift"],
            "steps": (1 ... 10).map { ["actor": "Agent", "text": "step \($0)"] },
        ])
        // Five steps to a band, so ten steps is two bands and each actor's
        // label appears once per band. A band missing its labels is a
        // continuation fragment, which is the thing banding is not.
        XCTAssertEqual(skeletons.filter { $0.label == "Agent" }.count, 2)
        XCTAssertEqual(skeletons.filter { $0.label == "Swift" }.count, 2)
    }

    func test_lanesNumbersItsStepsSoContinuitySurvivesTheBandBreak() throws {
        let skeletons = try plan("lanes", [
            "actors": ["Agent"],
            "steps": (1 ... 7).map { _ in ["actor": "Agent", "text": "do it"] },
        ])
        let numbered = skeletons.compactMap(\.label).filter { $0.hasSuffix("do it") }
        XCTAssertEqual(numbered.first, "1 do it")
        XCTAssertEqual(numbered.last, "7 do it")
    }

    /// **Asserted as "every arrow points rightward", not as "both ends share a
    /// y".** The y predicate is what this checked first, and it was nearly
    /// worthless: it holds trivially when every step names the same actor,
    /// which is what the test fed it, and it is *wrong* the moment actors vary,
    /// because a legitimate within-band arrow between two different lanes has
    /// two different y values by construction. A cross-band arrow is the one
    /// that runs from the rightmost column back to the leftmost, so `to.x >
    /// from.x` catches exactly it, at any actor count.
    func test_noArrowCrossesABandBoundary() throws {
        let steps = 12
        let skeletons = try plan("lanes", [
            "actors": ["Agent", "Swift", "Page"],
            // Actors deliberately varied, so a within-band arrow really does
            // change lane and the assertion has something to be wrong about.
            "steps": (1 ... steps).map {
                ["actor": ["Agent", "Swift", "Page"][($0 - 1) % 3], "text": "step \($0)"]
            },
        ])
        let byID = Dictionary(
            uniqueKeysWithValues: skeletons.filter { $0.type == "rectangle" }.map { ($0.id, $0) }
        )
        let arrows = skeletons.filter { $0.type == "arrow" }
        for arrow in arrows {
            guard let from = byID[arrow.from ?? ""], let to = byID[arrow.to ?? ""] else {
                return XCTFail("an arrow named something that is not in the batch")
            }
            XCTAssertGreaterThan(
                to.x, from.x,
                "arrow from \(from.label ?? "") to \(to.label ?? "") runs backwards, "
                    + "which is what a band boundary would look like"
            )
        }
        // And the count says a band break really happened: each band chains its
        // own steps, so a break costs exactly one arrow. Without this the test
        // above would pass just as well on a plan that drew no arrows at all.
        let bands = Int(ceil(Double(steps) / Double(Arrangement.columnsThatFit() - 1)))
        XCTAssertGreaterThan(bands, 1, "this case must actually band, or it proves nothing")
        XCTAssertEqual(arrows.count, steps - bands)
    }

    // MARK: - The label cap, across scripts

    /// **The corpus is deliberately not Latin-only.** A 30-character cap looks
    /// like a clean invariant after testing English: 30 characters of even
    /// all-`W` wraps to three lines and fits the supplied 90. CJK and emoji do
    /// not — both go to four lines and 110 — so the pitch is set from the
    /// widest script rather than from the cap. A Latin-only corpus is how the
    /// wrong rule gets re-derived by the next person to touch this.
    func test_theCapHoldsForEveryScriptMeasured() throws {
        let atTheCap = [
            String(repeating: "W", count: 30),
            String(repeating: "i", count: 30),
            "認証トークンストアのパス検証処理を担当する層", // CJK
            "🔴🟠🟡🟢🔵🟣⚫⚪🟤🔺🔻🔶🔷🔸🔹", // emoji
            "Проверка токена аутентификации", // Cyrillic
        ]
        for label in atTheCap {
            XCTAssertLessThanOrEqual(label.count, Arrangement.labelCap, label)
            let skeletons = try plan("before_after", [
                "before": ["nodes": [label]],
                "after": ["nodes": [label]],
            ])
            assertNoOverlap(skeletons)
        }
    }

    func test_aLabelPastTheCapIsRefusedAndTheRefusalNamesTheCap() throws {
        XCTAssertThrowsError(try plan("before_after", [
            "before": ["nodes": [String(repeating: "a", count: 31)]],
            "after": ["nodes": ["fine"]],
        ])) { error in
            XCTAssertEqual(
                error as? Arrangement.Failure,
                .labelTooLong(String(repeating: "a", count: 31), limit: Arrangement.labelCap)
            )
            XCTAssertTrue(
                error.localizedDescription.contains("\(Arrangement.labelCap) characters"),
                error.localizedDescription
            )
        }
    }

    /// A grapheme cluster is one glyph however many scalars it holds, and it is
    /// what renders — so it is what is counted. Counting scalars would refuse a
    /// label that draws perfectly well.
    func test_aMultiScalarEmojiCountsAsOneCharacter() throws {
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 10)
        XCTAssertGreaterThan(family.unicodeScalars.count, Arrangement.labelCap)
        XCTAssertNoThrow(try plan("before_after", [
            "before": ["nodes": [family]], "after": ["nodes": ["fine"]],
        ]))
    }

    /// A step label carries its number, so the number is part of what has to be
    /// bounded — a cap applied to the caller's text alone passes and then
    /// overruns the row anyway.
    func test_aStepLabelIsCappedWithRoomForItsNumber() throws {
        XCTAssertLessThan(Arrangement.stepLabelCap, Arrangement.labelCap)
        XCTAssertThrowsError(try plan("lanes", [
            "actors": ["a"],
            "steps": [["actor": "a", "text": String(repeating: "x", count: 27)]],
        ]))
    }

    // MARK: - No bare text

    /// **Every label is a container.** A bare `text` element does not wrap and
    /// has nothing to clamp it — a 67-character label measured 665px wide on
    /// one line, which inside a layout claiming to be collision-free by
    /// construction would run straight across the columns beside it. The
    /// sizing table is a table about containers; an element with no container
    /// is outside it.
    func test_noLayoutEmitsABareTextElement() throws {
        let cases: [(String, [String: Any])] = [
            ("small_multiples", [
                "nodes": ["a", "b"], "frames": [["title": "one"], ["title": "two"]],
            ]),
            ("lanes", [
                "actors": ["Agent"], "steps": [["actor": "Agent", "text": "go"]],
            ]),
            ("before_after", [
                "before": ["title": "Today", "nodes": ["a"]],
                "after": ["title": "Proposed", "nodes": ["b"]],
            ]),
        ]
        for (layout, content) in cases {
            let skeletons = try plan(layout, content)
            XCTAssertFalse(skeletons.contains { $0.type == "text" }, layout)
            for skeleton in skeletons where skeleton.type == "rectangle" {
                XCTAssertEqual(skeleton.width, Arrangement.columnWidth, layout)
            }
        }
    }

    // MARK: - Refusals

    func test_anUnknownLayoutNamesTheOnesThatExistAndThePrimitives() {
        XCTAssertThrowsError(try plan("sequence", ["nodes": ["a"]])) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("small_multiples"), text)
            XCTAssertTrue(text.contains("lanes"), text)
            XCTAssertTrue(text.contains("before_after"), text)
            // The escape hatch is named, because an agent refused here needs
            // somewhere to go that is not a second attempt at this tool.
            XCTAssertTrue(text.contains("whiteboard_add"), text)
        }
    }

    func test_anUnknownHighlightNamesTheNodesThatExist() {
        XCTAssertThrowsError(try plan("small_multiples", [
            "nodes": ["Client", "Gateway"],
            "frames": [["title": "one", "highlight": "Datbase"]],
        ])) { error in
            XCTAssertEqual(
                error as? Arrangement.Failure,
                .unknownNode("Datbase", known: ["Client", "Gateway"])
            )
        }
    }

    func test_anUnknownActorNamesTheActorsThatExist() {
        XCTAssertThrowsError(try plan("lanes", [
            "actors": ["Agent", "Swift"],
            "steps": [["actor": "Page", "text": "expand"]],
        ])) { error in
            XCTAssertEqual(
                error as? Arrangement.Failure,
                .unknownActor("Page", known: ["Agent", "Swift"])
            )
        }
    }

    /// Refused rather than ignored: an agent whose edge labels silently
    /// vanished has learned nothing, and two of four evaluation runs collided
    /// on exactly this.
    func test_anEdgeLabelIsRefusedRatherThanDropped() {
        XCTAssertThrowsError(try plan("lanes", [
            "actors": ["Agent"],
            "steps": [["actor": "Agent", "text": "go", "label": "then"]],
        ])) { error in
            XCTAssertEqual(error as? Arrangement.Failure, .edgeLabelsRefused)
        }
    }

    func test_tooManyStepsIsRefusedNamingWhatFitsAndTheActorCount() {
        XCTAssertThrowsError(try plan("lanes", [
            "actors": (1 ... 6).map { "actor \($0)" },
            "steps": (1 ... 60).map { ["actor": "actor 1", "text": "step \($0)"] },
        ])) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("6 actors"), text)
            XCTAssertTrue(text.contains("fewer"), text)
        }
    }

    func test_malformedContentIsRefusedRatherThanDrawnEmpty() {
        XCTAssertThrowsError(try Arrangement.plan(
            layout: "lanes", content: "not json", live: empty, mint: minter()
        ))
        XCTAssertThrowsError(try plan("lanes", ["actors": ["a"]])) { error in
            XCTAssertEqual(error as? Arrangement.Failure, .missingField("steps"))
        }
        XCTAssertThrowsError(try plan("lanes", ["actors": [], "steps": []])) { error in
            XCTAssertEqual(error as? Arrangement.Failure, .emptyField("actors"))
        }
    }

    // MARK: - What it hands the page

    /// It emits the same skeletons the `add` arm does, so the page needs no new
    /// arm and every invariant it maintains for that op holds here for free.
    func test_everyElementCarriesTheAgentAuthorMarker() throws {
        let skeletons = try plan("before_after", [
            "before": ["nodes": ["a"]], "after": ["nodes": ["b"]],
        ])
        XCTAssertFalse(skeletons.isEmpty)
        for skeleton in skeletons {
            let customData = skeleton.json["customData"] as? [String: Any]
            XCTAssertEqual(
                customData?[Whiteboard.Element.authorKey] as? String,
                Whiteboard.Element.agentAuthorValue
            )
        }
    }

    /// One accent per arrangement, named at the top level — not per side, and
    /// not per frame. Two emphasis colours in one arrangement would say the two
    /// highlights mean different things, which is a distinction this vocabulary
    /// does not carry.
    func test_aHighlightedNodeCarriesAStrokeAndFillPair() throws {
        let skeletons = try plan("before_after", [
            "color": "red",
            "before": ["nodes": ["a"]],
            "after": ["nodes": ["b"], "highlight": ["b"]],
        ])
        let highlighted = try XCTUnwrap(skeletons.first { $0.label == "b" })
        XCTAssertEqual(highlighted.strokeColor, "#e03131")
        XCTAssertEqual(highlighted.backgroundColor, "#ffc9c9")
    }

    func test_arrowsAreNeverLabelled() throws {
        let skeletons = try plan("small_multiples", [
            "nodes": ["a", "b", "c"], "frames": [["title": "one"]],
        ])
        let arrows = skeletons.filter { $0.type == "arrow" }
        XCTAssertEqual(arrows.count, 2)
        for arrow in arrows {
            XCTAssertNil(arrow.label)
        }
    }
}
