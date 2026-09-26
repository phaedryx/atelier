// ABOUTME: Renders a parsed board as the text digest an agent reads.
// ABOUTME: Pure, budgeted, and it says so when it truncates.

import Foundation

extension Whiteboard {
    /// The board as text.
    ///
    /// **Not a caption for `board.png`.** An LLM reads text precisely and pixels
    /// only impressionistically, so the two halves of the read path answer
    /// different questions: the digest is the part of the board that can be
    /// reasoned about exactly — "move `n7`" — and the picture is the part that
    /// cannot. Strokes and images therefore appear here as **opaque entries with
    /// a bounding box**: the agent learns that they exist and where, and nothing
    /// in this file pretends to know what they say.
    ///
    /// Everything is a pure function of a `SceneLoad` and a `Render`, following
    /// `IPC.VerificationSummary` — the wording, the state mapping and the
    /// truncation are where this feature's bugs live, and none of them need a
    /// webview, a workstream or a board on disk to pin.
    enum Digest {
        /// Cap on the assembled digest.
        ///
        /// Not the 64KB `IPC.Store` limit, which a digest never crosses: it
        /// travels as a tool answer rather than as a message, and the cap that
        /// really binds a tool answer is `IPC.Server.maxFrameBytes`, at 1MB.
        ///
        /// **It was 8,000, and that number rested on a claim that is false at
        /// the size where it matters.** The argument was that the agent is asked
        /// to open `board.png` in the same breath, so the picture carries
        /// whatever the text does not, and 8KB was already two thousand tokens
        /// spent before it had looked. But the render is capped at
        /// `MAX_RENDER_EDGE` — 1600, `editor/src/whiteboard.jsx` — which is
        /// below the size a board reaches by the time the digest starts
        /// cutting, so the picture is downscaled and its label text stops being
        /// legible (boards are *reported* at 2000–2900px on the long edge; that
        /// range is second-hand and the structural point does not rest on
        /// it). Both halves of the read
        /// path therefore degraded **together**, and they did it exactly as a
        /// board got large enough to be worth checking: measured, a board of 83
        /// elements reported 21 of them not listed.
        ///
        /// **The replacement is measured.** Assembled digests of a board shaped
        /// like the ones this feature produces — labelled diagram nodes,
        /// labelled edges, a note every few elements, a captioned screenshot:
        ///
        ///     12 elements → 1,229 B      120 elements → 10,722 B
        ///     30 elements → 2,813 B      200 elements → 17,856 B
        ///     83 elements → 7,371 B      250 elements → 22,314 B
        ///                                300 elements → 26,774 B
        ///
        /// A flat ~89 bytes an entry past the first few. (The board in the
        /// report above ran heavier — 62 entries inside 8,000 less its reserve,
        /// so ~123 bytes each — so treat ~89 as the shape of a clean board and
        /// ~123 as a busy one.) At those rates 32,000 lists about 355 of the
        /// first and about 260 of the second: past any board this feature has
        /// produced, a mermaid flowchart's expansion included.
        ///
        /// **The number is settled by the ceiling property, and that is
        /// measured too.** At this default a 30-element board answers with
        /// 2,813 bytes and a 12-element one with 1,229. Nothing pads, and every
        /// board that fits under the old 8,000 — which is every board of about
        /// 80 elements or fewer — returns **byte-identical** output. So the
        /// usual objection to a 4x raise does not apply: `read_whiteboard` is
        /// on a hot path (draw, read back for the extent, read again to verify)
        /// and none of those calls pay anything for it. The whole of the cost
        /// falls on the boards that were previously being lied to.
        ///
        /// **Which is why the middle option was rejected.** 16,000 was tried,
        /// on the reasoning that a well-formed board is 60–120 elements — the
        /// skill that draws these caps concepts at 3–5 and diagram nodes at
        /// 5–8 — so ~180 entries covers the realistic case and anything past it
        /// is cut honestly rather than silently. Both halves of that are true
        /// and it is still the wrong trade. The ceiling measurement had already
        /// answered the cost question, so lowering bought nothing on the calls
        /// anyone was worried about; what it cost was completeness on boards of
        /// 180–355 elements, and an honest cut is still a loss of exactly the
        /// thing this file exists to provide — a record a caller can verify its
        /// own board against, exactly. `admitted` makes being cut survivable,
        /// not free, and it is not a reason to arrange to be cut more often.
        /// Against that, eight thousand tokens on an explicit read of a
        /// 350-element board is one large file read, and half what
        /// `IPC.ExecutionLogs.defaultBudgetBytes` already allows a single log
        /// tail — a precedent in this same system rather than a number from
        /// taste. `text(budget:)` takes the cap as a parameter for a caller
        /// that needs a different one.
        ///
        /// Raising it does not make truncation rare enough to stop thinking
        /// about — `admitted` is what decides which elements a board past this
        /// size loses, and it is the load-bearing half of this pair.
        static let maxBytes = 32_000

