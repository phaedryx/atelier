// ABOUTME: The status line channel: context-window figures Claude Code computes
// ABOUTME: itself, and the per-session --settings file that registers it.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "statusline")

/// Claude Code's status line, used as a data channel rather than a display.
///
/// Hook payloads carry no token or context fields at all — `session_id`,
/// `transcript_path`, `cwd`, `permission_mode` and the event's own fields are
/// the whole of it. The status line command is the one interface Claude Code
/// hands the numbers to: `context_window.total_input_tokens` and
/// `context_window.context_window_size`, already resolved, including whether
/// the session is on a 1M window. That is why this exists and why the meter
/// prefers it over `TranscriptContextReader`, which infers the same two figures
/// by parsing a file whose format Claude Code's own documentation calls
/// internal and version-unstable.
///
/// `statusLine` is a **single command slot** in settings, not a list like
/// `hooks`, so there is no way to register alongside whatever the user already
/// has. Atelier therefore never writes that slot: it passes `--settings` when
/// it launches an agent, which sits above user settings, merges per key, lasts
/// one session and writes to no file. A Claude session the user starts anywhere
/// else is untouched.
enum StatusLine {}

extension StatusLine {
    /// The two figures the meter needs, as Claude Code resolved them.
    ///
    /// `limitTokens` comes from the payload rather than from `ContextLimits`:
    /// the status line knows the real window, so the model-string inference and
    /// its "[1m]" marker are not consulted on this path at all.
    struct Reading: Equatable {
        let usedTokens: Int
        let limitTokens: Int
    }

    /// Extracts the reading from one status line payload.
    ///
    /// Returns nil until the session's first API response, when
    /// `context_window` is absent or still zero-sized — a reading with no window
    /// to divide by would render as a full bar. Output tokens are deliberately
    /// not added: what fills a context window is what gets sent back up, which
    /// is the input side, and `TranscriptContextReader` sums the same three
    /// input-side counts for the same reason.
    static func reading(payload: [String: Any]) -> Reading? {
        guard let window = payload["context_window"] as? [String: Any] else { return nil }
        let used = int(window, "total_input_tokens")
        let size = int(window, "context_window_size")
        guard used > 0, size > 0 else { return nil }
        return Reading(usedTokens: used, limitTokens: size)
    }

    /// The directory Claude Code was launched in, which is what the hook channel
    /// sends as `project_dir` and what `workstreamLookup` resolves. `cwd` is the
    /// fallback and not the first choice: it follows the session as it wanders
    /// between directories, and the workstream is the launch directory.
    static func projectDir(payload: [String: Any]) -> String? {
        if let workspace = payload["workspace"] as? [String: Any],
           let dir = workspace["project_dir"] as? String, !dir.isEmpty
        {
            return dir
        }
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }
        return nil
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int {
        if let value = dict[key] as? Int {
            return value
        }
        if let value = dict[key] as? Double {
            return Int(value)
        }
        return 0
    }
}

extension StatusLine {
    /// The `--settings` file that registers `atelier-statusline` for one
    /// workstream's agents.
    enum Config {
        /// Builds the settings file, or returns nil when there is nothing to
        /// chain to.
        ///
        /// **No configured status line means no file and no flag.** Registering
        /// one anyway would give that user a status line they never asked for:
        /// Claude Code hides most of the footer's keyboard hints as soon as one
        /// is configured, and a script with nothing to print leaves the row
        /// blank. Those sessions keep the transcript reader instead.
        ///
        /// The user's command is resolved **here, at launch**, and passed to the
        /// script as an argument rather than re-read on every render: a `sh`
        /// script has no JSON parser, which is the same reason `atelier-hook`
        /// takes a flag instead of sniffing its own stdin. The cost is that a
        /// `/statusline` change reaches a running agent only when its surface
        /// respawns.
        static func write(
            for workstreamID: UUID,
            cwd: String?,
            scriptPath: String? = StatusLine.scriptPath(),
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            innerCommand: String? = nil
        ) -> String? {
            guard let scriptPath else { return nil }
            let inner = innerCommand
                ?? ClaudeCodeSettings.statusLineCommand(cwd: cwd, homeDirectory: homeDirectory)
            guard let inner, !inner.isEmpty else { return nil }
            // Chaining our own script would recurse for as long as the session
            // lives. Only reachable if someone has registered it by hand, which
            // Atelier never does.
            guard !inner.contains("atelier-statusline") else {
                logger.warning("Refusing to chain a status line that is already atelier-statusline")
                return nil
            }

            let command = "\(CommandBuilder.shellQuote(scriptPath)) \(CommandBuilder.shellQuote(inner))"
            let settings: [String: Any] = [
                "statusLine": ["type": "command", "command": command],
            ]
            let url = configURL(for: workstreamID)
            do {
                let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
                try FilePersistence.writeAtomically(data, to: url)
                return url.path
            } catch {
                logger.error("Failed to write status line settings: \(error.localizedDescription)")
                return nil
            }
        }

        static func remove(for workstreamID: UUID) {
            try? FileManager.default.removeItem(at: configURL(for: workstreamID))
        }

        static func configURL(for workstreamID: UUID) -> URL {
            AppConstants.cacheDirectory
                .appendingPathComponent("statusline")
                .appendingPathComponent("\(workstreamID.uuidString.lowercased()).json")
        }
    }

    /// The bundled script, resolved the same way `atelier-hook` is.
    static func scriptPath() -> String? {
        if let url = Bundle.main.url(forResource: "atelier-statusline", withExtension: nil, subdirectory: "Scripts") {
            return url.path
        }
        return Bundle.main.url(forResource: "atelier-statusline", withExtension: nil)?.path
    }
}
