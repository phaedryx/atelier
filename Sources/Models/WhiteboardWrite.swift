// ABOUTME: Validates and normalizes the narrow vocabulary an agent writes in.
// ABOUTME: Pure and Foundation-only — the page expands what this approves.

import Foundation

extension Whiteboard {
    /// The agent write path's Swift half.
    ///
    /// **Swift validates; the page expands.** This turns `{kind, text, at,
    /// from, to, color}` into an Excalidraw *skeleton* and refuses everything
    /// outside the vocabulary; `convertToExcalidrawElements` in
    /// `editor/src/whiteboard.jsx` turns a skeleton into a real element. The
    /// split falls here because this half is where the feature's mistakes live
    /// — an unknown kind, an arrow pointing at nothing, a colour that is not a
    /// colour — and none of them need a webview to pin, while the expansion
    /// needs Excalidraw's own `seed`, `versionNonce`, `groupIds` and
    /// `boundElements` and must never be hand-written.
    ///
    /// **Ids are minted here, not by Excalidraw.** The page converts with
    /// `regenerateIds: false` — measured against 0.18.1: a supplied id survives
    /// byte-identical — which is what lets `whiteboard_add` answer with ids that
    /// are the *real* element ids, the same ones the digest reports and
    /// `whiteboard_update` takes. There is no mapping table because there is
    /// nothing to map, and no display-id vocabulary for the two ends to drift
    /// apart on. The one exception is a `mermaid` entry — see `Mermaid` — where
    /// the page regenerates ids on purpose and the answer is read off what
    /// really landed, which is the same source of truth reached the other way.
    ///
    /// **Nothing here reads `board.excalidraw`.** What is on the board arrives
    /// as a `Live` parameter, supplied from the *page*, because the file lags it
    /// by the 800ms save debounce: an agent that adds a box and then updates it
    /// would otherwise be refused for naming an id that is plainly on the board.
    /// That is also what keeps this file pure, and testable with no board on
    /// disk and no libghostty.
    enum Write {
        /// A batch bound. A diagram is eight boxes and six arrows; a thousand is
        /// a runaway loop, and the refusal should arrive before the page spends
        /// a minute on it.
        static let maxBatch = 100
        /// The default size of a box or a note. A text element is sized by
        /// Excalidraw from its content.
        static let boxSize = (width: 220.0, height: 90.0)
        /// The vertical step between elements that were given no position.
        static let rowStep = 120.0
        /// Clearance left under the lowest thing already on the board, and
        /// under anything this batch places explicitly.
        static let layoutGap = 60.0
        /// What makes a note look like a note rather than a box. The marker in
        /// `customData` is what makes it *read* as one.
        static let noteBackground = "#fff3bf"

        /// The vocabulary. The design's four, plus `mermaid`.
        ///
        /// A mermaid diagram is the one kind Swift can neither expand nor
        /// validate: only the page, through Excalidraw's own converter, can say
        /// whether a definition parses and how big it comes out. It is in the
        /// vocabulary rather than behind a fifth tool because an agent reaches
        /// for `whiteboard_add` to put a diagram on the board, and a diagram it
        /// already knows how to write is the most natural thing to hand it.
        enum Kind: String, CaseIterable {
            case box, note, text, arrow, mermaid
        }

        /// Where the next unpositioned element goes.
        ///
        /// Reported by the *page*, because Swift cannot know it: a board's
        /// extent is live state. Passed in rather than read here so this stays
        /// pure.
        struct Layout: Equatable {
            let originX: Double
            let nextY: Double
            /// An empty board — the same `(100, 100)` the page reports for one
            /// itself, so this is its answer rather than a stand-in for one.
            ///
            /// It used to serve "a page that could not answer" as well, and
            /// that reading is gone: `Host.decodeLiveState` refuses a page that
            /// cannot answer instead of completing it from here, because the
            /// coordinates this holds are exactly the ones that drop an element
            /// on top of the user's diagram. `WhiteboardWriteTests`' empty
            /// board is the only reader left.
            static let fallback = Layout(originX: 100, nextY: 100)
        }