        /// What `board.png` currently is.
        ///
        /// `.stale` is a real answer rather than an absence. A render that no
        /// longer matches the scene must never be read as fresh — and deleting
        /// it instead would throw away a picture that is usually still mostly
        /// right, which is worse than describing it accurately.
        enum Render: Equatable {
            case none
            case current(width: Int, height: Int, path: String)
            case stale(path: String)
        }

        /// - Parameter assets: fileID → the absolute path of that image in
        ///   `assets/`. Passed in rather than listed here so this stays pure,
        ///   the same way `render` is. An id missing from it is reported as
        ///   having no file rather than rendered as a path that would not open.
        ///
        /// **Not paginated, and that is a decision rather than an omission.**
        /// The obvious answer to a digest that cuts is to let the caller ask for
        /// the rest, and it is a real answer — but it is a change to the *tool*,
        /// not to this file: `read_whiteboard` takes no arguments at all
        /// (`IPC.ToolRegistry`), so an offset would mean a new argument, a
        /// cursor whose meaning survives a board being edited between two calls,
        /// and a second round trip an agent has to know to make. Against that,
        /// a budget that covers every board this feature has produced and a cut
        /// that drops the entries `board.png` genuinely answers for costs one
        /// call and no vocabulary. `budget` is already a parameter here, so an
        /// `offset:` beside it later is additive and not a redesign — which is
        /// the point of recording this rather than leaving the door unmarked.
        static func text(
            load: SceneLoad,
            render: Render,
            updated: String,
            assets: [String: String] = [:],
            budget: Int = maxBytes
        ) -> String {
            switch load {
            case .empty:
                // Deliberately says nothing about a render. A board with nothing
                // on it has no picture worth pointing at, and a `board.png` left
                // over from before the user cleared it would be a distraction at
                // best.
                """
                # Whiteboard — empty
                Nothing has been drawn on this board yet. That is the ordinary first \
                state for a workstream, not a fault: open the Whiteboard tab and draw \
                on it, or ask the user to.
                """
            case let .unreadable(reason):
                """
                # Whiteboard — could not be read
                This workstream's board.excalidraw could not be read: \(reason). The \
                board itself is still on disk and the Whiteboard tab will still open \
                it; it is this text view of it that is unavailable.
                """
            case let .loaded(scene):
                loadedText(scene, render: render, updated: updated, assets: assets, budget: budget)
            }
        }

        private static func loadedText(
            _ scene: Scene,
            render: Render,
            updated: String,
            assets: [String: String],
            budget: Int
        ) -> String {
            let header = headerLine(scene.elements, updated: updated)
            let renderLine = line(for: render)
            // Bound once and used for both the reserve and the append, so the
            // sentence that is charged to the budget is the sentence that is
            // written. Two reads of a state-dependent value are two numbers
            // that can disagree.
            let closing = closingLine(for: render)

            // Reserved before anything is assembled, the way
            // `VerificationSummary.fitVerdicts` reserves its overflow note.
            // These are what a reader needs *most* when the list has been cut,
            // so they cannot be what the cut takes — and the overflow note's own
            // length depends on what was left out, so the worst case is charged
            // up front rather than discovered after assembling. The worst case
            // is *every* element omitted, and that really is an upper bound:
            // `breakdown` buckets on a closed set, so a subset of the board can
            // name no more buckets and no larger counts than the whole of it.
            var reserved = header.utf8.count + 1
            reserved += renderLine.utf8.count + 1
            reserved += 1 // the blank line under the header
            reserved += 1 + closing.utf8.count + 1
            reserved += overflowNote(for: scene.elements).utf8.count + 1

            // Rendered once. An entry's cost is its own length, and the
            // admission below needs the cost of an element it may not reach in
            // board order, so the two cannot be interleaved the way they were.
            let rendered = scene.elements.map { entry(for: $0, assets: assets) }
            let kept = admitted(
                scene.elements,
                costs: rendered.map { $0.utf8.count + 1 },
                available: budget - reserved
            )

            var out = [header, renderLine, ""]
            // Listed in the **board's** order, not the order the cut admitted
            // them in. Which elements survive is a judgement about what is worth
            // keeping; where they appear is the board's business, and a reader
            // comparing the digest against the picture is reading positions.
            out.append(contentsOf: scene.elements.indices.filter(kept.contains).map { rendered[$0] })
            // Taken from the kept set at the end rather than tallied inside the
            // admission loop. An element can be admitted as part of another
            // element's bundle, so a per-iteration counter has two places to be
            // wrong about the number and this has none.
            let omitted = scene.elements.indices
                .filter { !kept.contains($0) }
                .map { scene.elements[$0] }
            if !omitted.isEmpty {
                out.append(overflowNote(for: omitted))
            }
            out.append("")
            out.append(closing)
            return out.joined(separator: "\n")
        }

