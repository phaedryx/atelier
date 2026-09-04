// ABOUTME: Tests that the retired OpenCode plugin is removed only when Atelier
// ABOUTME: wrote it, so a user's own plugin at that path survives.

@testable import Atelier
import XCTest

final class OpencodePluginRemoverTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePlugin(_ contents: String) throws -> String {
        let url = directory.appendingPathComponent("atelier.js")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testRecognizesTheInstallerMarker() {
        XCTAssertTrue(OpencodePluginRemover.isAtelierPlugin(
            contents: "// ATELIER_OPENCODE_PLUGIN version=9\nexport const Plugin = {}"
        ))
        XCTAssertFalse(OpencodePluginRemover.isAtelierPlugin(contents: "export const Plugin = {}"))
    }

    func testRemovesAPluginAtelierWrote() throws {
        let path = try writePlugin("// ATELIER_OPENCODE_PLUGIN version=9\nexport const Plugin = {}")
        OpencodePluginRemover.uninstall(at: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Someone else's plugin can sit at the same path; it must survive.
    func testLeavesAnUnmarkedPluginAlone() throws {
        let path = try writePlugin("export const Plugin = { name: 'mine' }")
        OpencodePluginRemover.uninstall(at: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// The absent file's own non-existence holds whatever `uninstall` did with it, so
    /// asserting it proved nothing. What "no-op" actually means here is that a path
    /// holding nothing leaves the rest of the directory alone.
    func testMissingPluginIsANoOp() throws {
        let neighbour = directory.appendingPathComponent("other.js")
        try "export const Other = {}".write(to: neighbour, atomically: true, encoding: .utf8)
        let path = directory.appendingPathComponent("absent.js").path

        OpencodePluginRemover.uninstall(at: path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["other.js"],
            "uninstall must not touch anything but the path it was given"
        )
    }

    /// Launch calls this unconditionally, so a second pass must not error.
    func testUninstallIsIdempotent() throws {
        let path = try writePlugin("// ATELIER_OPENCODE_PLUGIN version=9\n")
        OpencodePluginRemover.uninstall(at: path)
        OpencodePluginRemover.uninstall(at: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
