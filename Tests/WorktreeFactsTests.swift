// ABOUTME: Tests for Worktree.Facts — the fold that lays a sweep over what is already known.
// ABOUTME: Pins the carry-forward rules, the unknown-path answer, and the equality that gates publishing.

@testable import Atelier
import XCTest

final class WorktreeFactsFoldTests: XCTestCase {
    // MARK: - The fold

    /// The first sweep of a path it has never seen: everything it looked at lands.
    func testFirstSweepFillsEveryFieldItLookedAt() {
        let swept = Worktree.Facts.Swept(
            isPathValid: true,
            branch: "feat-thing",
            cleanliness: .dirty,
            taskDescription: "Make the thing",
            hasActivePort: true,
            state: Worktree.State(hasUncommittedChanges: true, hasRemote: true)
        )

        let facts = Worktree.Facts.applying(swept, to: nil)

        XCTAssertTrue(facts.isPathValid)
        XCTAssertEqual(facts.branch, "feat-thing")
        XCTAssertEqual(facts.cleanliness, .dirty)
        XCTAssertEqual(facts.taskDescription, "Make the thing")
        XCTAssertTrue(facts.hasActivePort)
        XCTAssertTrue(facts.state.hasUncommittedChanges)
        XCTAssertNil(facts.shortcutStoryID, "the sweep cannot learn a story id and must not invent one")
    }

    /// The reason this is a fold and not an assignment.
    ///
    /// `shortcutStoryID` is written by `ContentView.syncShortcutStoryIDs`, from
    /// the project list — the sweep never sees it. Assigning a freshly built
    /// value would have dropped every workstream's Shortcut story on the next
    /// fifteen-second tick.
    func testCarriesForwardTheOneFieldNoSweepCanLearn() {
        var existing = Worktree.Facts()
        existing.shortcutStoryID = 4711

        let facts = Worktree.Facts.applying(
            Worktree.Facts.Swept(isPathValid: true, branch: "main"),
            to: existing
        )

        XCTAssertEqual(facts.shortcutStoryID, 4711, "the sweep overwrote a fact it knows nothing about")
    }

    /// A sweep that learned only a branch leaves everything else standing.
    ///
    /// Each optional in `Swept` means "the probe did not run", not "the answer is
    /// nothing" — which is what `branchNameCache.merge(...)` meant before the
    /// caches were folded together.
    func testABranchOnlyUpdateLeavesTheOtherFieldsIntact() {
        let existing = Worktree.Facts(
            isPathValid: true,
            branch: "old-branch",
            cleanliness: .clean,
            taskDescription: "Still the same task",
            hasActivePort: true,
            shortcutStoryID: 99,
            state: Worktree.State(hasUnpushedCommits: true, hasRemote: true)
        )

        let facts = Worktree.Facts.applying(
            Worktree.Facts.Swept(
                isPathValid: true,
                branch: "renamed-branch",
                taskDescription: "Still the same task",
                hasActivePort: true
            ),
            to: existing
        )

        XCTAssertEqual(facts.branch, "renamed-branch")
        XCTAssertEqual(facts.cleanliness, .clean, "a probe that did not run cleared a real answer")
        XCTAssertEqual(facts.state, existing.state, "a probe that did not run cleared a real answer")
        XCTAssertEqual(facts.shortcutStoryID, 99)
        XCTAssertEqual(facts.taskDescription, "Still the same task")
    }

    /// `.unknown` is a real answer — git ran and could not tell — and must not be
    /// confused with "did not look", which is what the optional means. Preserving
    /// that distinction is the whole reason `cleanliness` is not a `Bool`:
    /// `Git.RepoInfo.isDirtyUnknown` exists so a `false` from a `git status` that
    /// never ran is not rendered as a green "Clean".
    func testAProbeThatCouldNotTellOverwritesAKnownAnswer() {
        var existing = Worktree.Facts()
        existing.cleanliness = .clean

        let facts = Worktree.Facts.applying(
            Worktree.Facts.Swept(isPathValid: true, cleanliness: .unknown),
            to: existing
        )

        XCTAssertEqual(facts.cleanliness, .unknown)
    }

    /// A description file that has been deleted stops being reported. This is the
    /// one field the old caches replaced wholesale rather than merging, so the
    /// nil here has to *clear* rather than carry forward.
    func testADeletedDescriptionIsCleared() {
        var existing = Worktree.Facts()
        existing.taskDescription = "Gone now"

        let facts = Worktree.Facts.applying(
            Worktree.Facts.Swept(isPathValid: true),
            to: existing
        )

        XCTAssertNil(facts.taskDescription)
        XCTAssertFalse(facts.hasActivePort)
    }

    /// The map fold keeps entries the sweep did not visit.
    ///
    /// A sweep carries the project snapshot it started with, so a workstream
    /// created while it was in flight is not in it. Pruning here would delete
    /// facts `refreshBranchName` had just written for a worktree on screen.
    func testTheMapFoldLeavesUnvisitedPathsAlone() {
        let existing: [String: Worktree.Facts] = [
            "/a": Worktree.Facts(branch: "a-branch"),
            "/just-created": Worktree.Facts(branch: "brand-new"),
        ]

        let updated = Worktree.Facts.applying(
            ["/a": Worktree.Facts.Swept(isPathValid: true, branch: "a-branch-moved")],
            to: existing
        )

        XCTAssertEqual(updated["/a"]?.branch, "a-branch-moved")
        XCTAssertEqual(updated["/just-created"]?.branch, "brand-new", "the sweep pruned a path it had never seen")
    }

