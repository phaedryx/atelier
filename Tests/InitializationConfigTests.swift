// ABOUTME: Tests for parsing and locating a project's initialization.yaml.
// ABOUTME: Order is the file's, and an unreadable file is never "no steps".

@testable import Atelier
import XCTest

final class InitializationConfigTests: XCTestCase {
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

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func load() -> Initialization.Config.Load {
        Initialization.Config.load(projectDirectory: project.path)
    }

    private func parse(_ yaml: String) -> Initialization.Config.Load {
        Initialization.Config.parse(yaml, path: "/tmp/initialization.yaml")
    }

    // MARK: - Locating

    func test_load_withNoFile_isMissing() {
        XCTAssertEqual(load(), .missing)
    }

    func test_load_readsInitializationYaml() throws {
        try write("initialization.yaml", "deps:\n  command: bundle install\n")
        guard case let .loaded(config) = load() else { return XCTFail("expected a loaded config") }
        XCTAssertEqual(config.stepNames, ["deps"])
        XCTAssertEqual(config.path, project.appendingPathComponent("initialization.yaml").path)
    }

    func test_load_acceptsTheYmlSpelling() throws {
        try write("initialization.yml", "deps:\n  command: bundle install\n")
        guard case let .loaded(config) = load() else { return XCTFail("expected a loaded config") }
        XCTAssertEqual(config.stepNames, ["deps"])
    }

    /// The `.yaml` spelling is listed first, so it is the one read. A second file
    /// is never merged: two files whose precedence a reader has to hold in their
    /// head is the shape `ProcessCompose.Config` retired.
    func test_load_prefersYamlOverYml() throws {
        try write("initialization.yaml", "fromYaml:\n  command: echo a\n")
        try write("initialization.yml", "fromYml:\n  command: echo b\n")
        guard case let .loaded(config) = load() else { return XCTFail("expected a loaded config") }
        XCTAssertEqual(config.stepNames, ["fromYaml"])
    }

    /// There is deliberately no worktree tier. A step file inside a work tree
    /// could be edited by an agent confined to that worktree, which is exactly
    /// what the project-directory rule exists to prevent.
    func test_load_ignoresAWorktreeCopy() throws {
        let worktree = project.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "sneaky:\n  command: echo pwned\n"
            .write(to: worktree.appendingPathComponent("initialization.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(load(), .missing)
    }

    // MARK: - Parsing

    /// File order, which is why the parse walks Yams nodes rather than decoding
    /// a dictionary. Steps run in this order, so a shuffle would reorder setup.
    func test_parse_keepsFileOrder() {
        let yaml = """
        zebra:
          command: echo z
        apple:
          command: echo a
        middle:
          command: echo m
        """
        guard case let .loaded(config) = parse(yaml) else { return XCTFail("expected a loaded config") }
        XCTAssertEqual(config.stepNames, ["zebra", "apple", "middle"])
    }

    func test_parse_readsTheShell() {
        let yaml = """
        deps:
          shell: fish
          command: bundle install
        assets:
          command: bun install
        """
        guard case let .loaded(config) = parse(yaml) else { return XCTFail("expected a loaded config") }
        XCTAssertEqual(config.step(named: "deps")?.shell, "fish")
        XCTAssertNil(config.step(named: "assets")?.shell)
    }

    /// An empty file declares no steps. That is a project with nothing to run,
    /// not a broken file — the same distinction `declaredProcesses` draws.
    func test_parse_emptyFileDeclaresNoSteps() {
        guard case let .loaded(config) = parse("# nothing here\n") else {
            return XCTFail("expected a loaded config")
        }
        XCTAssertTrue(config.steps.isEmpty)
        XCTAssertNotNil(parse("# nothing here\n").unavailableReason)
    }

    /// The whole reason `Load` has three cases. A file Atelier cannot read must
    /// never render as "this project declares no setup", which is the same
    /// sentence a project with genuinely none gets.
    func test_parse_brokenYamlIsInvalidRatherThanEmpty() {
        guard case .invalid = parse("deps:\n  command: [\n") else {
            return XCTFail("expected .invalid")
        }
    }

    func test_parse_aTopLevelListIsInvalid() {
        guard case .invalid = parse("- deps\n- assets\n") else {
            return XCTFail("expected .invalid")
        }
    }

    func test_parse_aStepGivenAsABareStringIsInvalid() {
        guard case .invalid = parse("deps: bundle install\n") else {
            return XCTFail("expected .invalid")
        }
    }

    func test_parse_aStepWithNoCommandIsInvalid() {
        guard case .invalid = parse("deps:\n  shell: fish\n") else {
            return XCTFail("expected .invalid")
        }
    }

    func test_parse_aStepWithABlankCommandIsInvalid() {
        guard case .invalid = parse("deps:\n  command: \"   \"\n") else {
            return XCTFail("expected .invalid")
        }
    }

    func test_parse_aShellThatIsNotAStringIsInvalid() {
        guard case .invalid = parse("deps:\n  shell: [fish]\n  command: echo hi\n") else {
            return XCTFail("expected .invalid")
        }
    }

    /// Yams refuses a duplicated key itself, as a parse error. Two steps of one
    /// name would be indistinguishable in every report, so the refusal matters;
    /// it just is not this parser's to make.
    func test_parse_duplicateNamesAreRefusedByYams() {
        guard case .invalid = parse("deps:\n  command: a\ndeps:\n  command: b\n") else {
            return XCTFail("expected .invalid")
        }
    }

    // MARK: - unavailableReason

    /// Empty exactly when there is a reason, so the two cannot describe
    /// different states.
    func test_unavailableReason_isSetExactlyWhenThereAreNoSteps() {
        XCTAssertNotNil(Initialization.Config.Load.missing.unavailableReason)
        XCTAssertNotNil(Initialization.Config.Load.invalid(reason: "nope").unavailableReason)
        XCTAssertNotNil(parse("# empty\n").unavailableReason)
        XCTAssertNil(parse("deps:\n  command: echo hi\n").unavailableReason)

        XCTAssertTrue(Initialization.Config.Load.missing.stepNames.isEmpty)
        XCTAssertTrue(Initialization.Config.Load.invalid(reason: "nope").stepNames.isEmpty)
    }

    func test_unavailableReason_namesTheParseFailure() {
        guard let reason = Initialization.Config.Load.invalid(reason: "the moon was wrong").unavailableReason
        else { return XCTFail("expected a reason") }
        XCTAssertTrue(reason.contains("the moon was wrong"))
    }
}
