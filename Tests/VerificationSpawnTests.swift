// ABOUTME: Tests the wrapper one check runs under — its quoting, its pid, and its status file.
// ABOUTME: The command is really executed here, because quoting that only looks right is the hazard.

@testable import Atelier
import XCTest

final class VerificationSpawnTests: XCTestCase {
    private func check(
        _ name: String = "rspec", command: String, shell: String? = nil
    ) -> Verification.Config.Check {
        Verification.Config.Check(name: name, command: command, shell: shell)
    }

    // MARK: - Identity

    /// **Deterministic, and it has to be.** Surfaces are keyed by `UUID` and the
    /// rows are rebuilt on every publish, so a derived id that moved would mean a
    /// second terminal for a check already running in one.
    func test_surfaceID_isStableForTheSameWorkstreamAndCheck() {
        let id = UUID()
        XCTAssertEqual(
            Verification.Spawn.surfaceID(for: id, check: "rspec"),
            Verification.Spawn.surfaceID(for: id, check: "rspec")
        )
    }

    func test_surfaceID_differsByCheckAndByWorkstream() {
        let one = UUID()
        let two = UUID()
        XCTAssertNotEqual(
            Verification.Spawn.surfaceID(for: one, check: "rspec"),
            Verification.Spawn.surfaceID(for: one, check: "rubocop")
        )
        XCTAssertNotEqual(
            Verification.Spawn.surfaceID(for: one, check: "rspec"),
            Verification.Spawn.surfaceID(for: two, check: "rspec")
        )
    }

    /// The one collision that would be catastrophic rather than merely wrong: the
    /// workstream's own id is the Coding Agent's surface, so a check landing on it
    /// would replace the user's agent with a test runner.
    func test_surfaceID_neverCollidesWithTheWorkstreamsOwnSurface() {
        let id = UUID()
        for name in ["rspec", "", "main", id.uuidString] {
            XCTAssertNotEqual(Verification.Spawn.surfaceID(for: id, check: name), id)
        }
    }

    /// A check's name is the user's and may hold `/`, spaces, or more bytes than a
    /// path component takes — so the state files are named by a hash, not by it.
    func test_fileStem_survivesANameThatIsNotAPathComponent() {
        let id = UUID()
        let stem = Verification.Spawn.fileStem(for: id, check: "packages/web: lint & test")
        XCTAssertFalse(stem.contains("/"))
        XCTAssertFalse(stem.contains(" "))
        XCTAssertEqual(stem, Verification.Spawn.fileStem(for: id, check: "packages/web: lint & test"))
    }

    // MARK: - The command

    /// Ghostty runs a surface command through `/bin/bash -c` on macOS, so the
    /// outermost token is read by bash before any shell of ours sees it — which is
    /// why it is POSIX-quoted and never fish-quoted.
    func test_build_wrapsTheUsersCommandInTheUsersShell() {
        let spawn = Verification.Spawn.build(
            check: check(command: "bundle exec rspec"),
            workstreamID: UUID(),
            defaultShell: "/bin/zsh"
        )

        XCTAssertTrue(spawn.command.hasPrefix("sh -c "), spawn.command)
        XCTAssertTrue(spawn.command.contains("/bin/zsh -lic"), spawn.command)
        XCTAssertTrue(spawn.command.contains("bundle exec rspec"), spawn.command)
    }

    /// `-lic`, not `-lc`: zsh users put PATH in `.zshrc`, which only an interactive
    /// shell reads, and a check that cannot find `bundle` fails for a reason
    /// nothing on the row could explain.
    func test_build_usesAnInteractiveLoginShell() {
        let spawn = Verification.Spawn.build(
            check: check(command: "true"), workstreamID: UUID(), defaultShell: "/bin/zsh"
        )
        XCTAssertTrue(spawn.command.contains("-lic"), spawn.command)
    }

    func test_build_prefersTheCheckesOwnShellOverTheDefault() {
        let spawn = Verification.Spawn.build(
            check: check(command: "true", shell: "/bin/sh"),
            workstreamID: UUID(),
            defaultShell: "/bin/zsh"
        )
        XCTAssertTrue(spawn.command.contains("/bin/sh -lic"), spawn.command)
        XCTAssertFalse(spawn.command.contains("/bin/zsh"), spawn.command)
    }

    // MARK: - Running it

    /// **The command is actually executed**, because quoting that only looks right
    /// is exactly the hazard: the string passes through bash, then `sh -c`, then
    /// the user's shell, and a test that asserted on substrings would pass for a
    /// command no shell can parse.
    private func execute(_ spawn: Verification.Spawn, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The same `-c` Ghostty hands a surface command to.
        process.arguments = ["-c", spawn.command]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
    }

    private func makeSpawn(
        _ check: Verification.Config.Check, shell: String = "/bin/sh"
    ) -> Verification.Spawn {
        Verification.Spawn.ensureStateDirectory()
        let spawn = Verification.Spawn.build(
            check: check, workstreamID: UUID(), defaultShell: shell
        )
        spawn.clearState()
        addTeardownBlock { spawn.clearState() }
        return spawn
    }

