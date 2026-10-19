// ABOUTME: A named group of workstreams under a project; each group gets a coordinator agent.
// ABOUTME: Holds the Group value type and the name rules (trimmed, non-empty, unique per project).

import Foundation

extension Workstream {
    /// A named set of workstreams within one project.
    ///
    /// Identity is `id` alone, the way `Workstream` does it: a rename or a
    /// permissions change is the same group, not a new one.
    struct Group: Identifiable, Hashable, Codable {
        let id: UUID
        var name: String
        var createdAt: Date
        var lastAccessedAt: Date
        var bypassPermissions: Bool

        init(
            name: String,
            bypassPermissions: Bool = false,
            id: UUID = UUID(),
            createdAt: Date = Date(),
            lastAccessedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.bypassPermissions = bypassPermissions
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
        }

        static func == (lhs: Group, rhs: Group) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
}

extension Workstream.Group {
    enum NameRefusal: Error, Equatable {
        case empty
        case taken(String)

        /// The wording shown for a refused name, shared by every field that asks for one.
        var message: String {
            switch self {
            case .empty:
                NSLocalizedString("Group name can't be empty.", comment: "Group name refusal")
            case .taken:
                NSLocalizedString("A group with this name already exists.", comment: "Group name refusal")
            }
        }
    }

    /// Trims, refuses empty, and refuses a name another group in `siblings`
    /// already has. `excluding` is the group being renamed, so keeping its own
    /// name is not a collision. Comparison is exact and case-sensitive.
    static func validateName(
        _ input: String,
        siblings: [Workstream.Group],
        excluding: UUID? = nil
    ) -> Result<String, NameRefusal> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let clash = siblings.contains { $0.id != excluding && $0.name == trimmed }
        return clash ? .failure(.taken(trimmed)) : .success(trimmed)
    }
}

extension Workstream.Group {
    /// The workstream segment of this group's coordinator tmux session:
    /// `group-` and the first eight hex characters of the lowercased id.
    ///
    /// The one spelling, used by `CoordinatorLaunch.plan` (through
    /// `AgentCommand.tmuxWrapped`) and by `Archiver` to kill it. Keyed on the id
    /// rather than the name: `TmuxSession.sanitize` maps only `:`, `.` and
    /// space, so "Q4 audit" and "Q4-audit" shared one session — the second pane
    /// attached to the first coordinator through `new-session -A`, and removing
    /// either killed both — and a rename made Remove kill a name nothing ran
    /// under, leaking the live coordinator. The `group-` prefix keeps it apart
    /// from any workstream's session.
    var coordinatorTmuxSegment: String {
        "group-" + id.uuidString.lowercased().prefix(8)
    }

    /// The full tmux session name `coordinatorTmuxSegment` produces.
    func coordinatorSessionName(projectName: String) -> String {
        TmuxSession.sessionName(project: projectName, workstream: coordinatorTmuxSegment, role: "agent")
    }
}