        /// What the page says is on the board right now.
        ///
        /// `imageIDs` is a subset of `ids`, and it is here for exactly one
        /// question: a caption is an agent's transcription of pixels, so it
        /// belongs on an image and nowhere else. Swift can only refuse a
        /// caption on a box if it is told which elements are images, and the
        /// page is the only thing that knows.
        struct Live: Equatable {
            let ids: Set<String>
            let imageIDs: Set<String>
            let layout: Layout
        }

        /// One element, as the page will expand it.
        ///
        /// A skeleton, not an element: it carries what Excalidraw's converter
        /// needs and nothing that converter computes for itself.
        struct Skeleton: Equatable {
            let id: String
            let type: String
            let x: Double
            let y: Double
            let width: Double?
            let height: Double?
            /// A container's bound label, or a bare text element's own text.
            /// Which of the two it becomes is decided by `type` in `json`.
            let label: String?
            let strokeColor: String?
            let backgroundColor: String?
            let from: String?
            let to: String?
            let isNote: Bool

            var json: [String: Any] {
                var out: [String: Any] = ["id": id, "type": type, "x": x, "y": y]
                if let width {
                    out["width"] = width
                }
                if let height {
                    out["height"] = height
                }
                if let strokeColor {
                    out["strokeColor"] = strokeColor
                }
                if let backgroundColor {
                    out["backgroundColor"] = backgroundColor
                }
                if let label {
                    // A bare text element carries its text directly; every other
                    // kind carries it as a bound label, which Excalidraw expands
                    // into a separate element carrying `containerId` — the same
                    // join `Whiteboard.SceneLoad.labels` makes when reading.
                    if type == "text" {
                        out["text"] = label
                    } else {
                        out["label"] = ["text": label]
                    }
                }
                if let from {
                    out["start"] = ["id": from]
                }
                if let to {
                    out["end"] = ["id": to]
                }
                // Every agent-authored element is marked, so both sides can tell
                // who put something on the board.
                var customData: [String: Any] = [Element.authorKey: Element.agentAuthorValue]
                // Only a note. The reader promotes a rectangle on this key
                // alone, so a box carrying it would read back as a note.
                if isNote {
                    customData[Element.kindKey] = Element.noteKindValue
                }
                out["customData"] = customData
                return out
            }
        }

        /// Named colours, normalized to hex.
        ///
        /// A palette as well as raw hex because an agent asked to "colour it
        /// red" writes `red`, and refusing that over punctuation is the kind of
        /// refusal that makes a tool not worth reaching for.
        static let palette: [String: String] = [
            "black": "#1e1e1e",
            "grey": "#868e96",
            "gray": "#868e96",
            "red": "#e03131",
            "orange": "#f08c00",
            "yellow": "#f1c40f",
            "green": "#2f9e44",
            "blue": "#1971c2",
            "violet": "#9c36b5",
            "purple": "#9c36b5",
        ]

        /// Why a write was refused.
        ///
        /// Agent-facing protocol text, so deliberately not localized — the rule
        /// `IPC.Error`'s descriptions state. Each one names the offending value,
        /// because an agent cannot see the board and the refusal is the whole of
        /// what it has to work from.
        enum Failure: LocalizedError, Equatable {
            case emptyBatch
            case malformedJSON
            case batchTooLarge(Int)
            case malformedEntry(Int)
            case unknownKind(String)
            case textRequired(kind: String)
            case arrowNeedsEndpoints
            case unknownElement(String)
            case invalidPosition(String)
            case invalidColor(String)
            case captionNeedsImage(String)
            case textNeedsCanvasText(String)
            case nothingToUpdate
            case mermaidStandsAlone
            case mermaidFieldRefused(String)

