// ABOUTME: Tests for FilePersistence.writeAtomically's permissions and cleanup contract.
// ABOUTME: The token-adjacent files it writes must never be left group- or world-readable.

@testable import Atelier
import XCTest

final class FilePersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("file-persistence-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testWritesContentsAndCreatesTheParentDirectory() throws {
        let url = directory.appendingPathComponent("nested/state.json")
        try FilePersistence.writeAtomically(Data("{}".utf8), to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
        XCTAssertEqual(try permissions(of: url.deletingLastPathComponent()), 0o700)
    }

    func testANewFileIsOwnerReadableOnly() throws {
        let url = directory.appendingPathComponent("state.json")
        try FilePersistence.writeAtomically(Data("{}".utf8), to: url)

        XCTAssertEqual(try permissions(of: url), 0o600)
    }

    /// `replaceItemAt` preserves the *original* item's metadata by default, so
    /// tightening the temp file is not enough on its own: replacing a file that
    /// was already group-readable has to end up at 0600 too.
    func testReplacingALooserFileStillEndsAt0600() throws {
        let url = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("old".utf8),
            attributes: [.posixPermissions: 0o644]
        )

        try FilePersistence.writeAtomically(Data("new".utf8), to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual(try permissions(of: url), 0o600)
    }
}
