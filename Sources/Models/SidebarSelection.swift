// ABOUTME: Represents the selected item in the sidebar.
// ABOUTME: A project, a workstream or a workstream group, enabling single-selection across all three.

import Foundation

enum SidebarSelection: Hashable, Codable {
    case project(UUID)
    case workstream(UUID)
    /// A workstream group, whose detail pane is its coordinator.
    case group(UUID)
    case settings
    case help

    var projectID: UUID? {
        if case let .project(id) = self {
            return id
        }
        return nil
    }

    var workstreamID: UUID? {
        if case let .workstream(id) = self {
            return id
        }
        return nil
    }

    var groupID: UUID? {
        if case let .group(id) = self {
            return id
        }
        return nil
    }

    /// The id the agent-state tracker treats as "being looked at": a
    /// workstream's own id, or a group's, because a coordinator's state is
    /// keyed by its group id. Without the group half a selected group's idle
    /// coordinator kept reading "just finished".
    var agentStateID: UUID? {
        workstreamID ?? groupID
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "atelier.selection"

    static func loadSaved() -> SidebarSelection? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let selection = try? JSONDecoder().decode(SidebarSelection.self, from: data)
        else { return nil }
        return selection
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }
}

enum SidebarState {
    private static let userDefaultsKey = "atelier.expandedProjects"
    private static let expandedGroupsKey = "atelier.expandedGroups"

    static func loadExpanded() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data)
        else { return [] }
        return ids
    }

    static func saveExpanded(_ ids: Set<UUID>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// Expanded groups, a separate set from expanded projects: a group's
    /// disclosure state is its own, and the two sets are opened by different
    /// things — selection opens a project, creation and selection open a group.
    static func loadExpandedGroups(defaults: UserDefaults = .standard) -> Set<UUID> {
        guard let data = defaults.data(forKey: expandedGroupsKey),
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data)
        else { return [] }
        return ids
    }

    static func saveExpandedGroups(_ ids: Set<UUID>, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        defaults.set(data, forKey: expandedGroupsKey)
    }
}