            var errorDescription: String? {
                switch self {
                case .emptyBatch:
                    "No elements were given. Name at least one."
                case .malformedJSON:
                    "`elements` is not a JSON array. It looks like "
                        + "[{\"kind\": \"box\", \"text\": \"Auth service\", \"at\": \"120,80\"}]."
                case let .batchTooLarge(count):
                    "\(count) elements is more than one call may take; the limit is \(maxBatch). "
                        + "Split it across calls."
                case let .malformedEntry(index):
                    "Element \(index) is not an object. Each entry looks like "
                        + "{\"kind\": \"box\", \"text\": \"Auth service\", \"at\": \"120,80\"}."
                case let .unknownKind(kind):
                    "\"\(kind)\" is not a kind this board can draw. Use one of: "
                        + Kind.allCases.map(\.rawValue).joined(separator: ", ") + "."
                case let .textRequired(kind):
                    "A \(kind) element needs `text`."
                case .arrowNeedsEndpoints:
                    "An arrow needs both `from` and `to`, each naming an element id."
                case let .unknownElement(id):
                    "No element on this board has the id \"\(id)\". Call read_whiteboard for the "
                        + "current ids. An arrow may only name an element already on the board, or "
                        + "one added earlier in the same call — not one added later in it."
                case let .invalidPosition(raw):
                    "\"\(raw)\" is not a position. Write it as \"x,y\", for example \"120,80\"."
                case let .invalidColor(raw):
                    "\"\(raw)\" is not a colour. Use a hex value like \"#e03131\", or one of: "
                        + palette.keys.sorted().joined(separator: ", ") + "."
                case let .captionNeedsImage(id):
                    // Names the alternative, because a refusal that does not is
                    // one an agent retries verbatim.
                    // "that already carries words" rather than the flat "a box,
                    // note, text or arrow" this used to name. `text` is now
                    // refused by the page for an element drawn without a label,
                    // so the unqualified advice sent an agent captioning an
                    // unlabelled box from one refusal straight into another with
                    // nothing naming the way out.
                    "\"\(id)\" is not an image, and a caption is a transcription of one. "
                        + "Use `text` to change what a box, note, text or arrow already "
                        + "says. read_whiteboard lists each image on this board."
                case let .textNeedsCanvasText(id):
                    // The mirror of `captionNeedsImage`, and the more valuable
                    // of the two: reaching for `text` to describe a screenshot
                    // is the obvious first move, and it used to succeed while
                    // changing nothing.
                    "\"\(id)\" is an image, and an image carries no text on the canvas. "
                        + "Use `caption` to record what it shows — read_whiteboard reports that "
                        + "under the image."
                case .nothingToUpdate:
                    "Nothing to change — name at least one of `at`, `text`, `color` or `caption`."
                case .mermaidStandsAlone:
                    // The page learns the diagram's height only after it has
                    // parsed it, so the column layout for anything after it
                    // would be a guess — and a guess drops the next element on
                    // top of the diagram, which reads fine in the digest.
                    "A mermaid diagram must be the only entry in its call: its size is not "
                        + "known until the page has drawn it, so nothing else can be placed "
                        + "around it in the same call. Add the diagram on its own, then add "
                        + "the rest in a second call."
                case let .mermaidFieldRefused(field):
                    "`\(field)` does nothing on a mermaid diagram. A mermaid entry takes `text` "
                        + "(the definition) and optionally `at`; colour and connections belong "
                        + "in the definition itself."
                }
            }
        }