    // MARK: - Equality

    /// The guard that stops the fifteen-second sweep redrawing the whole app.
    ///
    /// `AppEnvironment.commitChanges` sends `objectWillChange` as its first act,
    /// so the comparison has to happen before it is called — and it can only
    /// happen at all because `Facts` and `Worktree.State` are `Equatable`.
    func testASweepThatLearnedNothingNewComparesEqual() {
        let existing: [String: Worktree.Facts] = [
            "/a": Worktree.Facts(
                isPathValid: true,
                branch: "main",
                cleanliness: .clean,
                taskDescription: "Task",
                shortcutStoryID: 7,
                state: Worktree.State(hasRemote: true)
            ),
        ]

        let updated = Worktree.Facts.applying(
            [
                "/a": Worktree.Facts.Swept(
                    isPathValid: true,
                    branch: "main",
                    cleanliness: .clean,
                    taskDescription: "Task",
                    state: Worktree.State(hasRemote: true)
                ),
            ],
            to: existing
        )

        XCTAssertEqual(updated, existing, "an unchanged world produced a different value, so every row would redraw")
    }

    /// And one that did learn something is not equal — the other half, so the
    /// guard cannot be satisfied by a type that compares everything equal.
    func testASweepThatLearnedSomethingComparesUnequal() {
        let existing: [String: Worktree.Facts] = ["/a": Worktree.Facts(branch: "main")]

        let updated = Worktree.Facts.applying(
            ["/a": Worktree.Facts.Swept(isPathValid: true, branch: "main", cleanliness: .dirty)],
            to: existing
        )

        XCTAssertNotEqual(updated, existing)
    }

    // MARK: - Cleanliness

    /// `Git.RepoInfo` reports "could not tell" as `isDirty: false` plus a flag, so
    /// the flag has to win — reading the `false` on its own is exactly the
    /// collapse the flag exists to prevent.
    func testUnknownWinsOverTheFalseItShipsWith() {
        XCTAssertEqual(Worktree.Cleanliness(isDirty: false, isDirtyUnknown: true), .unknown)
        XCTAssertEqual(Worktree.Cleanliness(isDirty: false, isDirtyUnknown: false), .clean)
        XCTAssertEqual(Worktree.Cleanliness(isDirty: true, isDirtyUnknown: false), .dirty)
    }
}

@MainActor
final class AppEnvironmentFactsTests: XCTestCase {
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

    /// Nothing has swept this path, so there is nothing to say about it.
    func testFactsAreNilForAnUnknownPath() {
        let env = AppEnvironment()
        XCTAssertNil(env.facts(for: "/nowhere/at/all"))
        XCTAssertNil(env.facts(for: nil))
    }

    /// The accessors are wrappers, and their defaults are the reason they were
    /// kept: an unswept worktree is *valid* until something looks, not invalid —
    /// a nil read rendered as invalid would strike through every row at launch.
    func testTheAccessorDefaultsSurviveAMissingEntry() {
        let env = AppEnvironment()
        XCTAssertTrue(env.isPathValid("/nowhere/at/all"))
        XCTAssertNil(env.branchName(for: "/nowhere/at/all"))
        XCTAssertFalse(env.hasActivePort(for: "/nowhere/at/all"))
        XCTAssertNil(env.taskDescription(for: "/nowhere/at/all"))
        XCTAssertEqual(env.worktreeState(for: "/nowhere/at/all"), Worktree.State())
    }

    /// `refreshBranchName` runs off `Worktree.HeadWatcher`'s debounced callback,
    /// which fires on *any* git activity in the worktree. It has to stay a
    /// single-field update: a story id registered from the project list, and
    /// anything the sweep has established, must still be there afterwards.
    func testABranchRefreshLeavesTheRestOfTheFactsStanding() async throws {
        let repo = try makeRepo(branch: "first-branch")
        let env = AppEnvironment()

        env.registerShortcutStory(id: 123, for: repo.path)
        await env.refreshBranchName(for: repo.path)
        XCTAssertEqual(env.branchName(for: repo.path), "first-branch")
        XCTAssertEqual(env.facts(for: repo.path)?.shortcutStoryID, 123)

        XCTAssertTrue(git(["checkout", "-b", "second-branch"], in: repo))
        await env.refreshBranchName(for: repo.path)

        XCTAssertEqual(env.branchName(for: repo.path), "second-branch")
        XCTAssertEqual(
            env.facts(for: repo.path)?.shortcutStoryID,
            123,
            "a branch rename dropped the workstream's Shortcut story"
        )
    }

    /// The Info tab's own probe. It fills the branch and the cleanliness
    /// together, because the tab needs both on appearance and the sweep that
    /// otherwise supplies cleanliness is on a fifteen-second timer.
    func testTheWiderProbeFillsBranchAndCleanlinessTogether() async throws {
        let repo = try makeRepo(branch: "main")
        let env = AppEnvironment()

        await env.refreshGitFacts(for: repo.path)
        XCTAssertEqual(env.facts(for: repo.path)?.branch, "main")
        XCTAssertEqual(env.facts(for: repo.path)?.cleanliness, .clean)

        try "untracked".write(
            to: repo.appendingPathComponent("scratch.txt"),
            atomically: true,
            encoding: .utf8
        )
        await env.refreshGitFacts(for: repo.path)

        XCTAssertEqual(env.facts(for: repo.path)?.cleanliness, .dirty)
    }

    // MARK: - Helpers

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
