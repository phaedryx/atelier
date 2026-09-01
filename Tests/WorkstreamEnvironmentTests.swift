// ABOUTME: Tests for WorkstreamEnvironment env var construction.
// ABOUTME: Validates ATELIER_* vars, default branch, and compatibility aliases for external tools.

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
            defaultBranch: "main",
            scriptSource: nil
        )
        XCTAssertEqual(vars["ATELIER_WORKSTREAM_ID"], "12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(vars["ATELIER_PROJECT"], "my-project")
        XCTAssertEqual(vars["ATELIER_WORKSTREAM"], "coral-reef")
        XCTAssertEqual(vars["ATELIER_PROJECT_DIR"], "/Users/test/my-project")
        XCTAssertEqual(vars["ATELIER_WORKTREE_DIR"], "/Users/test/.atelier/worktrees/my-project/coral-reef")
        XCTAssertEqual(vars["ATELIER_PORT"], "42847")
        XCTAssertEqual(vars["ATELIER_DEFAULT_BRANCH"], "main")
    }

    // MARK: - Conductor aliases

    func testConductorAliases() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main",
            scriptSource: "conductor.json"
        )
        XCTAssertEqual(vars["CONDUCTOR_WORKSPACE_NAME"], "coral-reef")
        XCTAssertEqual(vars["CONDUCTOR_ROOT_PATH"], "/Users/test/my-project")
        XCTAssertEqual(vars["CONDUCTOR_WORKSPACE_PATH"], "/Users/test/.atelier/worktrees/my-project/coral-reef")
        XCTAssertEqual(vars["CONDUCTOR_PORT"], "42847")
        XCTAssertEqual(vars["CONDUCTOR_DEFAULT_BRANCH"], "main")
    }

    // MARK: - Emdash aliases

    func testEmdashAliases() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "develop",
            scriptSource: ".emdash.json"
        )
        XCTAssertEqual(vars["EMDASH_TASK_ID"], "12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(vars["EMDASH_TASK_NAME"], "coral-reef")
        XCTAssertEqual(vars["EMDASH_TASK_PATH"], "/Users/test/.atelier/worktrees/my-project/coral-reef")
        XCTAssertEqual(vars["EMDASH_ROOT_PATH"], "/Users/test/my-project")
        XCTAssertEqual(vars["EMDASH_PORT"], "42847")
        XCTAssertEqual(vars["EMDASH_DEFAULT_BRANCH"], "develop")
    }

    // MARK: - Superset aliases

    func testSupersetAliases() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main",
            scriptSource: ".superset/config.json"
        )
        XCTAssertEqual(vars["SUPERSET_WORKSPACE_NAME"], "coral-reef")
        XCTAssertEqual(vars["SUPERSET_ROOT_PATH"], "/Users/test/my-project")
        XCTAssertEqual(vars["SUPERSET_PORT_BASE"], "42847")
    }

    // MARK: - No aliases for native config

    func testNoAliasesForAtelierConfig() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main",
            scriptSource: ".atelier.json"
        )
        XCTAssertNil(vars["CONDUCTOR_WORKSPACE_NAME"])
        XCTAssertNil(vars["EMDASH_TASK_NAME"])
        XCTAssertNil(vars["SUPERSET_WORKSPACE_NAME"])
    }

    func testNoAliasesForNilSource() {
        let vars = WorkstreamEnvironment.variables(
            workstreamID: baseParams.0,
            projectName: baseParams.1,
            workstreamName: baseParams.2,
            projectDirectory: baseParams.3,
            workingDirectory: baseParams.4,
            port: baseParams.5,
            defaultBranch: "main",
            scriptSource: nil
        )
        XCTAssertNil(vars["CONDUCTOR_WORKSPACE_NAME"])
        XCTAssertNil(vars["EMDASH_TASK_NAME"])
        XCTAssertNil(vars["SUPERSET_WORKSPACE_NAME"])
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
            defaultBranch: "main",
            scriptSource: nil
        )
        let atelierKeys = vars.keys.filter { $0.hasPrefix("ATELIER_") }
        XCTAssertFalse(atelierKeys.isEmpty)
        for key in atelierKeys {
            let legacy = "FF_" + key.dropFirst("ATELIER_".count)
            XCTAssertEqual(vars[legacy], vars[key], "\(legacy) should mirror \(key)")
        }
    }
}
