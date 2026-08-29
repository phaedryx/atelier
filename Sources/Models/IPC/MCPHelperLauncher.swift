// ABOUTME: Locates the bundled atelier-mcp helper binary.
// ABOUTME: Same resolution order as RunLauncher: Contents/Helpers first, then a sibling of the executable.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "ipc-helper")

enum MCPHelperLauncher {
    static func executableURL(bundle: Bundle = .main) -> URL? {
        let helperURL = bundle.bundleURL.appendingPathComponent("Contents/Helpers/atelier-mcp")
        if FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL
        }

        if let executableURL = bundle.executableURL {
            let siblingURL = executableURL.deletingLastPathComponent().appendingPathComponent("atelier-mcp")
            if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
                return siblingURL
            }
        }

        logger.warning("atelier-mcp helper not found, agent IPC will be unavailable")
        return nil
    }
}
