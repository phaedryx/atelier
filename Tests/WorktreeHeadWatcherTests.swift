// ABOUTME: Tests for resolving a worktree's git directory and watching its HEAD for changes.
// ABOUTME: Covers the .git-file parser, debounced firing, and reconciling the watched path set.

@testable import Atelier
import XCTest

final class WorktreeGitDirectoryTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// A normal clone: `.git` is a directory and holds HEAD itself.
    func testResolvesPlainRepositoryGitDirectory() throws {
        let gitDir = tmpDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        XCTAssertEqual(Worktree.HeadWatcher.gitDirectory(forWorktreeAt: tmpDir.path), gitDir.path)
    }

    /// A linked worktree: `.git` is a file pointing at the real git dir, which
    /// is where HEAD lives. Watching `<worktree>/.git` would watch the pointer,
    /// which never changes on `git branch -m`.
    func testResolvesLinkedWorktreeGitDirectoryFromAbsolutePointer() throws {
        let realGitDir = tmpDir.appendingPathComponent("bare/worktrees/feature")
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        let worktree = tmpDir.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(realGitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(Worktree.HeadWatcher.gitDirectory(forWorktreeAt: worktree.path), realGitDir.path)
    }

    func testResolvesRelativePointerAgainstTheWorktree() throws {
        let worktree = tmpDir.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let realGitDir = tmpDir.appendingPathComponent("bare/worktrees/feature")
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        try "gitdir: ../bare/worktrees/feature\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        let resolved = Worktree.HeadWatcher.gitDirectory(forWorktreeAt: worktree.path)
        XCTAssertEqual(resolved.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, realGitDir.standardizedFileURL.path)
    }

    func testReturnsNilWhenThereIsNoGitEntry() {
        XCTAssertNil(Worktree.HeadWatcher.gitDirectory(forWorktreeAt: tmpDir.path))
    }

    func testReturnsNilForAGitFileWithoutAGitdirLine() throws {
        let worktree = tmpDir.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "not a pointer\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        XCTAssertNil(Worktree.HeadWatcher.gitDirectory(forWorktreeAt: worktree.path))
    }
}

final class WorktreeHeadWatcherTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// Builds a worktree whose `.git` is a directory, so the watcher has a real
    /// directory to attach to, and returns the worktree path plus its HEAD file.
    private func makeWorktree(_ name: String) throws -> (worktree: String, head: URL) {
        let worktree = tmpDir.appendingPathComponent(name)
        let gitDir = worktree.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let head = gitDir.appendingPathComponent("HEAD")
        try "ref: refs/heads/main\n".write(to: head, atomically: true, encoding: .utf8)
        return (worktree.path, head)
    }

    /// Rewrites HEAD the way git does: write a lockfile, then rename it over
    /// HEAD. The rename replaces the inode, which is why the watcher must watch
    /// the directory rather than the HEAD file itself.
    private func renameBranch(head: URL, to ref: String) throws {
        let lock = head.appendingPathExtension("lock")
        try "ref: refs/heads/\(ref)\n".write(to: lock, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(head, withItemAt: lock)
    }

    /// Collects callback paths across threads: the watcher's callback is
    /// `@Sendable` and runs on its own queue, so a captured `var` will not do.
    private final class ReportedPaths: @unchecked Sendable {
        private var paths: [String] = []
        private let lock = NSLock()

        func append(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        var first: String? {
            lock.lock()
            defer { lock.unlock() }
            return paths.first
        }
    }

    func testFiresForAWatchedWorktreeWhenHeadIsReplaced() throws {
        let (worktree, head) = try makeWorktree("alpha")
        let fired = expectation(description: "watcher reported a HEAD change")
        // replaceItemAt performs several directory operations; a second one can
        // straddle the debounce window and fulfill again after the wait returns.
        fired.assertForOverFulfill = false
        let reported = ReportedPaths()

        let watcher = Worktree.HeadWatcher(debounce: .milliseconds(50)) { path in
            reported.append(path)
            fired.fulfill()
        }
        watcher.sync(paths: [worktree])
        // The watch attaches asynchronously on the watcher's queue.
        Thread.sleep(forTimeInterval: 0.2)

        try renameBranch(head: head, to: "renamed")

        wait(for: [fired], timeout: 5)
        XCTAssertEqual(reported.first, worktree)
        watcher.sync(paths: [])
    }

    func testDoesNotFireForAPathRemovedFromTheWatchedSet() throws {
        let (worktree, head) = try makeWorktree("beta")
        let stayedQuiet = expectation(description: "no callback after unwatch")
        stayedQuiet.isInverted = true

        let watcher = Worktree.HeadWatcher(debounce: .milliseconds(50)) { _ in
            stayedQuiet.fulfill()
        }
        watcher.sync(paths: [worktree])
        Thread.sleep(forTimeInterval: 0.2)
        watcher.sync(paths: [])
        Thread.sleep(forTimeInterval: 0.1)

        try renameBranch(head: head, to: "renamed")

        wait(for: [stayedQuiet], timeout: 1)
    }

    /// A burst of writes must collapse into a single callback — that git dir is
    /// noisy (index rewrites on ordinary git activity), so an un-debounced
    /// watcher would spawn a git subprocess per event.
    func testCollapsesABurstOfWritesIntoOneCallback() throws {
        let (worktree, head) = try makeWorktree("gamma")
        let fired = expectation(description: "watcher reported once")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true

        let watcher = Worktree.HeadWatcher(debounce: .milliseconds(300)) { _ in
            fired.fulfill()
        }
        watcher.sync(paths: [worktree])
        Thread.sleep(forTimeInterval: 0.2)

        for i in 0 ..< 5 {
            try renameBranch(head: head, to: "burst-\(i)")
            Thread.sleep(forTimeInterval: 0.02)
        }

        wait(for: [fired], timeout: 5)
        watcher.sync(paths: [])
    }

    func testIgnoresPathsThatAreNotWorktrees() {
        let watcher = Worktree.HeadWatcher(debounce: .milliseconds(50)) { _ in
            XCTFail("should not watch a directory with no .git")
        }
        watcher.sync(paths: [tmpDir.appendingPathComponent("nope").path])
        XCTAssertTrue(watcher.watchedPathsForTesting.isEmpty)
        watcher.sync(paths: [])
    }

    func testSyncIsIdempotentAndDropsStalePaths() throws {
        let (alpha, _) = try makeWorktree("alpha2")
        let (beta, _) = try makeWorktree("beta2")

        let watcher = Worktree.HeadWatcher(debounce: .milliseconds(50)) { _ in }
        watcher.sync(paths: [alpha, beta])
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(watcher.watchedPathsForTesting, Set([alpha, beta]))

        watcher.sync(paths: [alpha, beta])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(watcher.watchedPathsForTesting, Set([alpha, beta]))

        watcher.sync(paths: [alpha])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(watcher.watchedPathsForTesting, Set([alpha]))

        watcher.sync(paths: [])
    }
}
