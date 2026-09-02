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

    /// Only `execute` gets the bare path. bootstrap now runs in the background
    /// behind an already-open terminal, so it and execute overlap in time, and
    /// a second `up` on a path a live server holds rebinds it — stranding the
    /// first server rather than refusing.
    func testHeadlessPhasesGetTheirOwnSocketPath() {
        let execute = PhaseRunner.socketPath(for: workstreamID, phase: .execute)
        let bootstrap = PhaseRunner.socketPath(for: workstreamID, phase: .bootstrap)
        let dispose = PhaseRunner.socketPath(for: workstreamID, phase: .dispose)

        XCTAssertEqual(execute, PhaseRunner.socketPath(for: workstreamID))
        XCTAssertEqual(Set([execute, bootstrap, dispose]).count, 3)
        XCTAssertTrue(bootstrap.hasSuffix("-bootstrap.sock"), bootstrap)
        XCTAssertLessThan(bootstrap.utf8.count, 104, "the longest suffix must still fit sun_path")
        XCTAssertTrue(dispose.hasSuffix("-dispose.sock"), dispose)
    }

    /// `--keep-project` is off by default, because `startCommand` chains
    /// prepare into execute with `&&` and a prepare that never exits would
    /// never let execute start.
    func testKeepProjectIsOptInAndAbsentFromTheStartChain() {
        let plain = PhaseRunner.command(
            phase: .bootstrap, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )
        let kept = PhaseRunner.command(
            phase: .bootstrap, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: [], keepProject: true
        )
        let start = PhaseRunner.startCommand(
            config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertFalse(plain.contains("--keep-project"), plain)
        XCTAssertTrue(kept.contains("--keep-project"), kept)
        XCTAssertFalse(start.contains("--keep-project"), start)
    }

    /// A worktree config is named too, and that is the security property, not an
    /// implementation detail. Leaving it unnamed left process-compose's own
    /// discovery on, and discovery loads files Atelier neither displays nor
    /// fingerprints — `compose.yaml` above all, which wins outright over
    /// `process-compose.yaml` (verified against v1.122.0). Naming every file is
    /// what makes the executed set equal the approved set.
    func testWorktreeConfigIsNamedSoDiscoveryCannotAddFiles() {
        let command = PhaseRunner.command(
            phase: .execute, config: worktreeConfig, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertTrue(command.contains("-f /repo/wt/process-compose.yaml"), command)
        XCTAssertTrue(command.contains("-n execute"), command)
    }

    /// Every loaded file is named, in order, so nothing is left to discovery.
    func testEveryLoadedFileIsNamed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try writeConfig("""
          web:
            namespace: execute
            command: "true"
        """, in: dir)
        try "processes: {}".write(
            to: dir.appendingPathComponent("process-compose.override.yml"),
            atomically: true, encoding: .utf8
        )

        let command = PhaseRunner.command(
            phase: .execute, config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertEqual(config.loadedFiles.count, 2, "\(config.loadedFiles)")
        for file in config.loadedFiles {
            XCTAssertTrue(command.contains("-f \(file)"), command)
        }
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
    /// A real config (not a synthetic nonexistent path) so this exercises
    /// genuine "prepare is declared" parsing rather than the fail-open branch
    /// of `namespaceIsConfidentlyEmpty` — a worktree-style config, which is
    /// named with `-f` like every other. Passes a selection to check the other
    /// half of the chain that its sibling in the "namespace-aware" section
    /// below does not: prepare always runs its whole namespace regardless of
    /// selection, so "bff" must land exactly once, at the end, on execute.
    func testStartCommandChainsPrepareIntoExecute() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try writeConfig("""
          setup:
            namespace: prepare
            command: "true"
          web:
            namespace: execute
            command: "true"
        """, in: dir)

        let command = PhaseRunner.startCommand(
            config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: ["bff"]
        )

        XCTAssertTrue(command.contains("-n prepare && "), command)
        XCTAssertTrue(command.hasSuffix("-n execute bff"), command)
        XCTAssertEqual(command.components(separatedBy: "bff").count, 2, "\"bff\" must appear only on execute: \(command)")
    }

    /// The whole point of the integration: with a config present and a binary
    /// available, Start runs process-compose rather than a dev script. Real
    /// config content (not a synthetic nonexistent path), so this exercises
    /// genuine "prepare is declared" parsing rather than the fail-open branch
    /// of `namespaceIsConfidentlyEmpty` — a project-directory-style config
    /// (`isRepositoryProvided: false`), so this also pins the `-f` shape and
    /// process selection together, distinct from the worktree-style sibling
    /// above.
    func testStartCommandIsUsedWhenAConfigExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("process-compose.yaml")
        try """
        processes:
          setup:
            namespace: prepare
            command: "true"
          bff:
            namespace: execute
            command: "true"
        """.write(to: path, atomically: true, encoding: .utf8)
        let config = ProcessComposeConfig(path: path.path, isRepositoryProvided: false, overridePath: nil)

        let command = PhaseRunner.startCommand(
            config: config, binary: binary,
            workstreamID: workstreamID, selectedProcesses: ["bff"]
        )

        XCTAssertTrue(command.contains("-n prepare"), command)
        XCTAssertTrue(command.contains("-f \(path.path)"), command)
        XCTAssertTrue(command.contains("-n execute"), command)
        XCTAssertTrue(command.hasSuffix("bff"), command)
    }

    // MARK: - Namespace-aware prepare chaining

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ body: String, in dir: URL) throws -> ProcessComposeConfig {
        let path = dir.appendingPathComponent("process-compose.yaml")
        try "processes:\n\(body)".write(to: path, atomically: true, encoding: .utf8)
        return ProcessComposeConfig(path: path.path, isRepositoryProvided: true, overridePath: nil)
    }

    /// A config that declares both namespaces keeps the existing chain.
    func testStartCommandChainsBothWhenConfigDeclaresPrepare() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try writeConfig("""
          setup:
            namespace: prepare
            command: "true"
          web:
            namespace: execute
            command: "true"
        """, in: dir)

        let command = PhaseRunner.startCommand(
            config: config, binary: binary, workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertTrue(command.contains("-n prepare && "), command)
        XCTAssertTrue(command.hasSuffix("-n execute"), command)
    }

    /// The bug this guards against: process-compose does not exit when told
    /// to run an empty namespace, it idles forever, so chaining `up -n
    /// prepare` ahead of execute for a config that never declares one would
    /// hang Start forever. Only `execute` should run.
    func testStartCommandRunsOnlyExecuteWhenPrepareIsNotDeclared() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try writeConfig("""
          web:
            namespace: execute
            command: "true"
        """, in: dir)

        let command = PhaseRunner.startCommand(
            config: config, binary: binary, workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertFalse(command.contains("prepare"), command)
        XCTAssertTrue(command.contains("-n execute"), command)
        XCTAssertFalse(command.contains("&&"), command)
    }

    /// A process with no `namespace:` key belongs to process-compose's own
    /// default namespace, not to `prepare` — a config with only such
    /// processes (the shape of a project that predates the namespace
    /// convention) must not be treated as declaring `prepare`.
    func testStartCommandTreatsUnnamespacedProcessesAsNotDeclaringPrepare() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try writeConfig("""
          web:
            command: "true"
        """, in: dir)

        let command = PhaseRunner.startCommand(
            config: config, binary: binary, workstreamID: workstreamID, selectedProcesses: []
        )

        XCTAssertFalse(command.contains("prepare"), command)
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
