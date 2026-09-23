// ABOUTME: Parses board.excalidraw into the element model the digest renders.
// ABOUTME: Pure and Foundation-only — no webview, no libghostty, no main actor.

import Foundation

extension Whiteboard {
    /// One element of a board, as the digest reads it.
    ///
    /// **A projection, not Excalidraw's model.** Swift never writes a scene —
    /// the web app is the sole writer, which is the rule that keeps this feature
    /// from becoming a sync engine — so this carries only what a digest line
    /// needs and deliberately cannot round-trip. Anything richer would be a
    /// second model of the scene, and a second model is the thing to avoid.
    struct Element: Equatable {
        /// What the digest calls this element.
        ///
        /// Excalidraw's `rectangle` is the design's `box`; everything else that
        /// has a name keeps it. `.other` keeps `rawType` rather than guessing: a
        /// board carrying a kind this build has never heard of has to say so,
        /// not be rendered as the nearest thing it does know.
        enum Kind: Equatable {
            case box, note, ellipse, diamond, line, arrow, text, stroke, image, other
        }

        /// The `customData` keys. Fixed here, in the **reader**, so that PR 3's
        /// author marker and PR 4's image transcription each have exactly one
        /// spelling to write to — the same reason `IPC.Vocabulary` exists for the
        /// strings two processes share. `customData` is Excalidraw's own
        /// sanctioned extension point (`customData?: Record<string, any>` on
        /// every element).
        static let authorKey = "atelierAuthor"
        static let agentAuthorValue = "agent"
        static let captionKey = "atelierCaption"
        /// How an element was authored, where Excalidraw has no type for it.
        ///
        /// The write vocabulary is box / note / text / arrow, and Excalidraw has
        /// no `note`: one is a rectangle with a distinct background and this
        /// marker. The reader half is not optional — without it a note
        /// round-trips as a box and the vocabulary silently has three kinds
        /// instead of four. An annotation and a diagram node are different
        /// things, and reporting them differently is what lets an agent re-read
        /// its own board and tell its commentary apart from the structure it
        /// drew.
        static let kindKey = "atelierKind"
        static let noteKindValue = "note"

        let id: String
        let kind: Kind
        /// Excalidraw's own `type`, kept so an unknown kind can name itself.
        let rawType: String
        /// The element's own text, or the bound label of the container it sits
        /// on. **Always nil for a stroke and an image**, by construction: those
        /// two are opaque and nothing here may speak for them.
        let text: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        /// An arrow's endpoints, by element id.
        let from: String?
        let to: String?
        /// An image's `fileId`, which **is** its file's name in `assets/`.
        /// `Store.writeAsset` refuses any id it would have had to rewrite, so
        /// there is no mapping table here and no normalisation step.
        let fileID: String?
        /// A stroke's point count — the one honest thing to say about a shape
        /// nothing may transcribe.
        let pointCount: Int?
        /// An agent's transcription of an image, when one has been written.
        let caption: String?
        let isAgentAuthored: Bool
    }

    struct Scene: Equatable {
        let elements: [Element]
    }

    /// What reading `board.excalidraw` produced.
    ///
    /// **Three cases and never two.** A file Atelier cannot read must never
    /// render as "nothing has been drawn here", which is the same sentence an
    /// untouched board gets — the distinction `Verification.Config.Load` draws
    /// between "declares no checks" and "could not be read". It exists because
    /// the two send a reader to completely different places: one to draw
    /// something, the other to a file that is right there and broken.
    ///
    /// Deliberately separate from `Store.loadScene`, which stays two-valued and
    /// must. That one feeds the *page*, where an unreadable scene has to mount
    /// an empty canvas rather than refuse — an empty canvas the user can draw on
    /// beats a blank pane, and the next save replaces it. Here the difference
    /// between the two is the whole answer.
    enum SceneLoad {
        case empty
        case unreadable(reason: String)
        case loaded(Scene)

        static func load(for workstreamID: UUID) -> SceneLoad {
            let url = Store.sceneURL(for: workstreamID)
            guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
            do {
                return try parse(String(contentsOf: url, encoding: .utf8))
            } catch {
                return .unreadable(reason: error.localizedDescription)
            }
        }

        static func parse(_ json: String) -> SceneLoad {
            guard let data = json.data(using: .utf8) else {
                return .unreadable(reason: "the scene file is not valid UTF-8")
            }
            let root: Any
            do {
                root = try JSONSerialization.jsonObject(with: data)
            } catch {
                return .unreadable(reason: error.localizedDescription)
            }
            guard let object = root as? [String: Any] else {
                return .unreadable(reason: "the scene file is not a JSON object")
            }
            guard let raw = object["elements"] as? [[String: Any]] else {
                return .unreadable(reason: "the scene file has no `elements` list")
            }

            let live = raw.filter { ($0["isDeleted"] as? Bool) != true }
            // Built once, not per element: a board is unbounded and this is the
            // one place the whole list is walked twice.
            let bound = labels(in: live)
            // Which containers are really here, so a label whose container is
            // gone is not folded into nothing — see `element(from:…)`.
            let present = Set(live.compactMap { $0["id"] as? String })
            let elements = live.compactMap { element(from: $0, labels: bound, present: present) }
            return elements.isEmpty ? .empty : .loaded(Scene(elements: elements))
        }

