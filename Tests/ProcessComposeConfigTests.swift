// ABOUTME: Tests for locating a worktree's process-compose config.
// ABOUTME: Worktree wins over the project directory; authorship follows location.

@testable import Atelier
import XCTest

final class ProcessComposeConfigTests: XCTestCase {
    private var worktree: URL!
    private var project: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("project")
        worktree = project.appendingPathComponent("wt")
        try! FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        super.tearDown()
    }

    private func write(_ name: String, in dir: URL) throws {
        try "processes:\\n  web:\\n    command: echo hi\\n"
            .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testFindsConfigInWorktree() throws {
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.path, worktree.appendingPathComponent("process-compose.yaml").path)
        XCTAssertTrue(config.isRepositoryProvided)
        XCTAssertNil(config.overridePath)
    }

    func testFindsConfigInProjectDirectory() throws {
        try write("process-compose.yaml", in: project)

        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.path, project.appendingPathComponent("process-compose.yaml").path)
        XCTAssertFalse(config.isRepositoryProvided)
    }

    func testWorktreeWinsOverProjectDirectory() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.path, worktree.appendingPathComponent("process-compose.yaml").path)
    }

    /// Only a project-directory config needs the override named explicitly —
    /// a worktree config keeps process-compose's own discovery.
    func testOverrideFoundOnlyForProjectDirectoryConfig() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.override.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.overridePath, worktree.appendingPathComponent("process-compose.override.yaml").path)
    }

    func testWorktreeConfigReportsNoOverride() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertNil(config.overridePath, "discovery finds it; naming it would disable discovery")
    }

    /// A plain checkout passes the same path for both. The project-directory
    /// branch must not re-find the worktree's own config.
    func testSamePathForBothIsTreatedAsWorktree() throws {
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: worktree.path)
        )

        XCTAssertTrue(config.isRepositoryProvided)
    }

    func testNoConfigAnywhere() {
        XCTAssertNil(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))
    }

    func testIgnoresBareComposeFile() throws {
        try "services: {}".write(
            to: worktree.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8
        )

        XCTAssertNil(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))
    }
}
