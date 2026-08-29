// ABOUTME: Writes the per-workstream MCP config that points Claude Code at atelier-mcp.
// ABOUTME: Lives in the cache directory, never in the worktree, so it stays out of git status.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "ipc-config")

/// Builds the `--mcp-config` file for a workstream's Coding Agent.
///
/// Written to `~/Library/Caches/atelier/mcp/<workstream-id>.json` rather than a
/// `.mcp.json` in the worktree: the worktree is a checkout of the user's own
/// repository, and a config dropped there would show up in `git status`. The
/// cache directory already hosts `run-state/` and `tmux.conf`.
///
/// The file carries no token — the helper reads that from `ipc.json` — and no
/// identity: the helper is a child of the agent's terminal, so it inherits
/// `ATELIER_*` from the environment.
enum IPCConfig {
    /// The MCP server name agents see.
    static let serverName = "atelier-ipc"

    static func configURL(for workstreamID: UUID) -> URL {
        AppConstants.cacheDirectory
            .appendingPathComponent("mcp")
            .appendingPathComponent("\(workstreamID.uuidString.lowercased()).json")
    }

    static func configJSON(helperPath: String) -> [String: Any] {
        [
            "mcpServers": [
                serverName: [
                    "type": "stdio",
                    "command": helperPath,
                    "args": [] as [String],
                ],
            ],
        ]
    }

    /// Writes the config and returns its path, or nil when the helper binary is
    /// missing or the write fails — in which case the agent launches without the
    /// IPC server rather than not launching at all.
    static func write(for workstreamID: UUID, helperPath: String? = MCPHelperLauncher.executableURL()?.path) -> String? {
        guard let helperPath else { return nil }
        let url = configURL(for: workstreamID)
        do {
            let data = try JSONSerialization.data(withJSONObject: configJSON(helperPath: helperPath), options: [.sortedKeys])
            try FilePersistence.writeAtomically(data, to: url)
            return url.path
        } catch {
            logger.error("Failed to write MCP config: \(error.localizedDescription)")
            return nil
        }
    }

    static func remove(for workstreamID: UUID) {
        try? FileManager.default.removeItem(at: configURL(for: workstreamID))
    }
}
