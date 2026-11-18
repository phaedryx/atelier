// ABOUTME: Runs Resources/Scripts/atelier-hook itself, with a stand-in curl, to pin what it posts.
// ABOUTME: Covers the --cursor path, whose directory is the only thing that attributes a Cursor event.

@testable import Atelier
import XCTest

@MainActor
final class AtelierHookScriptTests: XCTestCase {
    private var home: URL!
    private var bin: URL!
    private var workspace: URL!
    private var captured: URL!

    private var script: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Scripts/atelier-hook")
            .path
    }

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-hook-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        bin = root.appendingPathComponent("bin")
        workspace = root.appendingPathComponent("worktree")
        captured = root.appendingPathComponent("curl-args")
        let caches = home.appendingPathComponent("Library/Caches/atelier")
        for dir: URL in [caches, bin, workspace] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "4242".write(to: caches.appendingPathComponent("hook-port"), atomically: true, encoding: .utf8)

        // One argument per line; the body is the argument after `-d`.
        let curl = bin.appendingPathComponent("curl")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\n".write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Runs the script and returns the JSON body it posted, or nil when it posted nothing.
    private func run(_ arguments: [String], environment extra: [String: String]) throws -> [String: Any]? {
        var environment = [
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "CAPTURE": captured.path,
        ]
        environment.merge(extra) { _, new in new }
        let output = ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: [script] + arguments,
            environment: environment,
            currentDirectory: workspace,
            standardInput: Data(#"{"hook_event_name":"stop","cursor_version":"2026.10.19"}"#.utf8),
            timeout: 10
        )
        XCTAssertEqual(output?.status, 0)
        guard let args = try? String(contentsOf: captured, encoding: .utf8) else { return nil }
        let lines = args.components(separatedBy: "\n")
        let body = try XCTUnwrap(lines.firstIndex(of: "-d").map { lines[$0 + 1] })
        return try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    }

    /// Cursor exports no `CLAUDE_PROJECT_DIR`, and the app attributes a hook
    /// event by its directory alone, so the working directory Cursor runs the
    /// hook in is all that ties a Cursor tab's turns to its workstream. Without
    /// it a Cursor peer has no turn state and is never nudged.
    func test_cursor_withoutAProjectDirectory_reportsTheWorkingDirectory() throws {
        let body = try XCTUnwrap(run(["--cursor"], environment: ["ATELIER_SURFACE_ID": "S"]))

        let reported = try XCTUnwrap(body["project_dir"] as? String)
        XCTAssertEqual(
            Workstream.AgentStateTracker.normalize(reported),
            Workstream.AgentStateTracker.normalize(workspace.path)
        )
        XCTAssertEqual(body["surface_id"] as? String, "S")
    }

    /// The fallback is Cursor's alone: a Claude hook with no project directory
    /// is a session outside any workstream, and must stay unattributed rather
    /// than be pinned to wherever it happened to run.
    func test_claude_withoutAProjectDirectory_reportsNone() throws {
        let body = try XCTUnwrap(run([], environment: ["ATELIER_SURFACE_ID": "S"]))

        XCTAssertEqual(body["project_dir"] as? String, "")
    }

    /// Every Cursor session on the machine runs the global entry; only an
    /// Atelier surface has anything to report.
    func test_cursor_outsideAnAtelierSurface_postsNothing() throws {
        XCTAssertNil(try run(["--cursor"], environment: [:]))
    }
}