        /// A fresh element id.
        ///
        /// Prefixed so a board's own file shows which elements an agent put
        /// there even if `customData` is ever lost, and alphanumeric-and-hyphen
        /// only because the id travels through JSON, through Excalidraw's own
        /// maps and out through the digest.
        static func mintID() -> String {
            "atl-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }

        // MARK: - plan

        /// What one `whiteboard_add` call asked for.
        ///
        /// Two shapes rather than one, because the two arms answer different
        /// questions: `elements` is a batch Swift has fully validated and the
        /// page merely expands, while `mermaid` is a definition Swift cannot
        /// read and the page has to parse, size and place.
        /// The elements arm carries **only** the skeletons, and deliberately no
        /// second id list. It had one and nothing read it:
        /// `WorkspaceActions.whiteboardAdd` bound it to `_` and answered with
        /// the ids the *page* reports really landed — which for the mermaid arm
        /// is the only source there is, and for this one is the same list read
        /// off what was really stored rather than what was asked for. It was in
        /// any case `skeletons.map(\.id)`, a second copy of a fact the
        /// skeletons already carry, and two copies of one list is how they
        /// eventually differ.
        enum Add: Equatable {
            case elements(skeletons: [Skeleton])
            case mermaid(Mermaid)
        }

        /// A mermaid diagram, as the page will draw it.
        ///
        /// Carries the definition and the origin its top-left goes to, and
        /// nothing else: how many elements it becomes, and which, is the
        /// converter's answer. So unlike an `elements` plan there are no ids to
        /// mint here — the answer to the tool is whatever the page reports
        /// really landed, which `Host.apply` already returns.
        struct Mermaid: Equatable {
            let definition: String
            let x: Double
            let y: Double

            var op: [String: Any] {
                [
                    "kind": "mermaid",
                    "definition": definition,
                    "x": x,
                    "y": y,
                    // The page stamps every element the diagram expands to,
                    // and it cannot spell a `customData` key — so the marker
                    // travels on the op, the rule `captionKey` already follows.
                    "customData": [Element.authorKey: Element.agentAuthorValue],
                    // For the diagram types the converter renders as an image:
                    // that image carries no words on the canvas, so its caption
                    // is the definition, and the digest is not blind to it.
                    "captionKey": Element.captionKey,
                ]
            }
        }

        /// The same plan, from the JSON array the tool argument carries.
        ///
        /// Arguments cross IPC as `[String: String]` — every tool on this
        /// surface takes only strings — so a list of objects has to arrive
        /// encoded. Parsed here rather than at the handler so that a malformed
        /// array is refused in the same voice as everything else this file
        /// refuses, and so the parse is covered by the same pure tests.
        static func plan(
            fromJSON json: String,
            live: Live,
            mint: () -> String = mintID
        ) throws -> Add {
            guard let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { throw Failure.malformedJSON }
            return try plan(from: raw, live: live, mint: mint)
        }

        /// Routes a batch to the arm that can draw it.
        ///
        /// A batch holding a mermaid entry must hold nothing else — see
        /// `Failure.mermaidStandsAlone` — so the decision is made on the whole
        /// batch before either arm reads an entry. `addPlan` refuses a mermaid
        /// entry on its own account too, so a caller reaching it directly
        /// cannot draw one as something else.
        static func plan(
            from raw: [Any],
            live: Live,
            mint: () -> String = mintID
        ) throws -> Add {
            let mermaidEntries = raw.filter { kind(of: $0) == .mermaid }
            guard !mermaidEntries.isEmpty else {
                return try .elements(skeletons: addPlan(from: raw, live: live, mint: mint))
            }
            guard raw.count == 1, let entry = raw.first as? [String: Any] else {
                throw Failure.mermaidStandsAlone
            }
            return try .mermaid(mermaidPlan(from: entry, live: live))
        }

        /// Whether an entry really asked for a field.
        ///
        /// **A JSON `null` and an empty string are not asking.** `entry[field]
        /// != nil` reads both as present — `JSONSerialization` hands `null`
        /// back as `NSNull`, which is very much not nil — so a serializer that
        /// writes every key of its struct had a mermaid entry refused for a
        /// `color` it never set, with `mermaidFieldRefused` explaining that
        /// colour belongs in the definition. The elements arm accepts exactly
        /// those two from exactly that serializer: `normalizedColor` returns
        /// nil for an empty string, and `from`/`to` are read as
        /// `as? String, !isEmpty`. One serializer must not be refused by one
        /// arm and accepted by the other for the same bytes.
        private static func asks(_ entry: [String: Any], for field: String) -> Bool {
            guard let value = entry[field], !(value is NSNull) else { return false }
            if let text = value as? String {
                return !text.isEmpty
            }
            return true
        }

        private static func mermaidPlan(from entry: [String: Any], live: Live) throws -> Mermaid {
            for field in ["color", "from", "to"] where asks(entry, for: field) {
                throw Failure.mermaidFieldRefused(field)
            }
            guard let definition = entry["text"] as? String, !definition.isEmpty else {
                throw Failure.textRequired(kind: Kind.mermaid.rawValue)
            }
            let position: (x: Double, y: Double) = if let at = entry["at"] as? String {
                try parsePosition(at)
            } else {
                (live.layout.originX, live.layout.nextY)
            }
            return Mermaid(definition: definition, x: position.x, y: position.y)
        }

        /// An entry's kind as written, or nil for one that names none it knows.
        ///
        /// **The one place a kind is read.** There were three, and they did not
        /// agree: this one trims and lowercases, while `addPlan`'s column
        /// pre-scan only lowercased. So `"box "` passed the batch loop as a box
        /// and was missed by the pre-scan, which then left `nextRow` above the
        /// box rather than below it — and the next unplaced element landed on
        /// top of it. Invisible in the digest, because both sets of coordinates
        /// read exactly as asked, and wrong only in the picture, which is the
        /// shape the layout scan exists to prevent.
        private static func kind(of entry: Any) -> Kind? {
            guard let entry = entry as? [String: Any] else { return nil }
            let raw = (entry["kind"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return Kind(rawValue: raw)
        }

        // MARK: - add

        static func addPlan(
            from raw: [Any],
            live: Live,
            mint: () -> String = mintID
        ) throws -> [Skeleton] {
            guard !raw.isEmpty else { throw Failure.emptyBatch }
            guard raw.count <= maxBatch else { throw Failure.batchTooLarge(raw.count) }

            var skeletons: [Skeleton] = []
            // Grows as the batch is walked, so an arrow may name a box created
            // earlier in the same call — but not a later one. A forward
            // reference is refused rather than resolved: resolving it would make
            // a batch's meaning depend on a reading order nothing states.
            var known = live.ids
            // The column starts below everything already on the board AND
            // below anything this batch places by hand.
            //
            // Scanned up front rather than as the batch is walked, so the
            // answer does not depend on whether the placed element came first:
            // an agent that draws two boxes at chosen coordinates and adds an
            // unplaced note would otherwise have the note dropped on top of
            // them, which is invisible in the digest — the coordinates read
            // fine — and ruins the picture, the half of the read path that
            // exists to corroborate the other.
            var nextRow = live.layout.nextY
            for entry in raw {
                guard let entry = entry as? [String: Any],
                      let at = entry["at"] as? String,
                      let placed = try? parsePosition(at)
                else { continue }
                // `kind(of:)`, not a second inline read: this used to lowercase
                // without trimming, so `"box "` was a box to the loop below and
                // not a box here, and its height was left out of the floor.
                let kind = kind(of: entry)
                let bottom = placed.y + (kind == .box || kind == .note ? boxSize.height : 0)
                nextRow = max(nextRow, bottom + layoutGap)
            }

            for (index, entry) in raw.enumerated() {
                guard let entry = entry as? [String: Any] else {
                    throw Failure.malformedEntry(index)
                }
                guard let kind = kind(of: entry) else {
                    throw Failure.unknownKind(entry["kind"] as? String ?? "")
                }
                // This arm draws elements; a diagram is `plan`'s to route, and
                // one reaching here is either mixed into a batch or a direct
                // caller — refused either way rather than drawn as a box.
                guard kind != .mermaid else { throw Failure.mermaidStandsAlone }

                let text = (entry["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if kind == .text, text == nil {
                    throw Failure.textRequired(kind: kind.rawValue)
                }

                let color = try normalizedColor(entry["color"] as? String)

                var from: String?
                var to: String?
                if kind == .arrow {
                    guard let start = entry["from"] as? String, !start.isEmpty,
                          let end = entry["to"] as? String, !end.isEmpty
                    else { throw Failure.arrowNeedsEndpoints }
                    guard known.contains(start) else { throw Failure.unknownElement(start) }
                    guard known.contains(end) else { throw Failure.unknownElement(end) }
                    from = start
                    to = end
                }

                let position: (x: Double, y: Double)
                if let at = entry["at"] as? String {
                    position = try parsePosition(at)
                } else {
                    // An explicitly placed element must not consume a column
                    // slot, or two placed elements would leave a gap in the
                    // stack of the ones that were not placed.
                    position = (live.layout.originX, nextRow)
                    nextRow += rowStep
                }

                let isBoxy = kind == .box || kind == .note
                let type = switch kind {
                case .arrow: "arrow"
                case .text: "text"
                case .box, .note: "rectangle"
                case .mermaid: preconditionFailure("refused above")
                }
                let id = mint()
                skeletons.append(Skeleton(
                    id: id,
                    type: type,
                    x: position.x,
                    y: position.y,
                    width: isBoxy ? boxSize.width : nil,
                    height: isBoxy ? boxSize.height : nil,
                    label: text,
                    strokeColor: color,
                    backgroundColor: kind == .note ? noteBackground : nil,
                    from: from,
                    to: to,
                    isNote: kind == .note
                ))
                known.insert(id)
            }
            return skeletons
        }

        // MARK: - update

        /// **A caption is for an image and nothing else.**
        ///
        /// It is the agent's own transcription of pixels — the design's answer
        /// to Excalidraw's canvas search matching text elements only, so a
        /// pasted screenshot is otherwise opaque to everything. On a box it
        /// would be a second, invisible text channel: present in the digest,
        /// absent from the picture, which is the disagreement the read path's
        /// two halves exist to make impossible. `text` is the channel for
        /// everything that can carry words on the canvas.
        ///
        /// Deliberately **not** materialized as a real text element. That would
        /// make ⌘F find it, at the cost of a block of text under every
        /// screenshot on a board the user is sketching on; canvas search over
        /// screenshots is the accepted gap the design states.
        static func updatePlan(
            id: String,
            at: String?,
            text: String?,
            color: String?,
            caption: String? = nil,
            live: Live
        ) throws -> [String: Any] {
            guard live.ids.contains(id) else { throw Failure.unknownElement(id) }
            var op: [String: Any] = ["kind": "update", "id": id]
            if let at {
                let position = try parsePosition(at)
                op["x"] = position.x
                op["y"] = position.y
            }
            // Checked for nil rather than for emptiness, unlike every other
            // optional argument on this surface: clearing a label is a real
            // edit, and `""` is how it is asked for.
            if let text {
                // **An image is refused here**, and this is the mirror of
                // `captionNeedsImage` below. An image carries no text on the
                // canvas, so the page's `textTargetFor` finds nothing to change
                // — and the call still reported "Updated i1.", which is a silent
                // success teaching an agent that its transcription landed.
                // Reaching for `text` to describe a screenshot is the obvious
                // first move, so it is the one that most needs answering.
                //
                // An image is the only case this side can answer. The other
                // silent success of the same shape — `text` on a box, ellipse,
                // diamond or arrow the user drew WITHOUT a label — is refused by
                // the page, because whether an element carries a bound label is
                // a fact about the live scene and `Live` does not carry it. Not
                // a second copy of this rule: the two refuse different things,
                // each where the fact it needs lives.
                guard !live.imageIDs.contains(id) else {
                    throw Failure.textNeedsCanvasText(id)
                }
                op["text"] = text
            }
            if let color {
                op["strokeColor"] = try normalizedColor(color)
            }
            // Checked for nil rather than for emptiness, the rule `text` above
            // follows: clearing a transcription is a real edit, and `""` is how
            // it is asked for. The page removes the key rather than storing an
            // empty string, or the digest would render a blank caption line
            // under the image.
            if let caption {
                guard live.imageIDs.contains(id) else { throw Failure.captionNeedsImage(id) }
                // **Whitespace-only clears**, and everything else is stored
                // exactly as sent. This is not new policy: the page already
                // removes the key rather than storing `""` because "the digest
                // renders a caption line for any caption it finds, so an empty
                // string would leave a blank one under the image forever" — and
                // a caption of three spaces renders that same blank line while
                // reading, in the file, as a transcription that exists. An
                // agent clearing one is far likelier to send a stray space than
                // to mean a caption made of whitespace.
                //
                // Trimmed HERE and deliberately not also in the page. The two
                // would be a second copy of one rule, and this half is the pure,
                // testable one — `WhiteboardWriteTests` pins it with no board on
                // disk, which is the split `Tests/Harnesses/README.md` states.
                op["caption"] = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "" : caption
                // **The key travels with the value**, so the page never spells
                // it. `customData` keys live in exactly one place — `Element`,
                // the reader — and this is the first write of one from the
                // JavaScript side, where a literal could not be tied back to
                // that constant. A rename in Swift would have left the page
                // writing the old key: the caption would reach the board and
                // vanish from the digest, which is written and invisible, the
                // shape this feature is organized around. Same reasoning as
                // `IPC.Vocabulary`, for a boundary that cannot import Swift.
                op["captionKey"] = Element.captionKey
            }
            // Refused rather than treated as a no-op: an update naming no field
            // is an agent that meant something, and succeeding silently teaches
            // it that the call worked.
            guard op.count > 2 else { throw Failure.nothingToUpdate }
            return op
        }

        // MARK: - delete

        /// **No existence check, deliberately.** An id that is already gone is
        /// success, and that is precisely what makes `whiteboard_delete` safe to
        /// replay after a lost connection — checking here would turn a replay
        /// into a refusal about a fact that is merely no longer true.
        static func deletePlan(ids: [String]) throws -> [String: Any] {
            guard !ids.isEmpty else { throw Failure.emptyBatch }
            guard ids.count <= maxBatch else { throw Failure.batchTooLarge(ids.count) }
            return ["kind": "delete", "ids": ids]
        }

        // MARK: - Pieces

        /// `"x,y"`, refused rather than defaulted.
        ///
        /// A typo silently placing an element at the origin is the same class of
        /// bug as `open_editor`'s line number scrolling to the top of the file:
        /// the element really is on the board, just nowhere the agent meant.
        ///
        /// **Both components must be finite, and that is a crash fix rather
        /// than tidiness.** `Double(String)` accepts `inf`, `nan` and anything
        /// that overflows to infinity — `1e999` is the spelling an agent
        /// reaches by arithmetic rather than by typing. A non-finite coordinate
        /// survives every guard below it and reaches `Host.apply`, where
        /// `JSONSerialization` raises `NSInvalidArgumentException` for a
        /// non-finite `Double`. That is an Objective-C exception, so the `try?`
        /// wrapped around the call cannot catch it and the app dies: one
        /// `whiteboard_add` with `"at": "1e999,0"` was enough. Refused here, in
        /// the one place all three callers go through — the column pre-scan in
        /// `addPlan` reaches this under `try?`, so a guard at a call site would
        /// have left that path carrying the value.
        static func parsePosition(_ raw: String) throws -> (x: Double, y: Double) {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  x.isFinite, y.isFinite
            else { throw Failure.invalidPosition(raw) }
            return (x, y)
        }

        static func normalizedColor(_ raw: String?) throws -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let named = palette[value] {
                return named
            }
            guard value.hasPrefix("#") else { throw Failure.invalidColor(raw) }
            let digits = String(value.dropFirst())
            guard digits.allSatisfy(\.isHexDigit) else { throw Failure.invalidColor(raw) }
            switch digits.count {
            case 6: return "#" + digits
            case 3: return "#" + digits.flatMap { [$0, $0] }
            default: throw Failure.invalidColor(raw)
            }
        }
    }
}
