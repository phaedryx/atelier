// ABOUTME: Workstream.Group, the optional named color that marks related workstreams.
// ABOUTME: A fixed palette of seven; the raw value is the name stored and sent over IPC.

import Foundation

extension Workstream {
    /// An optional label on a workstream, one of seven named colors, so related
    /// workstreams can be recognised at a glance in the sidebar and over agent IPC.
    ///
    /// A group is only the color. It is not #235's group record (a `groupID`
    /// UUID pointing at a named, user-managed entity), which #239 reverted:
    /// nothing is created, renamed or deleted, and two workstreams share a group
    /// exactly when they carry the same name.
    ///
    /// Case order is the order the picker lists them in; do not reorder.
    enum Group: String, Codable, CaseIterable, Sendable {
        case red, orange, yellow, green, blue, purple, gray
    }
}

extension Workstream.Group {
    /// A lock-guarded, `nonisolated` read of every workstream's current group,
    /// kept in step with `ProjectList.items`.
    ///
    /// It exists because `IPC.Service` is an actor answering real socket
    /// requests and cannot hop to the main actor to ask a `Project` for a
    /// group: a `MainActor.run` inside a reply once deadlocked `IPCServerTests`,
    /// which block the main thread in `recv()` waiting for that very reply. A
    /// lock around a dictionary keeps the read synchronous and isolation-free,
    /// the same shape as `UserPromptClock` in `WorkstreamAgentStateTracker.swift`.
    ///
    /// It is fed by `didSet` on `ProjectList.items`, not `.onChange(of: items)`.
    /// `Project` and `Workstream` equate by id, so a group change leaves every
    /// id in place and `onChange` never fires. Writes come only from MainActor
    /// code; `sync(_:)` replaces the whole map, so a removed workstream stops
    /// reporting a group.
    final class Mirror: @unchecked Sendable {
        nonisolated static let shared = Mirror()

        private let lock = NSLock()
        private var groups: [UUID: Workstream.Group] = [:]

        /// Replaces the whole map with the groups in `projects`.
        func sync(_ projects: [Project]) {
            var next: [UUID: Workstream.Group] = [:]
            for project in projects {
                for workstream in project.workstreams {
                    if let group = workstream.group {
                        next[workstream.id] = group
                    }
                }
            }
            lock.lock(); defer { lock.unlock() }
            groups = next
        }

        /// Sets or clears one workstream's group, for tests that have no `Project`.
        func sync(workstreamID: UUID, group: Workstream.Group?) {
            lock.lock(); defer { lock.unlock() }
            groups[workstreamID] = group
        }

        func group(forWorkstream id: UUID) -> Workstream.Group? {
            lock.lock(); defer { lock.unlock() }
            return groups[id]
        }
    }
}
