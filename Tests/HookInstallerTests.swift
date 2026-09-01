// ABOUTME: Tests for merging atelier-hook entries into Claude Code's settings.json.
// ABOUTME: Covers idempotency, preservation of foreign entries, and refusal to clobber bad JSON.

@testable import Atelier
import XCTest

final class HookInstallerTests: XCTestCase {
    private var settingsPath: String!
    private var directory: URL!

    /// Every event `HookInstaller` registers for. Kept here rather than read
    /// from the type so a silent change to that list fails a test.
    private let events = [
        "PreToolUse", "PostToolUse", "Stop", "SubagentStart",
        "SubagentStop", "UserPromptSubmit", "Notification",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsPath = directory.appendingPathComponent("settings.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hooks(in settings: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(settings["hooks"] as? [String: Any])
    }

    private func entries(for event: String, in settings: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(hooks(in: settings)[event] as? [[String: Any]])
    }

    private func commands(for event: String, in settings: [String: Any]) throws -> [String] {
        try entries(for: event, in: settings).flatMap { entry -> [String] in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// A foreign hook entry, shaped like Claude Code's own.
    private func foreignEntry(command: String) -> [String: Any] {
        ["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 10]]]
    }

    // MARK: - Install

    func testInstallsIntoEveryEventWhenSettingsDoNotExist() throws {
        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        let settings = try read()
        XCTAssertEqual(try Set(hooks(in: settings).keys), Set(events))
        for event in events {
            XCTAssertEqual(try commands(for: event, in: settings), ["/Apps/Atelier.app/atelier-hook"])
        }
    }

    /// The property the ABOUTME claims: installing twice must not double up.
    func testInstallIsIdempotent() throws {
        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)
        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        let settings = try read()
        for event in events {
            XCTAssertEqual(try entries(for: event, in: settings).count, 1, "duplicated entry for \(event)")
        }
    }

    /// Detection is by command *containing* "atelier-hook", so an entry left by
    /// an older install at a different path counts as already installed.
    func testDoesNotAddASecondEntryWhenTheHookIsRegisteredUnderAnotherPath() throws {
        try write(["hooks": ["Stop": [foreignEntry(command: "/old/location/atelier-hook")]]])

        HookInstaller.install(hookScriptPath: "/new/location/atelier-hook", at: settingsPath)

        XCTAssertEqual(try commands(for: "Stop", in: read()), ["/old/location/atelier-hook"])
    }

    func testPreservesForeignHooksAndUnrelatedSettings() throws {
        try write([
            "model": "opus",
            "hooks": ["Stop": [foreignEntry(command: "/usr/local/bin/other-tool")]],
        ])

        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        let settings = try read()
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(
            try commands(for: "Stop", in: settings),
            ["/usr/local/bin/other-tool", "/Apps/Atelier.app/atelier-hook"]
        )
    }

    func testQuotesAHookPathContainingSpaces() throws {
        HookInstaller.install(hookScriptPath: "/Apps/My Atelier.app/atelier-hook", at: settingsPath)

        XCTAssertEqual(try commands(for: "Stop", in: read()), ["\"/Apps/My Atelier.app/atelier-hook\""])
    }

    /// Settings this app cannot parse belong to the user, not to us.
    func testLeavesUnparseableSettingsUntouched() throws {
        let garbage = "{ this is not json"
        try garbage.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        XCTAssertEqual(try String(contentsOfFile: settingsPath, encoding: .utf8), garbage)
    }

    // MARK: - Uninstall

    func testUninstallRemovesEveryEventItInstalled() throws {
        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        HookInstaller.uninstall(at: settingsPath)

        XCTAssertNil(try read()["hooks"], "an empty hooks dictionary should be dropped entirely")
    }

    func testUninstallKeepsForeignHooksAndUnrelatedSettings() throws {
        try write([
            "model": "opus",
            "hooks": ["Stop": [foreignEntry(command: "/usr/local/bin/other-tool")]],
        ])
        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        HookInstaller.uninstall(at: settingsPath)

        let settings = try read()
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(try commands(for: "Stop", in: settings), ["/usr/local/bin/other-tool"])
        XCTAssertNil(try hooks(in: settings)["PreToolUse"], "events we solely occupied should be gone")
    }

    func testUninstallIsSafeWhenNothingIsInstalled() throws {
        try write(["model": "opus"])

        HookInstaller.uninstall(at: settingsPath)

        XCTAssertEqual(try read()["model"] as? String, "opus")
    }

    func testUninstallIsSafeWhenSettingsDoNotExist() {
        HookInstaller.uninstall(at: settingsPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))
    }
}
