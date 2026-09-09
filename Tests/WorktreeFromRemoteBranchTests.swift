// ABOUTME: Tests creating a worktree from a branch that already exists on origin.
// ABOUTME: Covers the remote-tip pre-flight, upstream tracking, and the already-checked-out lookup.

@testable import Atelier
import XCTest

/// `createWorktree` cuts a *new* branch from the base branch, so handing it the name of a
/// branch that only exists as `origin/<name>` succeeds and produces a worktree holding the
/// base branch's code under the right-looking name. These tests pin the separate operation
/// that checks the remote branch out instead.
final class WorktreeFromRemoteBranchTests: XCTestCase {
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

    // MARK: - createWorktreeTrackingRemote

    /// The failure `createWorktree` would produce: a worktree named for the branch, holding
    /// the base branch's commit. Asserting on the commit rather than the branch name is the
    /// only way to catch it — the branch name is right either way.
    func testTrackingWorktreeChecksOutTheRemoteTipNotTheBaseBranch() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        let featureTip = revParse("feature-work", in: origin)
        let mainTip = revParse("main", in: origin)
        XCTAssertNotEqual(featureTip, mainTip, "precondition: the branches must differ")

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "feature-work"
        )

        let worktree = try URL(fileURLWithPath: XCTUnwrap(created))
        XCTAssertEqual(revParse("HEAD", in: worktree), featureTip)
    }

    /// Without an upstream, the worktree's first `git push` needs `-u` and the app's
    /// ahead/behind readings have nothing to measure against.
    func testTrackingWorktreeSetsTheUpstreamToTheRemoteBranch() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "feature-work"
        )

        let worktree = try URL(fileURLWithPath: XCTUnwrap(created))
        XCTAssertEqual(
            gitOutput(["rev-parse", "--abbrev-ref", "feature-work@{upstream}"], in: worktree),
            "origin/feature-work"
        )
    }

    /// A teammate pushes a branch while the app is running, so the container's
    /// remote-tracking refs predate it. The operation has to fetch, not just resolve.
    func testTrackingWorktreeFetchesABranchPushedAfterTheLastFetch() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        XCTAssertTrue(git(["branch", "pushed-later", "feature-work"], in: origin))
        let pushedTip = revParse("pushed-later", in: origin)

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "pushed-later"
        )

        let worktree = try URL(fileURLWithPath: XCTUnwrap(created))
        XCTAssertEqual(revParse("HEAD", in: worktree), pushedTip)
    }

    /// The case the `.bare` container layout makes ordinary rather than exotic: a bare clone
    /// writes every branch into `refs/heads`, and the fetch refspec only ever updates
    /// `refs/remotes/origin/*` after that — so the local ref exists from clone time and is as
    /// old as the clone. Checking it out and stopping there is the same bug in a second
    /// disguise: a worktree named for the branch, holding code from whenever the clone happened.
    func testTrackingWorktreeAdvancesAStaleLocalBranchToTheRemoteTip() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        XCTAssertTrue(git(["checkout", "feature-work"], in: origin))
        try commit("later.txt", in: origin)
        XCTAssertTrue(git(["checkout", "main"], in: origin))
        let remoteTip = revParse("feature-work", in: origin)
        XCTAssertNotEqual(revParse("feature-work", in: container), remoteTip,
                          "precondition: the container's local ref is behind origin")

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "feature-work"
        )

        let worktree = try URL(fileURLWithPath: XCTUnwrap(created))
        XCTAssertEqual(revParse("HEAD", in: worktree), remoteTip)
        XCTAssertEqual(gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree), "feature-work")
    }

    /// The other half of advancing a stale local branch: a local branch carrying commits
    /// origin has never seen must keep them. `--ff-only` is what draws that line, so this is
    /// the test that stops it becoming a `reset --hard`.
    func testTrackingWorktreeKeepsUnpushedCommitsOnTheLocalBranch() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        // Commit on the container's own local branch, then drop the worktree that made it:
        // the branch keeps the commit, and origin never hears about it.
        let scratch = container.appendingPathComponent("scratch")
        XCTAssertTrue(git(["worktree", "add", scratch.path, "feature-work"], in: container))
        try commit("unpushed.txt", in: scratch)
        let unpushedTip = revParse("HEAD", in: scratch)
        XCTAssertTrue(git(["worktree", "remove", "--force", scratch.path], in: container))

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "feature-work"
        )

        let worktree = try URL(fileURLWithPath: XCTUnwrap(created))
        XCTAssertEqual(revParse("HEAD", in: worktree), unpushedTip)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("unpushed.txt").path),
            "the unpushed commit's work must survive"
        )
    }

    /// `renovate/*` and `dependabot/*` branches are the common case for this flow, and a
    /// slash in the path would plant the checkout a directory below `main` instead of
    /// beside it. The branch itself must keep its slash.
    func testTrackingWorktreeFlattensASlashedBranchIntoAPeerDirectory() throws {
        let origin = try makeOrigin(named: "origin-repo")
        XCTAssertTrue(git(["branch", "renovate/swift-format", "feature-work"], in: origin))
        let container = try makeContainerClone(of: origin, named: "app")

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "renovate/swift-format"
        )

        let worktree = try URL(fileURLWithPath: XCTUnwrap(created))
        XCTAssertEqual(worktree.deletingLastPathComponent().standardizedFileURL.path,
                       container.standardizedFileURL.path,
                       "the checkout belongs beside main, not under a renovate/ directory")
        XCTAssertEqual(worktree.lastPathComponent, "renovate--swift-format")
        XCTAssertEqual(
            gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree),
            "renovate/swift-format"
        )
    }

    /// Nothing on origin, nothing local: the operation reports failure rather than
    /// inventing a branch, which is what `createWorktree`'s `-b` would have done.
    func testTrackingWorktreeFailsForABranchThatExistsNowhere() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")

        let created = Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "never-existed"
        )

        XCTAssertNil(created)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: container.appendingPathComponent("never-existed").path),
            "a failed attempt must not leave a directory behind"
        )
    }

    // MARK: - remoteBranchTip

    func testRemoteBranchTipResolvesABranchPushedAfterTheLastFetch() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        XCTAssertTrue(git(["branch", "pushed-later", "feature-work"], in: origin))

        XCTAssertEqual(
            Git.Operations.remoteBranchTip(at: container.path, branch: "pushed-later"),
            revParse("pushed-later", in: origin)
        )
    }

    func testRemoteBranchTipIsNilForABranchOriginDoesNotHave() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")

        XCTAssertNil(Git.Operations.remoteBranchTip(at: container.path, branch: "never-existed"))
    }

    /// A local branch of the same name is not evidence origin has one, and this is the
    /// check that decides whether the sheet reports "no such branch".
    func testRemoteBranchTipIgnoresALocalBranchOfTheSameName() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        XCTAssertTrue(git(["branch", "local-only", "origin/main"], in: container))

        XCTAssertNil(Git.Operations.remoteBranchTip(at: container.path, branch: "local-only"))
    }

    func testRemoteBranchTipIsNilWithoutAnOriginRemote() throws {
        let origin = try makeOrigin(named: "origin-repo")

        XCTAssertNil(Git.Operations.remoteBranchTip(at: origin.path, branch: "feature-work"))
    }

    // MARK: - worktreePath(forBranch:)

    /// git refuses to check a branch out twice, and it reports that as a generic failure
    /// after the optimistic sidebar row already appeared. Naming the holder up front is
    /// what turns it into a message worth reading.
    func testWorktreePathForBranchNamesTheWorktreeHoldingIt() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")
        let created = try XCTUnwrap(Git.Operations.createWorktreeTrackingRemote(
            projectPath: container.path,
            projectName: "app",
            branch: "feature-work"
        ))

        let found = Git.Operations.worktreePath(forBranch: "feature-work", at: container.path)

        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(found)).standardizedFileURL.path,
            URL(fileURLWithPath: created).standardizedFileURL.path
        )
    }

    func testWorktreePathForBranchIsNilWhenNoWorktreeHoldsIt() throws {
        let origin = try makeOrigin(named: "origin-repo")
        let container = try makeContainerClone(of: origin, named: "app")

        XCTAssertNil(Git.Operations.worktreePath(forBranch: "feature-work", at: container.path))
    }

    // MARK: - Fixtures

    /// A repository with `main` and a `feature-work` branch whose tips are different
    /// commits, so a worktree cut from the wrong one is detectable.
    private func makeOrigin(named name: String) throws -> URL {
        let repo = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: repo))
        try commit("main.txt", in: repo)
        XCTAssertTrue(git(["checkout", "-b", "feature-work"], in: repo))
        try commit("feature.txt", in: repo)
        XCTAssertTrue(git(["checkout", "main"], in: repo))
        return repo
    }

    /// The README's container layout, built the way `BareRepoClone.clone` builds it:
    /// a bare clone in `.bare`, a `.git` file pointing at it, and the fetch refspec a
    /// bare clone does not get on its own — without which there are no `origin/*` refs.
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

    private func revParse(_ ref: String, in dir: URL) -> String {
        gitOutput(["rev-parse", ref], in: dir)
    }

    @discardableResult
    private func git(
        _ args: [String],
        in dir: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
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
