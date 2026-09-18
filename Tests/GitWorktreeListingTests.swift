// ABOUTME: Fixture tests for Git.WorktreeListing.parse, the one parser of
// ABOUTME: `git worktree list --porcelain`. Pure: no git, no filesystem.

@testable import Atelier
import XCTest

/// `Git.WorktreeListing.parse` replaced three hand-rolled walkers of the same
/// output — `worktreePath(forBranch:)`, `listWorktreesWithInfo` and
/// `registeredWorktrees` — which between them noticed two of the porcelain's
/// fields and disagreed about the rest.
///
/// These are fixtures rather than a real repository on purpose: a bare entry,
/// a detached HEAD and a locked worktree each need a different `git worktree
/// add` dance to produce, and a path with a space in it is a case no test that
/// builds its own repository was ever going to cover. The integration side is
/// already pinned in `GitOperationsTests`, against real git.
final class GitWorktreeListingTests: XCTestCase {
    /// Everything git emits, in one listing: the `.bare` container's own row,
    /// an ordinary checkout, a branch with a slash in it, a detached worktree,
    /// a locked one, and a path containing a space.
    private let fixture = """
    worktree /repos/app/.bare
    bare

    worktree /repos/app/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repos/app/feature
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feat/nested/thing

    worktree /repos/app/spike
    HEAD 3333333333333333333333333333333333333333
    detached

    worktree /repos/app/held
    HEAD 4444444444444444444444444444444444444444
    branch refs/heads/held
    locked on a removable drive

    worktree /repos/app/my worktree
    HEAD 5555555555555555555555555555555555555555
    branch refs/heads/spaced

    """

    private func entry(_ path: String, in entries: [Git.WorktreeListing.Entry])
        -> Git.WorktreeListing.Entry?
    {
        entries.first { $0.path == path }
    }

    func testParsesEveryBlockInTheListing() {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)
        XCTAssertEqual(entries.count, 6, "a block was dropped: \(entries.map(\.path))")
    }

    /// The bare repository is a row like any other and is parsed as one. Each
    /// public function drops it for itself, so the flag has to survive the parse.
    func testTheBareEntryIsReportedAsBareWithNoBranch() throws {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)
        let bare = try XCTUnwrap(entry("/repos/app/.bare", in: entries))

        XCTAssertTrue(bare.isBare)
        XCTAssertNil(bare.branch)
        XCTAssertNil(bare.ref)
        XCTAssertNil(bare.head, "the bare entry emits no HEAD line")
    }

    /// A detached worktree has no branch to match on. It must still be listed —
    /// stranded-workstream repair leaves it alone rather than dropping it.
    func testADetachedWorktreeIsListedWithNoBranch() throws {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)
        let spike = try XCTUnwrap(entry("/repos/app/spike", in: entries))

        XCTAssertTrue(spike.isDetached)
        XCTAssertNil(spike.branch)
        XCTAssertFalse(spike.isBare)
        XCTAssertEqual(spike.head, "3333333333333333333333333333333333333333")
    }

    /// `locked` carries a reason here. It also stands alone when none was given,
    /// so neither form may be the only one the parser matches — the next case.
    func testALockedWorktreeIsReportedLockedAndKeepsItsBranch() throws {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)
        let held = try XCTUnwrap(entry("/repos/app/held", in: entries))

        XCTAssertTrue(held.isLocked)
        XCTAssertEqual(held.branch, "held")
    }

    func testALockedWorktreeWithNoReasonIsStillLocked() throws {
        let entries = Git.WorktreeListing.parse(porcelain: """
        worktree /repos/app/held
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/held
        locked
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(entries.first).isLocked)
    }

    /// The whole reason `Entry.branch` strips exactly `refs/heads/` and nothing
    /// else. A `lastPathComponent` or a split on "/" turns this into "thing".
    func testABranchWithSlashesKeepsAllOfThem() throws {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)
        let feature = try XCTUnwrap(entry("/repos/app/feature", in: entries))

        XCTAssertEqual(feature.branch, "feat/nested/thing")
        XCTAssertEqual(feature.ref, "refs/heads/feat/nested/thing",
                       "the full ref is what worktreePath(forBranch:) matches on")
    }

    /// Porcelain neither quotes nor escapes the path, so the whole remainder of
    /// the line is the path. Any tokenizing on whitespace truncates this to
    /// "/repos/app/my".
    func testAPathWithASpaceSurvivesWhole() throws {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)
        let spaced = try XCTUnwrap(entry("/repos/app/my worktree", in: entries))

        XCTAssertEqual(spaced.branch, "spaced")
    }

    /// A ref outside `refs/heads/` is not a local branch, which is what the
    /// walkers this replaced expressed by only ever matching that literal
    /// prefix. The full ref is still reported, so nothing is lost.
    func testARefOutsideRefsHeadsIsNotABranch() throws {
        let entries = Git.WorktreeListing.parse(porcelain: """
        worktree /repos/app/odd
        HEAD 6666666666666666666666666666666666666666
        branch refs/remotes/origin/main
        """)
        let odd = try XCTUnwrap(entries.first)

        XCTAssertNil(odd.branch)
        XCTAssertEqual(odd.ref, "refs/remotes/origin/main")
    }

    /// The last block usually has no blank line after it, so the parser may not
    /// rely on one to close an entry.
    func testTheFinalBlockIsNotDroppedWithoutATrailingBlankLine() {
        let entries = Git.WorktreeListing.parse(porcelain: """
        worktree /repos/app/main
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.branch, "main")
    }

    func testEmptyOutputIsNoEntriesRatherThanOneEmptyOne() {
        XCTAssertTrue(Git.WorktreeListing.parse(porcelain: "").isEmpty)
        XCTAssertTrue(Git.WorktreeListing.parse(porcelain: "\n\n").isEmpty)
    }

    /// Flags belong to the block that declared them. A `bare` row followed by a
    /// real checkout must not leave the checkout marked bare — the reset on each
    /// `worktree` line is what the three walkers each had to remember separately.
    func testFlagsDoNotLeakFromOneBlockToTheNext() throws {
        let entries = Git.WorktreeListing.parse(porcelain: fixture)

        XCTAssertFalse(try XCTUnwrap(entry("/repos/app/main", in: entries)).isBare)
        XCTAssertFalse(try XCTUnwrap(entry("/repos/app/held", in: entries)).isDetached)
        XCTAssertFalse(try XCTUnwrap(entry("/repos/app/spike", in: entries)).isLocked)
        XCTAssertEqual(try XCTUnwrap(entry("/repos/app/main", in: entries)).branch, "main")
    }
}
