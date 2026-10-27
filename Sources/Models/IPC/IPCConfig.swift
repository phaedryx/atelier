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
                    withJSONObject: mcpJSON(helperPath: helperPath),
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

        /// What the helper reads from its environment, and a spawned tab always
        /// sets. The group variables are absent on purpose: a workstream tab
        /// never has them, and Cursor leaves an unset reference literal.
        static let identityVariables = [
            "ATELIER_WORKSTREAM_ID", "ATELIER_WORKSTREAM", "ATELIER_PROJECT_DIR",
            "ATELIER_SURFACE_ID", "ATELIER_PEER_NAME",
        ]

        /// `Config`'s server plus an `env` block, because Cursor — unlike Claude
        /// Code — starts stdio servers with a scrubbed environment, so the
        /// helper inherits none of `ATELIER_*`. Each is passed by reference,
        /// `${env:NAME}`, which Cursor expands from the agent's own environment
        /// at launch: that keeps this file per workstream while the surface id
        /// it delivers stays per tab.
        static func mcpJSON(helperPath: String) -> [String: Any] {
            var server = (Config.configJSON(helperPath: helperPath)["mcpServers"] as? [String: Any])?[Config.serverName]
                as? [String: Any] ?? [:]
            server["env"] = Dictionary(uniqueKeysWithValues: identityVariables.map { ($0, "${env:\($0)}") })
            return ["mcpServers": [Config.serverName: server]]
        }
    }
}

extension IPC {
    /// The `mcpAllowlist` entry in `~/.cursor/permissions.json` that lets a
    /// Cursor agent call atelier-ipc's tools without asking.
    ///
    /// `--approve-mcps` loads the server; it does not approve calls, and the
    /// first call a spawned peer makes is `register_peer`, in a tab nobody may
    /// be watching. Nothing narrower works (verified against cursor-agent
    /// 2026.10.22): a plugin directory cannot carry permissions, no flag grants
    /// them, a worktree `.cursor/cli.json` would be the user's checkout, and
    /// pointing `CURSOR_CONFIG_DIR` elsewhere replaces the user's whole CLI
    /// config. The file is additive to the user's own allowlist.
    ///
    /// Merged, never overwritten: Cursor reads it as JSONC, so a file this
    /// parser cannot read — a comment, a trailing comma — is the user's, and is
    /// left alone.
    enum CursorPermissions {
        /// Cursor names a plugin's server `plugin-<plugin>-<server>` and matches
        /// the whole id, so `atelier-ipc:*` alone does not match.
        static let allowlistEntry = "plugin-\(CursorPlugin.name)-\(Config.serverName):*"

        static var path: String {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/permissions.json").path
        }

        static func install(at path: String = path) {
            let fm = FileManager.default
            var file: [String: Any] = [:]
            if fm.fileExists(atPath: path) {
                guard let data = fm.contents(atPath: path),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    logger.warning("~/.cursor/permissions.json is not plain JSON — will not overwrite")
                    return
                }
                file = parsed
            }
            var allowlist = file["mcpAllowlist"] as? [String] ?? []
            guard !allowlist.contains(allowlistEntry) else { return }
            allowlist.append(allowlistEntry)
            file["mcpAllowlist"] = allowlist
            do {
                let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                logger.error("Failed to write ~/.cursor/permissions.json: \(error.localizedDescription)")
            }
        }
    }
}