        /// The header, which carries the two facts a caller needs **whether or
        /// not** the list below it is complete: how many elements are really on
        /// this board, and how far it extends.
        ///
        /// The count was always here. The extent is new, and it is here
        /// unconditionally rather than only when something is cut: a caller
        /// reading a complete digest still has to place what it draws next, and
        /// a line that appears only on large boards is one an agent learns to
        /// read only on large boards. It is also the one thing a truncated
        /// digest can still say exactly about the part it left out — the
        /// omitted elements are somewhere inside it.
        private static func headerLine(_ elements: [Element], updated: String) -> String {
            "# Whiteboard — \(elements.count) elements, \(extentText(elements)), updated \(updated)"
        }

        /// The bounding box of every element on the board, cut elements
        /// included, because this is computed before anything is cut.
        ///
        /// Computed here from the scene rather than taken from
        /// `Host.liveState`, which also carries an extent: this function is pure
        /// and `board.md` is regenerated with no page in existence. The two
        /// answer the same question about the same elements.
        private static func extentText(_ elements: [Element]) -> String {
            guard let first = elements.first else { return "no extent" }
            var minX = first.x
            var minY = first.y
            var maxX = first.x + first.width
            var maxY = first.y + first.height
            for element in elements.dropFirst() {
                minX = min(minX, element.x)
                minY = min(minY, element.y)
                maxX = max(maxX, element.x + element.width)
                maxY = max(maxY, element.y + element.height)
            }
            return "extent \(rounded(minX)),\(rounded(minY)) → \(rounded(maxX)),\(rounded(maxY))"
        }

        private static func line(for render: Render) -> String {
            switch render {
            case let .current(width, height, path):
                "# board.png (\(width)×\(height)) at \(path) — read it to see freehand and images"
            case let .stale(path):
                "# WARNING: board.png at \(path) is a render of an EARLIER version of this "
                    + "board. The digest below is current; the picture is not. It catches up "
                    + "the next time the board is saved."
            case .none:
                "# No board.png has been rendered yet, so there is no picture to read — "
                    + "freehand strokes and images are listed below by position only."
            }
        }

        /// The sentence that stops an agent reading five boxes and concluding
        /// that is the whole board.
        ///
        /// **Required, not decoration**, and charged to the budget *before* a
        /// single element is assembled. A digest that truncates and drops this
        /// is the precise failure the budget exists to report: the reader is
        /// told less than everything and not told that it was.
        ///
        /// It is a function of the `Render` rather than a constant, and it
        /// lives here so that it is written in the same place as `line(for:)`
        /// and cannot drift from it. A constant said "they are in board.png —
        /// open it" over a header saying no picture had been rendered: the
        /// digest contradicting itself two lines apart, which is the one thing
        /// this format is organised around not doing. `.stale` had the milder
        /// version of the same fault — the picture is there, but it is of an
        /// earlier board, and the closing line said nothing about that.
        static func closingLine(for render: Render) -> String {
            switch render {
            case .current:
                "Strokes and images are not transcribed. They are in board.png — open it."
            case .stale:
                "Strokes and images are not transcribed. They are in board.png — open it, "
                    + "remembering that it is a render of an earlier version of this board."
            case .none:
                "Strokes and images are not transcribed, and no board.png has been rendered "
                    + "yet — they appear above by position and size only."
            }
        }

