// ABOUTME: Tests for verification.yaml — its schema, its refusals, and its file order.
// ABOUTME: The three-way load (missing / invalid / loaded) is the whole availability decision.

@testable import Atelier
import XCTest

final class VerificationConfigTests: XCTestCase {
    private var projectDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("verification-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectDirectory)
        super.tearDown()
    }

    @discardableResult
    private func write(_ yaml: String, named name: String = "verification.yaml") throws -> String {
        let path = projectDirectory.appendingPathComponent(name).path
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func parse(_ yaml: String) -> Verification.Config.Load {
        Verification.Config.parse(yaml, path: "/tmp/verification.yaml")
    }

    // MARK: - The schema

    func test_parse_readsNameCommandAndShell() {
        guard case let .loaded(config) = parse("""
        rubocop:
          shell: fish
          command: bundle exec rubocop
        rspec:
          command: bundle exec rspec
        """) else { return XCTFail("expected a parse") }

        XCTAssertEqual(config.check(named: "rubocop")?.command, "bundle exec rubocop")
        XCTAssertEqual(config.check(named: "rubocop")?.shell, "fish")
        XCTAssertEqual(config.check(named: "rspec")?.command, "bundle exec rspec")
        XCTAssertNil(config.check(named: "rspec")?.shell, "no shell named means the user's own $SHELL")
    }

    /// **File order, which is why this walks Yams' nodes rather than decoding a
    /// dictionary.** A `[String: Check]` has no order, so the rows would be drawn
    /// in an arbitrary sequence that changed between launches.
    func test_parse_keepsTheDeclarationOrder() {
        guard case let .loaded(config) = parse("""
        zebra:
          command: echo z
        alpha:
          command: echo a
        middle:
          command: echo m
        """) else { return XCTFail("expected a parse") }

        XCTAssertEqual(config.checkNames, ["zebra", "alpha", "middle"])
    }

    // MARK: - Refusals

    /// The distinction the three-case `Load` exists for: a broken file must never
    /// render as "this project declares no checks", which is the same sentence a
    /// project with genuinely none gets and the only diagnostic either one has.
    func test_parse_distinguishesEmptyFromBroken() {
        guard case let .loaded(empty) = parse("# nothing but a comment") else {
            return XCTFail("a file with no checks is empty, not broken")
        }
        XCTAssertEqual(empty.checks, [])
        XCTAssertNotNil(
            Verification.Config.Load.loaded(empty).unavailableReason,
            "an empty config still has nothing to run, and has to say which nothing it is"
        )

        guard case .invalid = parse("- rspec\n- rubocop") else {
            return XCTFail("a top-level list is not a mapping of checks")
        }
    }

    func test_parse_refusesACheckWithNoCommand() {
        guard case let .invalid(reason) = parse("""
        rspec:
          shell: fish
        """) else { return XCTFail("a check with no command cannot run") }
        XCTAssertTrue(reason.contains("rspec"), reason)
    }

    func test_parse_refusesACheckGivenAsABareString() {
        guard case let .invalid(reason) = parse("rspec: bundle exec rspec") else {
            return XCTFail("the schema is a mapping with a command:, not a bare command")
        }
        XCTAssertTrue(reason.contains("command"), reason)
    }

    func test_parse_refusesAnEmptyCommand() {
        guard case .invalid = parse("""
        rspec:
          command: "   "
        """) else { return XCTFail("whitespace is not a command") }
    }

    /// Two rows of one name would share a record, a surface id and a status, with
    /// the loser invisible while quietly overwriting the winner. **Yams refuses the
    /// duplicate itself**, as a parse error — so this pins the outcome rather than
    /// a guard of ours, and is what showed the hand-written guard to be dead code.
    func test_parse_refusesADuplicatedCheckName() {
        guard case .invalid = parse("""
        rspec:
          command: echo one
        rspec:
          command: echo two
        """) else { return XCTFail("one name, one row") }
    }

    func test_parse_refusesAShellThatIsNotAName() {
        guard case .invalid = parse("""
        rspec:
          shell: [fish, bash]
          command: echo hi
        """) else { return XCTFail("a shell is one name") }
    }

    // MARK: - Loading

    func test_load_readsTheProjectDirectory() throws {
        try write("""
        rspec:
          command: bundle exec rspec
        """)

        guard case let .loaded(config) = Verification.Config.load(
            projectDirectory: projectDirectory.path
        ) else { return XCTFail("expected a load") }
        XCTAssertEqual(config.checkNames, ["rspec"])
    }

    func test_load_reportsMissingRatherThanEmpty() {
        guard case .missing = Verification.Config.load(projectDirectory: projectDirectory.path) else {
            return XCTFail("no file is missing, not empty")
        }
    }

    /// `.yml` is accepted, and `.yaml` wins when both exist — a second file is
    /// never merged, because two files whose precedence a reader has to hold in
    /// their head is the shape `ProcessCompose.Config` retired.
    func test_load_prefersTheYamlSpellingAndNeverMergesTheOther() throws {
        try write("yaml-one:\n  command: echo a")
        try write("yml-one:\n  command: echo b", named: "verification.yml")

        guard case let .loaded(config) = Verification.Config.load(
            projectDirectory: projectDirectory.path
        ) else { return XCTFail("expected a load") }
        XCTAssertEqual(config.checkNames, ["yaml-one"])
    }

    /// **The whole trust story.** The file is read from the project directory and
    /// nowhere else: a worktree copy is not a tier, not an override, and not
    /// consulted — which is what stops an agent confined to its worktree editing
    /// the checks that decide whether its own work passes.
    func test_load_ignoresAWorktreeCopyEntirely() throws {
        try write("from-project:\n  command: echo a")
        let worktree = projectDirectory.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "from-worktree:\n  command: echo b".write(
            toFile: worktree.appendingPathComponent("verification.yaml").path,
            atomically: true, encoding: .utf8
        )

        guard case let .loaded(config) = Verification.Config.load(
            projectDirectory: projectDirectory.path
        ) else { return XCTFail("expected a load") }
        XCTAssertEqual(config.checkNames, ["from-project"])
    }

    // MARK: - What the tab reads

    func test_load_reportsADifferentReasonForEachWayOfHavingNothingToRun() {
        let missing = Verification.Config.Load.missing.unavailableReason
        let broken = Verification.Config.Load.invalid(reason: "boom").unavailableReason
        let empty = parse("# nothing").unavailableReason

        XCTAssertNotNil(missing)
        XCTAssertNotNil(broken)
        XCTAssertNotNil(empty)
        XCTAssertEqual(Set([missing, broken, empty]).count, 3, "three states, three sentences")
    }

    func test_load_hasNoReasonWhenThereAreChecksToRun() {
        XCTAssertNil(parse("rspec:\n  command: echo hi").unavailableReason)
        XCTAssertEqual(parse("rspec:\n  command: echo hi").checkNames, ["rspec"])
    }
}
