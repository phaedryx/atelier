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

    /// A worktree config is left unnamed so process-compose's own discovery
    /// runs, and discovery loads a sibling `process-compose.override.yaml` that
    /// `locate` never records — `overridePath` is nil here by design. The probe
    /// has to read the same files process-compose will, or a namespace declared
    /// only in the override reads as absent and the phase is silently skipped.
    func testOverrideDiscoveredBesideAWorktreeConfigCounts() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        try writeProcesses("""
          seed:
            namespace: bootstrap
            command: "true"
        """, name: "process-compose.override.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertNil(config.overridePath, "discovery finds it; locate does not name it")
        XCTAssertEqual(config.namespacePresence("bootstrap"), .present)
        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
    }

    /// process-compose loads exactly one override, and with both extensions
    /// present it takes `.yml` — the opposite of the order `overrideFileNames`
    /// lists. Taking only the first would read the file that is not loaded, so
    /// every present override counts: over-reading can only make the probe run
    /// a phase, while under-reading skips one silently.
    func testEitherOverrideExtensionCounts() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        try writeProcesses("""
          noise:
            namespace: execute
            command: "true"
        """, name: "process-compose.override.yaml", in: worktree)
        try writeProcesses("""
          seed:
            namespace: bootstrap
            command: "true"
        """, name: "process-compose.override.yml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("bootstrap"), .present)
    }

    /// The same file beside a *project-directory* config is not loaded:
    /// naming the base with `-f` turns discovery off, so only files named
    /// explicitly count.
    func testOverrideBesideAProjectConfigIsNotCountedUnlessNamed() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: project)
        try writeProcesses("""
          seed:
            namespace: bootstrap
            command: "true"
        """, name: "process-compose.override.yaml", in: project)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.isRepositoryProvided)
        XCTAssertEqual(config.namespacePresence("bootstrap"), .empty)
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

    // MARK: - What has to be approved

    /// The base config in the worktree is repository content, so it is approved.
    func testWorktreeConfigRequiresApproval() throws {
        try write("process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertTrue(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [worktree.appendingPathComponent("process-compose.yaml").path])
    }

    /// The first hole this closes. A repository ships a benign base config and
    /// an override beside it; `locate` records only the base, but
    /// process-compose's own discovery loads both. Approving the base alone
    /// would show the user one file while another executed unattended.
    func testWorktreeOverrideIsPartOfWhatIsApproved() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertNil(config.overridePath, "locate does not record a discovered override")
        XCTAssertTrue(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [
            worktree.appendingPathComponent("process-compose.yaml").path,
            worktree.appendingPathComponent("process-compose.override.yaml").path,
        ])
    }

    /// A config the user placed in the project directory, with nothing in the
    /// worktree, is theirs: nothing to approve.
    func testProjectDirectoryConfigAloneRequiresNoApproval() throws {
        try write("process-compose.yaml", in: project)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [])
    }

    /// The second and worse hole. The user's own config sits in the project
    /// directory, so `isRepositoryProvided` is false — but `overridePath` points
    /// into the *worktree* and is named with `-f` explicitly, so repository
    /// content executes. Gating on `isRepositoryProvided` alone would leave this
    /// completely ungated.
    func testWorktreeOverrideBesideAUserConfigStillRequiresApproval() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.override.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.isRepositoryProvided)
        XCTAssertTrue(config.requiresApproval, "a worktree override is repository content whatever the base config is")
        XCTAssertEqual(config.repositoryProvidedFiles, [worktree.appendingPathComponent("process-compose.override.yaml").path])
    }

    /// The user's own project-directory file is never in the approved set, so
    /// editing it does not re-ask. It is theirs, placed by hand outside git.
    func testTheUsersOwnConfigIsNeverInTheApprovedSet() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.override.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.repositoryProvidedFiles.contains(project.appendingPathComponent("process-compose.yaml").path))
    }
}
