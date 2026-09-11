// ABOUTME: Tests for locating a worktree's process-compose config.
// ABOUTME: Explicitly-named files outrank generic ones; authorship follows location.

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

    private func locate() -> ProcessCompose.Config? {
        ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
    }

    // MARK: - The four tiers

    /// Tier one. A worktree saying outright that this file is Atelier's outranks
    /// everything, including a project-directory file of the same name.
    func testAtelierNameInWorktreeOutranksEverything() throws {
        try write("atelier.process-compose.yaml", in: worktree)
        try write("atelier.process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.yaml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, worktree.appendingPathComponent("atelier.process-compose.yaml").path)
        XCTAssertTrue(config.isRepositoryProvided)
    }

    /// Tier two over tier three, and the reason the prefix exists. A repository
    /// that runs process-compose for its own reasons checks in a generic
    /// `process-compose.yaml`; naming the project-directory file explicitly is
    /// what stops that file shadowing it.
    func testAtelierNameInProjectDirectoryOutranksAGenericWorktreeConfig() throws {
        try write("atelier.process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, project.appendingPathComponent("atelier.process-compose.yaml").path)
        XCTAssertFalse(config.isRepositoryProvided, "the user placed it, outside git")
    }

    /// Tier one over tier two: within one name, the worktree still wins, because
    /// a worktree carrying its own config is being deliberate about this branch.
    func testAtelierNameInWorktreeOutranksTheProjectDirectory() throws {
        try write("atelier.process-compose.yaml", in: worktree)
        try write("atelier.process-compose.yaml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, worktree.appendingPathComponent("atelier.process-compose.yaml").path)
    }

    /// Tier three over tier four — unchanged from before the prefix existed, so
    /// a project with a single unprefixed config is unaffected by any of this.
    func testGenericWorktreeConfigOutranksTheProjectDirectory() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, worktree.appendingPathComponent("process-compose.yaml").path)
    }

    func testFindsGenericConfigInWorktree() throws {
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, worktree.appendingPathComponent("process-compose.yaml").path)
        XCTAssertTrue(config.isRepositoryProvided)
    }

    func testFindsGenericConfigInProjectDirectory() throws {
        try write("process-compose.yaml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, project.appendingPathComponent("process-compose.yaml").path)
        XCTAssertFalse(config.isRepositoryProvided)
    }

    /// Within one tier, `.yaml` is preferred over `.yml`. Nothing external
    /// decides this any more — every file is named with `-f`, so
    /// process-compose's own discovery preference does not apply — but it has to
    /// be *some* fixed order, and a project with both should not see the answer
    /// move.
    func testYamlIsPreferredOverYmlWithinATier() throws {
        try write("atelier.process-compose.yaml", in: worktree)
        try write("atelier.process-compose.yml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, worktree.appendingPathComponent("atelier.process-compose.yaml").path)
    }

    /// When worktree and project directory are the same path (a plain checkout
    /// opened directly), the project-directory tiers are skipped rather than
    /// deduplicated: the file arrived with the repository, so it keeps the
    /// approval gate.
    func testSamePathForBothResolvesAsRepositoryProvided() throws {
        try write("process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: worktree.path)
        )

        XCTAssertTrue(config.isRepositoryProvided)
    }

    func testSamePathForBothResolvesAnAtelierNamedConfigAsRepositoryProvided() throws {
        try write("atelier.process-compose.yaml", in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: worktree.path)
        )

        XCTAssertEqual(config.path, worktree.appendingPathComponent("atelier.process-compose.yaml").path)
        XCTAssertTrue(config.isRepositoryProvided, "the prefix says who it is for, not who wrote it")
    }

    func testNoConfigAnywhere() {
        XCTAssertNil(locate())
    }

    func testIgnoresBareComposeFile() throws {
        try "services: {}".write(
            to: worktree.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8
        )

        XCTAssertNil(locate())
    }

    // MARK: - One config, one file

    /// An earlier design merged a worktree `process-compose.override.yml` into a
    /// project-directory base. That is gone: tier one is how a worktree says it
    /// wants its own arrangement. The name must stay inert, because a file that
    /// silently joined `loadedFiles` would be repository content executing
    /// unattended — which is exactly the hole `loadedFiles` exists to close.
    func testAnOverrideFileBesideTheConfigIsNeitherLoadedNorApproved() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.override.yml", in: worktree)
        try write("process-compose.override.yaml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.loadedFiles, [project.appendingPathComponent("process-compose.yaml").path])
        XCTAssertEqual(config.repositoryProvidedFiles, [])
        XCTAssertFalse(config.requiresApproval)
    }

    func testAnOverrideFileBesideAWorktreeConfigIsNotLoadedEither() throws {
        try write("process-compose.yaml", in: worktree)
        try write("process-compose.override.yml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.loadedFiles, [worktree.appendingPathComponent("process-compose.yaml").path])
    }

    /// A namespace declared only in a file Atelier does not load must read as
    /// absent. The probe has to describe what will run: counting a file that is
    /// never named with `-f` would chain `prepare` for a namespace
    /// process-compose is never told about, which hangs Start.
    func testANamespaceDeclaredOnlyInAnOverrideDoesNotCount() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, name: "process-compose.override.yml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
        XCTAssertEqual(config.declaredProcesses(in: "prepare"), [])
    }

    // MARK: - Namespace declarations

    private func writeProcesses(_ body: String, name: String = "process-compose.yaml", in dir: URL) throws {
        try "processes:\n\(body)".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testNamespaceIsPresentWhenAProcessDeclaresIt() throws {
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .present)
    }

    func testNamespaceIsEmptyWhenNoProcessDeclaresIt() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
    }

    /// The namespace probe reads whichever file won the lookup, so an
    /// `atelier.`-prefixed config is what gets described.
    func testNamespacePresenceReadsTheAtelierNamedConfig() throws {
        try writeProcesses("""
          api:
            namespace: web
            command: "true"
        """, in: worktree)
        try writeProcesses("""
          seed:
            namespace: bootstrap
            command: "true"
        """, name: "atelier.process-compose.yaml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("bootstrap"), .present)
        XCTAssertEqual(config.namespacePresence("web"), .empty, "the repository's own file is not loaded")
    }

    /// A process with no `namespace:` key belongs to process-compose's own
    /// default namespace, not to `prepare` — it must not count toward it.
    func testUnnamespacedProcessDoesNotSatisfyAnyNamespace() throws {
        try writeProcesses("""
          web:
            command: "true"
        """, in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
        XCTAssertEqual(config.namespacePresence("execute"), .empty)
    }

    /// An unreadable file is `.unknown`, never mistaken for "no namespaces".
    /// The three `.unknown` cases below are asserted as `.unknown` rather than
    /// as "not empty". That distinction is load-bearing:
    /// `ProcessCompose.PhaseRunner.startCommand` chains `prepare` only on `.present`, because
    /// chaining it on an unparseable config hangs Start forever, while
    /// `ProcessCompose.PhaseExecutor` still runs an `.unknown` phase on a bounded leash.
    func testUnknownWhenTheFileCannotBeRead() {
        let config = ProcessCompose.Config(
            path: "/nonexistent/process-compose.yaml", isRepositoryProvided: true
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
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    /// A config with no `processes:` key at all doesn't parse as a
    /// process-compose config in the shape this reads — `.unknown` rather
    /// than treating it as confidently declaring nothing.
    func testUnknownWhenProcessesKeyIsMissing() throws {
        try "version: \"0.5\"".write(
            to: worktree.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8
        )
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    // MARK: - What has to be approved

    /// A config in the worktree is repository content, so it is approved —
    /// whichever of the two names it carries. The prefix says who the file is
    /// *for*, not who wrote it, so it changes precedence and nothing else.
    func testWorktreeConfigRequiresApproval() throws {
        try write("process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertTrue(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [worktree.appendingPathComponent("process-compose.yaml").path])
    }

    func testAtelierNamedWorktreeConfigStillRequiresApproval() throws {
        try write("atelier.process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertTrue(config.requiresApproval, "an Atelier-named file is still repository content")
        XCTAssertEqual(
            config.repositoryProvidedFiles,
            [worktree.appendingPathComponent("atelier.process-compose.yaml").path]
        )
    }

    /// A config the user placed in the project directory, with nothing in the
    /// worktree, is theirs: nothing to approve.
    func testProjectDirectoryConfigRequiresNoApproval() throws {
        try write("process-compose.yaml", in: project)
        let config = try XCTUnwrap(locate())

        XCTAssertFalse(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [])
    }

    func testAtelierNamedProjectDirectoryConfigRequiresNoApproval() throws {
        try write("atelier.process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertFalse(config.requiresApproval)
        XCTAssertEqual(config.repositoryProvidedFiles, [])
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
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.loadedFiles, [worktree.appendingPathComponent("process-compose.yaml").path])
        XCTAssertFalse(config.loadedFiles.contains { $0.hasSuffix("/compose.yaml") })
        XCTAssertFalse(config.repositoryProvidedFiles.contains { $0.hasSuffix("/compose.yaml") })
    }

    /// Approval covers the files that execute, and only those.
    func testApprovedSetEqualsTheExecutedSetForARepositoryConfig() throws {
        try write("atelier.process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.repositoryProvidedFiles, config.loadedFiles)
    }

    /// The config that lost the lookup is not loaded, so it is not approved
    /// either — otherwise the user would be asked to approve a file that never
    /// runs, and the approval prompt would stop meaning anything.
    func testALosingRepositoryConfigIsNotApproved() throws {
        try write("atelier.process-compose.yaml", in: project)
        try write("process-compose.yaml", in: worktree)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.loadedFiles, [project.appendingPathComponent("atelier.process-compose.yaml").path])
        XCTAssertEqual(config.repositoryProvidedFiles, [])
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
        let config = try XCTUnwrap(locate())

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
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.declaredProcesses(in: "execute"), [])
    }

    /// A config with no `processes:` key at all is legal process-compose — it
    /// may set only `environment:` or `version:` — and declares no processes.
    /// It must not read as nil, which the Verification tab renders as "this
    /// project's process-compose files could not be parsed, so its verify checks
    /// are unknown" and `Verification.Runner.start` throws on, for a config
    /// process-compose runs happily.
    func testDeclaredProcessesIsEmptyForAConfigWithNoProcessesKey() throws {
        try write("process-compose.yaml", in: worktree, contents: """
        version: "0.5"
        environment:
          - "RAILS_ENV=test"
        """)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.declaredProcesses(in: "verify"), [])
    }

    /// The degenerate sibling of the case above: a config that is empty, or
    /// holds nothing but a comment. A placeholder a project has not filled in
    /// yet declares nothing; it is not a file Atelier failed to read.
    func testDeclaredProcessesIsEmptyForACommentOnlyConfig() throws {
        try write("process-compose.yaml", in: worktree, contents: "# nothing here yet\n")
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.declaredProcesses(in: "verify"), [])
    }

    /// nil, never `[]`. An empty list means "this namespace has no processes"
    /// and would silently offer no choices; the caller has to be able to tell
    /// that apart from a file it could not read.
    func testDeclaredProcessesIsNilWhenTheConfigCannotBeParsed() throws {
        try write("process-compose.yaml", in: worktree, contents: "processes: [this, is, not, a, mapping]")
        let config = try XCTUnwrap(locate())

        XCTAssertNil(config.declaredProcesses(in: "execute"))
    }
}
