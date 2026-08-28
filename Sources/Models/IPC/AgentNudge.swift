// ABOUTME: Types an arrival notice into an idle agent's terminal when a message lands.
// ABOUTME: Best-effort by design: the queue is authoritative, this only shortens the wait.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "ipc-nudge")

/// Delivers the optional terminal nudge that accompanies a queued message.
///
/// The mailbox is the contract; this is a courtesy. It fires only when the
/// recipient's turn has actually ended — Claude Code's own `Stop` hook says so,
/// via `WorkstreamAgentStateTracker` — and only into the Coding Agent surface,
/// never a terminal tab where the user happens to be running an agent by hand.
/// When it doesn't fire, the message still sits in the inbox, which is why the
/// tool descriptions tell agents to check at natural boundaries.
@MainActor
final class AgentNudge {
    static let shared = AgentNudge()

    /// Set by `ContentView`; the cache is a `@StateObject` there rather than a
    /// singleton, and nudging needs the live surfaces it owns.
    weak var surfaceCache: TerminalSurfaceCache?

    /// Last nudge per workstream, so a burst of messages produces one notice
    /// rather than one per message.
    private var lastNudge: [UUID: Date] = [:]

    /// Minimum gap between two nudges to the same workstream.
    static let cooldown: TimeInterval = 5

    /// Whether a nudge is allowed right now. Pure, so the policy is testable
    /// without a terminal.
    ///
    /// `.idle` and `.needsAttention(.justFinished)` are the same fact seen from
    /// two places — the tracker reports the first for the workstream the user is
    /// looking at and the second for the rest. Anything else means the agent is
    /// mid-turn, waiting on a permission prompt, or stalled without having
    /// ended its turn, and typing into any of those lands text in the middle of
    /// someone's work.
    static func shouldNudge(
        state: WorkstreamAgentStateTracker.AgentRunState,
        isAgentSurface: Bool,
        nudgeEnabled: Bool,
        lastNudge: Date?,
        now: Date = Date()
    ) -> Bool {
        guard nudgeEnabled, isAgentSurface else { return false }
        switch state {
        case .idle, .needsAttention(.justFinished):
            break
        case .working, .stalled, .needsAttention(.permission):
            return false
        }
        if let lastNudge, now.timeIntervalSince(lastNudge) < cooldown { return false }
        return true
    }

    /// Types a one-line notice into the recipient's agent surface, if it is at a
    /// prompt. The surface id is the workstream id — see `claudeID`.
    func nudge(workstreamID: UUID, senderName: String, waiting: Int, now: Date = Date()) {
        let state = WorkstreamAgentStateTracker.shared.state(for: workstreamID)
        guard Self.shouldNudge(
            state: state,
            isAgentSurface: true,
            nudgeEnabled: AgentIPCSettings.nudgeEnabled,
            lastNudge: lastNudge[workstreamID],
            now: now
        ) else { return }

        guard let surfaceCache else {
            logger.warning("No surface cache; dropping the nudge for \(workstreamID)")
            return
        }

        lastNudge[workstreamID] = now
        let plural = waiting == 1 ? "message" : "messages"
        surfaceCache.sendText(
            to: workstreamID,
            text: "[Atelier] \(senderName) sent you a message. Call receive_messages to read your inbox (\(waiting) \(plural) waiting)."
        )

        // Two stages, both deferred: the first Return confirms the paste the
        // agent's input widget just took, the second submits it. Sending one
        // immediately looks fine by hand and drops input intermittently in use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak surfaceCache] in
            surfaceCache?.sendReturn(to: workstreamID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak surfaceCache] in
                surfaceCache?.sendReturn(to: workstreamID)
            }
        }
    }

    func _testReset() {
        lastNudge.removeAll()
        surfaceCache = nil
    }
}
