// ABOUTME: Tests that archiving consults the shared unattended-phase policy for dispose.
// ABOUTME: Holds the wiring seam, since purge itself destroys a worktree.

@testable import Atelier
import XCTest

/// `PhasePolicyTests` covers what the policy decides. This covers that
/// `Workstream.Archiver` actually asks it — an archiver that stopped calling
/// `PhasePolicy.plan` altogether would otherwise pass every dispose test in
/// the suite.
final class WorkstreamArchiverDisposeTests: XCTestCase {
    private var project: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `plan` checks the config before the binary, but the tests that assert
        // a *run* need a real binary: `disposePlan` calls `resolveBinary()` with
        // no arguments on purpose, so the injected `resolveBinary(searchPaths:)`
        // seam does not reach here. The honest thing is to skip, the way
        // `AsyncSetupRerunTests` already does.
        //
        // Skipping cannot hide these in CI: `.github/workflows/ci.yml` installs
        // process-compose and then hard-fails the job if it is not on
        // `searchPaths`, in the same job that runs this suite and immediately
        // before it.
        try XCTSkipIf(
            ProcessCompose.Settings.resolveBinary() == nil,
            "process-compose is not installed, so no dispose could be planned"
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("project")
        worktree = project.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // `project` is nil when setUp skipped before assigning it.
        if let project {
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        super.tearDown()
    }

    /// Guards the guard: if this ever stops resolving, the tests below would
    /// start passing for the wrong reason. The skip above means this can only
    /// fail by the resolver disagreeing with itself between setUp and here.
    func testTheBinaryPreconditionIsSatisfiedForEveryTestHere() {
        XCTAssertNotNil(ProcessCompose.Settings.resolveBinary())
    }

    private func note(_ plan: PhasePolicy.Plan) -> String? {
        guard case let .nothingToDo(message) = plan else { return nil }
        return message
    }

    @discardableResult
    private func writeConfig(in dir: URL, named name: String = "execution.process-compose.yaml") throws -> String {
        let path = dir.appendingPathComponent(name)
        try "processes:\n  cleanup:\n    namespace: dispose\n    command: \"true\"\n"
            .write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    /// Proves the plan was consulted at all: a `runDispose` that had kept its
    /// own inline preconditions would report something else, or nothing. The
    /// missing-config branch is what stands in for it; no config is written in
    /// this project directory.
    func testDisposeAsksThePolicy() {
        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(
            note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan)
        )
        XCTAssertEqual(note(plan)?.contains("dispose"), true, "the note must name the phase")
    }

    /// The project directory is the only place a config comes from, so this is
    /// the ordinary case and there is nothing to approve in it.
    func testDisposeRunsTheProjectDirectoryConfig() throws {
        let path = try writeConfig(in: project)

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        guard case let .run(planned, _) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(planned.path, path)
    }

    /// **A config in the worktree is not dispose's to run, and nothing asks
    /// about it.** It used to be located and then refused until the user
    /// approved it; now it is not located at all, which is the same refusal made
    /// one step earlier and without a question that could be answered wrongly.
    /// A worktree tier put back here would run repository content unattended at
    /// archive with no gate behind it.
    func testAConfigInTheWorktreeIsNotPlanned() throws {
        try writeConfig(in: worktree)
        try writeConfig(in: worktree, named: "process-compose.yaml")

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(
            note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan)
        )
    }

    /// The hard break reaches dispose too: a project still carrying one of the
    /// old names gets the note naming the new one, not a silent run of a file
    /// nothing located.
    func testTheOldNamesAreNotPlanned() throws {
        try writeConfig(in: project, named: "process-compose.yaml")
        try writeConfig(in: project, named: "atelier.process-compose.yaml")

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(
            note(plan)?.contains("execution.process-compose.yaml"), true, String(describing: plan)
        )
    }
}
