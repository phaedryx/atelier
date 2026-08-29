// ABOUTME: Types an arrival notice into an idle agent's terminal when a message lands.
// ABOUTME: Best-effort by design: the queue is authoritative, this only shortens the wait.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "ipc-nudge")

/// Delivers the optional terminal nudge that accompanies a queued message.
///
/// The mailbox is the contract; this is a courtesy. It fires only when the
/// recipient's turn has actually ended — Claude Code's own `Stop` hook says so,
/// via `WorkstreamAgentStateTracker` — and only into a surface Atelier itself
/// launched, which is the only way it has an address to type into. When it
/// doesn't fire, the message still sits in the inbox, which is why the tool
/// descriptions tell agents to check at natural boundaries.
///
/// **Known limit.** Hook events carry `project_dir`, so the turn-ended signal is
/// per *workstream*, not per surface. With one agent per workstream that is
/// exact. With two agents sharing a worktree it is not: one finishing its turn
/// marks the workstream idle while the other may be mid-thought, so a notice
/// aimed at the second can land mid-turn. Aiming is per-surface; timing is not.
/// Attributing hook events to a surface would take a marker the hook script
/// forwards, which does not exist yet.
@MainActor
final class AgentNudge {
    static let shared = AgentNudge()

    /// Set by `ContentView`; the cache is a `@StateObject` there rather than a
    /// singleton, and nudging needs the live surfaces it owns.
    weak var surfaceCache: TerminalSurfaceCache?

    /// Last nudge per surface, so a burst of messages produces one notice
    /// rather than one per message. Keyed per surface, not per workstream: two
    /// agents sharing a worktree each get their own notice.
    private var lastNudge: [UUID: Date] = [:]

    /// Minimum gap between two nudges to the same surface.
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
        hasSurface: Bool,
        nudgeEnabled: Bool,
        lastNudge: Date?,
        now: Date = Date()
    ) -> Bool {
        guard nudgeEnabled, hasSurface else { return false }
        switch state {
        case .idle, .needsAttention(.justFinished):
            break
        case .working, .stalled, .needsAttention(.permission):
            return false
        }
        if let lastNudge, now.timeIntervalSince(lastNudge) < cooldown { return false }
        return true
    }

    /// Types a one-line notice into the surface the recipient occupies, if the
    /// workstream reports that a turn has ended.
    ///
    /// A peer whose helper has exited is already gone from the store by the time
    /// this runs — the socket closing retires it — so this cannot type into a
    /// tab whose agent has quit and left a shell at the prompt.
    func nudge(surfaceID: UUID, workstreamID: UUID, senderName: String, waiting: Int, now: Date = Date()) {
        let state = WorkstreamAgentStateTracker.shared.state(for: workstreamID)
        guard Self.shouldNudge(
            state: state,
            hasSurface: true,
            nudgeEnabled: AgentIPCSettings.nudgeEnabled,
            lastNudge: lastNudge[surfaceID],
            now: now
        ) else { return }

        guard let surfaceCache else {
            logger.warning("No surface cache; dropping the nudge for \(surfaceID)")
            return
        }

        lastNudge[surfaceID] = now
        let plural = waiting == 1 ? "message" : "messages"
        surfaceCache.sendText(
            to: surfaceID,
            text: "[Atelier] \(senderName) sent you a message. Call receive_messages to read your inbox (\(waiting) \(plural) waiting)."
        )

        // Two stages, both deferred: the first Return confirms the paste the
        // agent's input widget just took, the second submits it. Sending one
        // immediately looks fine by hand and drops input intermittently in use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak surfaceCache] in
            surfaceCache?.sendReturn(to: surfaceID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak surfaceCache] in
                surfaceCache?.sendReturn(to: surfaceID)
            }
        }
    }

    func _testReset() {
        lastNudge.removeAll()
        surfaceCache = nil
    }
}
