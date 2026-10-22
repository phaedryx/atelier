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
