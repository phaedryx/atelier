// ABOUTME: The layout half of the agent write path — three closed layouts, placed deterministically.
// ABOUTME: Pure and Foundation-only; it emits the same skeletons `Whiteboard.Write` does.

import Foundation

extension Whiteboard {
    /// `whiteboard_add_layout`'s Swift half.
    ///
    /// **The board's write API is a drawing API; this is a layout API.** `box`,
    /// `note`, `text`, `arrow` and `mermaid` make an agent do coordinate
    /// arithmetic in its head, and in a four-run evaluation every run sprawled
    /// to 2000–2900px and two produced colliding arrow labels. This moves
    /// placement out of the caller's head and into code that cannot get it
    /// wrong.
    ///
    /// **The vocabulary is closed, not open**, and it is closed on purpose:
    /// three layouts, each one of the spatial moves a canvas actually supports.
    /// The primitives stay as the escape hatch for everything else — this does
    /// not try to be general enough to replace them, and an attempt to make it
    /// so should be refused rather than accommodated.
    ///
    /// **One tool with a discriminator, not three tools.** Every entry in
    /// `IPC.Tool.advertisedOrder` costs schema tokens in every session of this
    /// project, for every agent, whether or not it ever draws. One discriminated
    /// tool is affordable; three are not.
    ///
    /// **Why this is not called `Layout`.** `Whiteboard.Write.Layout` already
    /// owns that spelling, for where the next *unpositioned* element goes. The
    /// agent-facing word is still "layout" — that is the tool's argument — but
    /// two Swift types called `Layout` in one namespace, meaning different
    /// things, is how a reader ends up applying the column-origin rules to a
    /// swimlane. The drift between the tool's word and the type's word is the
    /// cheaper of the two costs.
    ///
    /// **It emits `Write.Skeleton` and nothing else**, so the page needs no new
    /// arm at all: the result travels through the same `{"kind": "add"}` op
    /// `whiteboard_add` already uses, and every invariant the page maintains for
    /// that op — binding, `edgePoints`, the `customData` spread — holds here for
    /// free. A second expansion path would be a second set of those invariants,
    /// and the whiteboard doc is largely a record of what happens when there are
    /// two.
    enum Arrangement {
        // MARK: - The measured sizing table

        /// Every constant below was measured against the real bundle by drawing
        /// through `whiteboard_add` and reading `board.excalidraw` back — not
        /// derived, and not copied from Excalidraw's source.
        ///
        /// **THE REAL CONSTRAINT IS A WIDTH BUDGET. THE CHARACTER CAP IS A
        /// PROXY, AND THE PITCH IS SET FROM THE WIDEST SCRIPT, NOT FROM THE
        /// CAP.** That sentence is here because the obvious tidy-up is to test
        /// a few English labels, observe that they all come back 90 tall, and
        /// drop `maxLabelHeight` to match. They do come back 90 tall. CJK and
        /// emoji do not — see `labelCap`.
        ///
        /// **EVERY CONSTANT HERE IS MEASURED AT A FIXED 220 CONTAINER.** A
        /// layout that varies the container width, or that emits an element
        /// with *no* container, is outside this table and needs its own
        /// measurements. Both of those were live defects in this file's first
        /// design; see `labelCap` and `noBareText`.
        enum Measured {
            /// Excalidraw's line height for the board's font, exactly, at every
            /// label length measured: 1 line 25, 2 lines 50, 8 lines 200.
            static let lineHeight = 25.0
            /// A container is its text plus this. 200→210, 125→135, 100→110.
            static let containerPadding = 10.0
            /// Usable text width inside a 220 container, from the measured
            /// label widths (a full line came back ~198–208).
            static let usableTextWidth = 198.0
        }

        // MARK: - Geometry

        /// Every container this file emits is exactly this wide, everywhere.
        ///
        /// **A supplied width is a hard ceiling** — measured, and nothing
        /// exceeded it: not a 131-character label, not an unbroken 60-character
        /// token (Excalidraw breaks mid-word rather than overflowing), not CJK,
        /// not emoji. So the horizontal half of every layout here is exact.
        ///
        /// **Fixed, rather than shrunk to fit more columns.** An earlier design
        /// narrowed the column when a lane had many steps. That silently moved
        /// every label outside `Measured`, which is a table taken at 220: at a
        /// 140-wide column the same 30-character CJK label wraps to six lines,
        /// not four, and `maxLabelHeight` stops bounding anything. One width,
        /// one table, one pitch, no second sizing story.
        static let columnWidth = 220.0

