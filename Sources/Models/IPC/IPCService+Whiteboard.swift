// ABOUTME: IPC.Service's whiteboard read and its three writes.
// ABOUTME: Validation lives in Whiteboard.Write; this is the boundary and the wording.

import Foundation

extension IPC.Service {
    // MARK: - Whiteboard

    /// The caller's own board, as text plus a path to its picture.
    ///
    /// **Nothing here can fail with an error, and that is the point.** Every
    /// state a board can be in — never drawn on, drawn on and rendered,
    /// drawn on with a render that is behind, a scene file that will not
    /// parse — is a sentence rather than a refusal. An empty board is the
    /// first state every workstream is in, and answering it with an error
    /// would send an agent looking for a fault that is not there; the one
    /// state that *is* a fault says so in different words, the distinction
    /// `Verification.Config.Load` draws and for the same reason.
    ///
    /// Generated fresh rather than read back from `board.md`: the age and
    /// the staleness verdict are both answers to "right now", and a file
    /// cannot hold either.
    ///
    /// **No main-actor hop and no webview.** `Whiteboard.Store` is plain
    /// file IO, so a board whose tab has never been opened in this launch
    /// still reads, from whatever the last one saved.
    func readWhiteboard(for request: Request) -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        return .success(
            id: request.id,
            .text(Whiteboard.Store.digestText(for: workstreamID, now: Date()))
        )
    }

    /// The sentence every write ends with.
    ///
    /// An agent that reads "opened" as "they are looking at it" waits for a
    /// reaction nobody had — the same thing `open_tab` says, for the same
    /// reason, and the reason `request_attention` is named in it.
    private static let whiteboardTabNote =
        " The Whiteboard tab is open, but this did not take the selection, so the user is "
            + "still looking at whatever they had in front of them — use request_attention if "
            + "you need them to come and look."

    func whiteboardAdd(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        let elements: String
        do {
            elements = try ToolArguments(request).required("elements")
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
        do {
            let added = try await WorkspaceActions.shared.whiteboardAdd(
                workstreamID: workstreamID,
                elementsJSON: elements
            )
            // **A write can land and still not be what was asked for**, and
            // the note is the only thing that says so. A mermaid diagram of
            // a type the converter should expand can be degraded by its own
            // try/catch into one flat image — the board changed, so this is
            // not a refusal, but "Added 1 element" describes a picture as
            // though it were the boxes this tool promises. It goes before
            // the tab note, because it is about what is on the board rather
            // than about where to look at it.
            return .success(id: request.id, .text(
                Self.whiteboardAddText(added)
                    + (added.note.map { " \($0)" } ?? "")
                    + Self.whiteboardTabNote
            ))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// What `whiteboard_add` says it drew, and where.
    ///
    /// **The geometry is here because auto-sizing without it is strictly worse
    /// than the fixed size it replaced.** A box is now drawn at the size of its
    /// label, so a caller that is told only the ids no longer knows how wide
    /// anything is — a known-bad constant traded for an unknown one, and manual
    /// placement made harder rather than easier. Naming each rectangle is what
    /// makes the sizing pay for itself.
    ///
    /// The two arms are worded differently on purpose. An `elements` caller
    /// named each element and holds each id, so a line each is proportionate to
    /// what it asked for. A `mermaid` caller named a *diagram*; twenty lines for
    /// twenty nodes it did not choose would spend the whole answer describing
    /// something nobody asked about, and the one number it actually wants — how
    /// big the diagram came out — would be buried in it. That number is the
    /// `read_whiteboard` round trip this retires.
    static func whiteboardAddText(_ added: Whiteboard.Added) -> String {
        let count = added.ids.count
        let opening = "Added \(count) element\(count == 1 ? "" : "s")"
        // Named whatever the geometry did: the ids are true either way, and an
        // answer that withheld them because a measurement was missing would
        // fail the caller over the part it did not ask about.
        let named = added.ids.isEmpty ? "." : ": " + added.ids.joined(separator: ", ") + "."
        let body: String
        switch added.arm {
        case .elements:
            let rects = added.rects
            body = rects.isEmpty
                ? named
                : ":\n" + rects
                .map { "  \($0.id) at \($0.rect.atText), \($0.rect.sizeText)" }
                .joined(separator: "\n")
        case .mermaid:
            body = named + (added.bounds.map {
                " The diagram occupies \($0.sizeText) from \($0.atText)."
            } ?? "")
        }
        return opening + body + (added.boardText.map { "\n\($0)" } ?? "")
    }

    func whiteboardUpdate(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        let arguments = ToolArguments(request)
        let id: String
        do {
            id = try arguments.required("id")
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
        do {
            let updated = try await WorkspaceActions.shared.whiteboardUpdate(
                workstreamID: workstreamID,
                id: id,
                at: arguments.optional("at"),
                // `raw`, not `optional`: an empty string is how a label is
                // cleared, and `optional` reads empty as absent.
                text: arguments.raw["text"],
                color: arguments.optional("color"),
                // `raw` for the same reason `text` uses it: an empty string
                // is how a transcription is cleared, and `optional` reads
                // empty as absent.
                caption: arguments.raw["caption"]
            )
            return .success(
                id: request.id,
                .text("Updated \(updated)." + Self.whiteboardTabNote)
            )
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func whiteboardDelete(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        let ids = ToolArguments(request).list("ids")
        do {
            let removed = try await WorkspaceActions.shared.whiteboardDelete(
                workstreamID: workstreamID,
                ids: ids
            )
            // What was really there. An id already gone is success and is
            // simply not listed, which is what makes this replayable.
            let count = removed.count
            let what = removed.isEmpty
                ? "Nothing to remove — none of those ids are on the board."
                : "Removed \(count) element\(count == 1 ? "" : "s"): "
                + removed.joined(separator: ", ") + "."
            return .success(id: request.id, .text(what + Self.whiteboardTabNote))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }
}
