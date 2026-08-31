// ABOUTME: Tests where GitOperations places a new worktree for a project.
// ABOUTME: Bare-repo containers get siblings in place; ordinary clones keep the central location.

@testable import Atelier
import XCTest

final class WorktreeDestinationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A `.bare` directory plus a `.git` file pointing at it, with worktrees as siblings —
    /// the layout at /Volumes/repos/app.
    private func makeBareContainer(named name: String) throws -> URL {
        let container = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        git(["init", "--bare", ".bare"], in: container)
        try "gitdir: ./.bare\n".write(
            to: container.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        return container
    }

    func testBareContainerPutsWorktreesBesideTheRepo() throws {
        let container = try makeBareContainer(named: "app")

        let destination = GitOperations.worktreeDestination(
            projectPath: container.path,
            projectName: "app",
            workstreamName: "tadthorley/sc-15391/some-title"
        )

        XCTAssertEqual(
            destination.deletingLastPathComponent().standardizedFileURL.path,
            container.standardizedFileURL.path,
            "a bare container should host its worktrees directly, not in ~/.atelier/worktrees"
        )
        XCTAssertEqual(
            destination.lastPathComponent,
            "tadthorley--sc-15391--some-title",
            "slashes still become -- because a directory name cannot contain them"
        )
    }

    func testContainerIsFoundEvenWhenTheProjectPointsAtALinkedWorktree() throws {
        // A project may be registered as .../app/main rather than .../app; the container
        // is still the right home for new worktrees.
        let container = try makeBareContainer(named: "app")
        git(["worktree", "add", "-b", "main", "main"], in: container)
        let mainWorktree = container.appendingPathComponent("main")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mainWorktree.path))

        let destination = GitOperations.worktreeDestination(
            projectPath: mainWorktree.path,
            projectName: "app",
            workstreamName: "feature"
        )

        XCTAssertEqual(
            destination.deletingLastPathComponent().standardizedFileURL.path,
            container.standardizedFileURL.path
        )
    }

    func testOrdinaryCloneKeepsTheCentralLocation() throws {
        // Putting a worktree inside a normal checkout would drop it in the working tree,
        // where git would see it as untracked clutter.
        let repo = tempDir.appendingPathComponent("plain-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init"], in: repo)

        let destination = GitOperations.worktreeDestination(
            projectPath: repo.path,
            projectName: "plain-repo",
            workstreamName: "feature"
        )

        XCTAssertTrue(
            destination.path.hasPrefix(AppConstants.worktreesDirectory.path),
            "expected the central worktrees directory, got \(destination.path)"
        )
        XCTAssertEqual(destination.lastPathComponent, "feature")
    }

    func testNonRepositoryFallsBackToTheCentralLocation() throws {
        let plain = tempDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let destination = GitOperations.worktreeDestination(
            projectPath: plain.path,
            projectName: "not-a-repo",
            workstreamName: "feature"
        )

        XCTAssertTrue(destination.path.hasPrefix(AppConstants.worktreesDirectory.path))
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