    func test_run_recordsAZeroStatusForACommandThatSucceeds() throws {
        let spawn = makeSpawn(check(command: "true"))

        try execute(spawn, in: FileManager.default.temporaryDirectory)

        XCTAssertEqual(spawn.recordedStatus, 0)
    }

    func test_run_recordsTheExitCodeOfACommandThatFails() throws {
        let spawn = makeSpawn(check(command: "exit 4"))

        try execute(spawn, in: FileManager.default.temporaryDirectory)

        XCTAssertEqual(spawn.recordedStatus, 4, "the exit code is the verdict, so it has to survive three shells")
    }

    /// The pid is the only handle on a running check — Ghostty exposes none — and
    /// it is the *group* leader, so `kill(-pid)` reaches the whole tree.
    func test_run_recordsAPIDBeforeTheCommandRuns() throws {
        let spawn = makeSpawn(check(command: "true"))

        try execute(spawn, in: FileManager.default.temporaryDirectory)

        XCTAssertNotNil(spawn.recordedPID)
    }

    /// A command full of shell metacharacters is the case the quoting exists for:
    /// quotes, backticks, `$(…)` and `&&` must reach the user's shell as written
    /// rather than being evaluated by bash on the way past.
    func test_run_survivesACommandFullOfMetacharacters() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let spawn = makeSpawn(check(command: "echo \"a 'b' `c` $(d) && e\" > out.txt"))
        try execute(spawn, in: directory)

        let written = try String(
            contentsOf: directory.appendingPathComponent("out.txt"), encoding: .utf8
        )
        XCTAssertEqual(spawn.recordedStatus, 0)
        // Backticks and `$(…)` are evaluated by the *user's* shell, which is the
        // right place: what must not happen is bash performing them first.
        XCTAssertTrue(written.contains("a 'b'"), written)
        XCTAssertTrue(written.contains("&& e"), written)
    }

    /// Run in the worktree, which is what makes a relative command mean what the
    /// user expects.
    func test_run_usesTheWorkingDirectoryItIsGiven() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let spawn = makeSpawn(check(command: "touch ran-here"))
        try execute(spawn, in: directory)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran-here").path)
        )
    }

    /// **Before every spawn, because the status file is the completion signal.** A
    /// stale one from the previous run of this check would be read as this run
    /// finishing the instant it started.
    func test_clearState_removesAPreviousRunsVerdict() throws {
        let spawn = makeSpawn(check(command: "exit 3"))
        try execute(spawn, in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(spawn.recordedStatus, 3)

        spawn.clearState()

        XCTAssertNil(spawn.recordedStatus, "a re-run must not inherit the last run's verdict")
        XCTAssertNil(spawn.recordedPID)
    }

    /// Nothing has run, so there is no verdict — which is what the completion pass
    /// reads as "still going".
    func test_recordedStatus_isNilBeforeAnythingRuns() {
        let spawn = makeSpawn(check(command: "true"))
        XCTAssertNil(spawn.recordedStatus)
    }

    // MARK: - Collecting the state files

    /// **Nothing used to remove these.** `clearState` clears one check on its way
    /// into a new run, so at the end of a workstream's life its pid and status
    /// files were simply left behind — per workstream and per check, for the life
    /// of the install.
    func test_removeState_collectsEveryCheckOfOneWorkstream() throws {
        Verification.Spawn.ensureStateDirectory()
        let workstreamID = UUID()
        let spawns = ["rspec", "rubocop"].map {
            Verification.Spawn.build(
                check: check($0, command: "exit 0"), workstreamID: workstreamID, defaultShell: "/bin/sh"
            )
        }
        for spawn in spawns {
            try execute(spawn, in: FileManager.default.temporaryDirectory)
            XCTAssertEqual(spawn.recordedStatus, 0)
        }

        Verification.Spawn.removeState(for: workstreamID)

        for spawn in spawns {
            XCTAssertNil(spawn.recordedStatus, "a status file survived the sweep")
            XCTAssertNil(spawn.recordedPID, "a pid file survived the sweep")
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawn.statusPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawn.pidPath))
        }
    }

    /// Scoped by prefix, so archiving one workstream must not disturb another's
    /// files — including a check that is running in it right now.
    func test_removeState_leavesAnotherWorkstreamAlone() throws {
        Verification.Spawn.ensureStateDirectory()
        let mineID = UUID()
        let theirsID = UUID()
        let mine = Verification.Spawn.build(
            check: check(command: "exit 0"), workstreamID: mineID, defaultShell: "/bin/sh"
        )
        let theirs = Verification.Spawn.build(
            check: check(command: "exit 0"), workstreamID: theirsID, defaultShell: "/bin/sh"
        )
        addTeardownBlock { theirs.clearState() }
        try execute(mine, in: FileManager.default.temporaryDirectory)
        try execute(theirs, in: FileManager.default.temporaryDirectory)

        Verification.Spawn.removeState(for: mineID)

        XCTAssertNil(mine.recordedStatus)
        XCTAssertEqual(theirs.recordedStatus, 0, "another workstream's verdict was swept")
    }
}
