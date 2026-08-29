// ABOUTME: Identifies which coding-agent CLI a workstream runs.
// ABOUTME: Extensible enum so future harnesses (e.g., Codex) are one case away.

import Foundation

enum CodingHarness: String, Codable, CaseIterable, Sendable {
    case claudeCode

    /// Maps a persisted raw value onto a known harness, falling back to Claude
    /// Code. Blobs written before OpenCode support was removed still carry
    /// `"opencode"`; they must load, not throw.
    static func fromPersisted(_ rawValue: String?) -> CodingHarness {
        guard let rawValue else { return .claudeCode }
        return CodingHarness(rawValue: rawValue) ?? .claudeCode
    }

    var displayName: String {
        switch self {
        case .claudeCode:
            return NSLocalizedString("Claude Code", comment: "Name of the Claude Code coding agent")
        }
    }

    var cliName: String {
        switch self {
        case .claudeCode:
            return "claude"
        }
    }

    var systemImageName: String {
        switch self {
        case .claudeCode:
            return "sparkle"
        }
    }

    /// Sprite-store key used by `AgentSpriteStore` / `MainAgentPortrait`.
    var portraitName: String {
        switch self {
        case .claudeCode:
            return "Claude"
        }
    }

    var installURL: URL {
        switch self {
        case .claudeCode:
            return URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!
        }
    }
}
