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

    /// Why a prompt cannot be delivered to `surfaceID` right now, or `.ready`.
    ///
    /// The palette renders the reason on the row rather than dropping the
    /// command, so a gated prompt reads as gated instead of missing.
    enum Deliverability: Equatable {
        case ready
        /// No live Coding Agent surface to type into.
        case noAgent
        /// The agent is working, so typed input would land in its turn.
        case midTurn
        /// The agent is stopped on a permission prompt, where a synthetic
        /// Return would answer the prompt itself.
        case awaitingPermission

        /// Present-tense wording for why nothing can be typed, or nil when it
        /// can. The palette shows this on a disabled row.
        var reason: String? {
            switch self {
            case .ready:
                nil
            case .noAgent:
                NSLocalizedString(
                    "No Coding Agent is running in this workstream.",
                    comment: "Palette: stored prompt refused, no agent surface"
                )
            case .midTurn:
                NSLocalizedString(
                    "The Coding Agent is mid-turn.",
                    comment: "Palette: stored prompt refused, agent is working"
                )
            case .awaitingPermission:
                NSLocalizedString(
                    "The Coding Agent is waiting on a permission prompt.",
                    comment: "Palette: stored prompt refused, agent is blocked on permission"
                )
            }
        }
    }

    /// The whole decision, as a pure function of the three facts it rests on.
    ///
    /// **`channelDown` masks `.working` and `.stalled`, and nothing else** — the
    /// same rule `AgentStatusLabel` applies to the sidebar's status word, for the
    /// same reason. Both are held up by the *continued arrival* of hook events:
    /// `.working` means no `Stop` has come in, and `.stalled` is inferred from
    /// absence outright. Neither survives learning that the app has stopped
    /// hearing, and `surfaceStates` has no decay path — `sweepForStalls` never
    /// writes it, so a `Stop` dropped by `atelier-hook`'s one-second curl leaves
    /// a surface reading `.working` for the rest of the session. Without this
    /// mask that is a stored prompt the palette refuses forever, silently.
    /// `.needsAttention(.permission)` is *not* masked: it is a positive fact a
    /// delivered hook established, and losing the channel afterwards does not
    /// unmake it — the agent is stopped until someone answers.
    nonisolated static func deliverability(
        state: Workstream.AgentStateTracker.AgentRunState?,
        hasSurface: Bool,
        channelDown: Bool
    ) -> Deliverability {
        guard hasSurface else { return .noAgent }
        if state?.isAwaitingPermission == true {
            return .awaitingPermission
        }
        if channelDown {
            return .ready
        }
        return canInject(state: state) ? .ready : .midTurn
    }

    /// `deliverability` for a live surface, reading the app's current state.
    func deliverability(to surfaceID: UUID) -> Deliverability {
        Self.deliverability(
            state: Workstream.AgentStateTracker.shared.state(forSurface: surfaceID),
            hasSurface: surfaceCache?.hasLiveSurface(surfaceID) == true,
            channelDown: HookChannelProbe.shared.state.isDown
        )
    }

    /// Whether a prompt can be delivered to `surfaceID` right now: a live
    /// surface must exist, and the agent must not be mid-turn.
    func canDeliver(to surfaceID: UUID) -> Bool {
        deliverability(to: surfaceID) == .ready
    }

    func inject(_ text: String, into surfaceID: UUID) {
        let verdict = deliverability(to: surfaceID)
        guard let surfaceCache, verdict == .ready else {
            logger.detailed("Prompt not delivered to \(surfaceID): \(String(describing: verdict))")
            return
        }

        surfaceCache.typeAndSubmit(text, into: surfaceID) {
            PromptInjector.shared.deliverability(to: surfaceID) == .ready
        }
    }
}
