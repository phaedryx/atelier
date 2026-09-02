// ABOUTME: Tests for dev server command resolution (browser tab auto-start).
// ABOUTME: Covers process-compose config location and per-workstream override precedence.

@testable import Atelier
import XCTest

final class DevCommandTests: XCTestCase {
    private var tmpDir: URL!
    private var projectContainers: [URL] = []
    private let workstreamID = UUID()

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        DevCommandResolver.saveOverride(nil, for: workstreamID)
        for container in projectContainers {
            try? FileManager.default.removeItem(at: container)
        }
        projectContainers = []
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Resolution precedence

    func testOverrideBeatsDetection() throws {
        try writeProcessCompose(named: "process-compose.yaml")
        DevCommandResolver.saveOverride("npm run dev -- --port 3000", for: workstreamID)

        let resolved = DevCommandResolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: DevCommandResolver.savedOverride(for: workstreamID)
        )

        XCTAssertEqual(resolved?.command, "npm run dev -- --port 3000")
        XCTAssertEqual(resolved?.source, .override)
    }

    func testLocatedConfigUsedWhenNoOverride() throws {
        try writeProcessCompose(named: "process-compose.yaml")

        let resolved = DevCommandResolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertEqual(resolved?.source, .processCompose)
    }

    /// A `dev` script in package.json used to be a second detected runner, with
    /// a picker to choose between it and process-compose. It is not consulted
    /// at all any more: the override is the escape hatch it was standing in for.
    func testPackageJSONIsNotConsulted() throws {
        try writePackageJSON(["dev": "vite"])

        XCTAssertNil(DevCommandResolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        ))
    }

    func testNothingDetectedReturnsNil() {
        let resolved = DevCommandResolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertNil(resolved)
    }

    // MARK: - process-compose detection

    func testDetectsProcessComposeConfig() throws {
        try writeProcessCompose(named: "process-compose.yaml")

        let command = try XCTUnwrap(DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path))

        XCTAssertEqual(
            command.command,
            "process-compose up -U -f \(CommandBuilder.shellQuote(tmpDir.appendingPathComponent("process-compose.yaml").path))"
        )
        XCTAssertEqual(command.source, .processCompose)
        XCTAssertEqual(command.sourceDescription, "process-compose.yaml")
    }

    func testDetectsShortYamlExtension() throws {
        try writeProcessCompose(named: "process-compose.yml")

        let command = try XCTUnwrap(DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path))

        XCTAssertEqual(command.sourceDescription, "process-compose.yml")
    }

    /// process-compose would discover a bare `compose.yaml`, but that name means
    /// docker compose far more often, and running the wrong tool is worse than
    /// offering nothing.
    func testIgnoresBareComposeFile() throws {
        try "services: {}".write(
            to: tmpDir.appendingPathComponent("compose.yaml"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNil(DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path))
    }

    // MARK: - Config in the project directory

    /// The bare-repo layout keeps one config beside the worktrees, where git
    /// cannot see it and every worktree shares it.
    func testFindsConfigInProjectDirectory() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertEqual(
            command.command,
            "process-compose up -U -f \(CommandBuilder.shellQuote(project.appendingPathComponent("process-compose.yaml").path))"
        )
    }

    /// Every file is named, so a worktree override beside a project-directory
    /// base is named too — but only when it is really there, since
    /// process-compose treats a missing `-f` file as fatal.
    func testPassesWorktreeOverrideAlongsideProjectConfig() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)
        try writeProcessCompose(named: "process-compose.override.yaml")

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertTrue(command.command.hasSuffix(
            "-f \(CommandBuilder.shellQuote(tmpDir.appendingPathComponent("process-compose.override.yaml").path))"
        ), command.command)
    }

    /// A worktree carrying its own config is saying something deliberate, and it
    /// wins. It is named with `-f` like every other file, so Start runs exactly
    /// what bootstrap and dispose would.
    func testWorktreeConfigWinsOverProjectDirectory() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)
        try writeProcessCompose(named: "process-compose.yaml")

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertEqual(
            command.command,
            "process-compose up -U -f \(CommandBuilder.shellQuote(tmpDir.appendingPathComponent("process-compose.yaml").path))"
        )
        XCTAssertFalse(command.command.contains(project.path), command.command)
    }

    /// A plain checkout passes the same path for both. The fallback must not
    /// then re-find the worktree's own config and name it twice.
    func testProjectDirectoryEqualToWorktreeIsNotSearchedTwice() throws {
        try writeProcessCompose(named: "process-compose.yaml")

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path)
        )

        XCTAssertEqual(
            command.command,
            "process-compose up -U -f \(CommandBuilder.shellQuote(tmpDir.appendingPathComponent("process-compose.yaml").path))"
        )
    }

    /// Start must name the same files the gated phases name. Discovery would
    /// have loaded `compose.yaml` here and never read `process-compose.yaml`
    /// (verified against v1.122.0), so a Start that relied on it would run a
    /// different file from the one bootstrap and dispose run.
    func testStartNamesTheSameFilesTheGatedPhasesDo() throws {
        try writeProcessCompose(named: "process-compose.yaml")
        try "services: {}".write(
            to: tmpDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8
        )
        let config = try XCTUnwrap(
            ProcessComposeConfig.locate(worktree: tmpDir.path, projectDirectory: tmpDir.path)
        )

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path)
        )

        for file in config.loadedFiles {
            XCTAssertTrue(command.command.contains(CommandBuilder.shellQuote(file)), command.command)
        }
        XCTAssertFalse(command.command.contains("compose.yaml -f"), command.command)
        XCTAssertFalse(command.command.hasSuffix(CommandBuilder.shellQuote(
            tmpDir.appendingPathComponent("compose.yaml").path
        )), command.command)
    }

    func testNoConfigInEitherPlace() throws {
        let project = try makeProjectContainer()

        XCTAssertNil(DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path))
    }

    private func makeProjectContainer() throws -> URL {
        let project = tmpDir.deletingLastPathComponent().appendingPathComponent("project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        projectContainers.append(project)
        return project
    }

    private func writeProcessCompose(named name: String, in directory: URL) throws {
        try "processes:\n  web:\n    command: echo hi\n".write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeProcessCompose(named name: String) throws {
        try "processes:\n  web:\n    command: echo hi\n".write(
            to: tmpDir.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Override persistence

    func testOverrideRoundTrip() {
        DevCommandResolver.saveOverride("bun run dev", for: workstreamID)

        XCTAssertEqual(DevCommandResolver.savedOverride(for: workstreamID), "bun run dev")
    }

    func testEmptyOverrideClearsSavedValue() {
        DevCommandResolver.saveOverride("bun run dev", for: workstreamID)
        DevCommandResolver.saveOverride(nil, for: workstreamID)

        XCTAssertNil(DevCommandResolver.savedOverride(for: workstreamID))
    }

    func testBlankOverrideIsTreatedAsAbsent() {
        DevCommandResolver.saveOverride("   ", for: workstreamID)

        XCTAssertNil(DevCommandResolver.savedOverride(for: workstreamID))
    }

    // MARK: - Helpers

    private func writePackageJSON(_ scripts: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["scripts": scripts])
        try data.write(to: tmpDir.appendingPathComponent("package.json"))
    }
}
