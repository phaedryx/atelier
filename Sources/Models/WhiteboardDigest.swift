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
        /// travels as a tool answer rather than as a message. The real
        /// constraint is the reader. The agent is asked to open `board.png` in
        /// the same breath, and 8KB is already roughly two thousand tokens spent
        /// before it has looked at the picture — which is where an unbounded
        /// board belongs.
        static let maxBytes = 8_000

        /// The sentence that stops an agent reading five boxes and concluding
        /// that is the whole board.
        ///
        /// **Required, not decoration**, and charged to the budget *before* a
        /// single element is assembled. A digest that truncates and drops this
        /// is the precise failure the budget exists to report: the reader is
        /// told less than everything and not told that it was.
        static let closingLine =
            "Strokes and images are not transcribed. They are in board.png — open it."

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
            let header = "# Whiteboard — \(scene.elements.count) elements, updated \(updated)"
            let renderLine = line(for: render)

            // Reserved before anything is assembled, the way
            // `VerificationSummary.fitVerdicts` reserves its overflow note.
            // These are what a reader needs *most* when the list has been cut,
            // so they cannot be what the cut takes — and the overflow note's own
            // length depends on the count, so the worst case is charged up front
            // rather than discovered after assembling.
            var reserved = header.utf8.count + 1
            reserved += renderLine.utf8.count + 1
            reserved += 1 // the blank line under the header
            reserved += 1 + closingLine.utf8.count + 1
            reserved += overflowNote(count: scene.elements.count).utf8.count + 1

            var lines: [String] = []
            var spent = 0
            var omitted = 0
            for element in scene.elements {
                let rendered = entry(for: element, assets: assets)
                let cost = rendered.utf8.count + 1
                // `continue`, not `break`: the count has to be the number
                // actually left out, and a later element may still be small
                // enough to fit where this one was not.
                guard spent + cost <= budget - reserved else {
                    omitted += 1
                    continue
                }
                lines.append(rendered)
                spent += cost
            }

            var out = [header, renderLine, ""]
            out.append(contentsOf: lines)
            if omitted > 0 {
                out.append(overflowNote(count: omitted))
            }
            out.append("")
            out.append(closingLine)
            return out.joined(separator: "\n")
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

        private static func overflowNote(count: Int) -> String {
            "… and \(count) more elements, not listed — this digest hit its size budget. "
                + "The whole board is in board.png."
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
