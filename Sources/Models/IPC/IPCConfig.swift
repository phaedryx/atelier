// ABOUTME: Writes the per-workstream MCP config that points Claude Code at atelier-mcp.
// ABOUTME: Lives in the cache directory, never in the worktree, so it stays out of git status.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "ipc-config")

extension IPC {
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
    enum Config {
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
}

extension IPC {
    /// The `--plugin-dir` a Cursor CLI agent is launched with: the one way to
    /// hand a single `cursor-agent` launch the atelier-ipc server without
    /// editing `~/.cursor/mcp.json`, which every Cursor session on the machine
    /// reads.
    ///
    /// Written to `~/Library/Caches/atelier/cursor-plugin/<workstream-id>/atelier/`,
    /// beside `mcp/`, for `Config`'s reason: never in the worktree. The last
    /// component is `atelier` rather than the id because Cursor names the
    /// agent's tools after it — `plugin-atelier-atelier-ipc/list_peers` instead
    /// of a uuid in every tool name the model reads. Keyed by
    /// workstream and shared by every Cursor tab in it, like `Config`, because
    /// it carries no identity — the helper inherits `ATELIER_SURFACE_ID`.
    ///
    /// The layout is what `cursor-agent` loads: a manifest at
    /// `.cursor-plugin/plugin.json` whose `name` must be lowercase-hyphenated,
    /// and the servers at `.mcp.json` in the same shape `Config` writes.
    enum CursorPlugin {
        static let name = "atelier"

        static func directoryURL(for workstreamID: UUID) -> URL {
            workstreamDirectoryURL(for: workstreamID).appendingPathComponent(name)
        }

        private static func workstreamDirectoryURL(for workstreamID: UUID) -> URL {
            AppConstants.cacheDirectory
                .appendingPathComponent("cursor-plugin")
                .appendingPathComponent(workstreamID.uuidString.lowercased())
        }

        /// Writes the plugin and returns its directory, or nil when the helper
        /// binary is missing or a write fails — the agent then launches without
        /// the IPC server rather than not launching at all, as with `Config`.
        static func write(for workstreamID: UUID, helperPath: String? = MCPHelperLauncher.executableURL()?.path) -> String? {
            guard let helperPath else { return nil }
            let root = directoryURL(for: workstreamID)
            do {
                let manifest = try JSONSerialization.data(withJSONObject: ["name": name], options: [.sortedKeys])
                try FilePersistence.writeAtomically(manifest, to: root.appendingPathComponent(".cursor-plugin/plugin.json"))
                let servers = try JSONSerialization.data(
                    withJSONObject: Config.configJSON(helperPath: helperPath),
                    options: [.sortedKeys]
                )
                try FilePersistence.writeAtomically(servers, to: root.appendingPathComponent(".mcp.json"))
                return root.path
            } catch {
                logger.error("Failed to write the Cursor plugin: \(error.localizedDescription)")
                return nil
            }
        }

        static func remove(for workstreamID: UUID) {
            try? FileManager.default.removeItem(at: workstreamDirectoryURL(for: workstreamID))
        }
    }
}
