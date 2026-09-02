// ABOUTME: Tests for process-compose command construction per lifecycle phase.
// ABOUTME: Socket path, namespace selection, -f handling, and process selection.

@testable import Atelier
import XCTest

final class PhaseRunnerTests: XCTestCase {
    private let workstreamID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let binary = "/opt/homebrew/bin/process-compose"

    private var worktreeConfig: ProcessComposeConfig {
        ProcessComposeConfig(path: "/repo/wt/process-compose.yaml", isRepositoryProvided: true, overridePath: nil)
    }

    private var projectConfig: ProcessComposeConfig {
        ProcessComposeConfig(path: "/repo/process-compose.yaml", isRepositoryProvided: false, overridePath: nil)
    }

    /// The socket path must be predictable — a bare `-U` generates one
    /// containing the PID, which Atelier cannot find afterwards.
    func testSocketPathIsDerivedFromTheWorkstream() throws {
        let path = PhaseRunner.socketPath(for: workstreamID)
        let otherID = try XCTUnwrap(UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        let otherPath = PhaseRunner.socketPath(for: otherID)

        XCTAssertTrue(path.hasSuffix(".sock"), path)
        XCTAssertEqual(path, PhaseRunner.socketPath(for: workstreamID))
        XCTAssertNotEqual(path, otherPath, "different UUIDs must produce different paths")
    }

    /// macOS caps a unix socket path at 104 bytes. A full UUID plus a long home
    /// directory can approach that, so the name is shortened deliberately.
    func testSocketPathStaysUnderTheUnixLimit() {
        let path = PhaseRunner.socketPath(for: workstreamID)
        let fullUUID = workstreamID.uuidString.lowercased()
        let shortUUID = fullUUID.prefix(8)

        XCTAssertLessThan(path.utf8.count, 104)
        XCTAssertFalse(path.contains(fullUUID), "full UUID must not appear in path")
        XCTAssertTrue(path.contains(String(shortUUID)), "first 8 characters must be present")
    }

    func testWorktreeConfigPassesNoDashF() {
        let command = PhaseRunner.command(
            phase: .execute, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertFalse(command.contains(" -f "), "naming the config would disable override discovery")
        XCTAssertTrue(command.contains("-n execute"), command)
    }

    func testProjectConfigNamesTheFile() {
        let command = PhaseRunner.command(
            phase: .execute, config: projectConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertTrue(command.contains("-f /repo/process-compose.yaml"), command)
    }

    func testOverrideIsNamedWhenPresent() {
        let config = ProcessComposeConfig(
            path: "/repo/process-compose.yaml",
            isRepositoryProvided: false,
            overridePath: "/repo/wt/process-compose.override.yaml"
        )

        let command = PhaseRunner.command(
            phase: .execute, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertTrue(command.contains("-f /repo/wt/process-compose.override.yaml"), command)
    }

    func testHeadlessPhasesDisableTheTUI() {
        for phase in [ProcessComposePhase.bootstrap, .prepare, .dispose] {
            let command = PhaseRunner.command(
                phase: phase, config: worktreeConfig, binary: binary,
                workstreamID: workstreamID, selectedProcesses: []
            )
            XCTAssertTrue(command.contains("-t=false"), "\(phase): \(command)")
        }
    }

    func testExecuteKeepsTheTUI() {
        let command = PhaseRunner.command(
            phase: .execute, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertFalse(command.contains("-t=false"), command)
    }

    func testSelectedProcessesAreAppended() {
        let command = PhaseRunner.command(
            phase: .execute, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: ["bff", "api"]
        )

        XCTAssertTrue(command.hasSuffix("bff api"), command)
    }

    /// Selection applies only to execute — bootstrap runs whole or not at all.
    func testSelectionIsIgnoredForOtherPhases() {
        let command = PhaseRunner.command(
            phase: .bootstrap, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: ["bff"]
        )

        XCTAssertFalse(command.hasSuffix("bff"), command)
    }

    /// Start is prepare then execute, chained, so prepare's output lands in the
    /// surface the user is already looking at and a failing prepare stops it.
    func testStartCommandChainsPrepareIntoExecute() {
        let command = PhaseRunner.startCommand(
            config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertTrue(command.contains("-n prepare && "), command)
        XCTAssertTrue(command.hasSuffix("-n execute"), command)
    }

    func testPathsWithSpacesAreQuoted() {
        let config = ProcessComposeConfig(
            path: "/repo/my project/process-compose.yaml", isRepositoryProvided: false, overridePath: nil
        )

        let command = PhaseRunner.command(
            phase: .execute, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertTrue(command.contains("'/repo/my project/process-compose.yaml'"), command)
    }
}