        /// Which elements make it into a digest that cannot hold all of them.
        ///
        /// **Truncation is a choice about value, not a leftover of position.**
        /// It used to be the assembly loop's remainder — walk the scene in file
        /// order and keep whatever fits — which means what survives a cut is
        /// decided by the order Excalidraw happened to write the file in. Two
        /// things come out of that, and the second is the serious one:
        ///
        /// - **The cheapest entries to lose are the ones this file already
        ///   declines to describe.** A stroke renders as a point count and a
        ///   bounding box, and the closing line says in so many words that it is
        ///   only in `board.png`. Dropping those first is the one drop where the
        ///   fallback the overflow note offers is actually true — and in file
        ///   order a stroke is exactly as likely to be kept as a labelled box.
        /// - **A dropped element can be named by a kept one.** An arrow's entry
        ///   is `n1 → n2`; drop `n2` and the digest prints an id that appears
        ///   nowhere else in it. That is the same failure as an arrow left bound
        ///   to something `whiteboard_delete` removed — the digest lying, which
        ///   is the one thing this feature is organised around not doing — and
        ///   positional truncation produces it on any board big enough to cut.
        ///
        /// So elements are admitted in `Tier` order, and an arrow is admitted
        /// **together with the endpoints it names or not at all**. Bundling
        /// rather than repairing afterwards: a repair pass that goes looking for
        /// a missing endpoint can find no room left for it, and then has to
        /// choose between un-listing an arrow already charged to the budget and
        /// printing the dangling id anyway. Admitting the unit settles that
        /// before anything is spent. An endpoint naming an element that is not
        /// on this board at all is not something a cut can fix and is left
        /// alone; `whiteboard_delete` is what keeps that from arising.
        ///
        /// `continue` and not `break`, as before: the count has to be the number
        /// actually left out, and a later element may still be small enough to
        /// fit where this one was not.
        private static func admitted(
            _ elements: [Element],
            costs: [Int],
            available: Int
        ) -> Set<Int> {
            var indexByID: [String: Int] = [:]
            for (index, element) in elements.enumerated() where indexByID[element.id] == nil {
                indexByID[element.id] = index
            }
            // The element's own position breaks a tie, because `sorted` is not
            // guaranteed stable and the board's order has to survive inside a
            // tier — an agent that drew ten boxes and got nine expects the nine
            // it drew first.
            let order = elements.indices.sorted {
                let left = tier(of: elements[$0])
                let right = tier(of: elements[$1])
                return left == right ? $0 < $1 : left.rawValue < right.rawValue
            }

            var kept: Set<Int> = []
            var spent = 0
            for index in order where !kept.contains(index) {
                var bundle = [index]
                // Transitive, because an arrow may bind to another arrow —
                // Excalidraw allows it. Pulling `x2` in for `x1` and stopping
                // there charges nothing for `x2`'s own endpoints, and `x2`
                // lands in the digest printing the dangling id the bundle
                // exists to prevent, one hop further out. Membership in
                // `bundle` is the cycle guard, and an endpoint already in
                // `kept` needs no check: it could only have been admitted by a
                // bundle that closed over *its* endpoints.
                var frontier = 0
                while frontier < bundle.count {
                    let element = elements[bundle[frontier]]
                    frontier += 1
                    for endpoint in [element.from, element.to] {
                        guard let endpoint,
                              let target = indexByID[endpoint],
                              !kept.contains(target),
                              !bundle.contains(target)
                        else { continue }
                        bundle.append(target)
                    }
                }
                let cost = bundle.reduce(0) { $0 + costs[$1] }
                guard spent + cost <= available else { continue }
                kept.formUnion(bundle)
                spent += cost
            }
            return kept
        }

        /// What an element is worth when not all of them fit.
        ///
        /// Ordered by what is lost with it, and the order is an argument about
        /// **which half of the read path can answer for the element**:
        ///
        /// - `.words` — anything carrying a label or a caption. Text is the part
        ///   of a board that can be reasoned about exactly, which is this file's
        ///   entire reason to exist, and on a board large enough to truncate it
        ///   is also the part `board.png` renders too small to read.
        /// - `.structure` — an unlabelled arrow. The relations *are* the
        ///   diagram; a graph reported without its edges is a different graph.
        /// - `.shape` — a bare box, and **an uncaptioned image**. It is
        ///   tempting to put an uncaptioned image at the bottom with the
        ///   strokes, since neither carries anything this file may transcribe.
        ///   That would close the image-transcription arm on exactly the boards
        ///   it exists for: an agent captions a screenshot by reading its **id**
        ///   here, opening the picture, and calling `whiteboard_update`, so an
        ///   image the digest leaves out is one that can never be captioned.
        ///   Its id is actionable; a bare box's is only positional.
        /// - `.stroke` — freehand. Last, because the note that reports the cut
        ///   sends the reader to `board.png` and for a stroke that is not a
        ///   consolation prize: it is already the only answer there was, stated
        ///   in the closing line whether anything was cut or not.
        private enum Tier: Int {
            case words, structure, shape, stroke
        }

        private static func tier(of element: Element) -> Tier {
            // Asked before the kind, so a labelled arrow and a captioned image
            // are both `.words`. A stroke and an uncaptioned image reach the
            // switch because `Element` guarantees them no text.
            guard element.text == nil, element.caption == nil else { return .words }
            return switch element.kind {
            case .stroke: .stroke
            case .arrow: .structure
            default: .shape
            }
        }

        /// The sentence a truncated digest ends its list with.
        ///
        /// Three claims, and each one is here because a reader without it would
        /// draw a wrong conclusion: how much is missing and of what, where the
        /// numbers describing the whole board are, and that what *is* listed is
        /// internally complete. The last is scoped to precisely what `admitted`
        /// enforces — no arrow above names something the cut removed. It does
        /// not promise that every id on the board resolves, because a binding to
        /// an element that was never in the scene is not this function's to
        /// vouch for, and an over-broad claim here is the defect class this file
        /// exists to prevent.
        private static func overflowNote(for omitted: [Element]) -> String {
            "… and \(omitted.count) more elements, not listed — this digest hit its size "
                + "budget: \(breakdown(of: omitted)). The whole board is in board.png, and the "
                + "header above counts it and gives its extent. No arrow listed above names an "
                + "element the cut left out."
        }

