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

    var isEmpty: Bool { session == nil && week == nil && modelWeek == nil }
}

enum UsageProbe {
    /// Run `claude -p /usage --output-format json` and parse the result. Returns nil if
    /// claude isn't installed, the call fails, or nothing parseable comes back.
    /// Blocks on a subprocess — must be called off the main actor.
    static func fetch(shell: String = CommandBuilder.userShell) -> UsageReport? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "claude -p '/usage' --output-format json"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
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
