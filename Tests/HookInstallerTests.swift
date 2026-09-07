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
        "SessionStart", "SessionEnd", "PreCompact", "PostCompact",
        "PermissionRequest",
    ]

    /// The one event registered with an argument, because its invocation blocks
    /// waiting for an answer instead of posting and exiting.
    private let decidingEvent = "PermissionRequest"

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

    /// The command a given event should end up registered with.
    private func expectedCommand(for event: String, path: String) -> String {
        event == decidingEvent ? "\(path) --permission" : path
    }

    private func timeouts(for event: String, in settings: [String: Any]) throws -> [Int] {
        try entries(for: event, in: settings).flatMap { entry -> [Int] in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["timeout"] as? Int }
        }
    }

    func testInstallsIntoEveryEventWhenSettingsDoNotExist() throws {
        let path = "/Apps/Atelier.app/atelier-hook"
        HookInstaller.install(hookScriptPath: path, at: settingsPath)

        let settings = try read()
        XCTAssertEqual(try Set(hooks(in: settings).keys), Set(events))
        for event in events {
            XCTAssertEqual(try commands(for: event, in: settings), [expectedCommand(for: event, path: path)])
        }
    }

    /// The blocking invocation is chosen by a flag on the registered command, so
    /// the `sh` script never has to find `hook_event_name` in the harness's JSON.
    func testOnlyPermissionRequestIsRegisteredToWaitForADecision() throws {
        let path = "/Apps/Atelier.app/atelier-hook"
        HookInstaller.install(hookScriptPath: path, at: settingsPath)

        let settings = try read()
        XCTAssertEqual(try commands(for: decidingEvent, in: settings), ["\(path) --permission"])
        for event in events where event != decidingEvent {
            XCTAssertEqual(try commands(for: event, in: settings), [path], "\(event) must not block")
        }
    }

    /// A hook killed mid-wait loses an answer the user is halfway through
    /// giving, so the deciding entry has to outlast the longest hold the app
    /// will take — and the reporting entries must not inherit that patience.
    func testTheDecidingEntryOutlastsTheLongestHold() throws {
        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        let settings = try read()
        let deciding = try XCTUnwrap(timeouts(for: decidingEvent, in: settings).first)
        XCTAssertGreaterThan(TimeInterval(deciding), PermissionApprovalSettings.maximumHold)
        XCTAssertEqual(try timeouts(for: "Stop", in: settings), [5])
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

    /// The upgrade path: a settings.json written by a build that registered
    /// fewer events must gain the new ones, without a second entry appearing
    /// under the events it already had.
    func testAddsEventsThatAPreviousInstallDidNotRegister() throws {
        let path = "/Apps/Atelier.app/atelier-hook"
        let stale = ["matcher": "", "hooks": [["type": "command", "command": path, "timeout": 5]]] as [String: Any]
        try write(["hooks": ["PreToolUse": [stale], "Stop": [stale]]])

        HookInstaller.install(hookScriptPath: path, at: settingsPath)

        let settings = try read()
        XCTAssertEqual(try Set(hooks(in: settings).keys), Set(events))
        for event in events {
            XCTAssertEqual(
                try commands(for: event, in: settings),
                [expectedCommand(for: event, path: path)],
                "duplicate entry under \(event)"
            )
        }
    }

    /// The upgrade path. A build that predates in-app approval registered a
    /// plain entry under PermissionRequest; left in place beside the new one,
    /// Claude Code would run the hook twice and the extra run is the one that
    /// answers nothing.
    func testReplacesAPlainEntryLeftUnderPermissionRequest() throws {
        let path = "/Apps/Atelier.app/atelier-hook"
        try write(["hooks": ["PermissionRequest": [foreignEntry(command: path)]]])

        HookInstaller.install(hookScriptPath: path, at: settingsPath)

        XCTAssertEqual(try commands(for: "PermissionRequest", in: read()), ["\(path) --permission"])
    }

    /// And the same in reverse, so a reordering of the event list cannot leave a
    /// blocking invocation registered against an event that only reports.
    func testReplacesADecidingEntryLeftUnderAReportingEvent() throws {
        let path = "/Apps/Atelier.app/atelier-hook"
        try write(["hooks": ["Stop": [foreignEntry(command: "\(path) --permission")]]])

        HookInstaller.install(hookScriptPath: path, at: settingsPath)

        XCTAssertEqual(try commands(for: "Stop", in: read()), [path])
    }

    /// Replacing a wrong-shaped entry must not turn into replacing someone
    /// else's: the path stays out of the comparison, so another copy of Atelier
    /// keeps managing its own entry.
    func testAnotherPathsEntryOfTheRightShapeIsLeftAlone() throws {
        try write(["hooks": ["PermissionRequest": [foreignEntry(command: "/old/atelier-hook --permission")]]])

        HookInstaller.install(hookScriptPath: "/new/atelier-hook", at: settingsPath)

        XCTAssertEqual(try commands(for: "PermissionRequest", in: read()), ["/old/atelier-hook --permission"])
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

    // MARK: - Hand-edited shapes

    /// Claude Code takes a bare object where the schema shows an array, and
    /// people write settings.json by hand. `as? [[String: Any]] ?? []` returned
    /// nil for that shape and the `?? []` then *replaced* the user's entry
    /// instead of appending beside it.
    func testKeepsASingleObjectEntryWrittenByHand() throws {
        let foreign: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-hook"]],
        ]
        try write(["hooks": ["PreToolUse": foreign]])

        HookInstaller.install(hookScriptPath: "/Apps/Atelier.app/atelier-hook", at: settingsPath)

        let commands = try entries(for: "PreToolUse", in: read())
            .compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        XCTAssertEqual(commands.count, 2, "The hand-written entry must survive alongside ours")
        XCTAssertTrue(commands.contains("/usr/local/bin/my-hook"))
        XCTAssertTrue(commands.contains("/Apps/Atelier.app/atelier-hook"))
    }

    func testUninstallRemovesOurEntryFromASingleObjectShape() throws {
        let ours: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": "/Apps/Atelier.app/atelier-hook"]],
        ]
        try write(["hooks": ["Stop": ours]])

        HookInstaller.uninstall(at: settingsPath)

        let settings = try read()
        XCTAssertNil((settings["hooks"] as? [String: Any])?["Stop"])
    }
}
