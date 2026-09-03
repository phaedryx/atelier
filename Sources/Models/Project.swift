// ABOUTME: Data models for projects and workstreams.
// ABOUTME: Each project has a directory and multiple workstreams, each with its own terminal.

import Foundation

struct Workstream: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var displayName: String?
    var worktreePath: String?
    var bypassPermissions: Bool
    var lastAccessedAt: Date
    /// The Shortcut story this workstream was created from, when it came from one.
    ///
    /// Must stay Optional. The synthesized `init(from:)` calls `decode` — not
    /// `decodeIfPresent` — for a non-Optional property and throws when the key is
    /// absent, so a blob written before this key existed would fail to decode.
    /// That now costs one workstream rather than every project the user has (see
    /// `Project.init(from:)` and `LossyStore`), but a workstream silently
    /// vanishing on upgrade is still not an acceptable price for a stored field.
    var shortcutStoryID: Int?

    init(name: String, displayName: String? = nil, worktreePath: String? = nil, bypassPermissions: Bool = false, id: UUID = UUID(), lastAccessedAt: Date = Date(), shortcutStoryID: Int? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.worktreePath = worktreePath
        self.bypassPermissions = bypassPermissions
        self.lastAccessedAt = lastAccessedAt
        self.shortcutStoryID = shortcutStoryID
    }

    /// The user-facing label. Falls back to the branch-tracked `name` when no override is set.
    var label: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return name
    }

    /// Commit a rename from the user. An empty input or one matching the
    /// branch-tracked `name` clears the override so the label follows the
    /// branch again; anything else becomes the `displayName` override.
    mutating func applyRename(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (trimmed.isEmpty || trimmed == name) ? nil : trimmed
    }

    /// The working directory for this workstream's terminals.
    /// Uses the worktree path if available, otherwise falls back to the project directory.
    func workingDirectory(projectDirectory: String) -> String {
        worktreePath ?? projectDirectory
    }

    static func == (lhs: Workstream, rhs: Workstream) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var directory: String
    var workstreams: [Workstream]
    var lastAccessedAt: Date

    init(name: String, directory: String, id: UUID = UUID(), workstreams: [Workstream] = [], lastAccessedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.directory = directory
        self.workstreams = workstreams
        self.lastAccessedAt = lastAccessedAt
    }

    /// Hand-written for one reason: `workstreams` decodes element by element.
    ///
    /// A workstream the current shape cannot read used to fail the whole project,
    /// and `ProjectStore` then failed the whole list — so one stale record cost
    /// the user every project they had. `encode(to:)` is still synthesized, which
    /// is what keeps `CodingKeys` in step with the properties above.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        directory = try container.decode(String.self, forKey: .directory)
        lastAccessedAt = try container.decode(Date.self, forKey: .lastAccessedAt)
        workstreams = try container.decodeLossyArray(Workstream.self, forKey: .workstreams)
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Project {
    enum SortOrder: String, CaseIterable {
        case recent = "Recent"
        case alphabetical = "A-Z"
    }
}
