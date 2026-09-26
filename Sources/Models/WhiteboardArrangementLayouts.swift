// ABOUTME: The three closed layouts — small multiples, lanes, before/after — and their entry point.
// ABOUTME: Placement is exact arithmetic here; nothing is left for the page to decide.

import Foundation

extension Whiteboard.Arrangement {
    // MARK: - Entry point

    /// Routes one `whiteboard_add_layout` call to the layout that draws it.
    ///
    /// Answers `[Write.Skeleton]` — the same array `Whiteboard.Write.addPlan`
    /// answers — so the caller sends it through the existing `{"kind": "add"}`
    /// op and the page needs no new arm. See the namespace's own note.
    ///
    /// **Ids are minted here**, which is what lets each layout wire its own
    /// arrows: the arrangement already holds every id it made, so it never
    /// needs to name an element by a batch-local reference the way a
    /// hand-written batch does.
    static func plan(
        layout raw: String,
        content json: String,
        live: Whiteboard.Write.Live,
        mint: @escaping () -> String = Whiteboard.Write.mintID
    ) throws -> [Whiteboard.Write.Skeleton] {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = Kind(rawValue: name) else { throw Failure.unknownLayout(raw) }

        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.malformedContent("this layout takes — it must be a JSON object") }

        // Placed below whatever is already on the board, the rule an unplaced
        // element already follows. An arrangement is never dropped on top of
        // the user's diagram, which reads perfectly well in the digest and
        // ruins the picture.
        let origin = (x: live.layout.originX, y: live.layout.nextY)

