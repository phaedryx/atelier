// ABOUTME: Reads Claude Code's `model` selection out of its settings files.
// ABOUTME: The transcript records the resolved model, so the "[1m]" marker only lives here.

import Foundation

enum ClaudeCodeSettings {
    /// Claude Code's settings precedence, narrowest first. `.local` is the
    /// per-machine override, then the checked-in project file, then the user's.
    private static let projectRelativePaths = [
        ".claude/settings.local.json",
        ".claude/settings.json",
    ]

    /// The `model` value Claude Code would resolve for a session running in
    /// `cwd` — the raw selection string, markers and aliases intact
    /// (e.g. "opus[1m]", "claude-sonnet-5").
    ///
    /// Only the settings *files* are visible from outside the process: a
    /// `--model` flag on the command line or `ANTHROPIC_MODEL` in the session's
    /// environment cannot be accounted for, and a session started that way
    /// falls back to whatever the files say.
    static func configuredModel(
        cwd: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        if let cwd {
            let base = URL(fileURLWithPath: cwd)
            for relative in projectRelativePaths {
                if let model = model(at: base.appendingPathComponent(relative)) {
                    return model
                }
            }
        }
        return model(at: homeDirectory.appendingPathComponent(".claude/settings.json"))
    }

    /// Reads `model` from one settings file. A missing, unreadable, or
    /// hand-broken file is not an error worth surfacing — the caller's fallback
    /// (the default window) is the same answer it would have given anyway.
    private static func model(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String,
              !model.isEmpty
        else { return nil }
        return model
    }
}
