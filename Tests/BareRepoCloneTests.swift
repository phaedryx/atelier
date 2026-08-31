// ABOUTME: Tests for cloning a remote into the README's .bare container layout.
// ABOUTME: Covers remote normalization, directory-name derivation, and the clone recipe.

@testable import Atelier
import XCTest

final class BareRepoCloneTests: XCTestCase {
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

    // MARK: - normalizeRemote

    func testNormalizeRemoteExpandsOwnerRepoShorthandToSSH() {
        XCTAssertEqual(BareRepoClone.normalizeRemote("org/repo"), "git@github.com:org/repo.git")
    }

    func testNormalizeRemoteDoesNotDoubleSuffixShorthandThatAlreadyEndsInGit() {
        XCTAssertEqual(BareRepoClone.normalizeRemote("org/repo.git"), "git@github.com:org/repo.git")
    }

    func testNormalizeRemotePassesThroughHTTPSURLs() {
        XCTAssertEqual(
            BareRepoClone.normalizeRemote("https://github.com/org/repo.git"),
            "https://github.com/org/repo.git"
        )
        XCTAssertEqual(
            BareRepoClone.normalizeRemote("https://gitlab.com/group/sub/repo"),
            "https://gitlab.com/group/sub/repo"
        )
    }

    func testNormalizeRemotePassesThroughSCPStyleSSHRemotes() {
        XCTAssertEqual(
            BareRepoClone.normalizeRemote("git@github.com:org/repo.git"),
            "git@github.com:org/repo.git"
        )
    }

    func testNormalizeRemotePassesThroughLocalPaths() {
        XCTAssertEqual(BareRepoClone.normalizeRemote("/tmp/some/origin"), "/tmp/some/origin")
    }

    func testNormalizeRemoteTrimsSurroundingWhitespace() {
        XCTAssertEqual(BareRepoClone.normalizeRemote("  org/repo\n"), "git@github.com:org/repo.git")
    }

    func testNormalizeRemoteRejectsEmptyAndUnrecognizedInput() {
        XCTAssertNil(BareRepoClone.normalizeRemote(""))
        XCTAssertNil(BareRepoClone.normalizeRemote("   "))
        XCTAssertNil(BareRepoClone.normalizeRemote("just-a-word"))
        XCTAssertNil(BareRepoClone.normalizeRemote("org/repo/extra"))
    }

    // MARK: - suggestedDirectoryName

    func testSuggestedDirectoryNameStripsGitSuffixAndPath() {
        XCTAssertEqual(BareRepoClone.suggestedDirectoryName(for: "git@github.com:org/my-repo.git"), "my-repo")
        XCTAssertEqual(BareRepoClone.suggestedDirectoryName(for: "https://github.com/org/my-repo"), "my-repo")
        XCTAssertEqual(BareRepoClone.suggestedDirectoryName(for: "org/my-repo"), "my-repo")
        XCTAssertEqual(BareRepoClone.suggestedDirectoryName(for: "/tmp/some/origin"), "origin")
    }

    func testSuggestedDirectoryNameHandlesTrailingSlashAndBareSCPPath() {
        XCTAssertEqual(BareRepoClone.suggestedDirectoryName(for: "https://github.com/org/my-repo/"), "my-repo")
        XCTAssertEqual(BareRepoClone.suggestedDirectoryName(for: "git@github.com:my-repo.git"), "my-repo")
    }

    func testSuggestedDirectoryNameRejectsNamesThatAreNotUsableDirectories() {
        XCTAssertNil(BareRepoClone.suggestedDirectoryName(for: ""))
        XCTAssertNil(BareRepoClone.suggestedDirectoryName(for: "/"))
        XCTAssertNil(BareRepoClone.suggestedDirectoryName(for: "/tmp/.."))
    }

    // MARK: - clone

    func testCloneProducesTheReadmeBareLayout() throws {
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "main")
        let container = tempDir.appendingPathComponent("my-repo")

        let result = BareRepoClone.clone(remote: origin.path, into: container)