        switch kind {
        case .smallMultiples: return try smallMultiples(object, at: origin, mint: mint)
        case .lanes: return try lanes(object, at: origin, mint: mint)
        case .beforeAfter: return try beforeAfter(object, at: origin, mint: mint)
        }
    }

    // MARK: - Small multiples

    /// The same diagram redrawn per state, with one node highlighted in each.
    ///
    /// **Every frame draws the same nodes in the same order at the same offsets
    /// within its frame.** That is not an implementation convenience — it is
    /// the form: small multiples work because the eye holds one layout constant
    /// and reads the difference. A frame allowed its own node list would be
    /// three unrelated diagrams in a row, which is what `before_after` is for.
    ///
    /// Frames march left to right and **wrap to a second row** past the width
    /// budget, which is the one place wrapping is the right answer: frames are
    /// unordered in space, so a grid of them reads as readily as a row.
    static func smallMultiples(
        _ content: [String: Any],
        at origin: (x: Double, y: Double),
        mint: @escaping () -> String
    ) throws -> [Whiteboard.Write.Skeleton] {
        let nodes = try labels(content, "nodes")
        guard let rawFrames = content["frames"] as? [Any], !rawFrames.isEmpty else {
            throw content["frames"] == nil
                ? Failure.missingField("frames") : Failure.emptyField("frames")
        }
        let accent = try accentColour(content)

        // A frame is its title plus one row per node.
        let frameRows = nodes.count + 1
        let frameHeight = Double(frameRows) * rowStride - gap
        let frameStride = columnWidth + groupGap
        let perRow = columnsThatFit(spacing: groupGap)
        let rows = Int(ceil(Double(rawFrames.count) / Double(perRow)))
        let totalHeight = Double(rows) * (frameHeight + groupGap) - groupGap
        guard totalHeight <= maxEdge else {
            // Height is what runs away here — frames wrap, so width never does
            // — and the caller trades node count against frame count to get it
            // back. Both are named.
            let rowsThatFit = max(1, Int((maxEdge + groupGap) / (frameHeight + groupGap)))
            throw Failure.tooManyFrames(
                frames: rawFrames.count, fit: rowsThatFit * perRow, nodes: nodes.count
            )
        }

        var out: [Whiteboard.Write.Skeleton] = []
        for (index, rawFrame) in rawFrames.enumerated() {
            guard let frame = rawFrame as? [String: Any] else {
                throw Failure.malformedContent("`frames` takes — each frame must be an object")
            }
            let title = try checked(string(frame, "title") ?? "")
            let highlight = string(frame, "highlight")
            if let highlight, !nodes.contains(highlight) {
                throw Failure.unknownNode(highlight, known: nodes)
            }

            let column = index % perRow
            let row = index / perRow
            let x = origin.x + Double(column) * frameStride
            let top = origin.y + Double(row) * (frameHeight + groupGap)

            // The title is a note, not a bare `text` element — see `noBareText`.
            if !title.isEmpty {
                out.append(container(title, at: (x, top), isNote: true, mint: mint))
            }

            var ids: [String] = []
            for (offset, node) in nodes.enumerated() {
                let y = top + Double(offset + 1) * rowStride
                let skeleton = container(
                    node,
                    at: (x, y),
                    isNote: false,
                    emphasise: node == highlight ? accent : nil,
                    mint: mint
                )
                out.append(skeleton)
                ids.append(skeleton.id)
            }
            // Consecutive chain only. Arbitrary topology in a vertical stack
            // means arrows curving past the boxes between their endpoints,
            // which is a collision this cannot prevent — that diagram belongs
            // in the primitives.
            for pair in zip(ids, ids.dropFirst()) {
                out.append(connector(from: pair.0, to: pair.1, mint: mint))
            }
        }
        return out
    }

    // MARK: - Lanes

    /// Actors as rows, time as columns.
    ///
    /// **Past the width budget this BANDS rather than refusing**, and the
    /// distinction matters because banding is not wrapping. The objection to
    /// wrapping a time axis is that the reader takes column N+1 as adjacent to
    /// column N when it is really below and to the left. Three things defeat
    /// that here, and all three are load-bearing — remove any one and this
    /// becomes the wrap it is accused of being:
    ///
    /// - **Lane labels are repeated in every band**, so each band is a complete
    ///   swimlane rather than a continuation fragment.
    /// - **Step boxes are numbered**, so continuity is carried by the number
    ///   rather than by adjacency.
    /// - **No arrow crosses a band boundary.** Nothing on the canvas asserts an
    ///   adjacency that is not true — and a cross-band arrow would be a long
    ///   diagonal over the intervening rows, a collision this cannot prevent.
    ///
    /// It bands rather than refusing because refusing tops `lanes` out at five
    /// steps, which is below the four-actors-by-eight-steps case the layout
    /// exists for, and a tool that refuses its own worked example is not a tool.
    ///
    /// **Banding is still capped.** Unbounded bands would recreate the sprawl
    /// this whole tool exists to stop, rotated ninety degrees: the width budget
    /// stays satisfied while the board grows past `maxEdge` downward, and
    /// `board.png` is downscaled just the same. So the band count is bounded by
    /// the same budget, and past it this refuses naming how many steps fit.
    static func lanes(
        _ content: [String: Any],
        at origin: (x: Double, y: Double),
        mint: @escaping () -> String
    ) throws -> [Whiteboard.Write.Skeleton] {
        let actors = try labels(content, "actors")
        guard let rawSteps = content["steps"] as? [Any], !rawSteps.isEmpty else {
            throw content["steps"] == nil
                ? Failure.missingField("steps") : Failure.emptyField("steps")
        }

        // One column is spent on the lane gutter, in every band.
        let perBand = max(1, columnsThatFit() - 1)
        let bandHeight = Double(actors.count) * rowStride - gap
        let bandStride = bandHeight + bandGap
        let maxBands = max(1, Int((maxEdge + bandGap) / bandStride))
        let fit = maxBands * perBand
        guard rawSteps.count <= fit else {
            throw Failure.tooManySteps(steps: rawSteps.count, fit: fit, actors: actors.count)
        }

        var out: [Whiteboard.Write.Skeleton] = []
        let bands = Int(ceil(Double(rawSteps.count) / Double(perBand)))

        // Lane labels, repeated per band. Notes rather than bare `text`, so
        // their width is clamped — see `noBareText`, where a 67-character
        // actor name was measured at 665px on one unwrapped line.
        for band in 0 ..< bands {
            let top = origin.y + Double(band) * bandStride
            for (row, actor) in actors.enumerated() {
                let y = top + Double(row) * rowStride
                out.append(container(actor, at: (origin.x, y), isNote: true, mint: mint))
            }
        }

        // Step boxes, and the arrows within each band.
        var previousInBand: String?
        for (index, rawStep) in rawSteps.enumerated() {
            guard let step = rawStep as? [String: Any] else {
                throw Failure.malformedContent("`steps` takes — each step must be an object")
            }
            // An arrangement does not label its arrows, and saying so is worth
            // more than ignoring the field: an agent whose labels vanished has
            // learned nothing.
            if step["label"] != nil || step["edge"] != nil {
                throw Failure.edgeLabelsRefused
            }

            guard let actor = string(step, "actor") else { throw Failure.missingField("actor") }
            guard let name = actors.firstIndex(of: actor) else {
                throw Failure.unknownActor(actor, known: actors)
            }
            guard let text = string(step, "text") else { throw Failure.missingField("text") }
            // Checked against a cap reduced by the step number this composes on
            // to the front. The number is part of what renders, so it has to be
            // part of what is bounded — the alternative is a label that passes
            // the cap and overruns its row anyway.
            guard text.count <= stepLabelCap else {
                throw Failure.labelTooLong(text, limit: stepLabelCap)
            }

            let band = index / perBand
            let column = index % perBand
            if column == 0 {
                previousInBand = nil
            }

            let x = origin.x + Double(column + 1) * columnStride
            let y = origin.y + Double(band) * bandStride + Double(name) * rowStride
            let skeleton = container(
                "\(index + 1) \(text)", at: (x, y), isNote: false, mint: mint
            )
            out.append(skeleton)
            if let previous = previousInBand {
                out.append(connector(from: previous, to: skeleton.id, mint: mint))
            }
            previousInBand = skeleton.id
        }
        return out
    }

    /// `labelCap`, less the room a step number takes.
    ///
    /// Four characters covers `"99 "` with a character to spare; a lane
    /// diagram cannot reach three digits, because `maxEdge` caps it long
    /// before that.
    static let stepLabelCap = labelCap - 4

    // MARK: - Before / after

    /// Two diagrams side by side.
    ///
    /// Distinct from `small_multiples` — which repeats *one* node list — because
    /// the two sides hold different nodes; that difference is the whole content
    /// of the form. Collapsing the two layouts into "frames that may carry their
    /// own nodes" would save a case and lose the constraint that makes small
    /// multiples readable.
    ///
    /// Two columns always fit the width budget with room to spare, so the only
    /// bound here is height.
    static func beforeAfter(
        _ content: [String: Any],
        at origin: (x: Double, y: Double),
        mint: @escaping () -> String
    ) throws -> [Whiteboard.Write.Skeleton] {
        let accent = try accentColour(content)
        var out: [Whiteboard.Write.Skeleton] = []

        for (offset, side) in ["before", "after"].enumerated() {
            guard let object = content[side] as? [String: Any] else {
                throw Failure.missingField(side)
            }
            let nodes = try labels(object, "nodes")
            let title = try checked(string(object, "title") ?? side)
            let highlighted = Set((object["highlight"] as? [Any])?
                .compactMap { $0 as? String } ?? [])
            for name in highlighted where !nodes.contains(name) {
                throw Failure.unknownNode(name, known: nodes)
            }

            // A title row plus one row per node.
            let rows = nodes.count + 1
            guard Double(rows) * rowStride - gap <= maxEdge else {
                throw Failure.columnTooTall(
                    nodes: nodes.count, fit: Int((maxEdge + gap) / rowStride) - 1
                )
            }

            let x = origin.x + Double(offset) * (columnWidth + groupGap)
            out.append(container(title, at: (x, origin.y), isNote: true, mint: mint))

            var ids: [String] = []
            for (row, node) in nodes.enumerated() {
                let y = origin.y + Double(row + 1) * rowStride
                let skeleton = container(
                    node,
                    at: (x, y),
                    isNote: false,
                    emphasise: highlighted.contains(node) ? accent : nil,
                    mint: mint
                )
                out.append(skeleton)
                ids.append(skeleton.id)
            }
            for pair in zip(ids, ids.dropFirst()) {
                out.append(connector(from: pair.0, to: pair.1, mint: mint))
            }
        }
        return out
    }

    // MARK: - Content pieces

    /// A required list of labels, each one checked against the cap.
    private static func labels(_ content: [String: Any], _ field: String) throws -> [String] {
        guard let raw = content[field] as? [Any] else { throw Failure.missingField(field) }
        let names = raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw Failure.emptyField(field) }
        return try names.map(checked)
    }

    /// An optional string field, absent for empty — the rule
    /// `Whiteboard.Write.asks` states, so one serializer that writes every key
    /// of its struct is not refused here and accepted there.
    private static func string(_ content: [String: Any], _ field: String) -> String? {
        guard let value = content[field] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// The emphasis colour, normalized through the palette the primitives use.
    ///
    /// Routed through `Whiteboard.Write.normalizedColor` rather than read as
    /// hex, so `"red"` means the same thing on this tool as on `whiteboard_add`
    /// — one colour vocabulary, and an agent that learned it once has learned
    /// it here.
    private static func accentColour(_ content: [String: Any]) throws -> String {
        guard let raw = content["color"] as? String, !raw.isEmpty else { return defaultEmphasis }
        let normalized = try Whiteboard.Write.normalizedColor(raw)
        // A colour with no emphasis pair falls back to the default pair rather
        // than being refused: the caller asked for emphasis and naming an
        // off-palette hex should not lose them the layout.
        return emphasis[normalized ?? ""] != nil ? normalized! : defaultEmphasis
    }
}
