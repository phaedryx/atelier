// ABOUTME: Event types the hook receiver produces from Claude Code hook payloads.
// ABOUTME: Consumed by Workstream.AgentStateTracker to drive the sidebar roster.

import Foundation

struct AgentEvent: Codable {
    let type: EventType
    let agentId: String
    var name: String?
    var tool: String?
    /// Human-readable description of what the agent is doing right now
    /// (e.g. "Editing Foo.swift"), derived from the tool and its input.
    var activity: String?
    var status: String?
    var parentAgentId: String?
    /// Harness transcript location (Claude Code hook payloads); the tracker
    /// reads context-window usage from its tail.
    var transcriptPath: String?
    /// The Atelier terminal surface the reporting agent runs in, when the hook
    /// inherited `ATELIER_SURFACE_ID`. Deliberately absent from `CodingKeys`:
    /// this is app-internal routing, not part of the bridge protocol the
    /// webview sees.
    var surfaceID: String?

    enum EventType: String, Codable {
        case agentCreated
        case agentRemoved
        case agentStatus
        case agentToolStart
        case agentToolDone
        case agentIdle
        case agentWaiting
        /// A Claude session began in this workstream. Distinct from `agentIdle`,
        /// which ends a *turn*: this ends a whole previous session, so anything
        /// the last one left behind is stale rather than merely finished.
        case agentSessionStarted
        /// A Claude session ended. The only event that reports an agent is gone
        /// rather than between turns.
        case agentSessionEnded
    }

    enum CodingKeys: String, CodingKey {
        case type
        case agentId
        case name
        case tool
        case activity
        case status
        case parentAgentId
        case transcriptPath
    }

    // -- Factory methods --

    static func created(
        agentId: String,
        name: String,
        parentAgentId: String? = nil
    ) -> AgentEvent {
        AgentEvent(type: .agentCreated, agentId: agentId, name: name, parentAgentId: parentAgentId)
    }

    static func removed(agentId: String) -> AgentEvent {
        AgentEvent(type: .agentRemoved, agentId: agentId)
    }

    static func status(agentId: String, status: String, transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentStatus, agentId: agentId, status: status, transcriptPath: transcriptPath)
    }

    static func toolStart(agentId: String, tool: String, activity: String? = nil, transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentToolStart, agentId: agentId, tool: tool, activity: activity, transcriptPath: transcriptPath)
    }

    static func toolDone(agentId: String, transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentToolDone, agentId: agentId, transcriptPath: transcriptPath)
    }

    static func idle(agentId: String, transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentIdle, agentId: agentId, transcriptPath: transcriptPath)
    }

    static func waiting(agentId: String, transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentWaiting, agentId: agentId, transcriptPath: transcriptPath)
    }

    static func sessionStarted(transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentSessionStarted, agentId: "main", transcriptPath: transcriptPath)
    }

    static func sessionEnded(transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentSessionEnded, agentId: "main", transcriptPath: transcriptPath)
    }

    /// Compaction is modelled as a status carrying an activity rather than as a
    /// state of its own: it means the main agent is busy, which `.working`
    /// already says, and a new `AgentRunState` case would ripple into
    /// `turnHasEnded`, both state switches, the stall sweep and every
    /// exhaustive switch in the views to say nothing new.
    static func compacting(transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(
            type: .agentStatus,
            agentId: "main",
            activity: NSLocalizedString("Compacting context", comment: "Agent is compacting its context window"),
            status: "compacting",
            transcriptPath: transcriptPath
        )
    }

    static func compacted(transcriptPath: String? = nil) -> AgentEvent {
        AgentEvent(type: .agentStatus, agentId: "main", status: "compacted", transcriptPath: transcriptPath)
    }
}
