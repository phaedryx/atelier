// ABOUTME: Installs and uninstalls atelier-hook entries in ~/.claude/settings.json.
// ABOUTME: Idempotent — detects existing entries by command containing "atelier-hook",
// ABOUTME: and by which of the two invocations (report or decide) that command asks for.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "hook-installer")

enum HookInstaller {
    /// How `atelier-hook` is invoked for one event.
    ///
    /// The mode is chosen by the registered command rather than by the script
    /// sniffing `hook_event_name` out of its own stdin: the payload is the
    /// harness's JSON, its formatting is not ours to depend on, and a `sh`
    /// script has no parser for it. A flag settles it before the script reads a
    /// byte.
    enum Kind: Equatable {
        /// Post the event and exit. Every event but one.
        case report
        /// Post the event and *wait*, then print whatever decision comes back.
        /// The agent is stopped for the duration.
        case decide

        var argument: String? {
            switch self {
            case .report: nil
            case .decide: "--permission"
            }
        }

        /// The entry's `timeout`, in seconds — how long Claude Code lets the
        /// script run before killing it.
        ///
        /// A reporting hook keeps the 5s it always had: it posts with
        /// `curl --max-time 1` and exits. A deciding hook has to outlast both
        /// the longest hold the app will take and the script's own
        /// `--max-time`, or Claude Code kills it mid-wait and an answer the
        /// user is halfway through giving is thrown away.
        var timeout: Int {
            switch self {
            case .report: 5
            case .decide: Int(PermissionApprovalSettings.maximumHold) + 60
            }
        }
    }

    /// Hook event types that atelier-hook should be registered for.
    ///
    /// The session and compaction events are here because the roster is
    /// otherwise only ever *inferred* to be over. `SessionEnd` is the one
    /// report that an agent is actually gone; without it a killed session
    /// leaves its runs on screen until the stall sweep downgrades them to
    /// yellow, which says "wedged" about something that simply exited.
    ///
    /// `PermissionRequest` is registered whether or not in-app approval is
    /// turned on. With it off the app answers "no decision" the instant the
    /// request arrives — no hold, no behaviour change — and the payload still
    /// tells the tracker *which tool* is being asked about, which the
    /// `Notification` message can only be string-matched for. Installing and
    /// uninstalling the entry as the setting is toggled would churn a file
    /// shared with every other Claude session on the machine to buy nothing.
    private static let hookEvents: [(name: String, kind: Kind)] = [
        ("PreToolUse", .report),
        ("PostToolUse", .report),
        ("Stop", .report),
        ("SubagentStart", .report),
        ("SubagentStop", .report),
        ("UserPromptSubmit", .report),
        ("Notification", .report),
        ("SessionStart", .report),
        ("SessionEnd", .report),
        ("PreCompact", .report),
        ("PostCompact", .report),
        ("PermissionRequest", .decide),
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

        for (eventName, kind) in hookEvents {
            var eventEntries = entries(in: hooks[eventName])

            // An atelier-hook entry of the *wrong* kind for this event was left
            // by a build that invoked the script differently here — a plain
            // entry under PermissionRequest, from before this hook could answer
            // anything. Leaving it in place means Claude Code runs the hook
            // twice, and the extra run is the one that returns no decision, so
            // it is replaced rather than added beside.
            //
            // The *path* deliberately stays out of the comparison. An entry
            // pointing at another copy of Atelier is that copy's to manage, and
            // rewriting it here would have two installs fighting over the file.
            eventEntries.removeAll { entry in
                kinds(in: entry).contains { $0 != kind }
            }

            let alreadyInstalled = eventEntries.contains { entry in
                kinds(in: entry).contains(kind)
            }

            if !alreadyInstalled {
                let command = [quotedPath, kind.argument].compactMap(\.self).joined(separator: " ")
                eventEntries.append([
                    "matcher": "",
                    "hooks": [
                        ["type": "command", "command": command, "timeout": kind.timeout] as [String: Any],
                    ],
                ] as [String: Any])
            }

            hooks[eventName] = eventEntries
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
        for (eventName, _) in hookEvents {
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

    /// Which of our invocation kinds an entry registers, if any. Empty for a
    /// foreign entry, which is what keeps someone else's hooks out of every
    /// decision this file makes.
    private static func kinds(in entry: [String: Any]) -> [Kind] {
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return [] }
        return entryHooks.compactMap { hook in
            guard let command = hook["command"] as? String, command.contains("atelier-hook") else { return nil }
            return command.contains("--permission") ? .decide : .report
        }
    }

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
