// ABOUTME: Tests for Git.Operations worktree resolution.
// ABOUTME: Validates detection of worktree directories and resolution to main repository.

@testable import Atelier
import XCTest

final class GitOperationsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // `try!` aborted the whole runner when the temp directory could not be made,
        // instead of failing this one test.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - mainRepositoryPath

    func testMainRepositoryPathReturnsNilForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        XCTAssertNil(Git.Operations.mainRepositoryPath(for: plainDir.path))
    }

    func testMainRepositoryPathReturnsNilForMainRepo() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init"], in: repoDir)

        XCTAssertNil(Git.Operations.mainRepositoryPath(for: repoDir.path))
    }

    func testMainRepositoryPathResolvesWorktreeToMainRepo() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let worktreeDir = tempDir.appendingPathComponent("worktree-branch")
        git(["worktree", "add", "-b", "test-branch", worktreeDir.path], in: repoDir)

        let result = Git.Operations.mainRepositoryPath(for: worktreeDir.path)
        XCTAssertEqual(
            URL(fileURLWithPath: result ?? "").standardizedFileURL.path,
            repoDir.standardizedFileURL.path
        )
    }

    func testMainRepositoryPathReturnsNilForNestedDirectoryInWorktree() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let worktreeDir = tempDir.appendingPathComponent("worktree-branch")
        git(["worktree", "add", "-b", "test-branch", worktreeDir.path], in: repoDir)

        // A subdirectory inside the worktree doesn't have its own .git file
        let subDir = worktreeDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        XCTAssertNil(Git.Operations.mainRepositoryPath(for: subDir.path))
    }

    // MARK: - defaultBranch

    func testDefaultBranchReturnsLocalMainWhenNoRemote() throws {
        let repoDir = tempDir.appendingPathComponent("no-remote")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertEqual(branch, "main")
    }

    func testDefaultBranchReturnsMasterWhenNoMainBranch() throws {
        let repoDir = tempDir.appendingPathComponent("master-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "master"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertEqual(branch, "master")
    }

    func testDefaultBranchReturnsHEADWhenNeitherMainNorMasterExist() throws {
        let repoDir = tempDir.appendingPathComponent("custom-branch")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "develop"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertEqual(branch, "HEAD")
    }

    func testDefaultBranchPrefersOriginOverLocal() throws {
        // Create a non-bare "remote" repo with a commit on main
        let remoteDir = tempDir.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: remoteDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: remoteDir)

        // Clone it so we have origin/main
        let repoDir = tempDir.appendingPathComponent("cloned")
        git(["clone", remoteDir.path, repoDir.path], in: tempDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertTrue(branch.contains("origin"), "Expected origin-prefixed branch, got: \(branch)")
    }

    func testDefaultBranchPrefersLocalDevelopmentOverMain() throws {
        // development beats main/master in the precedence order.
        let repoDir = tempDir.appendingPathComponent("dev-over-main")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)
        git(["branch", "development"], in: repoDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertEqual(branch, "development", "local development must win over local main")
    }

    func testDefaultBranchPrefersOriginDevelopmentOverEverything() throws {
        // origin/development is the highest-priority ref of all.
        let remoteDir = tempDir.appendingPathComponent("remote-dev")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: remoteDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: remoteDir)
        git(["branch", "development"], in: remoteDir)

        let repoDir = tempDir.appendingPathComponent("cloned-dev")
        git(["clone", remoteDir.path, repoDir.path], in: tempDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertEqual(branch, "origin/development",
                       "origin/development must take precedence over every other ref")
    }

    func testDefaultBranchUsesOriginHEADWhenNoDevelopment() throws {
        // No development branch anywhere → resolve via origin/HEAD symbolic-ref,
        // which a clone sets to the remote's default branch (here: master).
        let remoteDir = tempDir.appendingPathComponent("remote-head")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        git(["init", "-b", "master"], in: remoteDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: remoteDir)

        let repoDir = tempDir.appendingPathComponent("cloned-head")
        git(["clone", remoteDir.path, repoDir.path], in: tempDir)
        // Ensure origin/HEAD points at the remote default branch.
        git(["remote", "set-head", "origin", "--auto"], in: repoDir)

        let branch = Git.Operations.defaultBranch(at: repoDir.path)
        XCTAssertEqual(branch, "origin/master",
                       "with no development branch, origin/HEAD must resolve the default, got: \(branch)")
    }

    // MARK: - fetchDefaultBranch

    func testFetchDefaultBranchDoesNotCrashWithoutRemote() throws {
        let repoDir = tempDir.appendingPathComponent("no-remote-fetch")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        // Should return silently without crashing
        Git.Operations.fetchDefaultBranch(at: repoDir.path)
    }

    func testFetchDefaultBranchDoesNotCrashForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        // Should return silently without crashing
        Git.Operations.fetchDefaultBranch(at: plainDir.path)
    }

    func testFetchDefaultBranchDoesNotCrashWithUnreachableRemote() throws {
        let repoDir = tempDir.appendingPathComponent("bad-remote")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)
        git(["remote", "add", "origin", "https://invalid.example.com/repo.git"], in: repoDir)

        // Should fail silently (timeout or network error)
        Git.Operations.fetchDefaultBranch(at: repoDir.path)
    }

    // MARK: - currentBranch

    func testCurrentBranchReturnsActiveBranch() throws {
        let repoDir = tempDir.appendingPathComponent("branch-test")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        XCTAssertEqual(Git.Operations.currentBranch(at: repoDir.path), "main")
    }

    func testCurrentBranchReturnsNilForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        XCTAssertNil(Git.Operations.currentBranch(at: plainDir.path))
    }

    func testCurrentBranchReturnsWorktreeBranch() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let worktreeDir = tempDir.appendingPathComponent("wt")
        git(["worktree", "add", "-b", "ff/my-feature", worktreeDir.path], in: repoDir)

        XCTAssertEqual(Git.Operations.currentBranch(at: worktreeDir.path), "ff/my-feature")
    }

    // MARK: - deleteLocalBranch

    func testDeleteLocalBranchRemovesBranch() throws {
        let repoDir = tempDir.appendingPathComponent("delete-branch")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)
        git(["branch", "feature"], in: repoDir)

        Git.Operations.deleteLocalBranch(at: repoDir.path, branchName: "feature")

        // Verify branch no longer exists
        let result = git(["rev-parse", "--verify", "refs/heads/feature"], in: repoDir)
        XCTAssertFalse(result, "Branch should have been deleted")
    }

    // MARK: - fetchDefaultBranch

    func testFetchDefaultBranchSkipsWithoutRemote() throws {
        let repoDir = tempDir.appendingPathComponent("no-remote-update")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        // Should return silently without crashing
        Git.Operations.fetchDefaultBranch(at: repoDir.path)
    }

    func testFetchDefaultBranchDoesNotMoveLocalRef() throws {
        // Create a "remote" repo
        let remoteDir = tempDir.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: remoteDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: remoteDir)

        // Clone it
        let repoDir = tempDir.appendingPathComponent("local")
        git(["clone", remoteDir.path, repoDir.path], in: tempDir)

        // Record the initial commit
        let beforeSHA = gitOutput(["rev-parse", "refs/heads/main"], in: repoDir)

        // Add a new commit to remote
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "second"], in: remoteDir)

        // Fetch should update remote tracking ref but not local main
        Git.Operations.fetchDefaultBranch(at: repoDir.path)

        let afterSHA = gitOutput(["rev-parse", "refs/heads/main"], in: repoDir)
        XCTAssertEqual(beforeSHA, afterSHA, "Local main should not have moved")

        let remoteSHA = gitOutput(["rev-parse", "refs/remotes/origin/main"], in: repoDir)
        XCTAssertNotEqual(beforeSHA, remoteSHA, "Remote tracking ref should have advanced")
    }

    // MARK: - fileStatuses

    func testFileStatusesReturnsModifiedForTrackedChanges() throws {
        let repoDir = tempDir.appendingPathComponent("status-modified")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)

        let filePath = repoDir.appendingPathComponent("tracked.txt")
        try "original".write(to: filePath, atomically: true, encoding: .utf8)
        git(["add", "tracked.txt"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)

        try "changed".write(to: filePath, atomically: true, encoding: .utf8)

        let statuses = Git.Operations.fileStatuses(at: repoDir.path)
        XCTAssertEqual(statuses["tracked.txt"], .modified)
    }

    func testFileStatusesReturnsUntrackedForNewFiles() throws {
        let repoDir = tempDir.appendingPathComponent("status-untracked")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        try "new file".write(
            to: repoDir.appendingPathComponent("untracked.txt"),
            atomically: true, encoding: .utf8
        )

        let statuses = Git.Operations.fileStatuses(at: repoDir.path)
        XCTAssertEqual(statuses["untracked.txt"], .untracked)
    }

    func testFileStatusesReturnsIgnoredForGitignored() throws {
        let repoDir = tempDir.appendingPathComponent("status-ignored")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)

        try "build/\n".write(
            to: repoDir.appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8
        )
        let buildDir = repoDir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "artifact".write(
            to: buildDir.appendingPathComponent("output.o"),
            atomically: true, encoding: .utf8
        )

        let statuses = Git.Operations.fileStatuses(at: repoDir.path)
        XCTAssertEqual(statuses["build"], .ignored)
    }

    func testFileStatusesReturnsEmptyForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("no-git")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        let statuses = Git.Operations.fileStatuses(at: plainDir.path)
        XCTAssertTrue(statuses.isEmpty)
    }

    func testFileStatusesHandlesRenames() throws {
        let repoDir = tempDir.appendingPathComponent("status-rename")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)

        try "content".write(
            to: repoDir.appendingPathComponent("old.txt"),
            atomically: true, encoding: .utf8
        )
        git(["add", "old.txt"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)

        git(["mv", "old.txt", "new.txt"], in: repoDir)

        let statuses = Git.Operations.fileStatuses(at: repoDir.path)
        XCTAssertEqual(statuses["new.txt"], .modified)
    }

    // MARK: - pruneCleanWorktrees

    func testPruneCleanWorktreesPrunesOnlyRequestedPaths() throws {
        let repoDir = tempDir.appendingPathComponent("prune-filtered")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        let worktreeA = tempDir.appendingPathComponent("worktree-a")
        let worktreeB = tempDir.appendingPathComponent("worktree-b")
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/a", worktreeA.path], in: repoDir))
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/b", worktreeB.path], in: repoDir))

        let pruned = Git.Operations.pruneCleanWorktrees(
            at: repoDir.path,
            onlyPaths: Set([worktreeA.path])
        )

        XCTAssertEqual(pruned, Set([worktreeA.standardizedFileURL.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreeB.path))
    }

    /// `applyPrunedWorktrees` used to drop every *attempted* path from the project's
    /// workstream list, so a worktree git refused to remove vanished from the sidebar
    /// while its directory sat on disk. It can only drop the right ones if this
    /// returns which ones actually went.
    func testPruneCleanWorktreesReportsOnlyTheOnesItRemoved() throws {
        let repoDir = tempDir.appendingPathComponent("prune-partial")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))

        let clean = tempDir.appendingPathComponent("prune-clean")
        let locked = tempDir.appendingPathComponent("prune-locked")
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/clean", clean.path], in: repoDir))
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/locked", locked.path], in: repoDir))
        // A *locked* worktree, not a dirty one. A dirty worktree is filtered out by
        // `isDirty` before removal is ever attempted, so it would exercise the
        // selection rather than the reporting, and this test would pass whether or
        // not the return distinguishes attempted from removed — confirmed by
        // mutation. A locked worktree is clean to `git status` and still refused by
        // `git worktree remove`, which is the case that actually reaches the branch.
        XCTAssertTrue(git(["worktree", "lock", locked.path], in: repoDir))

        let pruned = Git.Operations.pruneCleanWorktrees(
            at: repoDir.path,
            onlyPaths: Set([clean.path, locked.path])
        )

        XCTAssertEqual(pruned, Set([clean.standardizedFileURL.path]), "only the one git actually removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path), "git refused; the directory stays")
    }

    /// Prune selects on "clean", so a worktree whose cleanliness never got
    /// established must not be selected — regardless of what the caller asked for.
    func testPruneCleanWorktreesSkipsWorktreesItCouldNotVet() throws {
        let repoDir = tempDir.appendingPathComponent("prune-unknown")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        // `develop` resolves to no base branch, so hasBranchCommits cannot tell.
        XCTAssertTrue(git(["init", "-b", "develop"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))
        let worktree = tempDir.appendingPathComponent("prune-unvetted")
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/unvetted", worktree.path], in: repoDir))

        let pruned = Git.Operations.pruneCleanWorktrees(at: repoDir.path, onlyPaths: Set([worktree.path]))

        XCTAssertTrue(pruned.isEmpty, "cleanliness was never established, so this is not a clean worktree")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    }

    // MARK: - Probes that must not report "clean" when they could not look

    /// The destructive one. `updateDefaultBranch` runs `git reset --hard` behind
    /// `!hasUncommittedChanges`, so a status probe that fails reads as "clean" and
    /// the reset discards work that is not recoverable from anywhere — no branch
    /// ref, no reflog entry, nothing.
    ///
    /// The fixture breaks `git status` *specifically*: `status.showUntrackedFiles`
    /// set to a bad value makes status exit 128 while `fetch`, `merge-base`,
    /// `update-ref` and `reset --hard` all still succeed. That precision is the
    /// whole point — a corrupt `.git/index` also fails status, but it fails
    /// `reset --hard` too, so the file would survive whether or not this is fixed
    /// and the test would pass for the wrong reason.
    func testUpdateDefaultBranchDoesNotResetAWorkingTreeItCouldNotRead() throws {
        let (remote, local) = try makeCloneWithOrigin(named: "unreadable-status")
        _ = remote

        try "LOCAL EDIT".write(to: local.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        // Breaks `git status` and nothing else.
        XCTAssertTrue(git(["config", "status.showUntrackedFiles", "bogus"], in: local))
        XCTAssertNil(
            Git.Operations.hasUncommittedChanges(at: local.path),
            "precondition: the status probe has to actually fail for this test to mean anything"
        )

        Git.Operations.updateDefaultBranch(at: local.path)

        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "LOCAL EDIT",
            "an unreadable working tree must not be reset — the edit is unrecoverable"
        )
    }

    /// The positive control. Without it the test above passes on a fixture that
    /// never reached the reset at all, which would make it worthless.
    func testUpdateDefaultBranchStillResetsAReadableCleanWorkingTree() throws {
        let (remote, local) = try makeCloneWithOrigin(named: "readable-status")
        _ = remote

        // Committed to origin after the clone, so the local branch fast-forwards and
        // the reset has something to bring in.
        try "LOCAL EDIT".write(to: local.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Git.Operations.hasUncommittedChanges(at: local.path), true, "precondition")

        // Now make it genuinely clean, and prove the reset path is live.
        XCTAssertTrue(git(["checkout", "--", "tracked.txt"], in: local))
        XCTAssertEqual(Git.Operations.hasUncommittedChanges(at: local.path), false, "precondition")

        Git.Operations.updateDefaultBranch(at: local.path)

        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "original",
            "a readable clean tree still gets updated; the fix must not disable this path"
        )
    }

    func testHasUncommittedChangesSaysItCouldNotTellRatherThanClean() throws {
        let plainDir = tempDir.appendingPathComponent("not-a-repo-status")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        XCTAssertNil(Git.Operations.hasUncommittedChanges(at: plainDir.path))
    }

    func testHasUncommittedChangesDistinguishesCleanFromDirty() throws {
        let repoDir = tempDir.appendingPathComponent("status-states")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))

        XCTAssertEqual(Git.Operations.hasUncommittedChanges(at: repoDir.path), false)

        try "x".write(to: repoDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Git.Operations.hasUncommittedChanges(at: repoDir.path), true)
    }

    /// Same `"HEAD"` sentinel `worktreeDetail` guards against: `git log HEAD..HEAD`
    /// is a valid empty range that exits 0, so an unresolvable base branch used to
    /// report "no branch commits" with full confidence.
    func testHasBranchCommitsSaysItCouldNotTellWhenTheBaseDoesNotResolve() throws {
        let repoDir = tempDir.appendingPathComponent("develop-only")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "develop"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))
        XCTAssertEqual(Git.Operations.defaultBranch(at: repoDir.path), "HEAD", "precondition")

        XCTAssertNil(Git.Operations.hasBranchCommits(at: repoDir.path, projectPath: repoDir.path))
    }

    func testHasBranchCommitsDistinguishesNoneFromSome() throws {
        let repoDir = tempDir.appendingPathComponent("branch-commits")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))

        let worktree = tempDir.appendingPathComponent("wt-commits")
        XCTAssertTrue(git(["worktree", "add", "-b", "feature", worktree.path], in: repoDir))
        XCTAssertEqual(Git.Operations.hasBranchCommits(at: worktree.path, projectPath: repoDir.path), false)

        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "ahead"], in: worktree))
        XCTAssertEqual(Git.Operations.hasBranchCommits(at: worktree.path, projectPath: repoDir.path), true)
    }

    /// Prune has to fail closed: a worktree whose cleanliness could not be
    /// established is not a clean worktree.
    func testListWorktreesMarksCleanlinessUnknownWhenABaseBranchDoesNotResolve() throws {
        let repoDir = tempDir.appendingPathComponent("unknown-cleanliness")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "develop"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))
        let worktree = tempDir.appendingPathComponent("wt-unknown")
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/unknown", worktree.path], in: repoDir))

        let infos = Git.Operations.listWorktreesWithInfo(at: repoDir.path)
        let linked = try XCTUnwrap(infos.first { !$0.isMain })

        XCTAssertTrue(linked.cleanlinessUnknown, "the base branch did not resolve, so 'no commits' was never established")
    }

    func testListWorktreesReportsKnownCleanlinessForAnOrdinaryRepository() throws {
        let repoDir = tempDir.appendingPathComponent("known-cleanliness")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: repoDir))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "--allow-empty", "-m", "init"], in: repoDir))
        let worktree = tempDir.appendingPathComponent("wt-known")
        XCTAssertTrue(git(["worktree", "add", "-b", "feature/known", worktree.path], in: repoDir))

        let infos = Git.Operations.listWorktreesWithInfo(at: repoDir.path)
        let linked = try XCTUnwrap(infos.first { !$0.isMain })

        XCTAssertFalse(linked.cleanlinessUnknown, "both probes ran here; an always-true flag would make Prune useless")
        XCTAssertFalse(linked.isDirty)
        XCTAssertFalse(linked.hasBranchCommits)
    }

    /// A clone with a real `origin`, one tracked file, and a branch that can
    /// fast-forward — the preconditions `updateDefaultBranch` walks before it
    /// reaches the reset.
    private func makeCloneWithOrigin(named name: String) throws -> (remote: URL, local: URL) {
        let remote = tempDir.appendingPathComponent("\(name)-remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: remote))
        try "original".write(to: remote.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(git(["add", "tracked.txt"], in: remote))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "-m", "seed"], in: remote))

        let local = tempDir.appendingPathComponent("\(name)-local")
        XCTAssertTrue(git(["clone", remote.path, local.path], in: tempDir))
        return (remote, local)
    }

    // MARK: - uncommittedDiffFiles (Changes tab tracer)

    func testUncommittedDiffFilesListsModifiedTrackedFile() throws {
        let repoDir = tempDir.appendingPathComponent("changes-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        let file = repoDir.appendingPathComponent("a.swift")
        try "let original = 1\n".write(to: file, atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)

        // Modify the tracked file without committing.
        try "let modified = 2\n".write(to: file, atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        XCTAssertGreaterThanOrEqual(files.count, 1)
        XCTAssertTrue(files.contains { $0.relativePath == "a.swift" && $0.status == .modified })
    }

    func testFileContentReturnsCommittedContentForRef() throws {
        let repoDir = tempDir.appendingPathComponent("content-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        let file = repoDir.appendingPathComponent("a.swift")
        try "let original = 1\n".write(to: file, atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)

        let content = Git.Operations.fileContent(at: repoDir.path, ref: "HEAD", filePath: "a.swift")
        XCTAssertEqual(content, "let original = 1\n")
    }

    // MARK: - Pipe-deadlock fix (Hardening 4)

    func testFileContentReturnsFullContentForLargeFile() throws {
        // A file larger than the ~64 KB pipe buffer must be returned in full
        // (stdout drained before waitUntilExit; no truncation, no deadlock).
        let repoDir = tempDir.appendingPathComponent("large-blob")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)

        // 256 KB of text — well over the macOS pipe buffer.
        let line = "the quick brown fox jumps over the lazy dog\n"
        var big = ""
        big.reserveCapacity(300_000)
        while big.utf8.count < 256 * 1024 {
            big += line
        }
        let expectedCount = big.utf8.count
        let file = repoDir.appendingPathComponent("big.txt")
        try big.write(to: file, atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "big"], in: repoDir)

        let content = Git.Operations.fileContent(at: repoDir.path, ref: "HEAD", filePath: "big.txt")
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.utf8.count, expectedCount, "Large git output must not be truncated")
    }

    // MARK: - mergeBase

    func testMergeBaseReturnsCommonAncestor() throws {
        let repoDir = tempDir.appendingPathComponent("mb-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        let file = repoDir.appendingPathComponent("a.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "base"], in: repoDir)
        let baseSHA = gitOutput(["rev-parse", "HEAD"], in: repoDir)

        // Branch off, advance both branches.
        git(["checkout", "-b", "feature"], in: repoDir)
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        git(["commit", "-am", "feature work",
             "-c", "user.email=test@test.com", "-c", "user.name=Test"], in: repoDir)

        // mergeBase(main, HEAD=feature) must be the base commit.
        let mb = Git.Operations.mergeBase(worktreePath: repoDir.path, projectPath: repoDir.path)
        XCTAssertEqual(mb, baseSHA)
    }

    func testMergeBaseReturnsNilForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("mb-not-a-repo")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        XCTAssertNil(Git.Operations.mergeBase(worktreePath: plainDir.path, projectPath: plainDir.path))
    }

    // MARK: - branchDiffFiles (Branch mode + untracked union — Hardening 1)

    func testBranchDiffFilesIncludesCommittedUncommittedAndUntracked() throws {
        // Set up: project repo with a base commit on main, then a worktree
        // branch that has (a) a committed-but-unmerged file, (b) an uncommitted
        // edit to a tracked file, and (c) an untracked new file.
        let projectDir = tempDir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: projectDir)
        let tracked = projectDir.appendingPathComponent("b.swift")
        try "let b = 0\n".write(to: tracked, atomically: true, encoding: .utf8)
        git(["add", "."], in: projectDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "base"], in: projectDir)

        let wt = tempDir.appendingPathComponent("wt")
        git(["worktree", "add", "-b", "feature", wt.path], in: projectDir)

        // (a) committed-but-unmerged file on the branch
        let committedFile = wt.appendingPathComponent("a.swift")
        try "let a = 1\n".write(to: committedFile, atomically: true, encoding: .utf8)
        git(["add", "a.swift"], in: wt)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "add a"], in: wt)

        // (b) uncommitted edit to tracked b.swift
        try "let b = 99\n".write(to: wt.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        // (c) untracked new file
        try "let c = 3\n".write(to: wt.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)

        let files = Git.Operations.branchDiffFiles(worktreePath: wt.path, projectPath: projectDir.path)
        let paths = Set(files.map(\.relativePath))
        XCTAssertTrue(paths.contains("a.swift"), "committed file missing")
        XCTAssertTrue(paths.contains("b.swift"), "uncommitted edit missing")
        XCTAssertTrue(paths.contains("c.swift"), "untracked file missing (Hardening 1)")
        XCTAssertTrue(
            files.contains { $0.relativePath == "c.swift" && $0.status == .added },
            "untracked file must be status .added"
        )
    }

    func testBranchDiffFilesIncludesOnlyUntrackedFile() throws {
        // Branch whose only change is a never-committed new file.
        let projectDir = tempDir.appendingPathComponent("proj2")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: projectDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "base"], in: projectDir)

        let wt = tempDir.appendingPathComponent("wt2")
        git(["worktree", "add", "-b", "feature2", wt.path], in: projectDir)
        try "hello\n".write(to: wt.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let files = Git.Operations.branchDiffFiles(worktreePath: wt.path, projectPath: projectDir.path)
        XCTAssertTrue(
            files.contains { $0.relativePath == "new.txt" && $0.status == .added },
            "untracked-only branch change must be listed (PR #440 gap)"
        )
    }

    func testBranchDiffFilesMarksDeletedFile() throws {
        let projectDir = tempDir.appendingPathComponent("proj-del")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: projectDir)
        try "gone\n".write(to: projectDir.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: projectDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "base"], in: projectDir)

        let wt = tempDir.appendingPathComponent("wt-del")
        git(["worktree", "add", "-b", "feature-del", wt.path], in: projectDir)
        try FileManager.default.removeItem(at: wt.appendingPathComponent("gone.txt"))

        let files = Git.Operations.branchDiffFiles(worktreePath: wt.path, projectPath: projectDir.path)
        XCTAssertTrue(files.contains { $0.relativePath == "gone.txt" && $0.status == .deleted })
    }

    func testBranchDiffFilesUsesNewPathForRename() throws {
        let projectDir = tempDir.appendingPathComponent("proj-ren")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: projectDir)
        try "some longer content that survives rename detection\n"
            .write(to: projectDir.appendingPathComponent("old.swift"), atomically: true, encoding: .utf8)
        git(["add", "."], in: projectDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "base"], in: projectDir)

        let wt = tempDir.appendingPathComponent("wt-ren")
        git(["worktree", "add", "-b", "feature-ren", wt.path], in: projectDir)
        git(["mv", "old.swift", "new.swift"], in: wt)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "rename"], in: wt)

        let files = Git.Operations.branchDiffFiles(worktreePath: wt.path, projectPath: projectDir.path)
        XCTAssertTrue(
            files.contains { $0.relativePath == "new.swift" },
            "renamed file should be listed under its new path"
        )
        XCTAssertFalse(files.contains { $0.relativePath == "old.swift" })
    }

    func testBranchDiffFilesReturnsEmptyForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("branch-not-a-repo")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        XCTAssertTrue(
            Git.Operations.branchDiffFiles(worktreePath: plainDir.path, projectPath: plainDir.path).isEmpty
        )
    }

    // MARK: - uncommittedDiffFiles (untracked union — Hardening 1)

    func testUncommittedDiffFilesIncludesUntrackedAsAdded() throws {
        let repoDir = tempDir.appendingPathComponent("uncommitted-untracked")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)
        try "let c = 3\n".write(to: repoDir.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        XCTAssertTrue(files.contains { $0.relativePath == "c.swift" && $0.status == .added })
    }

    func testUncommittedDiffFilesExcludesUnchangedFiles() throws {
        let repoDir = tempDir.appendingPathComponent("uncommitted-clean")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "let a = 1\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "let b = 0\n".write(to: repoDir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)
        // Only modify b.swift.
        try "let b = 99\n".write(to: repoDir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        XCTAssertTrue(files.contains { $0.relativePath == "b.swift" })
        XCTAssertFalse(files.contains { $0.relativePath == "a.swift" }, "unchanged file must not appear")
    }

    // MARK: - Binary detection (Hardening 2)

    func testBranchDiffFilesDetectsBinaryTrackedFile() throws {
        let projectDir = tempDir.appendingPathComponent("proj-bin")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: projectDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "base"], in: projectDir)

        let wt = tempDir.appendingPathComponent("wt-bin")
        git(["worktree", "add", "-b", "feature-bin", wt.path], in: projectDir)

        // A committed binary file (contains NUL bytes) — numstat reports "-"/"-".
        var bytes = Data()
        for i in 0 ..< 2048 {
            bytes.append(UInt8(i % 256))
        }
        try bytes.write(to: wt.appendingPathComponent("image.png"))
        git(["add", "image.png"], in: wt)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "add binary"], in: wt)

        let files = Git.Operations.branchDiffFiles(worktreePath: wt.path, projectPath: projectDir.path)
        let entry = files.first { $0.relativePath == "image.png" }
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isBinary ?? false, "tracked binary must be flagged via numstat -/-")
    }

    func testUncommittedDiffFilesDetectsBinaryUntrackedViaNullByte() throws {
        let repoDir = tempDir.appendingPathComponent("uncommitted-bin")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)

        // Untracked binary file — numstat won't cover it; null-byte sniff must catch it.
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00])
        for i in 0 ..< 512 {
            bytes.append(UInt8(i % 256))
        }
        try bytes.write(to: repoDir.appendingPathComponent("untracked.bin"))

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "untracked.bin" }
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isBinary ?? false, "untracked binary must be detected by null-byte sniff")
    }

    func testTextFileIsNotMarkedBinary() throws {
        let repoDir = tempDir.appendingPathComponent("uncommitted-text")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "let a = 1\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)
        try "let a = 2\nlet b = 3\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "a.swift" }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.isBinary ?? true, "text file must not be flagged binary")
    }

    // MARK: - changedLines from numstat (Hardening 3)

    func testChangedLinesReflectNumstatCounts() throws {
        let repoDir = tempDir.appendingPathComponent("changed-lines")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "line1\nline2\nline3\n".write(to: repoDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)
        // Add 2 lines, remove 0 (append).
        try "line1\nline2\nline3\nline4\nline5\n".write(to: repoDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "a.txt" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.changedLines, 2, "added=2, deleted=0 → changedLines=2")
    }

    func testUntrackedChangedLinesCountFileLines() throws {
        let repoDir = tempDir.appendingPathComponent("untracked-lines")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)
        try "a\nb\nc\nd\n".write(to: repoDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "new.txt" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.changedLines, 4, "untracked changedLines = line count of file")
        XCTAssertGreaterThan(entry?.sizeHint ?? 0, 0, "sizeHint should reflect on-disk byte size")
    }

    // MARK: - separate added/deleted counts from numstat

    func testAddedAndDeletedCountsReflectNumstat() throws {
        let repoDir = tempDir.appendingPathComponent("add-del")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "line1\nline2\nline3\nline4\n".write(to: repoDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)
        // Replace line2/line3 (2 deletions) and append two new lines (2 additions).
        try "line1\nchanged2\nchanged3\nline4\nline5\nline6\n".write(
            to: repoDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "a.txt" }
        XCTAssertNotNil(entry)
        // git numstat: replacing 2 lines = 2 add + 2 del; appending 2 lines = 2 add.
        XCTAssertEqual(entry?.added, 4, "added lines from numstat")
        XCTAssertEqual(entry?.deleted, 2, "deleted lines from numstat")
        XCTAssertEqual(entry?.changedLines, 6, "changedLines = added + deleted")
    }

    func testUntrackedFileAddedEqualsLineCountDeletedZero() throws {
        let repoDir = tempDir.appendingPathComponent("untracked-add-del")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "--allow-empty", "-m", "init"], in: repoDir)
        try "a\nb\nc\n".write(to: repoDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "new.txt" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.added, 3, "untracked added = file line count")
        XCTAssertEqual(entry?.deleted, 0, "untracked deleted = 0")
    }

    func testDeletedFileHasDeletionsNoAdditions() throws {
        let repoDir = tempDir.appendingPathComponent("deleted-counts")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "x\ny\n".write(to: repoDir.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)
        try FileManager.default.removeItem(at: repoDir.appendingPathComponent("gone.txt"))

        let files = Git.Operations.uncommittedDiffFiles(at: repoDir.path)
        let entry = files.first { $0.relativePath == "gone.txt" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.added, 0, "deleted file has no additions")
        XCTAssertEqual(entry?.deleted, 2, "deleted file deletions = original line count")
    }

    // MARK: - diffFingerprint

    func testDiffFingerprintStableWhenNothingChanges() throws {
        let repoDir = tempDir.appendingPathComponent("fp-stable")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "let a = 1\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)
        try "let a = 2\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let fp1 = Git.Operations.diffFingerprint(worktreePath: repoDir.path, projectPath: repoDir.path, mode: "uncommitted")
        let fp2 = Git.Operations.diffFingerprint(worktreePath: repoDir.path, projectPath: repoDir.path, mode: "uncommitted")
        XCTAssertEqual(fp1, fp2, "fingerprint must be stable when nothing changes")
    }

    func testDiffFingerprintChangesWhenContentChanges() throws {
        let repoDir = tempDir.appendingPathComponent("fp-change")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoDir)
        try "let a = 1\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repoDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "init"], in: repoDir)

        let fpClean = Git.Operations.diffFingerprint(worktreePath: repoDir.path, projectPath: repoDir.path, mode: "uncommitted")

        // Edit the file.
        try "let a = 2\nlet b = 3\n".write(to: repoDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let fpEdited = Git.Operations.diffFingerprint(worktreePath: repoDir.path, projectPath: repoDir.path, mode: "uncommitted")
        XCTAssertNotEqual(fpClean, fpEdited, "fingerprint must change after an edit")

        // Add an untracked file (uncommitted mode includes ls-files --others).
        try "new\n".write(to: repoDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let fpUntracked = Git.Operations.diffFingerprint(worktreePath: repoDir.path, projectPath: repoDir.path, mode: "uncommitted")
        XCTAssertNotEqual(fpEdited, fpUntracked, "fingerprint must change when an untracked file appears")
    }

    func testDiffFingerprintDoesNotCrashForNonGitDirectory() throws {
        let plainDir = tempDir.appendingPathComponent("fp-not-a-repo")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        // Must not crash; returns some stable string.
        let fp = Git.Operations.diffFingerprint(worktreePath: plainDir.path, projectPath: plainDir.path, mode: "branch")
        XCTAssertFalse(fp.isEmpty)
    }

    func testDiffFingerprintBranchModeStableThenChangesOnTrackedEditAndUntracked() throws {
        // Branch mode: fingerprint is computed from `git diff --stat <merge-base>`
        // PLUS the untracked-file list (HEAD SHA + a hash of both). It must be
        // stable across calls when nothing changes, and shift when a tracked
        // file is edited OR an untracked file is added.
        //
        // Branch mode folds in `ls-files --others --exclude-standard` exactly
        // like uncommitted mode, so a newly-added untracked file moves the
        // fingerprint — keeping the refresh-on-tab-appear short-circuit in sync
        // with the diff listing, which unions untracked files in (Hardening 1).
        let projectDir = tempDir.appendingPathComponent("fp-branch-proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: projectDir)
        try "let b = 0\n".write(to: projectDir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        git(["add", "."], in: projectDir)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
             "commit", "-m", "base"], in: projectDir)

        let wt = tempDir.appendingPathComponent("fp-branch-wt")
        git(["worktree", "add", "-b", "feature-fp", wt.path], in: projectDir)

        let fp1 = Git.Operations.diffFingerprint(worktreePath: wt.path, projectPath: projectDir.path, mode: "branch")
        let fp2 = Git.Operations.diffFingerprint(worktreePath: wt.path, projectPath: projectDir.path, mode: "branch")
        XCTAssertEqual(fp1, fp2, "branch-mode fingerprint must be stable when nothing changes")

        // Edit a tracked file — this moves `git diff --stat`, so the fingerprint changes.
        try "let b = 99\n".write(to: wt.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let fpEdited = Git.Operations.diffFingerprint(worktreePath: wt.path, projectPath: projectDir.path, mode: "branch")
        XCTAssertNotEqual(fp1, fpEdited, "branch-mode fingerprint must change after a tracked-file edit")

        // Add an untracked file — branch mode folds in `ls-files --others`, so
        // the fingerprint must move even though `git diff --stat` is unchanged.
        try "let c = 3\n".write(to: wt.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)
        let fpUntracked = Git.Operations.diffFingerprint(worktreePath: wt.path, projectPath: projectDir.path, mode: "branch")
        XCTAssertNotEqual(fpEdited, fpUntracked, "branch-mode fingerprint must change when an untracked file is added")
    }

    // MARK: - projectLocation

    func testProjectLocationOfAPlainRepoIsTheRepoItself() throws {
        let repoDir = tempDir.appendingPathComponent("plain-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repoDir)
        git(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init"], in: repoDir)

        let location = Git.Operations.projectLocation(for: repoDir.path)
        XCTAssertEqual(standardized(location.directory), repoDir.standardizedFileURL.path)
        XCTAssertEqual(location.name, "plain-repo")
    }

    func testProjectLocationOfANonRepoDirectoryIsTheDirectoryItself() throws {
        let plainDir = tempDir.appendingPathComponent("just-files")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        let location = Git.Operations.projectLocation(for: plainDir.path)
        XCTAssertEqual(standardized(location.directory), plainDir.standardizedFileURL.path)
        XCTAssertEqual(location.name, "just-files")
    }

    func testProjectLocationOfAWorktreeResolvesToTheMainRepo() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repoDir)
        git(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init"], in: repoDir)
        let worktreeDir = tempDir.appendingPathComponent("wt")
        git(["worktree", "add", "-q", "-b", "feature", worktreeDir.path], in: repoDir)

        let location = Git.Operations.projectLocation(for: worktreeDir.path)
        XCTAssertEqual(standardized(location.directory), repoDir.standardizedFileURL.path)
        XCTAssertEqual(location.name, "main-repo")
    }

    func testProjectLocationOfABareContainerResolvesToItsDefaultWorktree() throws {
        let container = try makeBareContainer(named: "bare-project")

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(
            standardized(location.directory),
            container.appendingPathComponent("main").standardizedFileURL.path,
            "a bare container has no work tree; the project must be its default checkout"
        )
        XCTAssertEqual(location.name, "bare-project", "the project keeps the container's name, not the branch's")
    }

    func testProjectLocationOfACheckoutInsideABareContainerStaysOnTheCheckout() throws {
        let container = try makeBareContainer(named: "bare-project")
        let checkout = container.appendingPathComponent("main")

        let location = Git.Operations.projectLocation(for: checkout.path)
        XCTAssertEqual(standardized(location.directory), checkout.standardizedFileURL.path)
        XCTAssertEqual(location.name, "bare-project")
    }

    func testProjectLocationOfAnOutsideWorktreeOfABareContainerResolvesToTheDefaultCheckout() throws {
        let container = try makeBareContainer(named: "bare-project")
        let stray = tempDir.appendingPathComponent("stray-worktree")
        git(["worktree", "add", "-q", "-b", "stray", stray.path, "main"], in: container)

        let location = Git.Operations.projectLocation(for: stray.path)
        XCTAssertEqual(
            standardized(location.directory),
            container.appendingPathComponent("main").standardizedFileURL.path
        )
        XCTAssertEqual(location.name, "bare-project")
    }

    func testProjectLocationFindsTheCheckoutWhenWtDefaultIsUnset() throws {
        // A container built by hand, without the wt.default marker.
        let container = try makeBareContainer(named: "bare-project")
        git(["config", "--unset", "wt.default"], in: container)

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(
            standardized(location.directory),
            container.appendingPathComponent("main").standardizedFileURL.path
        )
    }

    func testProjectLocationPrefersTheDefaultBranchCheckoutOverASiblingWorkstream() throws {
        // Workstream worktrees are created beside the repository, so a container
        // holds the default checkout *and* workstreams as peers. Picking the
        // first one would register a workstream as the project.
        let container = try makeBareContainer(named: "bare-project")
        git(["config", "--unset", "wt.default"], in: container)
        // Sorts ahead of "main", so this is the entry a naive scan would take.
        git(["worktree", "add", "-q", "-b", "aaa-feature", container.appendingPathComponent("aaa-feature").path, "main"], in: container)

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(
            standardized(location.directory),
            container.appendingPathComponent("main").standardizedFileURL.path,
            "the project is the default branch's checkout, not whichever worktree git lists first"
        )
    }

    func testProjectLocationCarriesTheContainerSoStaleProjectsCanBeMatched() throws {
        let container = try makeBareContainer(named: "bare-project")

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(standardized(location.containerDirectory ?? ""), container.standardizedFileURL.path)

        // A plain repo resolved to itself has no container to report.
        let repoDir = tempDir.appendingPathComponent("plain-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repoDir)
        XCTAssertNil(Git.Operations.projectLocation(for: repoDir.path).containerDirectory)
    }

    func testProjectLocationPrefersTheCheckedOutDefaultOverADevelopmentBranch() throws {
        // defaultBranch prefers `development` for branching new work, which is a
        // different question from which checkout represents the project. A repo
        // that has a development branch but is checked out on main must still
        // resolve to main rather than falling through to an arbitrary worktree.
        let container = try makeBareContainer(named: "bare-project")
        git(["config", "--unset", "wt.default"], in: container)
        git(["branch", "development", "main"], in: container)
        git(["worktree", "add", "-q", "-b", "aaa-feature", container.appendingPathComponent("aaa-feature").path, "main"], in: container)

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(
            standardized(location.directory),
            container.appendingPathComponent("main").standardizedFileURL.path
        )
    }

    func testProjectLocationIgnoresWorktreesOutsideTheContainer() throws {
        // Atelier's own workstream worktrees live under ~/.atelier/worktrees and
        // must never be mistaken for the project's checkout.
        let container = try makeBareContainer(named: "bare-project")
        git(["config", "--unset", "wt.default"], in: container)
        let outside = tempDir.appendingPathComponent("elsewhere")
        git(["worktree", "add", "-q", "-b", "feature", outside.path, "main"], in: container)

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(
            standardized(location.directory),
            container.appendingPathComponent("main").standardizedFileURL.path
        )
    }

    func testProjectLocationFallsBackToTheContainerWhenNoCheckoutExists() throws {
        // A bare container whose default checkout was deleted has nothing better
        // to offer than itself.
        let container = try makeBareContainer(named: "bare-project")
        git(["worktree", "remove", "--force", "main"], in: container)

        let location = Git.Operations.projectLocation(for: container.path)
        XCTAssertEqual(standardized(location.directory), container.standardizedFileURL.path)
        XCTAssertEqual(location.name, "bare-project")
    }

    // MARK: - addExcludeEntry

    func testAddExcludeEntryWritesToAPlainRepo() throws {
        let repoDir = tempDir.appendingPathComponent("exclude-plain")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repoDir)

        Git.Operations.addExcludeEntry(at: repoDir.path, pattern: ".atelier-state/")

        XCTAssertTrue(excludeLines(of: repoDir).contains(".atelier-state/"))
    }

    func testAddExcludeEntryReachesTheRealFileFromACheckoutInABareContainer() throws {
        // `.git` is a file here, so the old hardcoded .git/info/exclude path
        // pointed at nothing and the write was silently dropped.
        let container = try makeBareContainer(named: "bare-project")
        let checkout = container.appendingPathComponent("main")

        Git.Operations.addExcludeEntry(at: checkout.path, pattern: ".atelier-state/")

        XCTAssertTrue(
            excludeLines(of: checkout).contains(".atelier-state/"),
            "the exclude entry must reach the file git actually reads"
        )
    }

    func testAddExcludeEntryDoesNotDuplicateAnExistingPattern() throws {
        let container = try makeBareContainer(named: "bare-project")
        let checkout = container.appendingPathComponent("main")

        Git.Operations.addExcludeEntry(at: checkout.path, pattern: ".atelier-state/")
        Git.Operations.addExcludeEntry(at: checkout.path, pattern: ".atelier-state/")

        XCTAssertEqual(excludeLines(of: checkout).count(where: { $0 == ".atelier-state/" }), 1)
    }

    /// The contents of whichever info/exclude git resolves for `dir`.
    private func excludeLines(of dir: URL) -> [String] {
        let path = gitOutput(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], in: dir)
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return contents.components(separatedBy: .newlines)
    }

    // MARK: - listWorktreesWithInfo

    func testListWorktreesSkipsTheBareRepositoryEntry() throws {
        let container = try makeBareContainer(named: "bare-project")
        let checkout = container.appendingPathComponent("main")

        let worktrees = Git.Operations.listWorktreesWithInfo(at: checkout.path)

        XCTAssertFalse(
            worktrees.contains { $0.standardizedPath == container.appendingPathComponent(".bare").standardizedFileURL.path },
            "the bare repository is not a worktree and must not be listed as one"
        )
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees.first?.branch, "main")
        XCTAssertEqual(worktrees.first?.isMain, true)
    }

    // MARK: - removeWorktree

    /// `removeWorktree` deletes whatever path it is handed, whether or not git
    /// agreed to remove it. Handing it the project directory — which
    /// `Workstream.Archiver.purge` did for any workstream with no worktree path —
    /// therefore erased the user's checkout.
    func testRemoveWorktreeRefusesToDeleteTheMainRepository() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q"], in: repoDir)
        let file = repoDir.appendingPathComponent("keep-me.txt")
        try "important".write(to: file, atomically: true, encoding: .utf8)

        Git.Operations.removeWorktree(projectPath: repoDir.path, worktreePath: repoDir.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repoDir.path), "the main checkout must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "its contents must survive")
    }

    /// The same guard has to hold when the two paths differ only by a trailing
    /// slash or a `.` segment, since callers pass unstandardized user paths.
    func testRemoveWorktreeRefusesTheMainRepositoryUnderAnUnstandardizedPath() throws {
        let repoDir = tempDir.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q"], in: repoDir)

        Git.Operations.removeWorktree(projectPath: repoDir.path, worktreePath: repoDir.path + "/./")

        XCTAssertTrue(FileManager.default.fileExists(atPath: repoDir.path))
    }

    /// Comparing the two spellings textually is not enough. A stored worktree path
    /// and a picked project directory can reach the same place through different
    /// symlinks — on macOS `/tmp` and `/var` are themselves symlinks — and
    /// `removeItem` follows a symlinked *parent* straight to the real directory.
    func testRemoveWorktreeRefusesTheMainRepositoryReachedThroughASymlinkedParent() throws {
        let realParent = tempDir.appendingPathComponent("real")
        let repoDir = realParent.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        git(["init", "-q"], in: repoDir)
        let linkedParent = tempDir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)

        Git.Operations.removeWorktree(
            projectPath: repoDir.path,
            worktreePath: linkedParent.appendingPathComponent("main-repo").path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: repoDir.path), "the main checkout must survive")
    }

    /// The guard must not cost the feature: a real linked worktree still goes.
    func testRemoveWorktreeRemovesALinkedWorktree() throws {
        let container = try makeBareContainer(named: "bare-project")
        let checkout = container.appendingPathComponent("main")
        git(["worktree", "add", "-q", "feature", "-b", "feature"], in: checkout)
        let feature = checkout.appendingPathComponent("feature")
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path), "precondition")

        Git.Operations.removeWorktree(projectPath: checkout.path, worktreePath: feature.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
    }

    /// `purgeOrphanWorktree` depends on the filesystem fallback: git has already
    /// forgotten the worktree, so `git worktree remove` fails and the directory
    /// is only cleaned up because `removeWorktree` deletes it anyway.
    func testRemoveWorktreeStillDeletesADirectoryGitHasForgotten() throws {
        let container = try makeBareContainer(named: "bare-project")
        let checkout = container.appendingPathComponent("main")
        let orphan = checkout.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        Git.Operations.removeWorktree(projectPath: checkout.path, worktreePath: orphan.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: - updateDefaultBranch

    /// `update-ref` moved the local branch onto origin's tip unconditionally, so
    /// commits that had not been pushed became unreachable with no warning.
    func testUpdateDefaultBranchKeepsCommitsOriginDoesNotHave() throws {
        let (origin, clone) = try makeOriginAndClone()

        try "local work".write(to: clone.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: clone)
        git(["commit", "-q", "-m", "unpushed"], in: clone)
        let localHead = gitOutput(["rev-parse", "refs/heads/main"], in: clone)
        XCTAssertNotEqual(localHead, gitOutput(["rev-parse", "refs/heads/main"], in: origin), "precondition")

        Git.Operations.updateDefaultBranch(at: clone.path)

        XCTAssertEqual(
            gitOutput(["rev-parse", "refs/heads/main"], in: clone),
            localHead,
            "the branch must not be moved off commits origin does not have"
        )
    }

    /// The fast-forward case is the whole point of the function and must survive
    /// the guard.
    func testUpdateDefaultBranchFastForwardsWhenTheLocalBranchIsBehind() throws {
        let (origin, clone) = try makeOriginAndClone()

        try "more".write(to: origin.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: origin)
        git(["commit", "-q", "-m", "second"], in: origin)
        let originHead = gitOutput(["rev-parse", "refs/heads/main"], in: origin)

        Git.Operations.updateDefaultBranch(at: clone.path)

        XCTAssertEqual(gitOutput(["rev-parse", "refs/heads/main"], in: clone), originHead)
    }

    // MARK: - Helpers

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// A non-bare "origin" repository on `main` plus a clone of it, so the
    /// fetch/update path in `updateDefaultBranch` has something real to talk to.
    private func makeOriginAndClone() throws -> (origin: URL, clone: URL) {
        let origin = tempDir.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: origin)
        git(["config", "user.email", "test@example.com"], in: origin)
        git(["config", "user.name", "Test"], in: origin)
        try "one".write(to: origin.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: origin)
        git(["commit", "-q", "-m", "first"], in: origin)

        let clone = tempDir.appendingPathComponent("clone")
        git(["clone", "-q", origin.path, clone.path], in: tempDir)
        git(["config", "user.email", "test@example.com"], in: clone)
        git(["config", "user.name", "Test"], in: clone)
        return (origin, clone)
    }

    /// Builds the README's layout: `<container>/{.bare, .git, main}` with HEAD
    /// parked on `root` and `wt.default` set.
    private func makeBareContainer(named name: String) throws -> URL {
        let origin = tempDir.appendingPathComponent("\(name)-origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: origin)
        git(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init"], in: origin)

        let container = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        git(["clone", "--bare", "-q", origin.path, ".bare"], in: container)
        try "gitdir: ./.bare\n".write(to: container.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: container)
        git(["fetch", "--all", "--prune", "-q"], in: container)
        git(["config", "wt.default", "main"], in: container)
        git(["branch", "root", "main"], in: container)
        git(["symbolic-ref", "HEAD", "refs/heads/root"], in: container)
        git(["worktree", "add", "-q", "main"], in: container)
        return container
    }

    /// Every git-backed test in this file goes through here, so a discarded launch
    /// error was the difference between a real suite and a green one. `try?` swallowed
    /// it, and a `Process` that never launched reports `terminationStatus == 0` — so a
    /// missing or unlaunchable git made this return success, and every assertion
    /// downstream then held against an empty filesystem. Fail loudly instead.
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

    /// Same contract as `git(_:in:)`: an unlaunchable git is a test failure, not an
    /// empty string that reads like a successful command with no output.
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
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Porcelain rename parsing

    /// `worktreeDetail` used to keep the whole `old -> new` field as the path, so the
    /// worktree detail sheet listed a renamed file as the literal string
    /// "old.swift -> new.swift" while `fileStatuses` — parsing the same output —
    /// recorded just "new.swift".
    func testRenamedDestinationTakesTheNewPath() {
        XCTAssertEqual(Git.Operations.renamedDestination(in: "old.swift -> new.swift"), "new.swift")
    }

    func testRenamedDestinationLeavesABarePathAlone() {
        XCTAssertEqual(Git.Operations.renamedDestination(in: "Sources/App.swift"), "Sources/App.swift")
    }

    func testRenamedDestinationHandlesQuotedPathsWithSpaces() {
        XCTAssertEqual(
            Git.Operations.renamedDestination(in: "\"old name.swift\" -> \"new name.swift\""),
            "\"new name.swift\""
        )
    }

    /// Git writes the separator once, so the first arrow is the separator. A path
    /// odd enough to contain " -> " itself is quoted by git, which keeps it on one side.
    func testRenamedDestinationSplitsOnTheFirstArrow() {
        XCTAssertEqual(Git.Operations.renamedDestination(in: "a.swift -> b -> c.swift"), "b -> c.swift")
    }
}
