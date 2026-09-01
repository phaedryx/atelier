// ABOUTME: Installs and uninstalls atelier-hook entries in ~/.claude/settings.json.
// ABOUTME: Idempotent — detects existing entries by command containing "atelier-hook".

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "hook-installer")

enum HookInstaller {
    /// Hook event types that atelier-hook should be registered for.
    private static let hookEvents = [
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "UserPromptSubmit",
        "Notification",
    ]

    /// Path to the Claude Code user settings file.
    ///
    /// Injectable so the merge logic can be tested against a scratch file
    /// rather than the developer's real settings, the way
    /// `OpencodePluginRemover.uninstall(at:)` already is.
    static var settingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
    }

    // MARK: - Install

    /// Reads `~/.claude/settings.json`, merges atelier-hook entries for all event types, and writes back atomically.
    /// - Parameter hookScriptPath: Absolute path to the `atelier-hook` script bundled in the app.
    static func install(hookScriptPath: String, at path: String = settingsPath) {
        let fm = FileManager.default

        // Read existing settings (or start fresh)
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: path) {
            guard let data = fm.contents(atPath: path) else {
                logger.warning("Could not read settings.json")
                return
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("settings.json is not valid JSON — will not overwrite")
                return
            }
            settings = parsed
        }

        // Get or create the hooks dictionary
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let quotedPath = hookScriptPath.contains(" ") ? "\"\(hookScriptPath)\"" : hookScriptPath
        let ffHookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": quotedPath, "timeout": 5] as [String: Any],
            ],
        ]

        for eventName in hookEvents {
            var eventEntries = hooks[eventName] as? [[String: Any]] ?? []

            // Check if atelier-hook is already registered for this event
            let alreadyInstalled = eventEntries.contains { entry in
                if let entryHooks = entry["hooks"] as? [[String: Any]] {
                    return entryHooks.contains { hook in
                        (hook["command"] as? String)?.contains("atelier-hook") == true
                    }
                }
                return false
            }

            if !alreadyInstalled {
                eventEntries.append(ffHookEntry)
                hooks[eventName] = eventEntries
            }
        }

        settings["hooks"] = hooks

        // Write atomically
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            logger.error("Failed to serialize settings.json")
            return
        }

        // Ensure directory exists
        let settingsDir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)

        do {
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            logger.info("Installed atelier-hook in settings.json for \(hookEvents.count) event types")
        } catch {
            logger.error("Failed to write settings.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Uninstall

    /// Removes all atelier-hook entries from `~/.claude/settings.json`, preserving everything else.
    static func uninstall(at path: String = settingsPath) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        var modified = false
        for eventName in hookEvents {
            guard let eventEntries = hooks[eventName] as? [[String: Any]] else { continue }

            let filtered = eventEntries.filter { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return true }
                return !entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains("atelier-hook") == true
                }
            }

            if filtered.count != eventEntries.count {
                modified = true
                if filtered.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = filtered
                }
            }
        }

        guard modified else { return }

        settings["hooks"] = hooks.isEmpty ? nil : hooks

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
        logger.info("Uninstalled atelier-hook from settings.json")
    }
}
