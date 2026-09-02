// ABOUTME: Tests that archiving consults the shared unattended-phase policy for dispose.
// ABOUTME: Holds the wiring seam, since purge itself destroys a worktree.

@testable import Atelier
import XCTest

/// `PhasePolicyTests` covers what the policy decides. This covers that
/// `WorkstreamArchiver` actually asks it — an archiver that stopped calling
/// `PhasePolicy.plan` altogether would otherwise pass every dispose test in
/// the suite.
final class WorkstreamArchiverDisposeTests: XCTestCase {
    private var project: URL!
    private var worktree: URL!
    private var savedSettings: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("project")
        worktree = project.appendingPathComponent("wt")
        try! FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        for key in [ProcessComposeSettings.enabledKey, ProcessComposeSettings.binaryPathKey] {
            savedSettings[key] = UserDefaults.standard.object(forKey: key)
        }
        ProcessComposeSettings.isEnabled = true
        // A real, always-present executable rather than whatever this machine
        // happens to have installed. `plan` checks the binary *before* it checks
        // approval, so on a runner without process-compose the refusal tests
        // would report "was not found" and fail — and those are precisely the
        // two that assert the security refusal. This makes every branch here
        // deterministic and independent of the host.
        ProcessComposeSettings.binaryPath = "/bin/ls"
    }

    override func tearDown() {
        ScriptTrust.revokeConfigFiles(for: project.path)
        for (key, value) in savedSettings {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        super.tearDown()
    }

    /// Guards the guard: if this ever stops resolving, the refusal tests below
    /// would start passing for the wrong reason (a missing binary, not a missing
    /// approval).
    func testTheBinaryPreconditionIsSatisfiedForEveryTestHere() {
        XCTAssertEqual(ProcessComposeSettings.resolveBinary(), "/bin/ls")
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

    /// The disabled-integration branch proves the plan was consulted at all: a
    /// `runDispose` that had kept its own inline preconditions would report
    /// something else, or nothing.
    func testDisposeAsksThePolicy() {
        ProcessComposeSettings.isEnabled = false

        let plan = WorkstreamArchiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(note(plan)?.contains("turned off"), true, String(describing: plan))
        XCTAssertEqual(note(plan)?.contains("dispose"), true, "the note must name the phase")
    }

    func testDisposeIsRefusedForAnUnapprovedRepositoryConfig() throws {
        _ = try writeConfig(in: worktree)

        let plan = WorkstreamArchiver.disposePlan(
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
            ProcessComposeConfig.locate(worktree: worktree.path, projectDirectory: project.path)
        )
        XCTAssertEqual(config.repositoryProvidedFiles, [path])
        ScriptTrust.approve(configFiles: config.repositoryProvidedFiles, for: project.path)

        let plan = WorkstreamArchiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        guard case let .run(planned, _) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(planned.path, path)
    }

    /// A worktree override beside the user's own project-directory config is
    /// repository content that dispose would execute, so archiving must gate on
    /// it too — the bypass that `isRepositoryProvided` alone missed.
    func testDisposeIsRefusedForAWorktreeOverrideBesideAUserConfig() throws {
        _ = try writeConfig(in: project)
        _ = try writeConfig(in: worktree, named: "process-compose.override.yml")

        let plan = WorkstreamArchiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        XCTAssertEqual(note(plan)?.contains("have not been approved"), true, String(describing: plan))
    }

    func testDisposeNeedsNoApprovalForTheUsersOwnConfig() throws {
        let path = try writeConfig(in: project)

        let plan = WorkstreamArchiver.disposePlan(
            worktreePath: worktree.path, projectDirectory: project.path
        )

        guard case let .run(planned, _) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(planned.path, path)
    }
}
