// ABOUTME: Tests for Project.seedDefaultConfigs, the one seeding entry point.
// ABOUTME: A newly created project starts with every template the app reads.

@testable import Atelier
import XCTest

final class ProjectSeedTests: XCTestCase {
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

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func test_seedDefaultConfigs_writesEveryTemplate() {
        Project.seedDefaultConfigs(projectDirectory: dir.path)

        for name in [
            "verification.yaml", "initialization.yaml", "ports.yaml",
            "execution.process-compose.yaml",
        ] {
            XCTAssertTrue(exists(name), "\(name) should have been seeded")
        }
    }

    /// One writer refusing must not stop the others: seeding is per file, not
    /// all-or-nothing, so a project that already carries its own ports.yml
    /// still gains the templates it lacks.
    func test_seedDefaultConfigs_skipsOnlyTheFilesAlreadyPresent() throws {
        try "ports:\n  WEB_PORT: { assigned: true }\n".write(
            to: dir.appendingPathComponent("ports.yml"), atomically: true, encoding: .utf8
        )

        Project.seedDefaultConfigs(projectDirectory: dir.path)

        XCTAssertFalse(exists("ports.yaml"), "the existing ports.yml must keep winning the lookup")
        XCTAssertTrue(exists("verification.yaml"))
        XCTAssertTrue(exists("initialization.yaml"))
        XCTAssertTrue(exists("execution.process-compose.yaml"))
    }
}
