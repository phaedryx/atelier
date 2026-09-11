// ABOUTME: Tests for the status line channel — payload parsing, the --settings
// ABOUTME: file it registers, and its precedence over the transcript reader.

@testable import Atelier
import XCTest

final class StatusLineChannelTests: XCTestCase {
    // MARK: - Payload

    private func payload(used: Int?, size: Int?, projectDir: String? = "/tmp/ws", cwd: String? = nil) -> [String: Any] {
        var window: [String: Any] = [:]
        if let used {
            window["total_input_tokens"] = used
        }
        if let size {
            window["context_window_size"] = size
        }
        var payload: [String: Any] = ["context_window": window]
        if let projectDir {
            payload["workspace"] = ["project_dir": projectDir]
        }
        if let cwd {
            payload["cwd"] = cwd
        }
        return payload
    }

    func test_reading_takesTokensAndWindowFromThePayload() {
        let reading = StatusLine.reading(payload: payload(used: 45127, size: 1_000_000))
        XCTAssertEqual(reading, StatusLine.Reading(usedTokens: 45127, limitTokens: 1_000_000))
    }

    func test_reading_acceptsJSONNumbersDecodedAsDouble() throws {
        let json = "{\"context_window\":{\"total_input_tokens\":42.0,\"context_window_size\":200000.0}}"
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(StatusLine.reading(payload: object)?.usedTokens, 42)
    }

    func test_reading_isNilBeforeTheFirstAPIResponse() {
        XCTAssertNil(StatusLine.reading(payload: ["workspace": ["project_dir": "/tmp/ws"]]))
        XCTAssertNil(StatusLine.reading(payload: payload(used: nil, size: 200_000)))
    }

    /// A window of zero would divide into a full bar for any token count.
    func test_reading_isNilWhenTheWindowIsUnknown() {
        XCTAssertNil(StatusLine.reading(payload: payload(used: 1000, size: 0)))
        XCTAssertNil(StatusLine.reading(payload: payload(used: 1000, size: nil)))
    }

    func test_projectDir_prefersTheLaunchDirectoryOverCwd() {
        let object = payload(used: 1, size: 2, projectDir: "/tmp/ws", cwd: "/tmp/ws/sub")
        XCTAssertEqual(StatusLine.projectDir(payload: object), "/tmp/ws")
    }

    func test_projectDir_fallsBackToCwd() {
        let object = payload(used: 1, size: 2, projectDir: nil, cwd: "/tmp/ws/sub")
        XCTAssertEqual(StatusLine.projectDir(payload: object), "/tmp/ws/sub")
    }

    func test_projectDir_isNilWithNeither() {
        XCTAssertNil(StatusLine.projectDir(payload: payload(used: 1, size: 2, projectDir: nil)))
    }

    // MARK: - The --settings file

