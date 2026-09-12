// ABOUTME: Tests for AppEnvironment's per-directory default-branch cache.
// ABOUTME: Pins that it caches a real answer and refuses to cache the "HEAD" sentinel.

@testable import Atelier
import XCTest

@MainActor
final class AppEnvironmentDefaultBranchTests: XCTestCase {
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

    /// The reason the cache exists: `Git.Operations.defaultBranch` costs up to six
    /// sequential git probes, and `TerminalContainerView` asks for it once per
    /// visit to *every* workstream of a project — for an answer that belongs to
    /// the project.
    ///
    /// Deleting the repository between the two calls is what makes this a test of
    /// the cache rather than of git: an uncached second call has no directory to
    /// run in, so it would fall all the way through to the `"HEAD"` sentinel.
    func testCachesTheAnswerPerDirectory() async throws {
        let repo = try makeRepo(branch: "main")
        let env = AppEnvironment()

        let first = await env.defaultBranch(for: repo.path)
        XCTAssertEqual(first, "main")

        try FileManager.default.removeItem(at: repo)
        let second = await env.defaultBranch(for: repo.path)
        XCTAssertEqual(second, "main", "the second call re-ran git instead of reading the cache")
    }

    /// `"HEAD"` is what `defaultBranch` returns when it resolves nothing, which for
    /// a freshly added project usually means `origin/HEAD` has not been fetched
    /// yet rather than that the repository has no default branch — and
    /// `AppEnvironment.fetchOrigin` is running concurrently to fix exactly that.
    /// Caching the sentinel would pin the wrong answer for the rest of the session.
    func testDoesNotCacheTheUnresolvedSentinel() async throws {
        let repo = try makeRepo(branch: "feature-only")
        let env = AppEnvironment()

        let unresolved = await env.defaultBranch(for: repo.path)
        XCTAssertEqual(unresolved, "HEAD", "a repo with no conventional branch and no remote should resolve nothing")

        XCTAssertTrue(git(["branch", "main"], in: repo))
        let resolved = await env.defaultBranch(for: repo.path)
        XCTAssertEqual(resolved, "main", "the sentinel was cached, so the real answer could never be seen")
    }

    /// Two directories are two answers. A cache keyed on anything coarser would
    /// hand one project's default branch to another.
    func testKeepsDirectoriesApart() async throws {
        let mainRepo = try makeRepo(branch: "main")
        let masterRepo = try makeRepo(branch: "master")
        let env = AppEnvironment()

        let first = await env.defaultBranch(for: mainRepo.path)
        let second = await env.defaultBranch(for: masterRepo.path)

        XCTAssertEqual(first, "main")
        XCTAssertEqual(second, "master")
    }

    // MARK: - Helpers

    /// A repository whose only branch is `branch`, with no remote — so
    /// `defaultBranch` resolves it only if `branch` is one of the names it looks
    /// for, and returns the sentinel otherwise.
    private func makeRepo(branch: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let repo = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", branch], in: repo), "git init failed", file: file, line: line)
        XCTAssertTrue(
            git(
                ["-c", "user.email=test@test.com", "-c", "user.name=Test",
                 "commit", "--allow-empty", "-m", "init"],
                in: repo
            ),
            "git commit failed", file: file, line: line
        )
        return repo
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
}
