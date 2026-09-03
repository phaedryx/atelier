// ABOUTME: Tests where Git.Operations places a new worktree for a project.
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

        let destination = Git.Operations.worktreeDestination(
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

        let destination = Git.Operations.worktreeDestination(
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

        let destination = Git.Operations.worktreeDestination(
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

    /// `git clone --bare foo.git` with no `.bare`/`.git` container around it.
    ///
    /// The common directory *is* the repository, so the container resolves to its parent —
    /// which is usually just wherever repos are kept. Placing worktrees there would scatter
    /// them beside unrelated repositories, unscoped by project, and two projects each
    /// creating a "feature" workstream would collide.
    func testPlainBareCloneKeepsTheCentralLocation() throws {
        let parent = tempDir.appendingPathComponent("repos")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        git(["init", "--bare", "myproj.git"], in: parent)
        let bare = parent.appendingPathComponent("myproj.git")

        let destination = Git.Operations.worktreeDestination(
            projectPath: bare.path,
            projectName: "myproj",
            workstreamName: "feature"
        )

        XCTAssertTrue(
            destination.path.hasPrefix(AppConstants.worktreesDirectory.path),
            "expected the central location, got \(destination.path)"
        )
    }

    /// A git directory whose parent is not a worktree container either — the shape a
    /// submodule's `.git/modules/<name>` has. The worktree must not be created inside it.
    func testGitDirectoryWithoutAContainerKeepsTheCentralLocation() throws {
        let modules = tempDir.appendingPathComponent("super/.git/modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        git(["init", "--bare", "sub"], in: modules)
        let sub = modules.appendingPathComponent("sub")

        let destination = Git.Operations.worktreeDestination(
            projectPath: sub.path,
            projectName: "sub",
            workstreamName: "feature"
        )

        XCTAssertFalse(
            destination.path.contains("/.git/"),
            "must never create a worktree inside a .git directory, got \(destination.path)"
        )
        XCTAssertTrue(destination.path.hasPrefix(AppConstants.worktreesDirectory.path))
    }

    func testNonRepositoryFallsBackToTheCentralLocation() throws {
        let plain = tempDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let destination = Git.Operations.worktreeDestination(
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
