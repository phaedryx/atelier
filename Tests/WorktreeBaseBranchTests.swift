// ABOUTME: Tests which ref `Git.Operations.createWorktree` cuts a new workstream branch from.
// ABOUTME: Covers the stale local base branch, the no-remote fallback, and the absent upstream.

@testable import Atelier
import XCTest

/// `createWorktree` fetches the base branch and then cuts from it. The fetch only ever
/// updates `refs/remotes/origin/<base>`, while the *name* `main` resolves the local
/// `refs/heads/main` first — and in the README's container layout that ref is the trunk
/// checkout's branch, which moves only when somebody pulls. These tests pin that the
/// start point is the ref the fetch just updated.
///
/// Everything here runs on `BaseBranchSetting`'s default, `.main`, and writes nothing to
/// `UserDefaults`: the setting is shared with the rest of the suite, and
/// `repositoryDefault` would additionally consult `defaultBranch`'s process-global cache.
final class WorktreeBaseBranchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// The bug. Origin moves after the clone, nobody pulls, and the new workstream has to
    /// start from origin's tip rather than from whatever the container captured.
    ///
    /// Asserting on the SHA is the only way to see it: the branch name and the worktree
    /// path are right either way. No explicit fetch here — `createWorktree` does its own,
    /// and fetch-plus-start-point together are what was broken.
    func testWorktreeIsCutFromTheRemoteTipWhenLocalBaseIsStale() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")

        let staleTip = gitOutput(["rev-parse", "refs/heads/main"], in: container)
        try commit("later.txt", in: origin)
        let freshTip = gitOutput(["rev-parse", "main"], in: origin)
        XCTAssertNotEqual(staleTip, freshTip, "precondition: origin must have moved on")

        let created = try XCTUnwrap(Git.Operations.createWorktree(
            projectPath: container.path,
            projectName: "app",
            workstreamName: "new-work"
        ))

        XCTAssertEqual(
            gitOutput(["rev-parse", "HEAD"], in: URL(fileURLWithPath: created)),
            freshTip,
            "the worktree was cut from the local base branch, which has not been pulled since the clone"
        )
        XCTAssertEqual(
            gitOutput(["rev-parse", "refs/heads/main"], in: container), staleTip,
            "the local base branch belongs to the trunk checkout; creating a worktree must not move it"
        )
    }

    /// The fallback. Without an origin there is no remote-tracking ref to prefer, and the
    /// local base branch is then both the correct start point and the only one — a repository
    /// that never had a remote must still get a worktree.
    ///
    /// The remote is dropped rather than never added so the container layout still holds:
    /// `worktreeDestination` sends anything else to `~/.atelier/worktrees`, outside the
    /// temporary directory this test cleans up.
    func testWorktreeIsCutFromTheLocalBaseWhenThereIsNoRemote() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "solo")
        XCTAssertTrue(git(["remote", "remove", "origin"], in: container))
        let mainTip = gitOutput(["rev-parse", "refs/heads/main"], in: container)

        let created = try XCTUnwrap(Git.Operations.createWorktree(
            projectPath: container.path,
            projectName: "solo",
            workstreamName: "offline-work"
        ))

        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: URL(fileURLWithPath: created)), mainTip)
    }

    /// `--no-track`. Cutting from `origin/main` would otherwise hand the new branch an
    /// upstream of a different name, which makes a bare `git push` in the workstream's
    /// terminal fail under `push.default=simple` and empties the `@{upstream}..HEAD` range
    /// `hasUnpushedCommits` guards a purge with.
    func testWorktreeBranchGetsNoUpstream() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")

        let created = try XCTUnwrap(Git.Operations.createWorktree(
            projectPath: container.path,
            projectName: "app",
            workstreamName: "untracked-work"
        ))

        XCTAssertFalse(
            git(["rev-parse", "--abbrev-ref", "untracked-work@{upstream}"], in: URL(fileURLWithPath: created)),
            "the branch tracks origin/main, which is not its own name"
        )
    }

    // MARK: - Fixtures

    private func makeOrigin(named name: String) throws -> URL {
        let repo = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: repo))
        try commit("main.txt", in: repo)
        return repo
    }

    /// The README's container layout, built the way `BareRepoClone.clone` builds it: a bare
    /// clone in `.bare`, a `.git` file beside it, and the fetch refspec a bare clone does
    /// not get on its own — without which there are no `origin/*` refs at all.
    private func makeContainerClone(of origin: URL, named name: String) throws -> URL {
        let container = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        XCTAssertTrue(git(["clone", "--bare", origin.path, ".bare"], in: container))
        try "gitdir: ./.bare\n".write(
            to: container.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: container))
        XCTAssertTrue(git(["fetch", "--all", "--prune"], in: container))
        return container
    }

    private func commit(_ file: String, in repo: URL) throws {
        try file.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        XCTAssertTrue(git(["add", file], in: repo))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "-m", "add \(file)"], in: repo))
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func gitOutput(
        _ args: [String],
        in dir: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            XCTFail("could not launch git \(args.joined(separator: " ")): \(error)", file: file, line: line)
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
