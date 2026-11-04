// ABOUTME: IPC.Service's workspace reads and the actions that put something on the user's screen.
// ABOUTME: Every one acts on the caller's own workstream and no other.

import Foundation

extension IPC.Service {
    func listTabs(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        let callerSurfaceID = request.client.surfaceID.flatMap(UUID.init(uuidString:))
        let peers = await peersBySurface()
        do {
            let tabs = try await MainActor.run {
                try WorkspaceActions.shared.tabs(
                    workstreamID: workstreamID,
                    callerSurfaceID: callerSurfaceID,
                    peers: peers
                )
            }
            return .success(id: request.id, .tabs(tabs))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func readReviewComments(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        do {
            let comments = try await MainActor.run {
                try WorkspaceActions.shared.reviewComments(workstreamID: workstreamID)
            }
            return .success(id: request.id, .reviewComments(comments))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func openEditor(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        // `line` is optional, but a value that is present and unparseable is
        // a mistake worth reporting rather than silently ignoring — which is
        // `ToolArguments.integer`'s whole contract, rather than something
        // this handler has to remember to spell out.
        let path: String
        let line: Int?
        do {
            let arguments = ToolArguments(request)
            path = try arguments.required("path")
            line = try arguments.integer("line")
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
        do {
            let opened = try await MainActor.run {
                try WorkspaceActions.shared.openEditor(workstreamID: workstreamID, path: path, line: line)
            }
            return .success(id: request.id, .text("Opened \(opened) in the editor."))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// Opens one of the caller's singleton tabs — Changes, Execution,
    /// Verification or Whiteboard — without taking the selection.
    ///
    /// **The answer must never imply the user is now looking at it.** The tab
    /// is opened behind whatever they have in front of them, on purpose, so
    /// an agent that needs their eyes has to ask for them separately with
    /// `request_attention`. Saying "opened" and leaving the rest implied is
    /// how an agent ends up waiting for a reaction to something nobody saw.
    func openTab(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        let kind: String
        do {
            kind = try ToolArguments(request).required("kind")
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
        do {
            let opened = try await MainActor.run {
                try WorkspaceActions.shared.openTab(workstreamID: workstreamID, kind: kind)
            }
            let what = opened.wasAlreadyOpen
                ? "The \(opened.kind) tab was already open."
                : "Opened the \(opened.kind) tab."
            return .success(
                id: request.id,
                .text(what + " It did not take the selection, so the user is still looking at whatever they had "
                    + "in front of them — use request_attention if you need them to come and look.")
            )
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// Closes one of the caller's tabs — a singleton pane by `kind`, or a
    /// terminal tab by `surface_id`. See `WorkspaceActions.closeTab` for
    /// the full contract: exactly one of the two arguments, why closing
    /// Execution stops the dev stack on its way out, and why an id nothing
    /// currently owns is success rather than an error.
    func closeTab(for request: Request) async -> Response {
        let arguments = ToolArguments(request)
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        do {
            let result = try await MainActor.run {
                try WorkspaceActions.shared.closeTab(
                    workstreamID: workstreamID,
                    kind: arguments.optional("kind"),
                    surfaceID: arguments.optional("surface_id")
                )
            }
            let what = switch (result.kind, result.wasOpen) {
            case let (kind?, true):
                "Closed the \(kind) tab."
            case let (kind?, false):
                "The \(kind) tab was already closed."
            case (nil, _):
                "No tab in this workstream has that surface id — it may already be closed."
            }
            return .success(id: request.id, .text(what))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func requestAttention(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        // Sanitized *before* the emptiness check, not after: a reason of
        // nothing but control characters is as absent as no reason at all,
        // and this string is rendered into a notification.
        let reason = Names.sanitized(ToolArguments(request).optional("reason") ?? "", limit: 400, fallback: "")
        guard !reason.isEmpty else {
            return .failure(id: request.id, ToolError.missingArgument("reason").localizedDescription)
        }
        let name = request.client.workstreamName ?? "Atelier"
        let outcome = await MainActor.run {
            Workstream.AttentionNotifier.shared.notify(
                workstreamID: workstreamID,
                workstreamName: name,
                reason: reason
            )
        }
        switch outcome {
        case .success:
            return .success(id: request.id, .text("Notified the user. They may not respond immediately — carry on with anything you can do without them."))
        case let .failure(refusal):
            return .failure(id: request.id, refusal.localizedDescription)
        }
    }
}
