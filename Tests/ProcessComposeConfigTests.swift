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

    /// When worktree and project directory paths are the same (plain checkout),
    /// the result is marked as repository-provided.
    func testSamePathForBothResolvesAsRepositoryProvided() throws {
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

    // MARK: - Namespace declarations

    private func writeProcesses(_ body: String, name: String = "process-compose.yaml", in dir: URL) throws {
        try "processes:\n\(body)".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testNotConfidentlyEmptyWhenAProcessDeclaresTheNamespace() throws {
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.namespaceIsConfidentlyEmpty("prepare"))
    }

    func testConfidentlyEmptyWhenNoProcessDeclaresTheNamespace() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertTrue(config.namespaceIsConfidentlyEmpty("prepare"))
    }

    /// A process with no `namespace:` key belongs to process-compose's own
    /// default namespace, not to `prepare` — it must not count toward it.
    func testUnnamespacedProcessDoesNotSatisfyAnyNamespace() throws {
        try writeProcesses("""
          web:
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertTrue(config.namespaceIsConfidentlyEmpty("prepare"))
        XCTAssertTrue(config.namespaceIsConfidentlyEmpty("execute"))
    }

    /// A namespace declared only in the override file still counts — the
    /// override can add processes the base file never mentions.
    func testNamespaceDeclaredOnlyInTheOverrideStillCounts() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: project)
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, name: "process-compose.override.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.namespaceIsConfidentlyEmpty("prepare"))
    }

    /// An unreadable file must fail open: never mistaken for "no namespaces".
    func testFailsOpenWhenTheFileCannotBeRead() {
        let config = ProcessComposeConfig(
            path: "/nonexistent/process-compose.yaml", isRepositoryProvided: true, overridePath: nil
        )

        XCTAssertFalse(config.namespaceIsConfidentlyEmpty("prepare"))
    }

    /// Malformed YAML must fail open the same way — a parse bug must never
    /// masquerade as an empty namespace and cause a declared phase to be
    /// silently skipped.
    func testFailsOpenWhenTheFileIsMalformed() throws {
        try "processes: {web: {command: \"true\"".write(
            to: worktree.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8
        )
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.namespaceIsConfidentlyEmpty("prepare"))
    }

    /// A config with no `processes:` key at all doesn't parse as a
    /// process-compose config in the shape this reads — fail open rather
    /// than treat it as confidently declaring nothing.
    func testFailsOpenWhenProcessesKeyIsMissing() throws {
        try "version: \"0.5\"".write(
            to: worktree.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8
        )
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.namespaceIsConfidentlyEmpty("prepare"))
    }
}
