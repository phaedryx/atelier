// ABOUTME: Resolves the bundled atelier-run helper and builds wrapped run-script commands.
// ABOUTME: Keeps Environment tab command assembly small and consistent across tmux modes.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "run-launcher")

enum RunLauncher {
    static func executableURL(bundle: Bundle = .main) -> URL? {
        let helperURL = bundle.bundleURL.appendingPathComponent("Contents/Helpers/atelier-run")
        if FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL
        }

        if let executableURL = bundle.executableURL {
            let siblingURL = executableURL.deletingLastPathComponent().appendingPathComponent("atelier-run")
            if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
                return siblingURL
            }
        }

        logger.warning("atelier-run helper not found, port detection will be unavailable")
        return nil
    }
}

func runScriptCommand(script: String, workstreamID: UUID, launcherPath: String, shell: String = CommandBuilder.userShell) -> String {
    let workstream = workstreamID.uuidString.lowercased()
    let quotedLauncher = CommandBuilder.shellQuote(launcherPath)
    let quotedScript = CommandBuilder.shellQuote(script, forShell: shell)
    // `shell` defaults to $SHELL, so it is as much user data as the other two.
    let quotedShell = CommandBuilder.shellQuote(shell)
    return "\(quotedLauncher) --workstream-id \(workstream) -- \(quotedShell) -lic \(quotedScript)"
}
