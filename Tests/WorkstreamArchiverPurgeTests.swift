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

    /// Both checklists' stored selections, and the stored run, gone together.
    ///
    /// `atelier.verifySelection.<id>` and `atelier.processSelection.<id>` are
    /// deliberately separate keys — one key for both would make checking a
    /// verify check uncheck an execute process — so they leak separately too,
    /// and a purge that dropped one and forgot the other is what this pins.
    /// `purge` proper destroys a worktree, so the seam is what is tested.
    func test_clearWorkstreamState_dropsBothSelectionKeysAndTheStoredRun() {
        let id = UUID()
        addTeardownBlock {
            Workstream.Archiver.clearWorkstreamState(for: id)
        }
        Verification.setSelection(.only(["rspec"]), for: id)
        ProcessCompose.TableModel.setSelection(.only(["web"]), for: id)
        Verification.Store.save(Verification.Run(
            id: "abcd1234", workstreamID: id, startedAt: Date(), stamp: "s",
            checks: [], wasStopped: false
        ))

        Workstream.Archiver.clearWorkstreamState(for: id)

        XCTAssertNil(
            UserDefaults.standard.object(forKey: Verification.selectionKey(for: id)),
            "the verify checklist's key outlived the workstream"
        )
        XCTAssertNil(
            UserDefaults.standard.object(forKey: ProcessCompose.TableModel.selectionKey(for: id)),
            "the execution checklist's key outlived the workstream"
        )
        XCTAssertNil(Verification.Store.latest(for: id))
    }

    // MARK: - Waiting for a verify run before the tree goes

    /// **A purge issued while a verify spawn is still binding must wait.**
    /// `ProcessCompose.PhaseExecutor.shutDown` no-ops when the socket file does
    /// not exist yet, so reaching for it directly let `purge` go straight on to
    /// `dispose` and `git worktree remove --force` under a suite that was still
    /// coming up. Going through the runner's own stop-and-wait is what closes
    /// that, and the control server here never answers within the deadline — so
    /// the honest answer is that the run is still live.
    ///
    /// The wait is bounded and the purge proceeds past it; what is pinned here
    /// is that it waits first and reports the truth, not that it blocks
    /// forever.
    @MainActor
    func test_quiesceVerification_waitsWhileTheVerifySpawnIsStillBinding() async {
        let id = UUID()
        addTeardownBlock { Verification.Store.clear(for: id) }
        // Forty polls of `.notRunning` at a 5ms cadence — `up` asked for, not
        // yet bound — then a server that answers, which is what lets the
        // withheld Stop finally land and the loop end.
        let client = StubComposeClient(
            socketPath: "/nonexistent",
            replies: Array(repeating: .failure(.notRunning), count: 40)
                + [.list([verifyEntry("rspec", status: "Running", isRunning: true, exitCode: 0)])],
            latency: .zero
        )
        let spawner = ParkedVerifySpawner(client: client)
        let runner = Verification.Runner(spawner: spawner, pollInterval: .milliseconds(5))
        runner.seedRunForTesting(workstreamID: id, runID: "abcd1234", checks: ["rspec"])
        let loop = Task { await runner.execute(verifyRequest(workstreamID: id), runID: "abcd1234") }

        let began = ContinuousClock.now
        let early = await Workstream.Archiver.quiesceVerification(
            workstreamID: id, runner: runner, timeout: .milliseconds(50)
        )
        let waited = ContinuousClock.now - began

        XCTAssertFalse(early, "a run that has not bound yet must not be reported gone")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(50), "purge must wait, not sail through")
        XCTAssertTrue(runner.isLive(id))

        let quiet = await Workstream.Archiver.quiesceVerification(
            workstreamID: id, runner: runner, timeout: .seconds(4)
        )
        XCTAssertTrue(quiet, "once the server answers, the withheld Stop lands and the run ends")
        XCTAssertFalse(runner.isLive(id))
        await loop.value
        let shutDowns = await spawner.shutDowns
        XCTAssertEqual(shutDowns, 1, "the run loop stays the only owner of the teardown")
    }

    /// The ordinary case: no run, no wait. This is also what a socket left by a
    /// crashed session looks like from here — the runner knows nothing about it,
    /// and `purge`'s own best-effort `shutDown` is what deals with that.
    @MainActor
    func test_quiesceVerification_returnsAtOnceWhenNoRunIsLive() async {
        let quiet = await Workstream.Archiver.quiesceVerification(
            workstreamID: UUID(), runner: Verification.Runner(), timeout: .milliseconds(50)
        )
        XCTAssertTrue(quiet)
    }

    private func verifyEntry(
        _ name: String, status: String, isRunning: Bool, exitCode: Int
    ) -> ProcessCompose.ProcessEntry {
        ProcessCompose.ProcessEntry(
            name: name, namespace: "verify", status: status, isReady: "",
            hasReadyProbe: false, restarts: 0, exitCode: exitCode,
            pid: 0, isRunning: isRunning
        )
    }

    private func verifyRequest(workstreamID: UUID) -> Verification.Runner.SpawnRequest {
        Verification.Runner.SpawnRequest(
            workstreamID: workstreamID,
            config: ProcessCompose.Config(
                path: "/tmp/process-compose.yaml", isRepositoryProvided: false
            ),
            binary: "/usr/bin/true",
            projectName: "app",
            workstreamName: "wisp",
            projectDirectory: "/tmp",
            worktreePath: "/tmp",
            checks: ["rspec"]
        )
    }
}

/// A verify spawn that never ends on its own, so the namespace is still running
/// when a purge arrives — the only shape in which "purge waited" is a question.
///
/// A local, smaller cousin of `VerificationRunnerTests`' own stub rather than a
/// share of it: that one is private to the file whose orderings it exists to
/// expose, and this needs two of its four behaviours.
private actor ParkedVerifySpawner: Verification.Runner.Spawning {
    nonisolated let client: StubComposeClient
    private(set) var shutDowns = 0
    private var parked: CheckedContinuation<Void, Never>?

    init(client: StubComposeClient) {
        self.client = client
    }

    func run(_: Verification.Runner.SpawnRequest) async -> ProcessCompose.PhaseExecutor.Outcome {
        await withCheckedContinuation { parked = $0 }
        return .succeeded
    }

    nonisolated func controlClient(for _: Verification.Runner.SpawnRequest) -> ProcessCompose.Controlling {
        client
    }

    func shutDown(_: Verification.Runner.SpawnRequest) async {
        shutDowns += 1
        await client.endServer()
        parked?.resume()
        parked = nil
    }
}
