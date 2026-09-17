// ABOUTME: Tests the guard that decides which path a purge is allowed to destroy.
// ABOUTME: `purge` itself removes a worktree, so the decision is tested, not the act.

@testable import Atelier
import XCTest

/// `Workstream.workingDirectory(checkout:)` falls back to the project's checkout
/// when a workstream has no worktree, which is right for launching a terminal and
/// catastrophic for archiving: `purge` fed that same fallback to
/// `Git.Operations.removeWorktree`, which deletes the path it is handed.
final class WorkstreamArchiverPurgeTests: XCTestCase {
    private let projectDirectory = "/tmp/atelier-test/project"
    private let checkoutDirectory = "/tmp/atelier-test/project/main"

    private func workstream(worktreePath: String?) -> Workstream {
        Workstream(name: "scan-deep-thr", worktreePath: worktreePath)
    }

    func testAWorkstreamWithAWorktreeIsDestroyable() {
        let path = Workstream.Archiver.destroyableWorktreePath(
            for: workstream(worktreePath: "/tmp/atelier-test/project/wt"),
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(path, "/tmp/atelier-test/project/wt")
    }

    /// The case that deleted a user's checkout: archived before
    /// `workstreamWorktreeReady` landed, so there is no worktree path at all.
    func testAWorkstreamWithNoWorktreePathIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: nil),
                projectDirectory: projectDirectory
            )
        )
    }

    func testTheProjectDirectoryItselfIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: projectDirectory),
                projectDirectory: projectDirectory
            )
        )
    }

    /// Stored paths are not normalized on the way in, so the two can name the
    /// same directory and still not compare equal as strings.
    func testTheProjectDirectoryIsNotDestroyableUnderAnotherSpelling() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: projectDirectory + "/./"),
                projectDirectory: projectDirectory
            )
        )
    }

    /// An empty path is `URL(fileURLWithPath:)`'s worst input: it resolves to the
    /// process's current directory, which has nothing to do with this project.
    func testAnEmptyWorktreePathIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: "   "),
                projectDirectory: projectDirectory
            )
        )
    }

    /// The comment above describes `""`, but only `"   "` was exercised. The
    /// two take different branches: whitespace survives the trim as a path
    /// component, an empty string does not.
    func testATrulyEmptyWorktreePathIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: ""),
                projectDirectory: projectDirectory
            )
        )
    }

    /// A relative path is resolved against the *process's* working directory,
    /// which has nothing to do with the project — so it never equals the
    /// protected set and sails through the guard. The raw, unresolved string is
    /// then what `removeWorktree` and `deleteLocalBranch` are handed, and they
    /// resolve it against their own working directory. Only absolute paths can
    /// be reasoned about here.
    func testARelativeWorktreePathIsNotDestroyable() {
        for relative in ["../sibling", "sibling", "./sibling", "~/sibling"] {
            XCTAssertNil(
                Workstream.Archiver.destroyableWorktreePath(
                    for: workstream(worktreePath: relative),
                    projectDirectory: projectDirectory
                ),
                "\(relative) is not an absolute path and must not be destroyable"
            )
        }
    }

    /// In the `.bare` container layout the project's directory is the container
    /// and its checkout is the trunk worktree inside it. Neither is ever a
    /// workstream — the container holds them all as peers — so both have to be
    /// refused, not whichever one the caller happened to pass.
    func testTheProjectsCheckoutIsNotDestroyable() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: checkoutDirectory),
                projectDirectory: projectDirectory,
                checkoutDirectory: checkoutDirectory
            )
        )
    }

    func testTheProjectsCheckoutIsNotDestroyableUnderAnotherSpelling() {
        XCTAssertNil(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: checkoutDirectory + "/./"),
                projectDirectory: projectDirectory,
                checkoutDirectory: checkoutDirectory
            )
        )
    }

    func testAPeerWorkstreamBesideTheCheckoutStaysDestroyable() {
        XCTAssertEqual(
            Workstream.Archiver.destroyableWorktreePath(
                for: workstream(worktreePath: "/tmp/atelier-test/project/tad@feature"),
                projectDirectory: projectDirectory,
                checkoutDirectory: checkoutDirectory
            ),
            "/tmp/atelier-test/project/tad@feature"
        )
    }

    // MARK: - The warning shown before purge destroys anything

    /// `purge` runs `git worktree remove --force` and then deletes the directory
    /// itself, so this warning is the only thing standing between the user and the
    /// loss. It was gated on probes that returned "no work here" when they had in
    /// fact failed to look, which turned a failed check into a silent all-clear.
    func testPurgeWarnsWhenItCouldNotEstablishWhatWouldBeLost() throws {
        let unreadable = try makeNonRepositoryDirectory()

        let warning = Workstream.Archiver.purgeWarning(
            for: workstream(worktreePath: unreadable.path)
        )

        XCTAssertNotNil(warning, "an unread worktree must not be presented as safe to purge")
    }

    func testOrphanPurgeWarnsWhenItCouldNotEstablishWhatWouldBeLost() throws {
        let unreadable = try makeNonRepositoryDirectory()

        XCTAssertNotNil(Workstream.Archiver.orphanPurgeWarning(at: unreadable.path))
    }

    /// The positive control: a readable worktree with nothing at stake still purges
    /// without a warning, or the warning becomes noise on every purge and the user
    /// learns to click through it.
    ///
    /// It has to be a *clone*. `hasUnpushedCommits` treats a missing upstream as
    /// "everything is unpushed", which is correct and would warn on a standalone
    /// repository for a reason that has nothing to do with what is being tested.
    func testACleanReadableWorktreePurgesWithoutAWarning() throws {
        let repo = try makeCleanClone()

        XCTAssertNil(Workstream.Archiver.purgeWarning(for: workstream(worktreePath: repo.path)))
        XCTAssertNil(Workstream.Archiver.orphanPurgeWarning(at: repo.path))
    }

    /// `hasUncommittedChanges` can succeed (a clean tree, `git status` ran fine)
    /// while `hasUnpushedCommits` cannot answer at all — a repository with an
    /// unborn HEAD makes both of its log probes fail the same way a genuine
    /// probe failure would. Dropping that out of the warning silently is the
    /// exact defect this fix closes: the user must be told commits might be
    /// unpushed, not shown a warning-free purge.
    func testPurgeWarnsWhenUnpushedStatusIsUnknownEvenWithNoUncommittedChanges() throws {
        let repo = try makeNonRepositoryDirectory()
        XCTAssertTrue(runGit(["init", "-b", "main"], in: repo))

        let warning = try XCTUnwrap(
            Workstream.Archiver.purgeWarning(for: workstream(worktreePath: repo.path)),
            "unpushed status could not be established, so this must not purge silently"
        )
        XCTAssertTrue(warning.contains("possibly unpushed"), "warning was: \(warning)")

        let orphanWarning = try XCTUnwrap(Workstream.Archiver.orphanPurgeWarning(at: repo.path))
        XCTAssertTrue(orphanWarning.contains("possibly unpushed"), "warning was: \(orphanWarning)")
    }

    private func makeNonRepositoryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeCleanClone() throws -> URL {
        let remote = try makeNonRepositoryDirectory()
        XCTAssertTrue(runGit(["init", "-b", "main"], in: remote))
        XCTAssertTrue(runGit(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                              "commit", "--allow-empty", "-m", "init"], in: remote))

        let parent = try makeNonRepositoryDirectory()
        let local = parent.appendingPathComponent("clone")
        XCTAssertTrue(runGit(["clone", remote.path, local.path], in: parent))
        return local
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL, file: StaticString = #filePath, line: UInt = #line) -> Bool {
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

    // MARK: - What a purge must not leave behind

    /// The execute checklist's stored selection, gone.
    ///
    /// Verification has no checklist or selection key of its own — see
    /// `test_clearWorkstreamState_dropsThePerCheckRecords` below for what does
    /// outlive a purged workstream on that side. `purge` proper destroys a
    /// worktree, so the seam is what is tested.
    func test_clearWorkstreamState_dropsTheExecuteSelectionKey() {
        let id = UUID()
        addTeardownBlock {
            Workstream.Archiver.clearWorkstreamState(for: id)
        }
        ProcessCompose.TableModel.setSelection(.only(["web"]), for: id)

        Workstream.Archiver.clearWorkstreamState(for: id)

        XCTAssertNil(
            UserDefaults.standard.object(forKey: ProcessCompose.TableModel.selectionKey(for: id)),
            "the execution checklist's key outlived the workstream"
        )
    }

    // MARK: - Waiting for a running check before the tree goes

    /// A check whose wrapper has not written its pid yet, for the window a purge
    /// must not sail through: `stop` has nothing to signal, and the check is
    /// nonetheless live.
    @MainActor
    private func spawn(named name: String) -> Verification.Spawn {
        Verification.Spawn.ensureStateDirectory()
        let spawn = Verification.Spawn.build(
            check: Verification.Config.Check(name: name, command: "true", shell: nil),
            workstreamID: UUID()
        )
        spawn.clearState()
        return spawn
    }

    /// **A purge issued while a check is still starting must wait.** Killing the
    /// process group and moving on was the shape that let `purge` reach
    /// `git worktree remove --force` with the command still running in that tree —
    /// `stop` only *asks*, so the wait is what makes the tree safe to delete.
    ///
    /// Here the check never finishes, so the wait expires and the honest answer is
    /// that it is still live. The wait is bounded and the purge proceeds past it;
    /// what is pinned is that it waits first and reports the truth.
    @MainActor
    func test_quiesceVerification_waitsWhileACheckIsStillRunning() async {
        let id = UUID()
        let runner = Verification.Runner(pollInterval: .milliseconds(5))
        let spawn = spawn(named: "rspec")
        addTeardownBlock { spawn.clearState() }
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        runner.seedRunningForTesting(
            workstreamID: id, runID: "abcd1234", check: "rspec", spawn: spawn
        )

        let began = ContinuousClock.now
        let early = await Workstream.Archiver.quiesceVerification(
            workstreamID: id, runner: runner, timeout: 0.05
        )
        let waited = ContinuousClock.now - began

        XCTAssertFalse(early, "a check that has not started yet must not be reported gone")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(50), "purge must wait, not sail through")
        XCTAssertTrue(runner.isLive(id))

        // The wrapper's status file is what production's completion pass reads, so
        // writing one is the check exiting.
        try? "0\n".write(toFile: spawn.statusPath, atomically: true, encoding: .utf8)

        let quiet = await Workstream.Archiver.quiesceVerification(
            workstreamID: id, runner: runner, timeout: 4
        )
        XCTAssertTrue(quiet, "once the check is gone, the wait ends")
        XCTAssertFalse(runner.isLive(id))
    }

    /// The ordinary case: nothing running, no wait.
    @MainActor
    func test_quiesceVerification_returnsAtOnceWhenNothingIsLive() async {
        let quiet = await Workstream.Archiver.quiesceVerification(
            workstreamID: UUID(), runner: Verification.Runner(), timeout: 0.05
        )
        XCTAssertTrue(quiet)
    }

    /// The per-check results outlive a purged workstream otherwise, and they are keyed by
    /// a UUID nothing will ever reuse — so nothing would ever clean them up.
    func test_clearWorkstreamState_dropsThePerCheckRecords() {
        let id = UUID()
        Verification.CheckStore.save(
            ["rspec": Verification.CheckRecord(
                name: "rspec", state: .passed, duration: 1,
                stamp: "s", runID: "abcd1234", completedAt: Date()
            )],
            for: id
        )

        Workstream.Archiver.clearWorkstreamState(for: id)

        XCTAssertTrue(Verification.CheckStore.records(for: id).isEmpty)
    }

    /// The session-checkpoint tools' saved note outlives a purged workstream
    /// otherwise, keyed by a UUID nothing will ever reuse — so nothing else
    /// would ever clean it up.
    func test_clearWorkstreamState_dropsTheSessionCheckpoint() throws {
        let id = UUID()
        try IPC.CheckpointStore.save("left off mid-refactor", for: id)

        Workstream.Archiver.clearWorkstreamState(for: id)

        XCTAssertNil(IPC.CheckpointStore.read(for: id))
    }
}
