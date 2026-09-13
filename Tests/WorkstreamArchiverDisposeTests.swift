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
        // `plan` checks the binary *before* it checks approval, so on a host
        // without process-compose the refusal tests below would report "was not
        // found" and fail — and those are precisely the two that assert the
        // security refusal.
        //
        // This used to be made host-independent by pointing
        // `ProcessCompose.Settings.binaryPath` at `/bin/ls`. That setting is
        // gone — the binary is auto-detected — and the injected
        // `resolveBinary(searchPaths:)` seam does not reach here, because these
        // tests go through `disposePlan`, which calls `resolveBinary()` with no
        // arguments on purpose. So the honest thing is to skip, the way
        // `AsyncSetupRerunTests` already does.
        //
        // Skipping cannot hide these in CI: `.github/workflows/ci.yml` installs
        // process-compose and then hard-fails the job if it is not on
        // `searchPaths`, in the same job that runs this suite and immediately
        // before it.
        try XCTSkipIf(
            ProcessCompose.Settings.resolveBinary() == nil,
            "process-compose is not installed, so the binary precondition would mask the approval one"
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("project")
        worktree = project.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // `project` is nil when setUp skipped before assigning it.
        if let project {
            ScriptTrust.revokeConfigFiles(for: project.path)
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        super.tearDown()
    }

    /// Guards the guard: if this ever stops resolving, the refusal tests below
    /// would start passing for the wrong reason (a missing binary, not a missing
    /// approval). The skip above means this can only fail by the resolver
    /// disagreeing with itself between setUp and here.
    func testTheBinaryPreconditionIsSatisfiedForEveryTestHere() {
        XCTAssertNotNil(ProcessCompose.Settings.resolveBinary())
    }

    private func note(_ plan: PhasePolicy.Plan) -> String? {
        guard case let .nothingToDo(message) = plan else { return nil }
        return message
    }

    private func writeConfig(in dir: URL, named name: String = "process-compose.yaml") throws -> String {
        let path = dir.appendingPathComponent(name)
        try "processes:\n  cleanup:\n    namespace: dispose\n    command: \"true\"\n"
            .write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    /// Proves the plan was consulted at all: a `runDispose` that had kept its
    /// own inline preconditions would report something else, or nothing. The
    /// missing-config branch is what stands in for it now that the
    /// integration switch — the branch this used to reach — is gone; no config
    /// is written in this worktree or this project directory.
    func testDisposeAsksThePolicy() {
        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(note(plan)?.contains("no process-compose config"), true, String(describing: plan))
        XCTAssertEqual(note(plan)?.contains("dispose"), true, "the note must name the phase")
    }

    func testDisposeIsRefusedForAnUnapprovedRepositoryConfig() throws {
        _ = try writeConfig(in: worktree)

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(note(plan)?.contains("have not been approved"), true, String(describing: plan))
    }

    /// Approving through the same store the pane writes to has to reach the
    /// archiver, or dispose would be permanently dead for every repository
    /// config.
    func testDisposeRunsOnceTheRepositoryConfigIsApproved() throws {
        let path = try writeConfig(in: worktree)
        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )
        XCTAssertEqual(config.repositoryProvidedFiles, [path])
        XCTAssertTrue(try ScriptTrust.approve(
            configFiles: config.repositoryProvidedFiles,
            for: project.path,
            matching: XCTUnwrap(ScriptTrust.fingerprint(configFiles: config.repositoryProvidedFiles))
        ))

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        guard case let .run(planned, _) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(planned.path, path)
    }

    /// The gate follows the file that will be *loaded*, not merely the files
    /// that exist. A repository running process-compose for its own reasons
    /// checks in a generic `process-compose.yaml`; an `atelier.`-prefixed config
    /// in the project directory outranks it, so dispose runs the user's own file
    /// and asks about nothing.
    ///
    /// Asserting only "it ran" would pass just as well if the repository's file
    /// had been the one planned, so the planned path is checked too — being
    /// ungated is only correct because the file is the user's.
    func testDisposeRunsTheAtelierNamedConfigAndIgnoresTheRepositorysOwn() throws {
        let mine = try writeConfig(in: project, named: "atelier.process-compose.yaml")
        _ = try writeConfig(in: worktree)

        let config = try XCTUnwrap(
            ProcessCompose.Config.locate(worktree: worktree.path, projectDirectory: project.path)
        )
        XCTAssertEqual(config.loadedFiles, [mine])
        XCTAssertEqual(config.repositoryProvidedFiles, [],
                       "the repository's own file is not loaded, so there is nothing to approve")

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )
        guard case let .run(planned, _) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(planned.path, mine)
    }

    func testDisposeNeedsNoApprovalForTheUsersOwnConfig() throws {
        let path = try writeConfig(in: project)

        let plan = Workstream.Archiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        guard case let .run(planned, _) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(planned.path, path)
    }
}
