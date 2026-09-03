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
}