        /// What is supplied as a container's height. It grows to fit its label
        /// — height is `max(supplied, needed)`, measured — which is why the
        /// *pitch* rather than this is what keeps rows apart.
        static let containerHeight = 90.0

        /// The tallest a capped label can make a container, measured across
        /// every script tried.
        ///
        /// 30 characters of Latin — even all-`W`, the widest glyph — wraps to
        /// three lines and fits the supplied 90. **32 CJK characters and 30
        /// emoji both wrap to four lines and come back 110.** That is the whole
        /// reason this constant is not 90, and it is measured rather than
        /// reasoned: Latin-only testing yields "30 characters never grows the
        /// box", which is true in every test that testing would have written
        /// and false in production, and invisible in the digest because the
        /// coordinates all read correctly.
        static let maxLabelHeight = 110.0

        /// Clearance between two containers, in both axes.
        static let gap = 30.0

        /// Separation between one small-multiples frame and the next, and
        /// between one lane band and the next. Deliberately larger than `gap`:
        /// with no drawn border around a frame, the gutter is the only thing
        /// that makes a frame read as a unit rather than as more of the grid.
        static let groupGap = 60.0

        /// Separation between one lane band and the next.
        ///
        /// **Distinctly larger than `groupGap`, and that is a readability fix
        /// rather than a taste.** At `groupGap` the bands sat 80px apart while
        /// the rows inside a band sat 50px apart — barely a difference, so the
        /// eye read one continuous eight-row grid rather than two four-actor
        /// bands, and the repeated lane labels looked like duplicates instead
        /// of a new band's heading. Every geometry test passed: nothing
        /// overlapped, the budget held. It was only visible in `board.png`,
        /// which is why the render is worth looking at and not only measuring.
        static let bandGap = groupGap * 2

        /// Column-to-column stride. Width plus clearance.
        static let columnStride = columnWidth + gap
        /// Row-to-row stride. The *worst-case* label height plus clearance —
        /// not `containerHeight`, which a four-line label overruns.
        static let rowStride = maxLabelHeight + gap

        /// The budget, in **both** axes.
        ///
        /// `MAX_RENDER_EDGE` (`editor/src/whiteboard.jsx:29`) is
        /// `maxWidthOrHeight` on `exportToBlob` for the **whole board**, so a
        /// board larger than this on either edge is downscaled in `board.png` —
        /// the picture half of the read path, and the only way an agent sees
        /// freehand or a screenshot.
        ///
        /// **The claim this supports is narrow, and it is narrow on purpose:
        /// "the arrangement this places is never larger than 1600 on either
        /// edge", NOT "the board stays legible".** A layout is placed *below*
        /// whatever is already on the board, so it adds to the board's height;
        /// a 1500-wide arrangement on a board already 1400 tall is downscaled
        /// anyway. Nothing here can promise otherwise, and writing the wider
        /// claim down would be exactly the sort of asserted-and-unpinned
        /// sentence that this series of changes exists to remove.
        static let maxEdge = 1600.0

        /// The label length past which a container is no longer bounded by
        /// `maxLabelHeight`.
        ///
        /// **Counted in characters, which is a proxy for the thing that
        /// actually matters — rendered width — and a lossy one.** Measured
        /// density at `Measured.usableTextWidth`: Latin worst case (all-`W`)
        /// ~10 characters per line, CJK ~8.3, emoji ~7.6, Cyrillic ~15,
        /// ordinary Latin ~20. The cap is set so the *widest* of those still
        /// lands inside `maxLabelHeight`, which is why 30 rather than the 60
        /// that ordinary English would allow.
        ///
        /// A node label is a node label, not a paragraph. Anything longer is an
        /// annotation and belongs in a `note` through the primitives, or beside
        /// the diagram through `anchor`.
        static let labelCap = 30

