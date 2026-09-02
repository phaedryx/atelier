// ABOUTME: Settings for the process-compose integration, and binary resolution.
// ABOUTME: Global rather than per-project: these are preferences about the tool.

import Foundation

enum ProcessComposeSettings {
    static let enabledKey = "atelier.processCompose.enabled"
    static let binaryPathKey = "atelier.processCompose.binaryPath"

    /// Where process-compose usually lands. Not in homebrew-core, so a tap and a
    /// hand-installed release binary are both common.
    static let searchPaths = [
        "/opt/homebrew/bin/process-compose",
        "/usr/local/bin/process-compose",
        "\(NSHomeDirectory())/.local/bin/process-compose",
    ]

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var binaryPath: String {
        get { UserDefaults.standard.string(forKey: binaryPathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: binaryPathKey) }
    }

    /// The binary to run, or nil if there isn't one.
    ///
    /// A configured path is used or fails; it never falls back to a search,
    /// because silently running a different binary than the one named is worse
    /// than reporting that the named one is gone.
    static func resolveBinary() -> String? {
        let configured = binaryPath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty {
            return FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
        }
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