        /// What was left out, by kind — the shape of what the caller cannot see.
        ///
        /// **Bucketed on the closed `Kind` set, with every unrecognised type in
        /// one `other` bucket**, and that is what keeps the reserve honest
        /// rather than a tidiness preference. This note's worst case is charged
        /// to `reserved` before a single entry is assembled; if a bucket were
        /// named by `identifier(element.rawType)` the way an entry's kind column
        /// is, a board of distinct unknown types would give a worst case larger
        /// than `maxBytes` itself — `budget - reserved` would go negative, the
        /// digest would list nothing at all, and it would overshoot the very cap
        /// it was cut to respect. Eleven buckets of at most eight characters
        /// cannot do that.
        ///
        /// Largest bucket first, ties by name, so the ordering is a fact about
        /// the board rather than about `Dictionary`'s iteration order.
        private static func breakdown(of omitted: [Element]) -> String {
            var counts: [String: Int] = [:]
            for element in omitted {
                counts[bucket(of: element), default: 0] += 1
            }
            return counts
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
        }

        private static func bucket(of element: Element) -> String {
            element.kind == .other ? "other" : name(of: element)
        }

        /// One element's line, plus its caption indented under it when it has
        /// one.
        private static func entry(for element: Element, assets: [String: String]) -> String {
            let id = identifier(element.id)
            let kind = name(of: element)
            let at = "at \(rounded(element.x)),\(rounded(element.y))"
            let size = "\(rounded(element.width))×\(rounded(element.height))"
            let author = element.isAgentAuthored ? "  (agent)" : ""

            var line: String
            switch element.kind {
            case .stroke:
                let points = element.pointCount.map { "\($0) pts  " } ?? ""
                let bbox = "bbox \(rounded(element.x)),\(rounded(element.y)) → "
                    + "\(rounded(element.x + element.width)),\(rounded(element.y + element.height))"
                line = "\(id)  \(kind)  \(points)\(bbox)"
            case .image:
                // An ABSOLUTE path, or nothing that looks like one.
                //
                // The board lives in the cache directory and the agent's cwd is
                // its worktree, so a relative `assets/<id>` is unopenable from
                // where the agent stands — and it is shaped exactly like a path,
                // so an agent wanting a closer look at one screenshot would try
                // it and get nothing. That is the "sends a reader somewhere
                // completely different" failure this format exists to avoid, in
                // the one line where an image gets any handle at all. An id with
                // no file on disk says so in words instead.
                // The lookup uses the RAW id, because that is the key the
                // file was written under; only the fallback renders an
                // identifier, and it fires exactly when no file corroborates
                // the id.
                //
                // The path is deliberately NOT put through `identifier`, for
                // the reason this branch exists at all: it has to stay
                // openable, and a sanitized path is one that does not resolve
                // — the "sends a reader somewhere completely different"
                // failure above, reintroduced by the fix for a different one.
                // So the residual is stated rather than closed. `assetPaths`
                // *lists* the directory rather than replaying `writeAsset`, so
                // `isSafeComponent` does not vouch for what is in there: a
                // file placed by other means contributes its name to this line
                // unsanitized. That is the same exposure `line(for:)` already
                // accepts for `board.png`'s own path, for the same reason, and
                // closing it is not this function's job.
                let file = element.fileID.flatMap { assets[$0] }
                    ?? element.fileID.map { "fileId=\(identifier($0)) (no file in assets/)" }
                    ?? "(no file)"
                line = "\(id)  \(kind)  \(file)  \(at)  \(size)"
            case .arrow:
                let bound = element.from != nil || element.to != nil
                let ends = bound
                    ? "\(element.from.map(identifier) ?? "?") → \(element.to.map(identifier) ?? "?")"
                    : at
                let label = element.text.map { "  \(quoted($0))" } ?? ""
                line = "\(id)  \(kind)  \(ends)\(label)"
            default:
                let label = element.text.map { "\(quoted($0))  " } ?? ""
                line = "\(id)  \(kind)  \(label)\(at)  \(size)"
            }
            line += author
            if let caption = element.caption {
                line += "\n      caption: \(captionText(caption))"
            }
            return line
        }

        private static func name(of element: Element) -> String {
            switch element.kind {
            case .box: "box"
            case .note: "note"
            case .ellipse: "ellipse"
            case .diamond: "diamond"
            case .line: "line"
            case .arrow: "arrow"
            case .text: "text"
            case .stroke: "stroke"
            case .image: "image"
            // Its name rides in the text slot, so a namespace frame renders as
            // `frame  "Auth"  at …` through the default arm of `line(for:)`.
            case .frame: "frame"
            // Its own name rather than the nearest thing this build knows: a
            // kind it has never heard of must say so, not be reported as a box.
            case .other: identifier(element.rawType)
            }
        }

        private static func rounded(_ value: Double) -> Int {
            Int(value.rounded())
        }

