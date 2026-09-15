// ABOUTME: Tests for locating a project's execution.process-compose.yaml.
// ABOUTME: One name, one place — the project directory, never a work tree.

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
        try "processes:\n  web:\n    command: echo hi\n"
            .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func locate() -> ProcessCompose.Config? {
        ProcessCompose.Config.locate(projectDirectory: project.path)
    }

    // MARK: - One name, one place

    func testFindsTheConfigInTheProjectDirectory() throws {
        try write("execution.process-compose.yaml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, project.appendingPathComponent("execution.process-compose.yaml").path)
    }

    /// `.yaml` is preferred over `.yml`. Nothing external decides this — the
    /// located file is named with `-f`, so process-compose's own discovery
    /// preference does not apply — but it has to be *some* fixed order, and a
    /// project carrying both should not see the answer move between launches.
    func testYamlIsPreferredOverYml() throws {
        try write("execution.process-compose.yaml", in: project)
        try write("execution.process-compose.yml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, project.appendingPathComponent("execution.process-compose.yaml").path)
    }

    /// **Nothing inside a work tree is read, and this is the trust decision.**
    /// The lookup had four tiers, two of them in the worktree, and a config that
    /// arrived with a clone had to be approved before `bootstrap` or `dispose`
    /// would run it. Removing the tiers is what removed the question: a file in
    /// the project directory sits outside every work tree and was placed by hand.
    /// Reading a worktree again would reopen it, and there is no approval gate
    /// left to catch it.
    func testNothingInTheWorktreeIsRead() throws {
        for name in [
            "execution.process-compose.yaml",
            "execution.process-compose.yml",
            "atelier.process-compose.yaml",
            "process-compose.yaml",
        ] {
            try write(name, in: worktree)
        }

        XCTAssertNil(locate())
    }

    /// The hard break, pinned. The names this replaced are inert wherever they
    /// sit — a project still carrying one gets `nil`, and the Execution pane's
    /// "Nothing to start" copy is what names the file to create.
    func testTheOldNamesAreNotRead() throws {
        try write("process-compose.yaml", in: project)
        try write("process-compose.yml", in: project)
        try write("atelier.process-compose.yaml", in: project)

        XCTAssertNil(locate())
    }

    func testNoConfigAnywhere() {
        XCTAssertNil(locate())
    }

    /// `compose.yaml` is loaded by process-compose's own discovery — verified
    /// against v1.122.0, where it wins outright — and Atelier deliberately never
    /// names it. Because the located file is named with `-f`, discovery is off,
    /// so a name missing from `fileNames` is a name that never executes.
    func testComposeYamlIsNeverLoaded() throws {
        try write("execution.process-compose.yaml", in: project)
        try write("compose.yaml", in: project)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.loadedFiles, [project.appendingPathComponent("execution.process-compose.yaml").path])
        XCTAssertFalse(config.loadedFiles.contains { $0.hasSuffix("/compose.yaml") })
    }

    /// An earlier design merged a worktree `process-compose.override.yml` into a
    /// project-directory base. The name must stay inert: a file that silently
    /// rejoined `loadedFiles` would be content executing unattended that nothing
    /// located.
    func testAnOverrideFileBesideTheConfigIsNeverLoaded() throws {
        try write("execution.process-compose.yaml", in: project)
        try write("execution.process-compose.override.yml", in: project)
        try write("process-compose.override.yml", in: worktree)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.loadedFiles, [project.appendingPathComponent("execution.process-compose.yaml").path])
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
        """, in: project)
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, name: "execution.process-compose.override.yml", in: project)

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
        XCTAssertEqual(config.declaredProcesses(in: "prepare"), [])
    }

    // MARK: - Namespace declarations

    private func writeProcesses(
        _ body: String, name: String = "execution.process-compose.yaml", in dir: URL
    ) throws {
        try "processes:\n\(body)".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testNamespaceIsPresentWhenAProcessDeclaresIt() throws {
        try writeProcesses("""
          setup:
            namespace: prepare
            command: "true"
        """, in: project)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .present)
    }

    func testNamespaceIsEmptyWhenNoProcessDeclaresIt() throws {
        try writeProcesses("""
          web:
            namespace: execute
            command: "true"
        """, in: project)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .empty)
    }

    /// A process with no `namespace:` key belongs to process-compose's own
    /// default namespace, not to `prepare` — it must not count toward it.
    func testUnnamespacedProcessDoesNotSatisfyAnyNamespace() throws {
        try writeProcesses("""
          web:
            command: "true"
        """, in: project)
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
        let config = ProcessCompose.Config(path: "/nonexistent/execution.process-compose.yaml")

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    /// Malformed YAML is `.unknown` the same way — a parse bug must never
    /// masquerade as an empty namespace and cause a declared phase to be
    /// silently skipped.
    func testUnknownWhenTheFileIsMalformed() throws {
        try write("execution.process-compose.yaml", in: project, contents: "processes: {web: {command: \"true\"")
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    /// A config with no `processes:` key at all doesn't parse as a
    /// process-compose config in the shape this reads — `.unknown` rather
    /// than treating it as confidently declaring nothing.
    func testUnknownWhenProcessesKeyIsMissing() throws {
        try write("execution.process-compose.yaml", in: project, contents: "version: \"0.5\"")
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.namespacePresence("prepare"), .unknown)
    }

    // MARK: - Declared processes

    func testDeclaredProcessesListsOnlyTheNamedNamespace() throws {
        try write("execution.process-compose.yaml", in: project, contents: """
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
        try write("execution.process-compose.yaml", in: project, contents: """
        processes:
          orphan: { command: "true" }
        """)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.declaredProcesses(in: "execute"), [])
    }

    /// A config with no `processes:` key at all is legal process-compose — it
    /// may set only `environment:` or `version:` — and declares no processes.
    /// It must not read as nil, which a caller renders as "could not be parsed".
    func testDeclaredProcessesIsEmptyForAConfigWithNoProcessesKey() throws {
        try write("execution.process-compose.yaml", in: project, contents: """
        version: "0.5"
        environment:
          - "RAILS_ENV=test"
        """)
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.declaredProcesses(in: "execute"), [])
    }

    /// The degenerate sibling of the case above: a config that is empty, or
    /// holds nothing but a comment. A placeholder a project has not filled in
    /// yet declares nothing; it is not a file Atelier failed to read.
    func testDeclaredProcessesIsEmptyForACommentOnlyConfig() throws {
        try write("execution.process-compose.yaml", in: project, contents: "# nothing here yet\n")
        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.declaredProcesses(in: "execute"), [])
    }

    /// nil, never `[]`. An empty list means "this namespace has no processes"
    /// and would silently offer no choices; the caller has to be able to tell
    /// that apart from a file it could not read.
    func testDeclaredProcessesIsNilWhenTheConfigCannotBeParsed() throws {
        try write("execution.process-compose.yaml", in: project, contents: "processes: [this, is, not, a, mapping]")
        let config = try XCTUnwrap(locate())

        XCTAssertNil(config.declaredProcesses(in: "execute"))
    }

    // MARK: - The template a new project starts with

    func testWriteDefaultProducesAConfigThatLocates() throws {
        XCTAssertTrue(ProcessCompose.Config.writeDefault(projectDirectory: project.path))

        let config = try XCTUnwrap(locate())

        XCTAssertEqual(config.path, project.appendingPathComponent("execution.process-compose.yaml").path)
    }

    /// **The template must never be `.unknown`.** `RunCommandPlan` gates
    /// `execute` on `.empty` and only `.empty`, failing open on `.unknown` so a
    /// parse bug cannot silently skip a namespace a project really declared. A
    /// comments-only template — or one whose `processes:` key is null — would
    /// therefore ship every newly created project with an enabled Start running
    /// `up -n execute` against a namespace nobody declared, which does not fail
    /// and does not exit: it idles forever with no output.
    func testWriteDefaultProducesAConfigWhoseExecuteNamespaceIsKnown() throws {
        XCTAssertTrue(ProcessCompose.Config.writeDefault(projectDirectory: project.path))
        let config = try XCTUnwrap(locate())

        XCTAssertNotEqual(config.namespacePresence("execute"), .unknown)
        XCTAssertEqual(config.namespacePresence("execute"), .present)
        XCTAssertFalse(config.declaredProcesses(in: "execute")?.isEmpty ?? true)
    }

    func testWriteDefaultLeavesAnExistingConfigAlone() throws {
        try write("execution.process-compose.yaml", in: project, contents: "processes: {}\n")

        XCTAssertFalse(ProcessCompose.Config.writeDefault(projectDirectory: project.path))
        XCTAssertEqual(
            try String(contentsOf: project.appendingPathComponent("execution.process-compose.yaml"), encoding: .utf8),
            "processes: {}\n"
        )
    }

    /// The `.yml` spelling counts as present too. Seeding a `.yaml` beside an
    /// existing `.yml` would win the lookup and hide the project's real stack.
    func testWriteDefaultAlsoRespectsTheYmlSpelling() throws {
        try write("execution.process-compose.yml", in: project, contents: "processes: {}\n")

        XCTAssertFalse(ProcessCompose.Config.writeDefault(projectDirectory: project.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("execution.process-compose.yaml").path
        ))
    }
}