        /// **No layout emits a bare `text` element**, and this is a measured
        /// constraint rather than a stylistic one.
        ///
        /// A bare text element does not wrap and has no container to clamp it:
        /// a 67-character label came back **665px wide on a single line**. The
        /// first design used `text` for lane labels and frame titles, so a long
        /// actor name would have run straight across the columns beside it — a
        /// collision inside a layout whose entire claim is that it is
        /// collision-free by construction, and one that `Measured` said nothing
        /// about because `Measured` is a table about *containers*.
        ///
        /// So every label here is a container. This constant exists to be cited
        /// by the test that pins it.
        static let noBareText = true

        // MARK: - Colour

        /// Emphasis, as a stroke-and-fill pair.
        ///
        /// The pairs are Excalidraw's own, and are the same ones mermaid's
        /// `classDef` produces through the converter — measured, not guessed:
        /// a `fill:#ffc9c9,stroke:#e03131` definition lands as exactly this
        /// red. So a hand-composed arrangement and a mermaid diagram on the
        /// same board emphasise a node the same way.
        static let emphasis: [String: (stroke: String, fill: String)] = [
            "#e03131": ("#e03131", "#ffc9c9"),
            "#f08c00": ("#f08c00", "#ffec99"),
            "#f1c40f": ("#f1c40f", "#ffec99"),
            "#2f9e44": ("#2f9e44", "#b2f2bb"),
            "#1971c2": ("#1971c2", "#a5d8ff"),
            "#9c36b5": ("#9c36b5", "#d0bfff"),
        ]

        /// What a highlight is when the caller does not say.
        ///
        /// Violet rather than red, and the reason is semantic rather than
        /// aesthetic: these layouts mark *what changed*, and in a before/after
        /// pair a red "after" reads as a failure rather than as a difference.
        /// Violet carries the same contrast with no verdict attached.
        static let defaultEmphasis = "#9c36b5"

        // MARK: - Vocabulary

        /// The discriminator. Closed, and closed deliberately — see the type's
        /// own note.
        ///
        /// `anchor` is the fourth value and is not in this enum yet: it needs
        /// per-element rects in `Whiteboard.Write.Live` to offset a note from
        /// its target, which arrives with the auto-sizing change. It is a
        /// value of this discriminator rather than a second tool for the same
        /// reason the three layouts share one.
        enum Kind: String, CaseIterable {
            case smallMultiples = "small_multiples"
            case lanes
            case beforeAfter = "before_after"
        }

        // MARK: - Failures

        /// Why an arrangement was refused.
        ///
        /// Agent-facing protocol text, so deliberately not localized — the rule
        /// `IPC.Error` states. Each one names the offending value **and what
        /// would fit instead**, because an agent cannot see the board and a
        /// refusal that does not name the way out is one it retries verbatim.
        enum Failure: LocalizedError, Equatable {
            case unknownLayout(String)
            case malformedContent(String)
            case missingField(String)
            case emptyField(String)
            case labelTooLong(String, limit: Int)
            case unknownNode(String, known: [String])
            case unknownActor(String, known: [String])
            case tooManyFrames(frames: Int, fit: Int, nodes: Int)
            case tooManySteps(steps: Int, fit: Int, actors: Int)
            case columnTooTall(nodes: Int, fit: Int)
            case edgeLabelsRefused

