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
/// **Attribution.** `atelier-hook` forwards the `ATELIER_SURFACE_ID` it
/// inherited, so the tracker can answer "has *this pane's* agent finished its
/// turn?" for any agent whose hooks reach Atelier. When a surface has never
/// reported, `resolveState` falls back to the workstream signal for the Coding
/// Agent tab alone — see its doc comment for why that one case is not a guess.
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

    /// The evidence that a given surface may be interrupted, or nil when there
    /// is none.
    ///
    /// Per-surface evidence wins whenever it exists. Falling back to the
    /// workstream signal is allowed for exactly one surface: the Coding Agent
    /// tab, whose id *is* the workstream id (`claudeID == workstreamID`), so
    /// the workstream signal is by construction a statement about that pane.
    /// For any other surface the workstream signal is contaminated by whatever
    /// else is running in the worktree, so no evidence means no nudge.
    static func resolveState(
        surfaceState: WorkstreamAgentStateTracker.AgentRunState?,
        workstreamState: @autoclosure () -> WorkstreamAgentStateTracker.AgentRunState,
        surfaceID: UUID,
        workstreamID: UUID
    ) -> WorkstreamAgentStateTracker.AgentRunState? {
        if let surfaceState { return surfaceState }
        return surfaceID == workstreamID ? workstreamState() : nil
    }

    /// Types a one-line notice into the surface the recipient occupies, if the
    /// workstream reports that a turn has ended.
    ///
    /// A peer whose helper has exited is already gone from the store by the time
    /// this runs — the socket closing retires it — so this cannot type into a
    /// tab whose agent has quit and left a shell at the prompt.
    func nudge(surfaceID: UUID, workstreamID: UUID, senderName: String, waiting: Int, now: Date = Date()) {
        let tracker = WorkstreamAgentStateTracker.shared
        guard let state = Self.resolveState(
            surfaceState: tracker.state(forSurface: surfaceID),
            workstreamState: tracker.state(for: workstreamID),
            surfaceID: surfaceID,
            workstreamID: workstreamID
        ) else { return }

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
