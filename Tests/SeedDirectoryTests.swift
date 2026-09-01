// ABOUTME: Tests for resolving a project's seed directory, including the rename fallback.
// ABOUTME: seed-files is the default; .atelier-seed still works for projects set up before it.

@testable import Atelier
import XCTest

final class SeedDirectoryTests: XCTestCase {
    private var project: URL!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: project)
        super.tearDown()
    }

    func testDefaultsToSeedFiles() {
        let resolved = WorktreeSetupConfig.default.seedDirectory(in: project.path)

        XCTAssertEqual(resolved, project.appendingPathComponent("seed-files").path)
    }

    func testPrefersSeedFilesWhenBothExist() throws {
        try makeDirectory("seed-files")
        try makeDirectory(".atelier-seed")

        let resolved = WorktreeSetupConfig.default.seedDirectory(in: project.path)

        XCTAssertEqual(resolved, project.appendingPathComponent("seed-files").path)
    }

    /// A project seeded before the rename keeps working; nothing in the
    /// repository records which name it used.
    func testFallsBackToLegacyNameWhenOnlyItExists() throws {
        try makeDirectory(".atelier-seed")

        let resolved = WorktreeSetupConfig.default.seedDirectory(in: project.path)

        XCTAssertEqual(resolved, project.appendingPathComponent(".atelier-seed").path)
    }

    /// An explicit `seed` is never second-guessed, even when the old default is
    /// sitting right there.
    func testExplicitSeedIgnoresTheFallback() throws {
        try makeDirectory(".atelier-seed")
        var config = WorktreeSetupConfig.default
        config.seed = "config/secrets"

        let resolved = config.seedDirectory(in: project.path)

        XCTAssertEqual(resolved, project.appendingPathComponent("config/secrets").path)
    }

    /// A seed that escapes the project falls back to the default, which then
    /// gets the legacy treatment like any other default.
    func testEscapingSeedFallsBackToTheDefault() {
        var config = WorktreeSetupConfig.default
        config.seed = "../elsewhere"

        let resolved = config.seedDirectory(in: project.path)

        XCTAssertEqual(resolved, project.appendingPathComponent("seed-files").path)
    }

    private func makeDirectory(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
}
