// ABOUTME: DTOs and error type for the Shortcut REST API.
// ABOUTME: Decoding and status mapping live here; the transport lives in ShortcutClient.

import Foundation

/// A story, as returned by `GET /api/v3/stories/{public-id}`.
///
/// Only the fields the app renders are decoded; the real payload is far larger.
struct ShortcutStory: Codable, Equatable {
    let id: Int
    let name: String
    let description: String?
    let appURL: String
    /// Shortcut's own suggested branch name, e.g. `tadthorley/sc-17411/some-title`.
    /// The app uses this verbatim — it never builds or slugifies a branch name itself.
    let branchName: String
    let workflowStateID: Int
    /// "feature", "bug", or "chore". Optional so a payload without it still decodes.
    let storyType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case appURL = "app_url"
        case branchName = "formatted_vcs_branch_name"
        case workflowStateID = "workflow_state_id"
        case storyType = "story_type"
    }
}

/// A workflow and its states. Stories carry only `workflow_state_id`, so resolving a
/// human-readable state name needs this separate lookup.
struct ShortcutWorkflow: Codable, Equatable {
    let id: Int
    let name: String
    let states: [State]

    struct State: Codable, Equatable {
        let id: Int
        let name: String
        let type: String
    }
}

extension Collection where Element == ShortcutWorkflow {
    /// A state id is unique across the workspace, not per workflow, so this searches all of them.
    func stateName(for stateID: Int) -> String? {
        for workflow in self {
            if let match = workflow.states.first(where: { $0.id == stateID }) {
                return match.name
            }
        }
        return nil
    }
}

/// The member the API token belongs to. Used only by the Settings "Test" button, so a
/// successful check can name who the key authenticates as.
struct ShortcutMember: Codable, Equatable {
    let name: String
    let mentionName: String
    let workspaceName: String

    enum CodingKeys: String, CodingKey {
        case name
        case mentionName = "mention_name"
        case workspace2
    }

    private enum WorkspaceKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        mentionName = try container.decode(String.self, forKey: .mentionName)
        let workspace = try container.nestedContainer(keyedBy: WorkspaceKeys.self, forKey: .workspace2)
        workspaceName = try workspace.decode(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(mentionName, forKey: .mentionName)
        var workspace = container.nestedContainer(keyedBy: WorkspaceKeys.self, forKey: .workspace2)
        try workspace.encode(workspaceName, forKey: .name)
    }
}

enum ShortcutError: Error, Equatable {
    /// No API token is stored. Distinct from `.unauthorized` so the UI can point at Settings
    /// rather than implying the key is wrong.
    case noToken
    case unauthorized
    case notFound
    case http(Int)
    case transport(String)
    case decoding

    /// Maps an HTTP status to an error, or nil when the response succeeded.
    static func forStatus(_ code: Int) -> ShortcutError? {
        switch code {
        case 200 ..< 300: return nil
        case 401, 403: return .unauthorized
        case 404: return .notFound
        default: return .http(code)
        }
    }

    var message: String {
        switch self {
        case .noToken:
            return NSLocalizedString("No Shortcut API token. Add one in Settings > Integrations.", comment: "Shortcut error")
        case .unauthorized:
            return NSLocalizedString("Shortcut rejected the API token.", comment: "Shortcut error")
        case .notFound:
            return NSLocalizedString("No such Shortcut story.", comment: "Shortcut error")
        case let .http(code):
            return String(format: NSLocalizedString("Shortcut returned HTTP %d.", comment: "Shortcut error"), code)
        case let .transport(detail):
            return detail
        case .decoding:
            return NSLocalizedString("Could not read Shortcut's response.", comment: "Shortcut error")
        }
    }
}
