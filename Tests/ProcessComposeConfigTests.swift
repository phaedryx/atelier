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

    private func write(_ name: String, in dir: URL, contents: String) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func write(_ name: String, in dir: URL) throws {
        try "processes:\\n  web:\\n    command: echo hi\\n"
            .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testFindsConfigInWorktree() throws {
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.path, worktree.appendingPathComponent("process-compose.yaml").path)
        XCTAssertTrue(config.isRepositoryProvided)
        XCTAssertNil(config.overridePath)
    }

    func testFindsConfigInProjectDirectory() throws {
        try write("process-compose.yaml", in: project)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.path, project.appendingPathComponent("process-compose.yaml").path)
        XCTAssertFalse(config.isRepositoryProvided)
    }

    func testWorktreeWinsOverProjectDirectory() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.path, worktree.appendingPathComponent("process-compose.yaml").path)
    }

    /// `overridePath` is only recorded for a project-directory base. A worktree
    /// base finds its sibling override through `loadedFiles` instead, so the
    /// property being nil there says nothing about whether one exists.
    func testOverrideFoundOnlyForProjectDirectoryConfig() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.override.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.overridePath, worktree.appendingPathComponent("process-compose.override.yaml").path)
    }

    func testWorktreeConfigReportsNoOverride() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertNil(config.overridePath, "a worktree base resolves its sibling override through loadedFiles")
    }

    /// When worktree and project directory paths are the same (plain checkout),
    /// the result is marked as repository-provided.
    func testSamePathForBothResolvesAsRepositoryProvided() throws {
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: worktree.path)
        )

        XCTAssertTrue(config.isRepositoryProvided)
    }

    func testNoConfigAnywhere() {
        XCTAssertNil(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))
    }

    func testIgnoresBareComposeFile() throws {
        try "services: {}".write(
            to: worktree.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8
        )

        XCTAssertNil(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))
    }

    // MARK: - Namespace declarations

    private func writeProcesses(_ body: String, name: String = "process-compose.yaml", in dir: URL) throws {
        try "processes:\n\(body)".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A sibling override beside a worktree base is loaded, and `locate` does
    /// not record it — `overridePath` is nil here by design, and `loadedFiles`
    /// is what resolves it. The probe has to read the same files
    /// process-compose will be told to load, or a namespace declared only in the
    /// override reads as absent and the phase is silently skipped.
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
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertNil(config.overridePath, "loadedFiles resolves it; locate does not record it")
        XCTAssertEqual(config.namespacePresence("bootstrap"), .present)
        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
    }

    /// Exactly one override is loaded, and it is the one process-compose itself
    /// prefers: with both extensions present it takes `.yml` (verified against
    /// v1.122.0). So a namespace declared only in the ignored `.yaml` must read
    /// as absent — the probe's job is to describe what will run, and naming both
    /// would make Atelier run a file process-compose would have skipped.
    func testOnlyThePreferredOverrideExtensionCounts() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        try writeProcesses("""
          ignored:
            namespace: prepare
            command: "true"
        """, name: "process-compose.override.yaml", in: worktree)
        try writeProcesses("""
          seed:
            namespace: bootstrap
            command: "true"
        """, name: "process-compose.override.yml", in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.loadedFiles, [
            worktree.appendingPathComponent("process-compose.yaml").path,
            worktree.appendingPathComponent("process-compose.override.yml").path,
        ])
        XCTAssertEqual(config.namespacePresence("bootstrap"), .present, "declared in the loaded .yml")
        XCTAssertEqual(config.namespacePresence("prepare"), .empty, "declared only in the ignored .yaml")
    }

    /// The same file beside a *project-directory* config is only loaded when
    /// `locate` recorded it as `overridePath`. Every loaded file is named with
    /// `-f`, so nothing outside `loadedFiles` ever counts.
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
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.isRepositoryProvided)
        XCTAssertEqual(config.namespacePresence("bootstrap"), .empty)
    }

    func testNamespaceIsPresentWhenAProcessDeclaresIt() throws {
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("prepare"), .present)
    }

    func testNamespaceIsEmptyWhenNoProcessDeclaresIt() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
    }

    /// A process with no `namespace:` key belongs to process-compose's own
    /// default namespace, not to `prepare` — it must not count toward it.
    func testUnnamespacedProcessDoesNotSatisfyAnyNamespace() throws {
        try writeProcesses("""
          web:
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
        XCTAssertEqual(config.namespacePresence("execute"), .empty)
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
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("prepare"), .present)
    }

    /// An unreadable file is `.unknown`, never mistaken for "no namespaces".
    /// The three `.unknown` cases below are asserted as `.unknown` rather than
    /// as "not empty", which is what they used to say through
    /// `namespaceIsConfidentlyEmpty`. That distinction is now load-bearing:
    /// `ProcessCompose.PhaseRunner.startCommand` chains `prepare` only on `.present`, because
    /// chaining it on an unparseable config hangs Start forever, while
    /// `ProcessCompose.PhaseExecutor` still runs an `.unknown` phase on a bounded leash.
    func testUnknownWhenTheFileCannotBeRead() {
        let config = ProcessCompose.Config(
            path: "/nonexistent/process-compose.yaml", isRepositoryProvided: true, overridePath: nil
        )

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    /// Malformed YAML is `.unknown` the same way — a parse bug must never
    /// masquerade as an empty namespace and cause a declared phase to be
    /// silently skipped.
    func testUnknownWhenTheFileIsMalformed() throws {
        try "processes: {web: {command: \"true\"".write(
            to: worktree.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8
        )
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    /// A config with no `processes:` key at all doesn't parse as a
    /// process-compose config in the shape this reads — `.unknown` rather
    /// than treating it as confidently declaring nothing.
    func testUnknownWhenProcessesKeyIsMissing() throws {
        try "version: \"0.5\"".write(
            to: worktree.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8
        )
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    // MARK: - What has to be approved

    /// The base config in the worktree is repository content, so it is approved.
    func testWorktreeConfigRequiresApproval() throws {
        try write("process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertTrue(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [worktree.appendingPathComponent("process-compose.yaml").path])
    }

    /// The first hole this closes. A repository ships a benign base config and
    /// an override beside it; `locate` records only the base, but both are
    /// loaded and run. Approving the base alone would show the user one file
    /// while another executed unattended.
    func testWorktreeOverrideIsPartOfWhatIsApproved() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertNil(config.overridePath, "locate does not record the sibling override")
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
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

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
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertFalse(config.isRepositoryProvided)
        XCTAssertTrue(config.requiresApproval, "a worktree override is repository content whatever the base config is")
        XCTAssertEqual(config.repositoryProvidedFiles, [worktree.appendingPathComponent("process-compose.override.yaml").path])
    }

    // MARK: - The files that will execute

    /// The whole point of naming files with `-f`: what runs is what was
    /// approved. `compose.yaml` is loaded by process-compose's own discovery
    /// (verified against v1.122.0, where it wins outright over
    /// `process-compose.yaml`) but Atelier deliberately never detects that name,
    /// so leaving discovery on let a repository have one file approved and a
    /// different one run.
    func testComposeYamlIsNeverLoaded() throws {
        try write("process-compose.yaml", in: worktree)
        try write("compose.yaml", in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.loadedFiles, [worktree.appendingPathComponent("process-compose.yaml").path])
        XCTAssertFalse(config.loadedFiles.contains { $0.hasSuffix("/compose.yaml") })
        XCTAssertFalse(config.repositoryProvidedFiles.contains { $0.hasSuffix("/compose.yaml") })
    }

    /// Exactly one override, and the one process-compose itself would have
    /// picked. Verified against v1.122.0: with both extensions present,
    /// discovery loads `.yml` and ignores `.yaml`. Naming both would run a file
    /// discovery would have skipped.
    func testOnlyTheOverrideProcessComposePrefersIsLoaded() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yaml", in: worktree)
        try write("process-compose.override.yml", in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.loadedFiles, [
            worktree.appendingPathComponent("process-compose.yaml").path,
            worktree.appendingPathComponent("process-compose.override.yml").path,
        ])
    }

    /// Approval covers the files that execute, and only those: the base config
    /// plus its override, with the user's own project-directory file excluded
    /// and `compose.yaml` never in the picture at all.
    func testApprovedSetEqualsTheExecutedSetForARepositoryConfig() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yml", in: worktree)
        let config = try XCTUnwrap(ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path))

        XCTAssertEqual(config.repositoryProvidedFiles, config.loadedFiles)
    }

    // MARK: - Declared processes

    func testDeclaredProcessesListsOnlyTheNamedNamespace() throws {
        try write("process-compose.yaml", in: worktree, contents: """
        processes:
          seed:   { namespace: bootstrap, command: "true" }
          checks: { namespace: prepare,   command: "true" }
          bff:    { namespace: execute,   command: "true" }
          api:    { namespace: execute,   command: "true" }
          orphan: { command: "true" }
        """)
        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.declaredProcesses(in: "execute"), ["api", "bff"])
        XCTAssertEqual(config.declaredProcesses(in: "bootstrap"), ["seed"])
        XCTAssertEqual(config.declaredProcesses(in: "dispose"), [])
    }

    /// A process with no `namespace:` belongs to process-compose's default
    /// namespace, so it must not be offered as an `execute` choice.
    func testAProcessWithNoNamespaceIsNotInExecute() throws {
        try write("process-compose.yaml", in: worktree, contents: """
        processes:
          orphan: { command: "true" }
        """)
        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertEqual(config.declaredProcesses(in: "execute"), [])
    }

    /// nil, never `[]`. An empty list means "this namespace has no processes"
    /// and would silently offer no choices; the caller has to be able to tell
    /// that apart from a file it could not read.
    func testDeclaredProcessesIsNilWhenTheConfigCannotBeParsed() throws {
        try write("process-compose.yaml", in: worktree, contents: "processes: [this, is, not, a, mapping]")
        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )

        XCTAssertNil(config.declaredProcesses(in: "execute"))
    }
}
