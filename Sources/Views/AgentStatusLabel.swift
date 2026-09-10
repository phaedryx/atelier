// ABOUTME: The word and colour of a workstream's agent status line.
// ABOUTME: One decision, shared by the sidebar row and the roster cards.

import SwiftUI

/// What the status line says about an agent, and in what colour.
///
/// Extracted from the two views that render it because they had drifted: the
/// row grew a permission state and a live-session-aware idle that the roster
/// cards never learned about. It is also where the hook channel's health is
/// allowed to override what the tracker believes, which is a rule worth having
/// in one testable place rather than inline in a `switch` inside a `View`.
struct AgentStatusLabel: Equatable {
    /// Localization key, which for English is also the displayed text.
    let key: String
    let color: Color

    var text: LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

extension AgentStatusLabel {
    /// The label for one workstream row, or nil when the row should draw no
    /// status line at all.
    ///
    /// **`channelDown` masks `.working` and `.stalled`, and nothing else.**
    /// Those two are the states held up by the *continued arrival* of hook
    /// events: "still working" means no `Stop` has come in, and `.stalled` is
    /// inferred from absence outright. Neither survives the discovery that the
    /// app has stopped hearing. The rest are positive facts a delivered hook
    /// established — a permission prompt, a finished turn, an idle session —
    /// and losing the channel afterwards does not unmake them. Masking
    /// `.needsAttention(.permission)` would be the worst of it: the agent is
    /// stopped until someone answers, so that is the one row that must keep
    /// asking.
    static func resolve(
        agentState: Workstream.AgentStateTracker.AgentRunState,
        hasLiveSession: Bool,
        channelDown: Bool
    ) -> AgentStatusLabel? {
        if channelDown {
            switch agentState {
            case .working, .stalled:
                // Grey deliberately. The fault is Atelier's own plumbing and
                // nothing is asked of the user, so it must not compete on the
                // colour scale with the states that do want them.
                return AgentStatusLabel(
                    key: NSLocalizedString("No Signal", comment: "Hook events are not reaching the app"),
                    color: .secondary
                )
            case .idle, .needsAttention:
                break
            }
        }

        switch agentState {
        case .working:
            return AgentStatusLabel(key: "Working", color: .blue)
        case .stalled:
            return AgentStatusLabel(key: "Stalled", color: .yellow)
        case .needsAttention(.permission):
            return AgentStatusLabel(key: "Waiting for approval", color: .orange)
        case .needsAttention(.justFinished):
            return AgentStatusLabel(key: "Done", color: .green)
        case .idle where hasLiveSession:
            return AgentStatusLabel(key: "Idle", color: .secondary)
        case .idle:
            return nil
        }
    }

    /// The label for one roster card. A subagent run has only the two states,
    /// and the same channel rule applies to both of them.
    static func resolve(
        runState: Workstream.AgentStateTracker.AgentRun.RunState,
        channelDown: Bool
    ) -> AgentStatusLabel {
        let equivalent: Workstream.AgentStateTracker.AgentRunState = switch runState {
        case .working: .working
        case .stalled: .stalled
        }
        // Never nil for these two: both map to a state that always has a label.
        return resolve(agentState: equivalent, hasLiveSession: true, channelDown: channelDown)
            ?? AgentStatusLabel(key: "Working", color: .blue)
    }
}
