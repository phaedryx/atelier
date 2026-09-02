// ABOUTME: Tests for WorkstreamEnvironment env var construction.
// ABOUTME: Validates ATELIER_* vars, the legacy FF_* mirror, and the project's port declarations.

@testable import Atelier
import XCTest

final class WorkstreamEnvironmentTests: XCTestCase {
    private let baseParams: (UUID, String, String, String, String, Int) = (
        UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
        "my-project",
        "coral-reef",
        "/Users/test/my-project",
        "/Users/test/.atelier/worktrees/my-project/coral-reef",
        42847
    )

    // MARK: - Core ATELIER_* variables

    func testCoreVariables() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main"
        )
        XCTAssertEqual(vars["ATELIER_WORKSTREAM_ID"], "12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(vars["ATELIER_PROJECT"], "my-project")
        XCTAssertEqual(vars["ATELIER_WORKSTREAM"], "coral-reef")
        XCTAssertEqual(vars["ATELIER_PROJECT_DIR"], "/Users/test/my-project")
        XCTAssertEqual(vars["ATELIER_WORKTREE_DIR"], "/Users/test/.atelier/worktrees/my-project/coral-reef")
        XCTAssertEqual(vars["ATELIER_PORT"], "42847")
        XCTAssertEqual(vars["ATELIER_DEFAULT_BRANCH"], "main")
    }

    // MARK: - No aliases for other tools

    /// `CONDUCTOR_*`, `EMDASH_*` and `SUPERSET_*` were emitted when a project's
    /// scripts had been read from another tool's config file. Those formats are
    /// no longer read, so nothing is compatible with them and nothing is
    /// exported for them.
    func testNoCompatibilityAliasesForOtherTools() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main"
        )
        for key in vars.keys {
            XCTAssertFalse(key.hasPrefix("CONDUCTOR_"), key)
            XCTAssertFalse(key.hasPrefix("EMDASH_"), key)
            XCTAssertFalse(key.hasPrefix("SUPERSET_"), key)
        }
    }

    // MARK: - Legacy FF_* aliases

    func testLegacyFFAliasesMirrorEveryAtelierVariable() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main"
        )
        let atelierKeys = vars.keys.filter { $0.hasPrefix("ATELIER_") }
        XCTAssertFalse(atelierKeys.isEmpty)
        for key in atelierKeys {
            let legacy = "FF_" + key.dropFirst("ATELIER_".count)
            XCTAssertEqual(vars[legacy], vars[key], "\(legacy) should mirror \(key)")
        }
    }

    // MARK: - Port plan export

    func testPortPlanValuesAreExported() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: UUID(),
            projectName: "app",
            workstreamName: "ws",
            projectDirectory: "/repo",
            workingDirectory: "/repo/ws",
            port: 40001,
            portPlan: PortPlan(values: ["BFF_PORT": "41476"], browserPort: 41476)
        )

        XCTAssertEqual(vars["BFF_PORT"], "41476")
    }

    /// A project naming a variable Atelier also sets should win — the project
    /// knows what its own stack needs.
    func testPortPlanOverridesAtelierDefaults() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: UUID(),
            projectName: "app",
            workstreamName: "ws",
            projectDirectory: "/repo",
            workingDirectory: "/repo/ws",
            port: 40001,
            portPlan: PortPlan(values: ["ATELIER_PORT": "50000"], browserPort: nil)
        )

        XCTAssertEqual(vars["ATELIER_PORT"], "50000")
    }

    /// The FF_* mirror must reflect the overridden value, not the pre-override
    /// default — a script reading FF_PORT should see what ATELIER_PORT says.
    func testPortPlanOverrideIsReflectedInFFAlias() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: UUID(),
            projectName: "app",
            workstreamName: "ws",
            projectDirectory: "/repo",
            workingDirectory: "/repo/ws",
            port: 40001,
            portPlan: PortPlan(values: ["ATELIER_PORT": "50000"], browserPort: nil)
        )

        XCTAssertEqual(vars["FF_PORT"], "50000")
    }

    func testEmptyPortPlanChangesNothing() {
        let base = WorkstreamEnvironment.variables(
            workstreamID: UUID(), projectName: "app", workstreamName: "ws",
            projectDirectory: "/repo", workingDirectory: "/repo/ws", port: 40001
        )

        XCTAssertEqual(base["ATELIER_PORT"], "40001")
    }
}