        /// Container id → the text bound to it.
        ///
        /// A shape's label is **not** a field on the shape. It is a separate
        /// `text` element carrying `containerId`, and it sits *after* its
        /// container in file order — measured against 0.18.1, on a scene built
        /// through Excalidraw's own `convertToExcalidrawElements`. Folding it in
        /// here is what stops a labelled box rendering as an empty box plus a
        /// floating caption that does not exist anywhere on the user's screen.
        private static func labels(in live: [[String: Any]]) -> [String: String] {
            var labels: [String: String] = [:]
            for element in live {
                guard element["type"] as? String == "text",
                      let container = element["containerId"] as? String,
                      let text = element["text"] as? String
                else { continue }
                labels[container] = text
            }
            return labels
        }

        private static func element(
            from raw: [String: Any],
            labels: [String: String],
            present: Set<String>
        ) -> Element? {
            guard let id = raw["id"] as? String,
                  let rawType = raw["type"] as? String
            else { return nil }
            // A bound label has already been folded into its container; listing
            // it again is the double-rendering this join exists to prevent.
            //
            // **Only when the container is really there.** A `containerId` is
            // a claim about another element, and nothing guarantees it is
            // still true: a scene edited outside Atelier, an older file, or a
            // delete that removed a container without its label leaves a text
            // element that Excalidraw draws on the canvas exactly where it sits
            // — while this skipped it unconditionally, so it vanished from the
            // digest. That is the digest reporting less than the picture holds,
            // which is the one thing the two halves of the read path exist to
            // make impossible. With the container gone there is nothing to fold
            // it into, so it is reported as the ordinary text element it has
            // become.
            if rawType == "text", let container = raw["containerId"] as? String,
               present.contains(container)
            {
                return nil
            }

            let rawKind: Element.Kind = switch rawType {
            case "rectangle": .box
            case "ellipse": .ellipse
            case "diamond": .diamond
            case "line": .line
            case "arrow": .arrow
            case "text": .text
            case "freedraw": .stroke
            case "image": .image
            default: .other
            }

            let customData = raw["customData"] as? [String: Any]
            // Only a rectangle is promoted. The marker names how a rectangle
            // was authored; it is not a way to relabel any element as something
            // else, and honouring it anywhere would let a board rename its own
            // shapes out from under the reader.
            let kind: Element.Kind =
                rawKind == .box && customData?[Element.kindKey] as? String == Element.noteKindValue
                    ? .note : rawKind
            // Strokes and images stay opaque: a bounding box and nothing more.
            // A caption is an agent's own transcription and is reported as one,
            // never as the element's text.
            //
            // **A frame's words are in `name`, not `text`.** It is the one
            // element type Excalidraw labels that way, and a mermaid class
            // diagram with a `namespace` block draws one per namespace. Read
            // through `text` alone it came out as a bare `frame` with its
            // dimensions and nothing saying *which* namespace — a real element,
            // on the canvas, carrying a word the digest could not see. Scoped
            // to `frame` rather than added to the general fallback: `name` is
            // not a field this reader knows the meaning of anywhere else, and
            // honouring it everywhere would be the "relabel any element" rule
            // the note promotion above refuses for the same reason.
            //
            // The kind still reports itself as `frame` through `.other`'s
            // `rawType`. This adds the word, and deliberately does **not** add
            // a `frame` case to the vocabulary: that would be a claim about how
            // a frame's children relate to it, which nothing here reads.
            let text: String? = switch kind {
            case .stroke, .image: nil
            case .other where rawType == "frame": raw["name"] as? String
            default: labels[id] ?? raw["text"] as? String
            }

            return Element(
                id: id,
                kind: kind,
                rawType: rawType,
                text: text,
                x: number(raw["x"]),
                y: number(raw["y"]),
                width: number(raw["width"]),
                height: number(raw["height"]),
                from: (raw["startBinding"] as? [String: Any])?["elementId"] as? String,
                to: (raw["endBinding"] as? [String: Any])?["elementId"] as? String,
                fileID: raw["fileId"] as? String,
                pointCount: (raw["points"] as? [Any])?.count,
                caption: customData?[Element.captionKey] as? String,
                isAgentAuthored: customData?[Element.authorKey] as? String == Element.agentAuthorValue
            )
        }

        /// `as? Double` alone is not enough: `JSONSerialization` hands back an
        /// integral coordinate as an `Int`-backed `NSNumber`, and a board drawn
        /// on a pixel boundary would then read as being at the origin.
        private static func number(_ raw: Any?) -> Double {
            (raw as? NSNumber)?.doubleValue ?? 0
        }
    }
}
