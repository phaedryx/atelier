// ABOUTME: Tests for Project.ConfigFile, the one mechanism behind every project-directory config.
// ABOUTME: The rule was stated in prose four times and implemented four times; this pins it once.

@testable import Atelier
import XCTest

/// The four configs each keep their own round-trip tests, which pin what their
/// *templates* load as — a per-file safety decision. These pin the mechanism
/// underneath all four: two spellings, first present wins, a seed only when
/// neither exists, and a parse failure that arrives as `.invalid` carrying the
/// thrown reason rather than as "this project declares nothing".
final class ProjectConfigFileTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A stand-in for a real config: the contents are the file's text, so a
    /// `.loaded` says exactly which file was read.
    private struct Contents: Equatable, Sendable {
        let text: String
        let path: String
    }

    private let file = Project.ConfigFile<Contents>(
        fileNames: ["sample.yaml", "sample.yml"],
        defaultContents: "# a template\n",
        parse: { text, path in
            guard !text.contains("boom") else {
                throw Project.InvalidConfig(reason: "the file said boom")
            }
            return Contents(text: text, path: path)
        }
    )

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: - Locating

    func test_locate_isNilWhenNeitherSpellingIsPresent() {
        XCTAssertNil(file.locate(projectDirectory: dir.path))
        XCTAssertEqual(file.load(projectDirectory: dir.path), .missing)
    }

    /// The order of `fileNames` is the precedence, and it is never a merge:
    /// two files whose contents combine is the shape this replaced.
    func test_locate_prefersTheYamlSpellingWhenBothExist() throws {
        try write("sample.yaml", "yaml wins")
        try write("sample.yml", "yml loses")

        XCTAssertEqual(file.locate(projectDirectory: dir.path), dir.appendingPathComponent("sample.yaml").path)
        XCTAssertEqual(file.load(projectDirectory: dir.path).config?.text, "yaml wins")
    }

    func test_locate_findsTheYmlSpellingOnItsOwn() throws {
        try write("sample.yml", "only the yml")

        XCTAssertEqual(file.locate(projectDirectory: dir.path), dir.appendingPathComponent("sample.yml").path)
        XCTAssertEqual(file.load(projectDirectory: dir.path).config?.text, "only the yml")
    }

    /// A parse failure must never arrive as "this project declares nothing",
    /// which is the same sentence a project with genuinely nothing gets. The
    /// parser's own reason is what reaches the user, unaltered.
    func test_load_reportsAParseFailureAsInvalidCarryingTheThrownReason() throws {
        try write("sample.yaml", "boom")

        XCTAssertEqual(file.load(projectDirectory: dir.path), .invalid(reason: "the file said boom"))
    }

    /// A parser with an error type of its own — `ProcessCompose.PortsConfig.LoadError`
    /// is the real one — still reports something, rather than being swallowed.
    func test_load_reportsAnUnrecognisedErrorByItsDescription() throws {
        struct Nope: Error, LocalizedError {
            var errorDescription: String? {
                "not that either"
            }
        }
        let thrower = Project.ConfigFile<Contents>(
            fileNames: ["sample.yaml"],
            defaultContents: "",
            parse: { _, _ in throw Nope() }
        )
        try "anything".write(to: dir.appendingPathComponent("sample.yaml"), atomically: true, encoding: .utf8)

        XCTAssertEqual(thrower.load(projectDirectory: dir.path), .invalid(reason: "not that either"))
    }

    // MARK: - Seeding

    func test_writeDefault_writesTheFirstSpelling() {
        XCTAssertTrue(file.writeDefault(projectDirectory: dir.path))

        XCTAssertTrue(exists("sample.yaml"))
        XCTAssertFalse(exists("sample.yml"))
        XCTAssertEqual(file.load(projectDirectory: dir.path).config?.text, "# a template\n")
    }

    func test_writeDefault_refusesWhenTheYamlSpellingExists() throws {
        try write("sample.yaml", "the project's own")

        XCTAssertFalse(file.writeDefault(projectDirectory: dir.path))
        XCTAssertEqual(file.load(projectDirectory: dir.path).config?.text, "the project's own")
    }

    /// The refusal is per *file*, not per name: seeding a `.yaml` beside an
    /// existing `.yml` would win the lookup above and hide the project's real
    /// declarations.
    func test_writeDefault_refusesWhenOnlyTheYmlSpellingExists() throws {
        try write("sample.yml", "the project's own")

        XCTAssertFalse(file.writeDefault(projectDirectory: dir.path))
        XCTAssertFalse(exists("sample.yaml"))
        XCTAssertEqual(file.load(projectDirectory: dir.path).config?.text, "the project's own")
    }

    // MARK: - The declared set

    /// Every file the app reads from the project directory goes through this
    /// mechanism, and `Project.seedDefaultConfigs` is the one seeding entry
    /// point — a fifth config added without joining the list would be read but
    /// never seeded.
    func test_configFiles_areTheFourTheAppReads() {
        XCTAssertEqual(
            Project.configFiles.map(\.fileNames),
            [
                ["verification.yaml", "verification.yml"],
                ["initialization.yaml", "initialization.yml"],
                ["ports.yaml", "ports.yml"],
                ["execution.process-compose.yaml", "execution.process-compose.yml"],
            ]
        )
    }
}
