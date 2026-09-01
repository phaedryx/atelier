// ABOUTME: Event types the hook receiver produces from Claude Code hook payloads.
// ABOUTME: Consumed by WorkstreamAgentStateTracker to drive the sidebar roster.

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
}