        guard case let .success(path) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(path, container.path)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: container.appendingPathComponent(".bare").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, ".bare must be a directory")

        let pointer = try String(contentsOf: container.appendingPathComponent(".git"), encoding: .utf8)
        XCTAssertEqual(pointer.trimmingCharacters(in: .whitespacesAndNewlines), "gitdir: ./.bare")

        XCTAssertEqual(git(["config", "remote.origin.fetch"], in: container), "+refs/heads/*:refs/remotes/origin/*")
        XCTAssertEqual(git(["config", "wt.default"], in: container), "main")
        XCTAssertEqual(git(["symbolic-ref", "HEAD"], in: container), "refs/heads/root")
        XCTAssertNotNil(git(["rev-parse", "--verify", "refs/heads/root"], in: container))

        // The refspec + fetch must populate remote-tracking refs, which
        // GitOperations.defaultBranch relies on.
        XCTAssertNotNil(git(["rev-parse", "--verify", "refs/remotes/origin/main"], in: container))

        // The default branch is checked out as a peer worktree.
        let worktree = container.appendingPathComponent("main")
        XCTAssertTrue(fm.fileExists(atPath: worktree.appendingPathComponent("f.txt").path))
        XCTAssertEqual(git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree), "main")
    }

    func testCloneResolvesToTheWorkingCheckoutAsTheProject() throws {
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "main")
        let container = tempDir.appendingPathComponent("my-repo")

        guard case .success = BareRepoClone.clone(remote: origin.path, into: container) else {
            return XCTFail("clone failed")
        }

        let location = GitOperations.projectLocation(for: container.path)
        XCTAssertEqual(
            URL(fileURLWithPath: location.directory).standardizedFileURL.path,
            container.appendingPathComponent("main").standardizedFileURL.path
        )
        XCTAssertEqual(location.name, "my-repo", "the project is named for the container, not the branch")
    }

    func testCloneHonoursANonMainDefaultBranch() throws {
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "trunk")
        let container = tempDir.appendingPathComponent("my-repo")

        guard case .success = BareRepoClone.clone(remote: origin.path, into: container) else {
            return XCTFail("clone failed")
        }

        XCTAssertEqual(git(["config", "wt.default"], in: container), "trunk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("trunk").path))
    }

    func testCloneChecksOutTheRealBranchWhenTheDefaultBranchHasASlash() throws {
        // `git worktree add release/1.0` alone infers the branch from the path's
        // last component, so it would create a stray `1.0` off the parked HEAD
        // and never check out release/1.0 at all.
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "release/1.0")
        let container = tempDir.appendingPathComponent("my-repo")

        guard case .success = BareRepoClone.clone(remote: origin.path, into: container) else {
            return XCTFail("clone failed")
        }

        let worktree = container.appendingPathComponent("release/1.0")
        XCTAssertEqual(git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree), "release/1.0")
        XCTAssertNil(
            git(["rev-parse", "--verify", "refs/heads/1.0"], in: container),
            "must not invent a branch named after the path's last component"
        )
    }

    func testCloneStopsAndCleansUpWhenCancelled() throws {
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "main")
        let container = tempDir.appendingPathComponent("cancelled")

        let cancellation = BareRepoClone.Cancellation()
        cancellation.cancel() // already cancelled: the first step must not run

        let result = BareRepoClone.clone(remote: origin.path, into: container, cancellation: cancellation)

        guard case .cancelled = result else {
            return XCTFail("expected .cancelled, got \(result)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: container.path),
            "a cancelled clone must not leave a container behind"
        )
    }

    func testCloneSucceedsWhenTheRepoAlreadyHasARootBranch() throws {
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "main")
        git(["branch", "root"], in: origin)
        let container = tempDir.appendingPathComponent("my-repo")

        guard case .success = BareRepoClone.clone(remote: origin.path, into: container) else {
            return XCTFail("clone failed")
        }
        XCTAssertEqual(git(["symbolic-ref", "HEAD"], in: container), "refs/heads/root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("main").path))
    }

    func testCloneOfAnEmptyRepoStillProducesTheBareContainer() throws {
        let origin = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main", "."], in: origin)
        let container = tempDir.appendingPathComponent("my-repo")

        guard case .success = BareRepoClone.clone(remote: origin.path, into: container) else {
            return XCTFail("expected an empty repo to clone rather than hard-fail")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(".bare").path))
        // No commits means no branch to park HEAD on and nothing to check out.
        XCTAssertNil(git(["rev-parse", "--verify", "refs/heads/root"], in: container))
    }

    func testCloneRefusesAnExistingDestinationAndLeavesItUntouched() throws {
        let origin = try makeSourceRepo(named: "origin", defaultBranch: "main")
        let container = tempDir.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let sentinel = container.appendingPathComponent("keep.txt")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

        guard case let .failure(message) = BareRepoClone.clone(remote: origin.path, into: container) else {
            return XCTFail("expected failure for an existing destination")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("already exists"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "must not touch existing contents")
    }

    func testCloneOfAnUnreachableRemoteLeavesNoDirectoryBehind() {
        let container = tempDir.appendingPathComponent("doomed")

        guard case let .failure(message) = BareRepoClone.clone(
            remote: tempDir.appendingPathComponent("no-such-repo").path,
            into: container
        ) else {
            return XCTFail("expected failure for a nonexistent remote")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: container.path),
            "a failed clone must not leave a half-built container in the base directory"
        )
    }

    // MARK: - Helpers

    private func makeSourceRepo(named name: String, defaultBranch: String) throws -> URL {
        let repo = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "-b", defaultBranch, "."], in: repo)
        try "hi".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        git(["add", "f.txt"], in: repo)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    /// Runs git and returns trimmed stdout, or nil when the command fails.
    @discardableResult
    private func git(_ args: [String], in directory: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
