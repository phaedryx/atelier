// ABOUTME: Resolves the bundled atelier-run helper and builds wrapped run-script commands.
// ABOUTME: Keeps Execution tab command assembly small and consistent across tmux modes.

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
    // POSIX, not `forShell:`. This token has one quoting layer and it is not
    // the login shell that strips it: the assembled string is read by ghostty's
    // `/bin/bash -c` wrapper (or by `sh -c` when tmux wraps it), which hands
    // the unquoted script to fish as its `-c` argument. Double quotes here
    // would leave backticks and `$(…)` for that outer shell to substitute.
    let quotedScript = CommandBuilder.shellQuote(script)
    // `shell` defaults to $SHELL, so it is as much user data as the other two.
    let quotedShell = CommandBuilder.shellQuote(shell)
    return "\(quotedLauncher) --workstream-id \(workstream) -- \(quotedShell) -lic \(quotedScript)"
}