        /// User text, flattened to one line, bounded, and quoted.
        ///
        /// Nothing bounds a label — a 200KB one in a single shape is the
        /// whiteboard's version of the 200KB check name
        /// `VerificationSummary.checkMessage` cuts. Cut from the **end**,
        /// because a label is read from the front, and marked with an ellipsis
        /// and nothing more: a label is what the user typed into the shape, so
        /// a reader seeing it cut can look at the shape.
        ///
        /// A **caption** is not this. It goes through `captionText`, which is
        /// bounded far more generously and says in words when it cut.
        ///
        /// **A quote in the user's text is escaped `\"`, and a backslash
        /// `\\`** — `clipped` does it, so a label and a caption cannot
        /// disagree about it. Unescaped, the delimiters were ambiguous: a label
        /// of `He said "hello"` rendered as `"He said "hello""`, and a reader
        /// cannot always tell where the user's text ends. That is the mildest
        /// class of defect this format has — the digest is read by an LLM, not
        /// parsed, so it is ambiguous rather than corrupt, and the dangerous
        /// relative (text that kept its newlines and could forge an entry for
        /// an element not on the board) was closed separately. It is fixed here
        /// rather than in `captionText` alone because the shared path is where
        /// it lives, which necessarily moves how **every label** renders too.
        private static func quoted(_ raw: String) -> String {
            let (kept, cut) = clipped(flattened(raw), to: maxTextBytes)
            return cut ? "\"\(kept)…\"" : "\"\(kept)\""
        }

        /// A transcription, bounded far more generously than a label — and
        /// **told in words when it was cut**, which a label is not.
        ///
        /// A caption exists so a later agent need not open the picture at all.
        /// A silently cut one therefore defeats the feature in a way a cut
        /// label does not: the reader is handed part of a transcription with
        /// nothing saying it is a part, and the digest's whole claim is that it
        /// is the half of the board that can be reasoned about *exactly*.
        ///
        /// **The marker goes outside the quotes.** Inside, it is
        /// indistinguishable from a transcription of a screenshot that was
        /// itself clipped — an ordinary thing to capture, and the reading the
        /// ellipsis alone invites. It deliberately does not name `board.png`,
        /// because the render may be `.none` or `.stale` and this line has no
        /// business deciding that; the entry's own first line already carries
        /// the absolute path of the image in `assets/`, which is where the
        /// pixels are whatever the render is doing.
        ///
        /// **The number it names is bytes of the escaped field, not of the
        /// user's transcription**, because `clipped` escapes as it cuts. For a
        /// caption carrying neither a quote nor a backslash — very nearly all
        /// of them — the two are the same number. A quote-heavy one that used
        /// to fit now cuts and says so, which is the honest half of the trade
        /// `clipped` argues: the sentence stays true about what was spent.
        private static func captionText(_ raw: String) -> String {
            let (kept, cut) = clipped(flattened(raw), to: maxCaptionBytes)
            guard cut else { return "\"\(kept)\"" }
            return "\"\(kept)…\"  (cut at \(maxCaptionBytes) bytes — "
                + "the rest is only in the image itself)"
        }

        /// One line, because one element is one line here and a reader counting
        /// lines has to be right.
        ///
        /// A caption pays this too. It costs a multi-line transcription its
        /// structure and not its words, which is the cheaper half — and the
        /// alternative, a continuation prefix per line, would make the entry's
        /// own line count depend on its content.
        private static func flattened(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }

        /// The budgeted cut both limits share, and **whether it cut** — which
        /// is what lets a caption say so and a label not.
        ///
        /// **It escapes as it goes, and that is the whole of the ordering
        /// decision.** Escaping adds bytes, so where it happens relative to the
        /// cut decides which of two things stays true. Escaping *after* the cut
        /// keeps the count of the user's own characters predictable and lets
        /// the rendered field reach twice its cap — `maxTextBytes` would go on
        /// saying "one shape cannot spend the whole digest" while a label of
        /// quotes spent 480 bytes of it. Escaping *before* keeps the cap true
        /// and costs a label made of quotes half its visible characters. This
        /// takes the second: the caps are stated as bounds on the rendered
        /// field, ordinary text holds neither a quote nor a backslash so for
        /// very nearly every real board the output is byte-identical to before,
        /// and what degrades is pathological by construction. The field already
        /// overshoots its cap by a fixed five bytes — two quotes and the
        /// ellipsis — and a *constant* overshoot is not what that sentence is
        /// guarding against; a multiplier is.
        ///
        /// **So the escape is charged and appended one character at a time,
        /// here, rather than applied to a string this function then cuts.** A
        /// cut landing between a `\` and its `"` leaves a dangling escape, which
        /// is the same malformed output as the U+FFFD below and reaches the
        /// reader the same way — the following character reads as escaped. The
        /// grapheme rule this loop already keeps is the identical rule, so the
        /// escape is simply the other thing that is appended whole or not at
        /// all. It is also why the early return on `flat.utf8.count` is gone:
        /// a string that fits unescaped need not fit escaped.
        ///
        /// **Accumulated by `Character`, not cut out of a byte array.** The
        /// obvious byte version — `prefix(n)`, then walk back off any trailing
        /// continuation byte — does not work, and fails in the case it is
        /// written for: stripping continuations leaves the multi-byte scalar's
        /// *lead* byte orphaned, which `String(decoding:)` renders as U+FFFD,
        /// three bytes where the scalar was two. So it produces both the
        /// replacement character it was meant to avoid and the overshoot.
        /// (`VerificationSummary.checkMessage` had exactly that shape when this
        /// was written, and was left alone here on purpose — quietly changing
        /// another surface under this PR is how a fix ships unreviewed. It was
        /// fixed on its own in #198 and now accumulates by `Character` too, so
        /// the two agree rather than one being the cautionary tale.)
        ///
        /// Counting graphemes rather than scalars is `IPC.Names.sanitized`'s
        /// rule and the same one applies: breaking between a base and its
        /// combining mark strands the mark on whatever the template puts next.
        /// The loop stops at the budget, so it costs `limit` steps rather than
        /// the length of the text.
        private static func clipped(_ flat: String, to limit: Int) -> (text: String, cut: Bool) {
            var kept = ""
            var spent = 0
            var index = flat.startIndex
            while index < flat.endIndex {
                let piece = escaped(flat[index])
                let width = piece.utf8.count
                guard spent + width <= limit else { break }
                kept += piece
                spent += width
                index = flat.index(after: index)
            }
            return (kept, index < flat.endIndex)
        }

