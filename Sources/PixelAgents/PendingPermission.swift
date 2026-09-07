// ABOUTME: One tool-permission request an agent is blocked on, plus the settings that gate holding it.
// ABOUTME: Built from a PermissionRequest hook payload; answered from the banner over the agent tab.

import Foundation

/// A tool call Claude Code is asking about, while its hook waits for an answer.
///
/// Unlike everything else `HookEventReceiver` produces, this is not a report of
/// something that happened — the agent is stopped until the request is resolved
/// one way or another, so every path out of it has to end in `resolve`.
struct PendingPermission: Identifiable, Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case allow
        case deny
    }

    let id: UUID
    /// The tool Claude Code wants to run, e.g. "Bash".
    let toolName: String
    /// The part of the tool's input worth reading before deciding — the command
    /// for Bash, the path for a write. Nil when the tool takes no input worth
    /// showing.
    let detail: String?
    /// The terminal surface the asking agent occupies, when the hook inherited
    /// `ATELIER_SURFACE_ID`. Used to say *which* pane is asking when it is not
    /// the workstream's Coding Agent.
    let surfaceID: UUID?
    let receivedAt: Date
    /// When the app gives up and lets Claude Code ask in the terminal instead.
    let expiresAt: Date

    // MARK: - Display

    /// Pulls the one field of a tool's input that decides the answer.
    ///
    /// Deliberately not a dump of the whole input: the point of showing anything
    /// is that "Bash" alone cannot be answered, and a wall of JSON cannot be
    /// answered either. Tools not named here fall back to every scalar field,
    /// which is worse but never empty — a custom or MCP tool must still show
    /// *something* about what it is about to do.
    static func detail(toolName: String, toolInput: [String: Any]?) -> String? {
        guard let toolInput, !toolInput.isEmpty else { return nil }

        switch toolName.lowercased() {
        case "bash":
            return (toolInput["command"] as? String)?.trimmed
        case "edit", "write", "multiedit", "notebookedit", "patch", "read":
            return (toolInput["file_path"] as? String) ?? (toolInput["notebook_path"] as? String)
        case "webfetch":
            return toolInput["url"] as? String
        case "websearch":
            return toolInput["query"] as? String
        case "grep", "glob":
            return (toolInput["pattern"] as? String).map { pattern in
                if let path = toolInput["path"] as? String {
                    return "\(pattern)  in \(path)"
                }
                return pattern
            }
        case "task":
            return toolInput["description"] as? String
        default:
            let scalars = toolInput.keys.sorted().compactMap { key -> String? in
                guard let value = scalar(toolInput[key]) else { return nil }
                return "\(key): \(value)"
            }
            return scalars.isEmpty ? nil : scalars.joined(separator: "\n")
        }
    }

    /// Renders a leaf value, and nothing else. A nested object or array is
    /// summarised away rather than serialised: this text goes into a banner
    /// three lines tall, and a truncated JSON blob is not more informative than
    /// saying there is one.
    private static func scalar(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.trimmed
        case let number as Int: String(number)
        case let number as Double: String(number)
        case let flag as Bool: flag ? "true" : "false"
        default: nil
        }
    }
}

private extension String {
    var trimmed: String? {
        let stripped = trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}

// MARK: - Settings

/// Whether Atelier may answer permission prompts, and for how long it may keep
/// an agent waiting while it asks.
///
/// Off by default, like the process-compose integration and agent messaging: the
/// hook is registered either way, but with this off the app answers "no
/// decision" the moment the request arrives, so nothing an agent does starts
/// depending on Atelier being awake without the user having said so.
enum PermissionApprovalSettings {
    static let enabledKey = "atelier.permissionApproval"
    static let holdKey = "atelier.permissionApprovalHold"

    static let defaultHold: TimeInterval = 90
    static let minimumHold: TimeInterval = 15
    /// The ceiling on the setting, and the number the hook script's own
    /// `--max-time` and the registered hook `timeout` are sized against. Raising
    /// it means raising both of those too, or Claude Code kills the script
    /// mid-wait and the answer is lost.
    static let maximumHold: TimeInterval = 300

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// How long a request may block its agent before the app gives up and lets
    /// Claude Code ask in the terminal.
    ///
    /// Clamped rather than trusted: this value decides how long an agent can sit
    /// blocked on a window nobody is looking at, and it is reachable through
    /// `defaults write`. An unset key reads as 0, which means "never set", not
    /// "hold for no time at all".
    static var hold: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: holdKey)
        guard stored > 0 else { return defaultHold }
        return min(max(stored, minimumHold), maximumHold)
    }
}
