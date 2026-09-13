// ABOUTME: Tests the worktree watcher behind the Verification tab's staleness banner.
// ABOUTME: The point is the edit no git-directory watcher sees, and the floor that bounds it.

@testable import Atelier
import XCTest

@MainActor
final class VerificationStalenessWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staleness-" + UUID().uuidString)
        // A `.git` directory so the fixture is shaped like a worktree: the whole
        // point of this watcher is the edit that happens *outside* it.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, _ contents: String = "x") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// **The gap #99 named.** Staleness was driven by `.worktreeGitActivity`,
    /// which comes from a watcher on the worktree's *git directory* — so an
    /// ordinary save, which touches nothing in `.git`, never reached a tab that
    /// stayed mounted. Shaped like `LazyFileTreeTests`' own watcher test,
    /// because the requirement is the file system actually reporting the edit
    /// rather than a pure function agreeing with itself.
    func test_armed_reportsAWorkingTreeEditThatTouchesNothingInGit() throws {
        let fired = expectation(description: "the watcher reported a working-tree edit")
        fired.assertForOverFulfill = false
        let watcher = Verification.StalenessWatcher { fired.fulfill() }
        watcher.arm(path: root.path)
        XCTAssertTrue(watcher.isArmed)

        try write("Sources/Models/thing.swift", "edited outside .git")

        wait(for: [fired], timeout: 15)
    }

    /// Disarmed on every tab switch, so an FSEvents stream over a whole worktree
    /// is not left running for a pane nobody is looking at — and a callback
    /// already queued must not arrive either.
    func test_disarm_goesQuiet() throws {
        let quiet = expectation(description: "no callback after disarm")
        quiet.isInverted = true
        let watcher = Verification.StalenessWatcher { quiet.fulfill() }
        watcher.arm(path: root.path)
        watcher.disarm()
        XCTAssertFalse(watcher.isArmed)

        try write("Sources/Models/thing.swift")

        wait(for: [quiet], timeout: 4)
    }

    /// Re-arming the same path is free: the tab's triggers fire more than once
    /// for one mount, and tearing an FSEvents stream down to build the same one
    /// again is work for nothing.
    func test_arm_isIdempotentForTheSamePath() {
        let watcher = Verification.StalenessWatcher {}
        watcher.arm(path: root.path)
        watcher.arm(path: root.path)
        XCTAssertTrue(watcher.isArmed)
    }

    /// A burst is absorbed, not queued behind itself: the callback already
    /// pending reads the tree when it runs, which is at least as late as
    /// anything arriving now. Driven through `noteChange` rather than the file
    /// system, because what is under test is the rate limit and not FSEvents.
    func test_noteChange_absorbsEventsArrivingWhileACallbackIsPending() async {
        let fired = expectation(description: "exactly one callback for a burst")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true
        let watcher = Verification.StalenessWatcher { fired.fulfill() }

        for _ in 0 ..< 20 {
            watcher.noteChange()
        }

        await fulfillment(of: [fired], timeout: 4)
    }

    /// **The floor, which is what makes this safe to run over a whole worktree.**
    /// A build writes files for minutes, and every callback costs a
    /// `diffFingerprint` — four or more git spawns. A debounce alone would fire
    /// one of those per event; the floor is what holds the second callback back
    /// for `minimumInterval`, rather than merely 500ms after the last event.
    func test_noteChange_holdsASecondCallbackForTheFloor() async {
        let first = expectation(description: "first callback")
        let second = expectation(description: "a second callback inside the floor")
        second.isInverted = true
        var hasFired = false
        let watcher = Verification.StalenessWatcher {
            if hasFired {
                second.fulfill()
            } else {
                hasFired = true
                first.fulfill()
            }
        }

        watcher.noteChange()
        await fulfillment(of: [first], timeout: 4)
        // Well inside `minimumInterval`, and well past `debounce` — which is
        // what a watcher with no floor would have waited.
        watcher.noteChange()
        await fulfillment(of: [second], timeout: 3)
    }
}
