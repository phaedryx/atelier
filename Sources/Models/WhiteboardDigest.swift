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
            let id = element.id
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
                let file = element.fileID.flatMap { assets[$0] }
                    ?? element.fileID.map { "fileId=\($0) (no file in assets/)" }
                    ?? "(no file)"
                line = "\(id)  \(kind)  \(file)  \(at)  \(size)"
            case .arrow:
                let bound = element.from != nil || element.to != nil
                let ends = bound ? "\(element.from ?? "?") → \(element.to ?? "?")" : at
                let label = element.text.map { "  \(quoted($0))" } ?? ""
                line = "\(id)  \(kind)  \(ends)\(label)"
            default:
                let label = element.text.map { "\(quoted($0))  " } ?? ""
                line = "\(id)  \(kind)  \(label)\(at)  \(size)"
            }
            line += author
            if let caption = element.caption {
                line += "\n      caption: \(quoted(caption))"
            }
            return line
        }

        private static func name(of element: Element) -> String {
            switch element.kind {
            case .box: "box"
            case .ellipse: "ellipse"
            case .diamond: "diamond"
            case .line: "line"
            case .arrow: "arrow"
            case .text: "text"
            case .stroke: "stroke"
            case .image: "image"
            // Its own name rather than the nearest thing this build knows: a
            // kind it has never heard of must say so, not be reported as a box.
            case .other: element.rawType
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
        /// because a label is read from the front.
        ///
        /// **Accumulated by `Character`, not cut out of a byte array.** The
        /// obvious byte version — `prefix(n)`, then walk back off any trailing
        /// continuation byte — does not work, and fails in the case it is
        /// written for: stripping continuations leaves the multi-byte scalar's
        /// *lead* byte orphaned, which `String(decoding:)` renders as U+FFFD,
        /// three bytes where the scalar was two. So it produces both the
        /// replacement character it was meant to avoid and the overshoot.
        /// (`VerificationSummary.checkMessage` has that shape today. Leaving it
        /// alone here deliberately: it is another surface with its own tests,
        /// and quietly changing it under this PR is how a fix ships unreviewed.)
        ///
        /// Counting graphemes rather than scalars is `IPC.Names.sanitized`'s
        /// rule and the same one applies: breaking between a base and its
        /// combining mark strands the mark on whatever the template puts next.
        /// The loop stops at the budget, so it costs `maxTextBytes` steps rather
        /// than the length of the label.
        ///
        /// Newlines are flattened because one element is one line here, and a
        /// reader counting lines has to be right.
        private static func quoted(_ raw: String) -> String {
            let flat = raw
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            guard flat.utf8.count > maxTextBytes else { return "\"\(flat)\"" }
            var kept = ""
            var spent = 0
            for character in flat {
                let width = String(character).utf8.count
                guard spent + width <= maxTextBytes else { break }
                kept.append(character)
                spent += width
            }
            return "\"\(kept)…\""
        }

        /// Per-label cap, well under `maxBytes` so that one shape cannot spend
        /// the whole digest and leave every other element unlisted — which would
        /// be truthfully reported and useless.
        private static let maxTextBytes = 240
    }
}