        /// One character as it appears between the quotes.
        ///
        /// **A backslash is escaped because the quote is.** Escaping only the
        /// quote looks like the smaller change and is a worse bug: a literal
        /// backslash sitting before a quote in the user's text then renders as
        /// `\\"`, which under the very rules the reader has just been given
        /// decodes as an escaped backslash followed by a *terminator*. The
        /// field ends early, the output looks well-formed, and nothing says
        /// otherwise — strictly worse than the ambiguity this replaced.
        ///
        /// Deliberately **not** `\n`. `flattened` has already run and there is
        /// no newline left to meet; an escape for one would imply the digest
        /// can carry multi-line text, which is the forgery #200 closed.
        private static func escaped(_ character: Character) -> String {
            switch character {
            case "\\": #"\\"#
            case "\"": #"\""#
            default: String(character)
            }
        }

        /// An identifier as it stands in a positional column: `id`, an unknown
        /// kind, an arrow's two bindings, and the `fileId` of an image with no
        /// file on disk.
        ///
        /// **These are not `quoted`'s problem in smaller clothes, and routing
        /// them through it would be wrong twice over.** That function renders
        /// *prose* — it wraps in `"…"` and escapes the quote and the backslash
        /// so the delimiters stay unambiguous. Here there are no delimiters:
        /// every other kind renders bare (`box`, `note`, `ellipse`), so quoting
        /// only the unrecognised one puts quotes in a column where no other
        /// value has them, and an escape outside a quoted field is a backslash
        /// that means nothing to the reader. The column keeps its shape and the
        /// value is made to fit it instead.
        ///
        /// **The exposure is an injected line, the vector #200 closed for
        /// captions.** An element's entry is one line and the digest's reader
        /// counts lines, so a newline here injects a line that reads as another
        /// element's entry — the digest reporting elements that are not on the
        /// board, which is the one thing this feature is organised around not
        /// doing. `id` is the worst of the five because it is *first* on the
        /// line: a newline there hands the forger the whole of the next one.
        ///
        /// **But flattening alone is not enough, and that is what picks an
        /// allowlist over `flattened`.** Nothing about
        /// `box  at 999,999  50×50  (agent)` as a kind crosses a line. The entry
        /// stays one line, the line-counting reader is satisfied, and the
        /// columns after the kind now read as a box at a position the user
        /// never put it, marked as drawn by an agent. A digest that invents
        /// authorship is worse than one with an extra line, because nothing
        /// about it looks wrong. So a space is as dangerous here as a newline,
        /// and neither is in the class.
        ///
        /// **No producer mints one of these today**, which is why this is
        /// stated as a structural guarantee rather than as a fix for a bug
        /// anybody has seen: `Write.Kind` is a closed enum so an agent cannot
        /// name an arbitrary type, and Excalidraw emits its own type names and
        /// a hex `fileId`. But "one element is one line" is an invariant this
        /// file states about itself, every other field reaching a line honours
        /// it, and whether a third-party dependency's current version only ever
        /// emits admissible values is pinned nowhere and is not this file's to
        /// assume.
        ///
        /// **The class is `Store.isSafeComponent`'s, deliberately.** That is
        /// already this feature's answer to what an identifier of this kind may
        /// contain — it is what `Store.writeAsset` checks before a `fileId` is
        /// allowed to name a file in `assets/`. (It does **not** vouch for the
        /// image line's other branch; the comment at that call site says what
        /// that path's provenance really is and why it stays verbatim.)
        ///
        /// **Every character this function adds is outside the class it
        /// enforces**, so a marker can never be mistaken for content: an
        /// ellipsis in one of these columns is always the digest saying it cut,
        /// and a `*` is always the digest saying something inadmissible was
        /// there. That is the inverse of the delimiter ambiguity `quoted`
        /// fixes — the same goal reached by making the field's alphabet small
        /// rather than by escaping within a large one.
        ///
        /// Per-`Character` rather than per-scalar, the grapheme rule `clipped`
        /// and `IPC.Names.sanitized` both keep: an emoji costs one marker, not
        /// one per scalar. Substituted rather than dropped, because dropping
        /// collapses two distinct ids into one string and says nothing about
        /// what was removed.
        private static func identifier(_ raw: String) -> String {
            var kept = ""
            var spent = 0
            var cut = false
            for character in raw {
                guard spent < maxIdentifierBytes else {
                    cut = true
                    break
                }
                // Every admissible character is single-byte ASCII and so is the
                // marker, so one `Character` costs exactly one byte and the
                // budget needs no width arithmetic. It is also why the U+FFFD
                // hazard `clipped`'s comment fights cannot arise here: nothing
                // multi-byte survives into the output to be cut in half.
                kept.append(admissible(character) ? character : marker)
                spent += 1
            }
            // An empty identifier is not a missing one. `raw["type"] as? String`
            // accepts `""`, and an absent kind column silently moves every
            // column after it one place to the left — the same misread-by-
            // position this function exists to prevent, arrived at by omission
            // rather than by injection.
            guard !kept.isEmpty else { return "(none)" }
            return cut ? "\(kept)…" : kept
        }

