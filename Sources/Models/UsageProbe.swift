// ABOUTME: Fetches Claude Code plan usage by running `claude -p /usage` (intercepted
// ABOUTME: client-side — no model call, no token cost) and parsing the percentage lines.

import Foundation

/// Usage figures parsed from Claude Code's `/usage` output: the 5-hour session window,
/// the weekly all-models window, and the weekly model-specific window (e.g. Fable).
struct UsageReport: Equatable {
    struct Window: Equatable {
        var percentUsed: Int
        var resetText: String?
    }

    var session: Window?
    var week: Window?
    var modelWeek: Window?
    /// Model named in the model-specific week line, e.g. "Fable" from
    /// `Current week (Fable): 29% used`.
    var modelName: String?

    var isEmpty: Bool {
        session == nil && week == nil && modelWeek == nil
    }
}

enum UsageProbe {
    /// Ceiling on a single probe. Generous enough for a cold `claude` start,
    /// short enough that a wedged one is only one stale refresh cycle.
    static let timeout: TimeInterval = 30

    /// Run `claude -p /usage --output-format json` and parse the result. Returns nil if
    /// claude isn't installed, the call fails or hangs, or nothing parseable comes back.
    /// Blocks on a subprocess — must be called off the main actor.
    ///
    /// The binary is executed directly rather than through `sh -lic`: a login
    /// *interactive* shell evaluates the user's whole rc every probe, and this
    /// runs on a timer. `CommandLineTools.path(for:)` already resolves against
    /// the login-shell PATH (cached process-wide), so the shell buys nothing.
    static func fetch(
        claudePath: String? = CommandLineTools.path(for: "claude"),
        timeout: TimeInterval = timeout
    ) -> UsageReport? {
        guard let claudePath else { return nil }
        let data = ProcessRunner.run(
            executable: claudePath,
            arguments: ["-p", "/usage", "--output-format", "json"],
            environment: childEnvironment(),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: timeout
        )
        return data.flatMap(parse)
    }

    /// The app's own environment, hardened for a GUI-launched child.
    ///
    /// Two things must be right or `/usage` comes back useless:
    ///
    /// - `PATH`: a GUI process inherits launchd's minimal PATH, and `claude`
    ///   shells out to tools that must resolve the way they do in a terminal.
    ///   The login-shell PATH is cached process-wide, so this is nearly free.
    /// - `USER`: without it `claude -p /usage` silently returns the *cost
    ///   summary* ("Total cost: $0.0000 …") instead of the plan-usage text,
    ///   and `parseText` finds no "% used" line to read. Verified by
    ///   bisecting the environment; `LOGNAME` does not substitute for it.
    ///   launchd normally provides it, but it is cheap to guarantee.
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPath: (String) -> String? = { CommandLineTools.loginShellPath(shell: $0) },
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = base
        if let shell = environment["SHELL"], !shell.isEmpty,
           let path = loginShellPath(shell)
        {
            environment["PATH"] = path
        }
        if environment["USER"]?.isEmpty ?? true {
            environment["USER"] = userName
        }
        if environment["HOME"]?.isEmpty ?? true {
            environment["HOME"] = homeDirectory
        }
        return environment
    }

    /// Parse the `--output-format json` envelope, then the human-readable `result` text.
    static func parse(_ data: Data) -> UsageReport? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String else { return nil }
        return parseText(result)
    }

    /// Parse the `/usage` body, e.g.:
    /// `Current session: 63% used · resets Aug 30 at 1:10am (America/Denver)`
    /// `Current week (all models): 43% used · resets Aug 31 at 8pm (America/Denver)`
    /// `Current week (Fable): 29% used · resets Aug 31 at 8pm (America/Denver)`
    static func parseText(_ text: String) -> UsageReport? {
        var report = UsageReport()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            let lower = line.lowercased()
            guard lower.contains("% used"), let percent = firstPercent(in: line) else { continue }
            let window = UsageReport.Window(percentUsed: percent, resetText: resetText(in: line))
            if lower.contains("session") {
                report.session = window
            } else if lower.contains("week (all models)") {
                report.week = window
            } else if let nameRange = line.range(of: #"week \(([^)]+)\)"#, options: [.regularExpression, .caseInsensitive]) {
                report.modelWeek = window
                report.modelName = String(line[nameRange].dropFirst("week (".count).dropLast())
            }
        }
        return report.isEmpty ? nil : report
    }

    /// First integer immediately followed by `%`.
    private static func firstPercent(in line: String) -> Int? {
        guard let range = line.range(of: #"\d+%"#, options: .regularExpression) else { return nil }
        return Int(line[range].dropLast())
    }

    /// Text after "resets ", trimmed and stripped of a trailing timezone parenthetical.
    private static func resetText(in line: String) -> String? {
        guard let r = line.range(of: "resets ") else { return nil }
        var rest = String(line[r.upperBound...])
        if let paren = rest.firstIndex(of: "(") {
            rest = String(rest[..<paren])
        }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
