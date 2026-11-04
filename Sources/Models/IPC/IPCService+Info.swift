// ABOUTME: IPC.Service's Info-tab reads and the per-workstream session checkpoint.
// ABOUTME: Setup state and the Shortcut story are the two facts an agent cannot get another way.

import Foundation

extension IPC.Service {
    // MARK: - The Info tab's two reads

    /// What initialization last reported for the caller's own workstream.
    ///
    /// No `MainActor.run` around the whole thing: that closure is
    /// synchronous and this needs two awaits — the workstream lookup on the
    /// main actor and the state read on `Initialization.Runner`, which is
    /// its own actor and is reachable from here directly.
    func getInitializationState(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        do {
            let info = try await WorkspaceActions.shared.initializationState(workstreamID: workstreamID)
            return .success(id: request.id, .initialization(info))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// The Shortcut story the caller's workstream was created for.
    ///
    /// The four ways to have no story are `WorkspaceActions`' to word and
    /// each arrives as a `.success` carrying an `unavailableReason`, not as
    /// a failure: "this workstream has no story" is an answer, not a refusal.
    func getShortcutStory(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        do {
            let info = try await WorkspaceActions.shared.shortcutStory(workstreamID: workstreamID)
            return .success(id: request.id, .shortcutStory(info))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    // MARK: - Session checkpoint

    /// Reads the caller's workstream's saved checkpoint.
    ///
    /// **No `MainActor` hop.** Unlike `listTabs`/`readReviewComments`, which
    /// route through `WorkspaceActions` because they need the live app
    /// environment, this is a plain `UserDefaults` read reachable directly
    /// from this actor.
    ///
    /// **"Never saved" and "saved" are different sentences**, not the same
    /// empty answer dressed up two ways — the same three-case discipline
    /// `Verification.Config.Load` applies to its own file: a state an agent
    /// could mistake for "nothing to report" must say plainly that nothing
    /// has been recorded yet, so it knows to write one rather than assume
    /// there was never anything worth saving.
    func getSessionCheckpoint(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let checkpoint = IPC.CheckpointStore.read(for: workstreamID) else {
            return .success(id: request.id, .text(
                "No checkpoint saved yet for this workstream. Call update_session_checkpoint "
                    + "before finishing a task, or at any milestone worth resuming from."
            ))
        }
        let secondsAgo = Int(Date().timeIntervalSince(checkpoint.updatedAt))
        return .success(id: request.id, .text("Checkpoint from \(secondsAgo)s ago:\n\n\(checkpoint.content)"))
    }

    /// Overwrites the caller's workstream's checkpoint.
    ///
    /// **Shared per workstream, not per agent** — see `IPC.CheckpointStore`'s
    /// doc comment. Two agents in one workstream read and write the same
    /// blob, and the tool's own description says so.
    func updateSessionCheckpoint(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        do {
            let content = try ToolArguments(request).nonEmpty("content")
            try IPC.CheckpointStore.save(content, for: workstreamID)
            return .success(id: request.id, .text("Checkpoint saved."))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }
}
