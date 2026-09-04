// ABOUTME: Tests that an unattended phase runs with the workstream's own environment.
// ABOUTME: Covers the assembled variables and the layering ProcessCompose.PhaseExecutor hands to the child.

@testable import Atelier
import XCTest

final class PhaseEnvironmentTests: XCTestCase {
    private var projectDirectory: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase-env-\(UUID().uuidString)")
        projectDirectory = root.appendingPathComponent("project")
        worktree = root.appendingPathComponent("project/worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: projectDirectory.deletingLastPathComponent()
        )
        try super.tearDownWithError()
    }

    private func writePortsFile(_ contents: String) throws {
        try contents.write(
            to: projectDirectory.appendingPathComponent("ports.yaml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func variables() -> [String: String] {
        ProcessCompose.PhaseEnvironment.variables(
            workstreamID: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!,
            projectName: "app",
            workstreamName: "amber-otter",
            projectDirectory: projectDirectory.path,
            worktreePath: worktree.path,
            defaultBranch: "main"
        )
    }

    /// The C1 case, stated directly: a `bootstrap` process must be able to read
    /// `$ATELIER_WORKTREE_DIR` and a port its own `ports.yaml` declared. Both
    /// were absent before — `ProcessCompose.PhaseExecutor` built the child environment from
    /// `ProcessInfo` alone — which made the documented seeding replacement
    /// (`rsync "$$ATELIER_PROJECT_DIR/seed-files/" .`) rsync from `/seed-files/`.
    func testBootstrapSeesTheWorktreeDirectoryAndItsDeclaredPorts() throws {
        try writePortsFile("""
        ports:
          BFF_PORT: { assigned: true }
          RAILS_PORT: { fixed: 3005 }
        """)

        let vars = variables()

        XCTAssertEqual(vars["ATELIER_WORKTREE_DIR"], worktree.path)
        XCTAssertEqual(vars["ATELIER_PROJECT_DIR"], projectDirectory.path)
        XCTAssertEqual(vars["RAILS_PORT"], "3005")
        // Assigned ports are allocated, so the number is not predictable here —
        // that it is a port at all is the claim.
        let assigned = try XCTUnwrap(vars["BFF_PORT"].flatMap(Int.init))
        XCTAssertGreaterThan(assigned, 1024)
    }

    /// The rest of the workstream identity, so a `dispose` process can name the
    /// thing it is cleaning up. `FF_*` is mirrored for the same reason it is
    /// mirrored into terminals: run scripts in the user's own repositories read
    /// it.
    func testTheWorkstreamIdentityIsExportedWithItsLegacyMirror() {
        let vars = variables()

        XCTAssertEqual(vars["ATELIER_PROJECT"], "app")
        XCTAssertEqual(vars["ATELIER_WORKSTREAM"], "amber-otter")
        XCTAssertEqual(vars["ATELIER_DEFAULT_BRANCH"], "main")
        XCTAssertEqual(vars["FF_WORKTREE_DIR"], worktree.path)
    }

    /// A `ports.yaml` that does not parse must not stop the phase. Nobody is
    /// watching an unattended run, so a throw here would strand a worktree with
    /// no visible cause.
    func testAMalformedPortsFileLeavesTheRestOfTheEnvironmentIntact() throws {
        try writePortsFile("ports: [this is not a mapping]")

        let vars = variables()

        XCTAssertEqual(vars["ATELIER_WORKTREE_DIR"], worktree.path)
        XCTAssertNil(vars["BFF_PORT"])
    }

    /// No `ports.yaml` at all is the ordinary case, and it is not an error.
    ///
    /// `XCTAssertNotNil(vars["ATELIER_PORT"])` was vacuous: `WorkstreamEnvironment`
    /// seeds that key unconditionally, so it held for any implementation of the
    /// no-file path. What that path actually has to get right is that the seeded port
    /// is a real port, that its `FF_` mirror agrees with it, and that nothing
    /// declared leaks in from somewhere else.
    func testNoPortsFileStillExportsTheAtelierVariables() throws {
        let vars = variables()

        XCTAssertEqual(vars["ATELIER_WORKTREE_DIR"], worktree.path)

        let port = try XCTUnwrap(try Int(XCTUnwrap(vars["ATELIER_PORT"])))
        XCTAssertTrue((1024 ... 65535).contains(port), "seeded port is out of range: \(port)")
        XCTAssertEqual(vars["FF_PORT"], vars["ATELIER_PORT"], "the FF_ mirror must not lag the seeded value")
        XCTAssertNil(vars["BFF_PORT"], "nothing was declared, so nothing declared may appear")
    }

    // MARK: - What the child actually receives

    /// The layering `ProcessCompose.PhaseExecutor` hands to `ProcessRunner`: inherited, then
    /// the workstream's own, then the login PATH. Asserted here rather than
    /// through `run`, which spawns process-compose.
    func testTheChildEnvironmentLayersTheWorkstreamVariablesOverTheInheritedOnes() {
        let child = ProcessCompose.PhaseExecutor.childEnvironment(
            workstreamEnvironment: ["ATELIER_WORKTREE_DIR": "/w", "BFF_PORT": "41476"],
            loginPath: "/opt/homebrew/bin:/usr/bin",
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/h", "ATELIER_WORKTREE_DIR": "/stale"]
        )

        XCTAssertEqual(child["ATELIER_WORKTREE_DIR"], "/w")
        XCTAssertEqual(child["BFF_PORT"], "41476")
        XCTAssertEqual(child["HOME"], "/h")
        XCTAssertEqual(child["PATH"], "/opt/homebrew/bin:/usr/bin")
    }

    /// PATH is the one variable a declaration must not be able to set: a phase
    /// whose PATH came from the repository's YAML would resolve tools from
    /// somewhere the user never chose.
    func testADeclaredPathCannotDisplaceTheLoginPath() {
        let child = ProcessCompose.PhaseExecutor.childEnvironment(
            workstreamEnvironment: ["PATH": "/attacker/bin"],
            loginPath: "/usr/bin",
            baseEnvironment: ["PATH": "/inherited"]
        )

        XCTAssertEqual(child["PATH"], "/usr/bin")
    }

    /// With no login shell PATH to inject, the inherited one stands — the
    /// pre-existing behaviour, which was to leave the environment alone.
    func testTheInheritedPathSurvivesWhenNoLoginPathResolves() {
        let child = ProcessCompose.PhaseExecutor.childEnvironment(
            workstreamEnvironment: ["ATELIER_PORT": "5000"],
            loginPath: nil,
            baseEnvironment: ["PATH": "/inherited"]
        )

        XCTAssertEqual(child["PATH"], "/inherited")
        XCTAssertEqual(child["ATELIER_PORT"], "5000")
    }

    /// The same question as `testADeclaredPathCannotDisplaceTheLoginPath`, but on
    /// the branch that had no answer. `if let loginPath` meant a failed login-shell
    /// lookup left the *workstream's* PATH standing — the one outcome the doc
    /// comment says cannot happen. The test above it passes either way, because it
    /// never puts a declared PATH in the way.
    func testADeclaredPathCannotSurviveAFailedLoginShellLookup() {
        let child = ProcessCompose.PhaseExecutor.childEnvironment(
            workstreamEnvironment: ["PATH": "/attacker/bin"],
            loginPath: nil,
            baseEnvironment: ["PATH": "/inherited"]
        )

        XCTAssertEqual(child["PATH"], "/inherited")
    }

    /// And with nothing to fall back to, the child gets no PATH at all rather than
    /// the declared one.
    func testNoPathAtAllBeatsADeclaredOneWhenNothingCanBeInherited() {
        let child = ProcessCompose.PhaseExecutor.childEnvironment(
            workstreamEnvironment: ["PATH": "/attacker/bin"],
            loginPath: nil,
            baseEnvironment: ["HOME": "/h"]
        )

        XCTAssertNil(child["PATH"])
        XCTAssertEqual(child["HOME"], "/h")
    }
}
