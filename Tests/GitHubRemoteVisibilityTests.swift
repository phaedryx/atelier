// ABOUTME: Tests that a project's GitHub remote is visible to the sidebar without `gh`.
// ABOUTME: The GitHub button and the "Open on GitHub" item both read caches filled by the sweep.

@testable import Atelier
import XCTest

/// The sidebar's GitHub button was invisible for every `.bare` container project, and the
/// row's "Open on GitHub" item missing with it, because both asked `AppEnvironment.githubURL`
/// — whose only populated source was `refreshGitHubInfo`, called from the project overview and
/// the workstream info tab and nowhere the sidebar draws. A container makes it unconditional:
/// the other fallback is keyed by the project's *checkout*, so a lookup by `directory` cannot
/// hit it however many views have appeared.
@MainActor
final class GitHubRemoteVisibilityTests: XCTestCase {
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

    // MARK: - githubRemoteURL

    func testRemoteURLReadsTheOriginOfAContainer() throws {
        let container = try makeContainerProject(remote: "git@github.com:acme/widgets.git")

        XCTAssertEqual(
            GitHub.Operations.githubRemoteURL(at: container.path),
            "git@github.com:acme/widgets.git"
        )
    }

    /// A repository hosted elsewhere must not offer a GitHub branch dialog: the flow's
    /// pre-flight resolves `origin/<branch>`, but every string it shows the user says GitHub.
    func testRemoteURLIsNilForANonGitHubRemote() throws {
        let container = try makeContainerProject(remote: "git@gitlab.com:acme/widgets.git")

        XCTAssertNil(GitHub.Operations.githubRemoteURL(at: container.path))
    }

    func testRemoteURLIsNilWhenThereIsNoOrigin() throws {
        let container = try makeContainerProject(remote: nil)

        XCTAssertNil(GitHub.Operations.githubRemoteURL(at: container.path))
    }

    // MARK: - The button's gate

    /// Near-tautological on its own; it is here to name the input in a place a reader edits.
    /// The bug was the gate reading `githubURL`, a cache no sidebar code fills — spelled
    /// inline in a view body, where nothing could pin it.
    func testBranchButtonNeedsARepoAndAGitHubRemote() {
        XCTAssertTrue(GitHub.Operations.shouldShowBranchButton(isGitRepo: true, hasGitHubRemote: true))
        XCTAssertFalse(GitHub.Operations.shouldShowBranchButton(isGitRepo: false, hasGitHubRemote: true))
        XCTAssertFalse(GitHub.Operations.shouldShowBranchButton(isGitRepo: true, hasGitHubRemote: false))
    }

    // MARK: - The sweep

    /// The regression: the sidebar reads these two the moment a project exists, and nothing
    /// it draws calls `gh` or `refreshGitHubInfo`. Both have to be answerable from the sweep
    /// alone, keyed by the repository's home rather than its checkout.
    func testSweepAnswersBothGitHubQuestionsForAContainerProject() async throws {
        let container = try makeContainerProject(remote: "git@github.com:acme/widgets.git")
        let project = Project(
            name: "widgets",
            directory: container.path,
            checkoutDirectory: container.appendingPathComponent("main").path
        )
        let env = AppEnvironment()

        env.refreshPathValidity(projects: [project])
        try await waitUntil { env.hasGitHubRemote(project.directory) }

        XCTAssertEqual(
            env.githubURL(for: project.directory),
            URL(string: "https://github.com/acme/widgets"),
            "the button and the context menu both read this, with no gh and no other view"
        )
    }

    func testSweepReportsNoGitHubURLForARemoteElsewhere() async throws {
        let container = try makeContainerProject(remote: "git@gitlab.com:acme/widgets.git")
        let project = Project(
            name: "widgets",
            directory: container.path,
            checkoutDirectory: container.appendingPathComponent("main").path
        )
        let env = AppEnvironment()

        env.refreshPathValidity(projects: [project])
        // The sweep publishes `isGitRepo` in the same batch as the GitHub answers, so waiting
        // on it means the negative below is a result rather than a cache that is still empty.
        try await waitUntil { env.isGitRepo(project.directory) }

        XCTAssertFalse(env.hasGitHubRemote(project.directory))
        XCTAssertNil(env.githubURL(for: project.directory))
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    /// The README's container layout: a bare clone in `.bare`, the `.git` file pointing at it,
    /// and a `main` worktree standing in as the checkout — so `directory` and `checkout` are
    /// different strings, which is the whole point of the case under test.
    private func makeContainerProject(remote: String?) throws -> URL {
        let origin = tempDir.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        XCTAssertTrue(git(["init", "-b", "main"], in: origin))
        try "hello".write(to: origin.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(git(["add", "README.md"], in: origin))
        XCTAssertTrue(git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                           "commit", "-m", "initial"], in: origin))

        let container = tempDir.appendingPathComponent("widgets")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        XCTAssertTrue(git(["clone", "--bare", origin.path, ".bare"], in: container))
        try "gitdir: ./.bare\n".write(
            to: container.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(git(["worktree", "add", "main", "main"], in: container))

        if let remote {
            XCTAssertTrue(git(["remote", "set-url", "origin", remote], in: container))
        } else {
            XCTAssertTrue(git(["remote", "remove", "origin"], in: container))
        }
        return container
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
            XCTFail("git \(args.joined(separator: " ")) failed to launch: \(error)", file: file, line: line)
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