            var errorDescription: String? {
                switch self {
                case let .unknownLayout(raw):
                    "\"\(raw)\" is not a layout. Use one of: "
                        + Kind.allCases.map(\.rawValue).joined(separator: ", ")
                        + ". For anything these do not fit, use whiteboard_add's "
                        + "box, note, text and arrow directly."
                case let .malformedContent(detail):
                    "`content` is not the shape \(detail)."
                case let .missingField(field):
                    "`content` is missing `\(field)`."
                case let .emptyField(field):
                    "`\(field)` is empty. Name at least one."
                case let .labelTooLong(label, limit):
                    // Names the cap AND the alternative: a refusal that only
                    // says "too long" sends an agent to trim by one character
                    // at a time.
                    "\"\(label)\" is longer than \(limit) characters, which is the most a "
                        + "label can carry without growing its box past the row it sits in. "
                        + "Shorten it to a node label, and put the explanation in a note "
                        + "beside the diagram."
                case let .unknownNode(name, known):
                    "\"\(name)\" is not one of this arrangement's nodes. It must be one of: "
                        + known.joined(separator: ", ") + "."
                case let .unknownActor(name, known):
                    "\"\(name)\" is not one of this arrangement's actors. It must be one of: "
                        + known.joined(separator: ", ") + "."
                case let .tooManyFrames(frames, fit, nodes):
                    // Names BOTH dimensions, because frames wrap: what runs out
                    // is height, and the caller trades node count against frame
                    // count to get it back. A refusal naming only the frame
                    // count sends an agent to drop frames when dropping a node
                    // from each would have done.
                    "\(frames) frames of \(nodes) nodes is more than the board can show "
                        + "legibly; \(fit) frames is the most at \(nodes) nodes. Use fewer "
                        + "frames, or fewer nodes, or split it across two arrangements."
                case let .tooManySteps(steps, fit, actors):
                    // Names the actor count, because that is what the caller
                    // can actually trade against the step count.
                    "\(steps) steps across \(actors) actors is taller than the board can show "
                        + "legibly; \(fit) steps is the most at \(actors) actors. Use fewer "
                        + "steps, or fewer actors, or split it across two arrangements."
                case let .columnTooTall(nodes, fit):
                    "\(nodes) nodes is taller than the board can show legibly; \(fit) is the "
                        + "most in one column. Use fewer nodes, or split it across two "
                        + "arrangements."
                case .edgeLabelsRefused:
                    // The one refusal here that is about the *form* rather than
                    // about size. See `Lanes`.
                    "An arrangement does not label its arrows. Two of four evaluation runs "
                        + "produced overlapping arrow labels, so the field is refused rather "
                        + "than placed cleverly. Put the words in the box the arrow points "
                        + "at, or draw the arrow yourself with whiteboard_add."
                }
            }
        }

        // MARK: - Shared pieces

        /// One container, at an exact position.
        ///
        /// The single place a skeleton is built in this file, so that "every
        /// label is a container" and "every container is `columnWidth` wide"
        /// are properties of one function rather than of six call sites.
        static func container(
            _ text: String,
            at point: (x: Double, y: Double),
            isNote: Bool,
            emphasise: String? = nil,
            mint: () -> String
        ) -> Write.Skeleton {
            let pair = emphasise.flatMap { emphasis[$0] }
            return Write.Skeleton(
                id: mint(),
                type: "rectangle",
                x: point.x,
                y: point.y,
                width: columnWidth,
                height: containerHeight,
                label: text,
                strokeColor: pair?.stroke,
                backgroundColor: pair?.fill ?? (isNote ? Write.noteBackground : nil),
                from: nil,
                to: nil,
                isNote: isNote
            )
        }

        /// An arrow between two containers this arrangement just made.
        ///
        /// **Never labelled** — see `Failure.edgeLabelsRefused`. The page
        /// computes the geometry from the bindings (`edgePoints`), so the
        /// coordinates here are a placeholder it overwrites, exactly as on the
        /// `add` arm.
        static func connector(
            from: String,
            to: String,
            mint: () -> String
        ) -> Write.Skeleton {
            Write.Skeleton(
                id: mint(),
                type: "arrow",
                x: 0,
                y: 0,
                width: nil,
                height: nil,
                label: nil,
                strokeColor: nil,
                backgroundColor: nil,
                from: from,
                to: to,
                isNote: false
            )
        }

        /// Refuses a label that would overrun its row. See `labelCap`.
        static func checked(_ label: String) throws -> String {
            // Counted in Characters — grapheme clusters — because that is what
            // renders. A family emoji is many scalars and one glyph, and
            // counting scalars would refuse a label that draws perfectly well.
            guard label.count <= labelCap else {
                throw Failure.labelTooLong(label, limit: labelCap)
            }
            return label
        }

        /// How many columns of `columnWidth` fit the width budget.
        ///
        /// `n` columns span `n * columnWidth + (n - 1) * spacing`, so the
        /// budget admits `(maxEdge + spacing) / (columnWidth + spacing)`.
        ///
        /// **The spacing is a parameter rather than `gap`**, because the two
        /// callers space their columns differently: `lanes` puts `gap` between
        /// steps, `small_multiples` puts `groupGap` between frames. Written with
        /// `gap` hard-coded it still answered 5 and 6 correctly — by
        /// coincidence, since the two spacings happen to land either side of the
        /// same integer — and would have started lying the moment either
        /// constant moved.
        static func columnsThatFit(spacing: Double = gap) -> Int {
            max(1, Int((maxEdge + spacing) / (columnWidth + spacing)))
        }
    }
}
