// ABOUTME: Tests for the per-workstream MCP config Atelier writes for Claude Code.
// ABOUTME: Checks the stdio server shape, the cache-directory location, and the missing-helper case.

@testable import Atelier
import XCTest

final class IPCConfigTests: XCTestCase {
    private let workstreamID = UUID()

    override func tearDown() {
        IPC.Config.remove(for: workstreamID)
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
}
