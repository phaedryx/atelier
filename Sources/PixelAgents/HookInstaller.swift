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

        // The directory has to exist before the lock file can, and the lock has
        // to be held across the whole read → merge → write below.
        do {
            try fm.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Cannot create the settings directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        withSettingsLock(at: path) {
            merge(hookScriptPath: hookScriptPath, at: path, fm: fm)
        }
    }

    private static func merge(hookScriptPath: String, at path: String, fm: FileManager) {
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
            var eventEntries = entries(in: hooks[eventName])

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
        withSettingsLock(at: path) {
            removeEntries(at: path)
        }
    }

    private static func removeEntries(at path: String) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        var modified = false
        for eventName in hookEvents {
            let eventEntries = entries(in: hooks[eventName])
            guard !eventEntries.isEmpty else { continue }

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
        ) else {
            logger.error("Failed to serialize settings.json")
            return
        }

        do {
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            logger.info("Uninstalled atelier-hook from settings.json")
        } catch {
            logger.error("Failed to write settings.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Shapes

    /// One event's entries, tolerating the bare object Claude Code also accepts
    /// where the schema shows an array.
    ///
    /// `as? [[String: Any]] ?? []` returned nil for a hand-written single object,
    /// and the `?? []` then *replaced* it — so installing hooks silently deleted
    /// the user's own entry for that event.
    private static func entries(in value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let single = value as? [String: Any] {
            return [single]
        }
        return []
    }

    // MARK: - Locking

    /// Serializes the whole read → merge → write against another Atelier.
    ///
    /// Debug and release builds are designed to run side by side
    /// (`AppConstants.appID`) and both install hooks on launch. `.atomic` makes
    /// the single write atomic; it does nothing about the sequence around it, so
    /// two launches could each read the same settings and each write back a merge
    /// missing the other's.
    ///
    /// The lock is a sidecar, not settings.json itself: an atomic write replaces
    /// that file's inode and `flock` is held against an inode, so two processes
    /// locking "settings.json" could end up holding two different files.
    ///
    /// Non-blocking with a bounded retry, because this runs on the main thread at
    /// launch. Failing to take it means skipping this launch's install — the next
    /// one retries, and a lost update to the user's settings.json does not undo.
    private static func withSettingsLock(at path: String, _ body: () -> Void) {
        let lockPath = path + ".atelier.lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            logger.error("Cannot open the hook settings lock at \(lockPath, privacy: .public)")
            return
        }
        defer { close(descriptor) }

        var attempts = 0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            attempts += 1
            guard attempts < 50 else {
                logger.error("Another Atelier is holding the hook settings lock; skipping")
                return
            }
            usleep(20_000)
        }
        defer { flock(descriptor, LOCK_UN) }

        body()
    }
}
