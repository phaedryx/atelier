// ABOUTME: Detection of the command-line tools and macOS apps Atelier depends on.
// ABOUTME: Model layer — `AppEnvironment.refresh()` runs `ToolStatus.detect()`; Settings and onboarding only render it.

import AppKit

// MARK: - Tool Detection

enum BinaryStatus {
    case notFound
    case found(String)

    var isInstalled: Bool {
        if case .found = self {
            return true
        }
        return false
    }

    var path: String? {
        if case let .found(p) = self {
            return p
        }
        return nil
    }
}

struct ToolStatus {
    var tmux: BinaryStatus = .notFound
    var tmuxVersion: String?
    var claude: BinaryStatus = .notFound
    var claudeVersion: String?
    var claudeSupportsSessionName: Bool = false
    var gh: BinaryStatus = .notFound
    var ghVersion: String?
    /// Display-only. `ghAuthenticated` is the flag to branch on — this string is
    /// a username or a status phrase and is free to be reworded.
    var ghAuthDetail: String?
    var ghAuthenticated: Bool = false
    var git: BinaryStatus = .notFound
    var gitVersion: String?
    /// Resolved by `ProcessCompose.Settings.resolveBinary()`, **not** by
    /// `findBinary`. The two disagree by construction: `resolveBinary` honours a
    /// configured path and *fails* rather than searching, while
    /// `CommandLineTools.path` walks the login PATH and six known locations. A
    /// row fed by the generic search would read green above a Start button
    /// reporting "process-compose was not found" — the button-versus-run
    /// disagreement `ProcessCompose.RunCommandPlan` exists to prevent, only
    /// spread across two windows.
    var processCompose: BinaryStatus = .notFound
    var processComposeVersion: String?

    static func detect() -> ToolStatus {
        var status = ToolStatus()

        status.tmux = findBinary("tmux")
        if let path = status.tmux.path {
            status.tmuxVersion = runForVersion(path, args: ["-V"])
        }

        status.claude = findBinary("claude")
        if let path = status.claude.path {
            status.claudeVersion = runForVersion(path, args: ["--version"])
            status.claudeSupportsSessionName = helpContainsFlag(path, flag: "--name")
        }

        status.gh = findBinary("gh")
        if let path = status.gh.path {
            status.ghVersion = runForVersion(path, args: ["--version"])
            let auth = checkGhAuth(path)
            status.ghAuthenticated = auth.authenticated
            status.ghAuthDetail = auth.detail
        }

        status.git = findBinary("git")
        if let path = status.git.path {
            status.gitVersion = runForVersion(path, args: ["--version"])
        }

        // `version -s`, not `--version`: process-compose has no such flag, and
        // bare `version` prints six lines of which the first is the product
        // name rather than a number. `-s` prints `v1.122.0` and nothing else.
        status.processCompose = ProcessCompose.Settings.resolveBinary().map(BinaryStatus.found) ?? .notFound
        if let path = status.processCompose.path {
            status.processComposeVersion = runForVersion(path, args: ["version", "-s"])
        }

        return status
    }

    private static func findBinary(_ name: String) -> BinaryStatus {
        guard let path = CommandLineTools.path(for: name) else { return .notFound }
        return .found(path)
    }

    private static func runForVersion(_ path: String, args: [String]) -> String? {
        guard let output = runCommand(path, args: args) else { return nil }
        let trimmed = output
            .replacingOccurrences(of: "tmux ", with: "")
            .replacingOccurrences(of: "gh version ", with: "")
        return trimmed.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
    }

    private static func helpContainsFlag(_ path: String, flag: String) -> Bool {
        guard let output = runCommand(path, args: ["--help"], includeStderr: true) else { return false }
        return output.contains(flag)
    }

    /// Returns the authentication *fact* alongside the string shown in Settings.
    /// The two are separate on purpose: callers that gate behaviour on gh being
    /// usable read the flag, so rewording the detail cannot switch them off.
    private static func checkGhAuth(_ ghPath: String) -> (authenticated: Bool, detail: String) {
        guard let output = runCommand(ghPath, args: ["auth", "status"], includeStderr: true) else {
            return (false, NSLocalizedString("Not authenticated", comment: "gh CLI auth status"))
        }
        if let range = output.range(of: "account ") {
            let afterAccount = output[range.upperBound...]
            let username = afterAccount.prefix(while: { !$0.isWhitespace && $0 != "(" })
            if !username.isEmpty {
                return (true, String(username))
            }
        }
        if output.contains("Logged in") {
            return (true, NSLocalizedString("Authenticated", comment: "gh CLI auth status"))
        }
        return (false, NSLocalizedString("Not authenticated", comment: "gh CLI auth status"))
    }

    /// Bounded: these probes run when the Environment pane appears, and
    /// `gh auth status` reaches the network. Without a deadline one stalled
    /// binary leaves the pane spinning with no way out.
    private static func runCommand(_ path: String, args: [String], includeStderr: Bool = false) -> String? {
        guard let output = ProcessRunner.capture(
            executable: path,
            arguments: args,
            timeout: ProcessRunner.Timeout.network
        ) else { return nil }
        guard output.isSuccess || includeStderr else { return nil }
        // Some of these tools report on stderr — `gh auth status` and `--help`
        // among them — so callers that need it ask for both streams.
        guard includeStderr else { return output.stdoutText }
        return [output.stdoutText, output.stderrText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - App Detection

struct AppInfo: Identifiable, @unchecked Sendable {
    let name: String
    let bundleID: String
    var id: String {
        bundleID
    }

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func isAppInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func detectTerminals() -> [AppInfo] {
        let candidates: [(String, String)] = [
            ("Ghostty", "com.mitchellh.ghostty"),
            ("iTerm2", "com.googlecode.iterm2"),
            ("Terminal", "com.apple.Terminal"),
            ("Warp", "dev.warp.Warp-Stable"),
            ("Alacritty", "org.alacritty"),
            ("kitty", "net.kovidgoyal.kitty"),
        ]
        return candidates.compactMap { name, id in
            isAppInstalled(id) ? AppInfo(name: name, bundleID: id) : nil
        }
    }

    static func detectBrowsers() -> [AppInfo] {
        let candidates: [(String, String)] = [
            ("Safari", "com.apple.Safari"),
            ("Google Chrome", "com.google.Chrome"),
            ("Firefox", "org.mozilla.firefox"),
            ("Arc", "company.thebrowser.Browser"),
            ("Brave", "com.brave.Browser"),
            ("Microsoft Edge", "com.microsoft.edgemac"),
            ("Opera", "com.operasoftware.Opera"),
        ]
        return candidates.compactMap { name, id in
            isAppInstalled(id) ? AppInfo(name: name, bundleID: id) : nil
        }
    }
}
