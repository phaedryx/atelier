// ABOUTME: End-to-end test that rerunning bootstrap on an existing worktree reaches `.completed`.
// ABOUTME: Uses a real process-compose when present; skips cleanly when absent.

@testable import Atelier
import XCTest

/// The Info tab's Rerun button and the palette's Rerun Bootstrap both call
/// `setupExistingWorktree`, and the row above the button reports whatever state
/// comes back. `bootstrapRow(for: .completed)` pins the copy for a successful
/// rerun; nothing pinned that `.completed` is a state a rerun can actually
/// reach.
///
/// It matters because `.completed` is unreachable by any other route a user
/// sees. `AsyncSetupService.states` lives in memory, so every workstream reports
/// `.idle` after a relaunch — pressing Rerun is the only way an existing
/// workstream gets a `.completed` back, and if it did not, the button would run
/// a real bootstrap and give no sign that it had worked.
final class AsyncSetupRerunTests: XCTestCase {
    private var worktree: URL!
    private var projectDir: URL!
    private let workstreamID = UUID()
    /// The test host's `UserDefaults.standard` is the real app's, so switching
    /// the integration on here switches it on for whoever ran the suite. Saved
    /// and put back the way `ProcessComposeSettingsTests` does it — as the raw
    /// object, so a key that was never set goes back to never set rather than
    /// to an explicit `false`. `binaryPathKey` is cleared for the run as well:
    /// a configured path is used or fails and never falls back to a search, so
    /// a stale one in the user's defaults would defeat the skip check below.
    private var savedSettings: [String: Any?] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessCompose.Settings.searchPaths.contains(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("process-compose is not installed")
        }
        for key in [ProcessCompose.Settings.enabledKey, ProcessCompose.Settings.binaryPathKey] {
            savedSettings[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: ProcessCompose.Settings.binaryPathKey)
        ProcessCompose.Settings.isEnabled = true
        worktree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for (key, value) in savedSettings {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedSettings.removeAll()
        try? FileManager.default.removeItem(at: worktree)
        try? FileManager.default.removeItem(at: projectDir)
        try? FileManager.default.removeItem(atPath: ProcessCompose.PhaseRunner.socketPath(for: workstreamID, phase: .bootstrap))
        super.tearDown()
    }

    /// In the project directory, not the worktree: a config that came with the
    /// repository needs `ScriptTrust` approval, and approval is not what this
    /// test is about.
    private func writeProjectConfig(_ body: String) throws {
        try body.write(
            to: projectDir.appendingPathComponent("process-compose.yaml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func testRerunningOnAnExistingWorktreeReportsCompleted() async throws {
        try writeProjectConfig("""
        version: "0.5"
        processes:
          ok:
            namespace: bootstrap
            command: sh -c 'touch rerun-marker'
            availability: { restart: "no" }
        """)
        let service = AsyncSetupService()
        let before = await service.state(for: workstreamID)
        XCTAssertEqual(before, .idle, "A workstream nothing has bootstrapped this session")

        await service.setupExistingWorktree(
            workstreamID: workstreamID,
            projectName: "proj",
            workstreamName: "ws",
            projectPath: projectDir.path,
            worktreePath: worktree.path
        )

        let after = await service.state(for: workstreamID)
        XCTAssertEqual(after, .completed)
        XCTAssertTrue(canRerunBootstrap(after), "And the button comes back")
        XCTAssertEqual(bootstrapRow(for: after).detail, "Ran successfully.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("rerun-marker").path),
            "The rerun has to actually run the phase, not just report that it did"
        )
    }

    /// The other half of what the row promises: a rerun that can do nothing says
    /// why, rather than failing or reporting a success it did not have. This is
    /// the shape a user hits by pressing Rerun with no config in either home.
    func testRerunningWithNothingToRunReportsANote() async {
        let service = AsyncSetupService()

        await service.setupExistingWorktree(
            workstreamID: workstreamID,
            projectName: "proj",
            workstreamName: "ws",
            projectPath: projectDir.path,
            worktreePath: worktree.path
        )

        let state = await service.state(for: workstreamID)
        guard case let .completedWithNote(note) = state else {
            return XCTFail("Expected a note, got \(state)")
        }
        XCTAssertEqual(bootstrapRow(for: state).detail, note)
        XCTAssertTrue(canRerunBootstrap(state))
    }
}
