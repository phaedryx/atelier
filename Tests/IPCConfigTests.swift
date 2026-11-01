// ABOUTME: Tests for the per-workstream MCP config Atelier writes for Claude Code.
// ABOUTME: Checks the stdio server shape, the cache-directory location, and the missing-helper case.

@testable import Atelier
import XCTest

final class IPCConfigTests: XCTestCase {
    private let workstreamID = UUID()

    override func tearDown() {
        IPC.Config.remove(for: workstreamID)
        IPC.CursorPlugin.remove(for: workstreamID)
        super.tearDown()
    }

    func test_configURL_livesInTheCacheDirectory_notTheWorktree() {
        let url = IPC.Config.configURL(for: workstreamID)
        XCTAssertEqual(url.lastPathComponent, "\(workstreamID.uuidString.lowercased()).json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "mcp")
        XCTAssertTrue(url.path.hasPrefix(AppConstants.cacheDirectory.path), "expected a cache-directory path, got \(url.path)")
    }

    func test_configJSON_declaresOneStdioServer() throws {
        let json = IPC.Config.configJSON(helperPath: "/Applications/Atelier.app/Contents/Helpers/atelier-mcp")
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["atelier-ipc"])

        let server = try XCTUnwrap(servers["atelier-ipc"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, "/Applications/Atelier.app/Contents/Helpers/atelier-mcp")
        XCTAssertEqual(server["args"] as? [String], [])
        XCTAssertNil(server["env"], "identity comes from the inherited environment, not the config")
    }

    func test_write_producesReadableJSONAtTheReturnedPath() throws {
        let path = try XCTUnwrap(IPC.Config.write(for: workstreamID, helperPath: "/tmp/atelier-mcp"))
        XCTAssertEqual(path, IPC.Config.configURL(for: workstreamID).path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["atelier-ipc"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "/tmp/atelier-mcp")
    }

    func test_write_withoutAHelperBinary_returnsNil() {
        XCTAssertNil(IPC.Config.write(for: workstreamID, helperPath: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: IPC.Config.configURL(for: workstreamID).path))
    }

    func test_remove_deletesTheConfig() throws {
        _ = try XCTUnwrap(IPC.Config.write(for: workstreamID, helperPath: "/tmp/atelier-mcp"))
        IPC.Config.remove(for: workstreamID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: IPC.Config.configURL(for: workstreamID).path))
    }

    // MARK: - Cursor plugin directory

    /// Cursor CLI has no `--mcp-config`; `--plugin-dir` is how one launch gets
    /// the server without touching `~/.cursor`. It lives beside the Claude
    /// config, in the cache directory, never in the worktree.
    func test_cursorPluginDirectory_livesInTheCacheDirectory_notTheWorktree() {
        let url = IPC.CursorPlugin.directoryURL(for: workstreamID)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, workstreamID.uuidString.lowercased())
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "cursor-plugin")
        XCTAssertTrue(url.path.hasPrefix(AppConstants.cacheDirectory.path), url.path)
    }

    /// The manifest Cursor needs to load the directory as a plugin at all, and
    /// the MCP file in the shape the Claude config already uses.
    /// Cursor names the agent's tools after the plugin directory, so it is
    /// `atelier`, never the workstream id.
    func test_cursorPluginDirectory_isNamedForTheToolsTheModelSees() {
        XCTAssertEqual(IPC.CursorPlugin.directoryURL(for: workstreamID).lastPathComponent, "atelier")
    }

    func test_cursorPluginWrite_producesAManifestAndTheMCPServer() throws {
        let path = try XCTUnwrap(IPC.CursorPlugin.write(for: workstreamID, helperPath: "/tmp/atelier-mcp"))
        XCTAssertEqual(path, IPC.CursorPlugin.directoryURL(for: workstreamID).path)
        let root = URL(fileURLWithPath: path)

        let manifestData = try Data(contentsOf: root.appendingPathComponent(".cursor-plugin/plugin.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, "atelier")

        let mcpData = try Data(contentsOf: root.appendingPathComponent(".mcp.json"))
        let mcp = try XCTUnwrap(try JSONSerialization.jsonObject(with: mcpData) as? [String: Any])
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["atelier-ipc"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "/tmp/atelier-mcp")
        XCTAssertEqual(server["type"] as? String, "stdio")
    }

    /// Cursor starts stdio MCP servers with a scrubbed environment (verified
    /// against cursor-agent 2026.10.22), so the helper would register with no
    /// identity at all. The `env` block hands each variable through by
    /// reference — `${env:NAME}`, which Cursor expands from the agent's own
    /// environment — so the per-workstream file still carries the per-tab
    /// surface id.
    func test_cursorPluginMCP_passesTheHelpersIdentityThroughByReference() throws {
        let path = try XCTUnwrap(IPC.CursorPlugin.write(for: workstreamID, helperPath: "/tmp/atelier-mcp"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(".mcp.json"))
        let mcp = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try XCTUnwrap((mcp["mcpServers"] as? [String: Any])?["atelier-ipc"] as? [String: Any])
        let env = try XCTUnwrap(server["env"] as? [String: String])

        XCTAssertEqual(env, [
            "ATELIER_WORKSTREAM_ID": "${env:ATELIER_WORKSTREAM_ID}",
            "ATELIER_WORKSTREAM": "${env:ATELIER_WORKSTREAM}",
            "ATELIER_PROJECT_DIR": "${env:ATELIER_PROJECT_DIR}",
            "ATELIER_SURFACE_ID": "${env:ATELIER_SURFACE_ID}",
            "ATELIER_PEER_NAME": "${env:ATELIER_PEER_NAME}",
        ])
    }

    /// The group variables are never set on a workstream tab, and Cursor leaves
    /// an unset reference as the literal `${env:NAME}` — which the helper would
    /// read as a group id.
    func test_cursorPluginMCP_neverReferencesAVariableATabDoesNotSet() throws {
        let path = try XCTUnwrap(IPC.CursorPlugin.write(for: workstreamID, helperPath: "/tmp/atelier-mcp"))
        let text = try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(".mcp.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("ATELIER_GROUP"), text)
    }

    func test_cursorPluginWrite_withoutAHelperBinary_returnsNil() {
        XCTAssertNil(IPC.CursorPlugin.write(for: workstreamID, helperPath: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: IPC.CursorPlugin.directoryURL(for: workstreamID).path))
    }

    func test_cursorPluginRemove_deletesTheDirectory() throws {
        _ = try XCTUnwrap(IPC.CursorPlugin.write(for: workstreamID, helperPath: "/tmp/atelier-mcp"))
        IPC.CursorPlugin.remove(for: workstreamID)
        let workstreamDirectory = IPC.CursorPlugin.directoryURL(for: workstreamID).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workstreamDirectory.path))
    }
}

/// Cursor asks before every MCP tool call unless the tool is allowlisted, and a
/// spawned peer's first call is `register_peer`, in a tab nobody may be
/// watching. `--approve-mcps` only loads the server. The allowlist that works
/// per user, without moving Cursor's config dir, is `~/.cursor/permissions.json`.
final class CursorPermissionsTests: XCTestCase {
    private var directory: URL!
    private var path: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("permissions.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Cursor names a plugin's server `plugin-<plugin>-<server>`, and the
    /// pattern is matched against that whole id: `atelier-ipc:*` alone does not.
    func testTheEntryNamesThePluginsServerAndEveryTool() {
        XCTAssertEqual(IPC.CursorPermissions.allowlistEntry, "plugin-atelier-atelier-ipc:*")
    }

    func testCreatesTheFileWithTheEntry() throws {
        IPC.CursorPermissions.install(at: path)
        XCTAssertEqual(try read()["mcpAllowlist"] as? [String], ["plugin-atelier-atelier-ipc:*"])
    }

    func testMergesIntoTheUsersOwnAllowlistAndKeys() throws {
        let existing: [String: Any] = ["mcpAllowlist": ["shortcut:*"], "other": true]
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: path))

        IPC.CursorPermissions.install(at: path)
        IPC.CursorPermissions.install(at: path)

        let file = try read()
        XCTAssertEqual(file["mcpAllowlist"] as? [String], ["shortcut:*", "plugin-atelier-atelier-ipc:*"])
        XCTAssertEqual(file["other"] as? Bool, true)
    }

    /// The file is JSONC to Cursor; one with a comment is the user's and is not
    /// rewritten by a parser that cannot read it.
    func testLeavesAFileItCannotParseAlone() throws {
        let jsonc = "{\n  // mine\n  \"mcpAllowlist\": [\"x:*\"],\n}\n"
        try Data(jsonc.utf8).write(to: URL(fileURLWithPath: path))

        IPC.CursorPermissions.install(at: path)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), jsonc)
    }
}