    private func settingsJSON(at path: String) -> [String: Any] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func statusLineCommand(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    func test_configWrite_registersTheScriptChainedToTheUsersCommand() throws {
        let id = UUID()
        defer { StatusLine.Config.remove(for: id) }

        let path = try XCTUnwrap(StatusLine.Config.write(
            for: id,
            cwd: nil,
            scriptPath: "/Apps/Atelier.app/Contents/Resources/atelier-statusline",
            innerCommand: "jq -r '.model.display_name'"
        ))

        let command = try XCTUnwrap(statusLineCommand(in: settingsJSON(at: path)))
        XCTAssertTrue(command.hasPrefix("/Apps/Atelier.app/Contents/Resources/atelier-statusline "))
        XCTAssertTrue(
            command.hasSuffix(#"'jq -r '\''.model.display_name'\'''"#),
            "a command with spaces or quotes reaches the script as one argument: \(command)"
        )
        XCTAssertEqual(
            (settingsJSON(at: path)["statusLine"] as? [String: Any])?["type"] as? String,
            "command"
        )
    }

    /// The settings file carries `statusLine` and nothing else: `--settings`
    /// merges per key, so anything extra here would silently override the user's
    /// own value for that key.
    func test_configWrite_setsNoKeyButStatusLine() throws {
        let id = UUID()
        defer { StatusLine.Config.remove(for: id) }
        let path = try XCTUnwrap(StatusLine.Config.write(
            for: id, cwd: nil, scriptPath: "/s", innerCommand: "mine"
        ))
        XCTAssertEqual(Array(settingsJSON(at: path).keys), ["statusLine"])
    }

    /// The gate the whole feature turns on: no configured status line, no
    /// registration. Registering one would hide Claude Code's footer hints to
    /// show a row with nothing in it.
    func test_configWrite_declinesWhenTheUserHasNoStatusLine() {
        let id = UUID()
        defer { StatusLine.Config.remove(for: id) }
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-no-statusline-\(UUID().uuidString)")
        XCTAssertNil(StatusLine.Config.write(for: id, cwd: nil, scriptPath: "/s", innerCommand: ""))
        XCTAssertNil(StatusLine.Config.write(for: id, cwd: nil, scriptPath: "/s", homeDirectory: home))
    }

    func test_configWrite_declinesWithoutTheBundledScript() {
        let id = UUID()
        XCTAssertNil(StatusLine.Config.write(for: id, cwd: nil, scriptPath: nil, innerCommand: "mine"))
    }

    /// Chaining our own script would recurse for the life of the session.
    func test_configWrite_refusesToChainItself() {
        let id = UUID()
        defer { StatusLine.Config.remove(for: id) }
        XCTAssertNil(StatusLine.Config.write(
            for: id,
            cwd: nil,
            scriptPath: "/s",
            innerCommand: "/Apps/Atelier.app/Contents/Resources/atelier-statusline 'inner'"
        ))
    }

    func test_configRemove_deletesTheFile() throws {
        let id = UUID()
        let path = try XCTUnwrap(StatusLine.Config.write(
            for: id, cwd: nil, scriptPath: "/s", innerCommand: "mine"
        ))
        StatusLine.Config.remove(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Reading the user's configured status line

    private func writeSettings(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func test_statusLineCommand_readsTheUserSettings() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-statusline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSettings(
            ["statusLine": ["type": "command", "command": "~/.claude/status-line"]],
            to: home.appendingPathComponent(".claude/settings.json")
        )

        XCTAssertEqual(
            ClaudeCodeSettings.statusLineCommand(cwd: nil, homeDirectory: home),
            "~/.claude/status-line"
        )
    }

    func test_statusLineCommand_prefersTheProjectFile() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-statusline-\(UUID().uuidString)")
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-worktree-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cwd)
        }
        try writeSettings(
            ["statusLine": ["type": "command", "command": "user"]],
            to: home.appendingPathComponent(".claude/settings.json")
        )
        try writeSettings(
            ["statusLine": ["type": "command", "command": "project"]],
            to: cwd.appendingPathComponent(".claude/settings.json")
        )

        XCTAssertEqual(
            ClaudeCodeSettings.statusLineCommand(cwd: cwd.path, homeDirectory: home),
            "project"
        )
    }

    /// A shape this does not recognise has to read as "leave it alone", not as
    /// "there is nothing there" — the latter would register over it.
    func test_statusLineCommand_ignoresANonCommandStatusLine() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-statusline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSettings(
            ["statusLine": ["type": "something-else", "command": "~/.claude/status-line"]],
            to: home.appendingPathComponent(".claude/settings.json")
        )

        XCTAssertNil(ClaudeCodeSettings.statusLineCommand(cwd: nil, homeDirectory: home))
    }

    func test_statusLineCommand_isNilWithNoSettingsFile() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-absent-\(UUID().uuidString)")
        XCTAssertNil(ClaudeCodeSettings.statusLineCommand(cwd: nil, homeDirectory: home))
    }
}
