// ABOUTME: Tests the guard that decides which path a purge is allowed to destroy.
// ABOUTME: `purge` itself removes a worktree, so the decision is tested, not the act.

@testable import Atelier
import XCTest

/// `Workstream.workingDirectory(projectDirectory:)` falls back to the project
/// directory when a workstream has no worktree, which is right for launching a
/// terminal and catastrophic for archiving: `purge` fed that same fallback to
/// `Git.Operations.removeWorktree`, which deletes the path it is handed.
final class WorkstreamArchiverPurgeTests: XCTestCase {
    private let projectDirectory = "/tmp/atelier-test/project"

    private func workstream(worktreePath: String?) -> Workstream {
        Workstream(name: "scan-deep-thr", worktreePath: worktreePath)
    }

    func testAWorkstreamWithAWorktreeIsDestroyable() {
        let path = Workstream.Archiver.destroyableWorktreePath(
            for: workstream(worktreePath: "/tmp/atelier-test/project/wt"),
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(path, "/tmp/atelier-test/project/wt")
    }

    /// The case that deleted a user's checkout: archived before
    /// `workstreamWorktreeReady` landed, so there is no worktree path at all.
    func testAWorkstreamWithNoWorktreePathIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: nil),
                projectDirectory: projectDirectory
            )
        )
    }

    func testTheProjectDirectoryItselfIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: projectDirectory),
                projectDirectory: projectDirectory
            )
        )
    }

    /// Stored paths are not normalized on the way in, so the two can name the
    /// same directory and still not compare equal as strings.
    func testTheProjectDirectoryIsNotDestroyableUnderAnotherSpelling() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: projectDirectory + "/./"),
                projectDirectory: projectDirectory
            )
        )
    }

    /// An empty path is `URL(fileURLWithPath:)`'s worst input: it resolves to the
    /// process's current directory, which has nothing to do with this project.
    func testAnEmptyWorktreePathIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: "   "),
                projectDirectory: projectDirectory
            )
        )
    }

    // MARK: - The warning shown before purge destroys anything

    /// `purge` runs `git worktree remove --force` and then deletes the directory
    /// itself, so this warning is the only thing standing between the user and the
    /// loss. It was gated on probes that returned "no work here" when they had in
    /// fact failed to look, which turned a failed check into a silent all-clear.
    func testPurgeWarnsWhenItCouldNotEstablishWhatWouldBeLost() throws {
        let unreadable = try makeNonRepositoryDirectory()

        let warning = Workstream.Archiver.purgeWarning(
            for: workstream(worktreePath: unreadable.path)
        )

        XCTAssertNotNil(warning, "an unread worktree must not be presented as safe to purge")
    }

    func testOrphanPurgeWarnsWhenItCouldNotEstablishWhatWouldBeLost() throws {
        let unreadable = try makeNonRepositoryDirectory()

        XCTAssertNotNil(Workstream.Archiver.orphanPurgeWarning(at: unreadable.path))
    }

    /// The positive control: a readable worktree with nothing at stake still purges
    /// without a warning, or the warning becomes noise on every purge and the user
    /// learns to click through it.
    ///
    /// It has to be a *clone*. `hasUnpushedCommits` treats a missing upstream as
    /// "everything is unpushed", which is correct and would warn on a standalone
    /// repository for a reason that has nothing to do with what is being tested.
    func testACleanReadableWorktreePurgesWithoutAWarning() throws {
        let repo = try makeCleanClone()

        XCTAssertNil(Workstream.Archiver.purgeWarning(for: workstream(worktreePath: repo.path)))
        XCTAssertNil(Workstream.Archiver.orphanPurgeWarning(at: repo.path))
    }

    private func makeNonRepositoryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeCleanClone() throws -> URL {
        let remote = try makeNonRepositoryDirectory()
        XCTAssertTrue(runGit(["init", "-b", "main"], in: remote))
        XCTAssertTrue(runGit(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                              "commit", "--allow-empty", "-m", "init"], in: remote))

        let parent = try makeNonRepositoryDirectory()
        let local = parent.appendingPathComponent("clone")
        XCTAssertTrue(runGit(["clone", remote.path, local.path], in: parent))
        return local
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            XCTFail("could not launch git \(args.joined(separator: " ")): \(error)", file: file, line: line)
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