        /// ASCII letters, digits, `-` and `_` — `Store.isSafeComponent`'s class,
        /// per character. It covers what every producer of these fields
        /// actually mints: Excalidraw's type names are lowercase ASCII, a
        /// `fileId` is a SHA-1 in lowercase hex, and an element id is
        /// alphanumerics with `-` and `_`.
        ///
        /// The two predicates ask different questions — may this name a file,
        /// may this stand unquoted in a column — and land on the same class
        /// because they are about the same identifiers, which is why this is
        /// restated per-`Character` rather than either being reused for the
        /// other's question. `isASCII` is checked rather than leaning on
        /// `isLetter`, which is true for a great many characters that are not
        /// safe here; that is `Store.isSafeComponent`'s own note.
        private static func admissible(_ character: Character) -> Bool {
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }

        /// Stands in for one inadmissible character.
        ///
        /// Outside the class by construction, and deliberately **not** `?`,
        /// which an arrow's own line already spends on an unbound end — a
        /// marker colliding with a meaning the format already has is the
        /// ambiguity this closes, reintroduced one column over.
        private static let marker: Character = "*"

        /// Per-identifier cap, and it is **not** `maxTextBytes` (240) or
        /// `maxCaptionBytes` (1200), because it bounds a different kind of
        /// thing. Those bound prose the user typed, which is legitimately long,
        /// and the question there is how much of a real sentence to keep. This
        /// bounds an identifier: a SHA-1 in hex is 40 characters, the longest
        /// type name Excalidraw mints is about ten, and an element id is
        /// shorter still — so anything past 64 is already not an identifier,
        /// and nothing a reader wanted is being cut. Nothing at the scene layer
        /// bounds these fields at all, so without this one element can spend
        /// the whole digest the way an unbounded label used to.
        ///
        /// The rendered field can exceed it by the three bytes of the cut
        /// marker, the fixed overshoot `clipped`'s comment already argues is
        /// not what a cap of this sort guards against.
        private static let maxIdentifierBytes = 64

        /// Per-label cap, well under `maxBytes` so that one shape cannot spend
        /// the whole digest and leave every other element unlisted — which would
        /// be truthfully reported and useless.
        private static let maxTextBytes = 240

        /// Per-caption cap, five times the label's, and the number is measured
        /// rather than picked.
        ///
        /// Transcriptions of the screenshots this feature is for — a settings
        /// pane, an error dialog, a failing test's output, a table of rows —
        /// run 225 to 400 bytes, so `maxTextBytes` cut most of them: a
        /// transcription written so the picture need not be opened, silently
        /// truncated to a third of itself. 1200 is three times the top of that
        /// band.
        ///
        /// **Erring large is safe because the assembly loop is honest about
        /// omission.** An entry that does not fit is `continue`d and counted
        /// into `overflowNote`, whose worst case is charged to `reserved`
        /// before anything is assembled. So a long caption costs other elements
        /// their lines and never their existence — which is exactly what
        /// `maxTextBytes` is guarding against, and why that limit stays where
        /// it is rather than being widened to cover both.
        private static let maxCaptionBytes = 1200
    }
}
