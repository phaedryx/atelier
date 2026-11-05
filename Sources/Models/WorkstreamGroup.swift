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
