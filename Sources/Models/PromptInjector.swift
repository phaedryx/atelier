// ABOUTME: Types a stored prompt into a workstream's Coding Agent surface and submits it.
// ABOUTME: User-initiated, unlike AgentNudge: only evidence the agent is mid-turn blocks it.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "prompt-injector")

@MainActor
final class PromptInjector {
    static let shared = PromptInjector()

    /// Set by `ContentView` alongside `AgentNudge.shared.surfaceCache`; the
    /// cache is a `@StateObject` there rather than a singleton.
    weak var surfaceCache: TerminalSurfaceCache?

    /// Whether the agent's reported turn state permits typing.
    ///
    /// `nil` (nothing reported yet) is allowed, where `AgentNudge` refuses it.
    /// A nudge is autonomous typing and needs positive evidence the pane is
    /// interruptible; a stored prompt runs on an explicit user command, and a
    /// freshly spawned agent reports nothing until its first hook event — that
    /// is exactly the pane the user is aiming at, so refusing it would make the
    /// feature fail most often on a new workstream.
    ///
    /// The cost of allowing nil is real: it also covers "hooks aren't reaching
    /// us", where the state stays nil through an entire live turn. In that case
    /// the deferred re-checks below cannot detect a turn starting, so the second
    /// Return can land in a live turn and submit whatever the user typed in the
    /// intervening half-second. That is accepted because this path only runs
    /// when the user just invoked the command on that pane. `canInject` is not
    /// a safety proof; it is a check for *evidence against*.
    nonisolated static func canInject(state: Workstream.AgentStateTracker.AgentRunState?) -> Bool {
        state.map(\.turnHasEnded) ?? true
    }

    /// Whether a prompt can be delivered to `surfaceID` right now: a live
    /// surface must exist, and the agent must not be mid-turn. The palette
    /// gates its stored-prompt commands on this, so a prompt is never offered
    /// where running it would silently do nothing.
    func canDeliver(to surfaceID: UUID) -> Bool {
        guard surfaceCache?.hasLiveSurface(surfaceID) == true else { return false }
        return Self.canInject(state: Workstream.AgentStateTracker.shared.state(forSurface: surfaceID))
    }

    func inject(_ text: String, into surfaceID: UUID) {
        guard let surfaceCache, canDeliver(to: surfaceID) else {
            logger.detailed("Prompt not delivered to \(surfaceID): no live surface, or the agent is mid-turn")
            return
        }

        surfaceCache.typeAndSubmit(text, into: surfaceID) {
            Self.canInject(state: Workstream.AgentStateTracker.shared.state(forSurface: surfaceID))
        }
    }
}
