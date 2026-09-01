// ABOUTME: Tests for dev server command resolution (browser tab auto-start).
// ABOUTME: Covers package.json detection, lockfile manager inference, and override precedence.

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
        DevCommandResolver.selectRunner(nil, for: tmpDir.path)
        for container in projectContainers {
            try? FileManager.default.removeItem(at: container)
        }
        projectContainers = []
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - package.json detection

    func testDetectsDevScriptFromPackageJSON() throws {
        try writePackageJSON(["dev": "vite"])

        let command = try XCTUnwrap(DevCommandResolver.detectPackageScript(in: tmpDir.path))

        XCTAssertEqual(command.command, "npm run dev")
        XCTAssertEqual(command.source, .packageJSON)
    }

    func testNoDevScriptReturnsNil() throws {
        try writePackageJSON(["build": "vite build"])

        XCTAssertNil(DevCommandResolver.detectPackageScript(in: tmpDir.path))
    }

    func testMissingPackageJSONReturnsNil() {
        XCTAssertNil(DevCommandResolver.detectPackageScript(in: tmpDir.path))
    }

    func testEmptyDevScriptReturnsNil() throws {
        try writePackageJSON(["dev": "   "])

        XCTAssertNil(DevCommandResolver.detectPackageScript(in: tmpDir.path))
    }

    // MARK: - Package manager inference

    func testDefaultsToNpmWithoutLockfile() {
        XCTAssertEqual(DevCommandResolver.packageManager(in: tmpDir.path), "npm")
    }

    func testBunLockfilesPickBun() throws {
        for name in ["bun.lock", "bun.lockb"] {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try Data().write(to: tmpDir.appendingPathComponent(name))
            XCTAssertEqual(
                DevCommandResolver.packageManager(in: tmpDir.path),
                "bun",
                "\(name) should select bun"
            )
            try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent(name))
        }
    }

    func testPnpmLockfilePicksPnpm() throws {
        try Data().write(to: tmpDir.appendingPathComponent("pnpm-lock.yaml"))

        XCTAssertEqual(DevCommandResolver.packageManager(in: tmpDir.path), "pnpm")
    }

    func testYarnLockfilePicksYarn() throws {
        try Data().write(to: tmpDir.appendingPathComponent("yarn.lock"))

        XCTAssertEqual(DevCommandResolver.packageManager(in: tmpDir.path), "yarn")
    }

    func testBunLockTakesPrecedenceOverYarn() throws {
        try Data().write(to: tmpDir.appendingPathComponent("bun.lockb"))
        try Data().write(to: tmpDir.appendingPathComponent("yarn.lock"))

        XCTAssertEqual(DevCommandResolver.packageManager(in: tmpDir.path), "bun")
    }

    // MARK: - Resolution precedence

    func testConfigRunScriptWinsOverEverything() throws {
        try writePackageJSON(["dev": "vite"])
        DevCommandResolver.saveOverride("npm --prefix frontend run dev", for: workstreamID)
        let config = ScriptConfig(setup: nil, run: "make serve", teardown: nil, source: ".atelier.json", loadError: nil)

        let resolved = DevCommandResolver.resolve(
            scriptConfig: config,
            workstreamID: workstreamID,
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: DevCommandResolver.savedOverride(for: workstreamID)
        )

        XCTAssertEqual(resolved?.command, "make serve")
        XCTAssertEqual(resolved?.source, .configScript)
    }

    func testOverrideBeatsPackageJSONDetection() throws {
        try writePackageJSON(["dev": "vite"])
        DevCommandResolver.saveOverride("npm run dev -- --port 3000", for: workstreamID)

        let resolved = DevCommandResolver.resolve(
            scriptConfig: .empty,
            workstreamID: workstreamID,
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: DevCommandResolver.savedOverride(for: workstreamID)
        )

        XCTAssertEqual(resolved?.command, "npm run dev -- --port 3000")
        XCTAssertEqual(resolved?.source, .override)
    }

    func testPackageJSONUsedWhenNoOverride() throws {
        try writePackageJSON(["dev": "next dev"])

        let resolved = DevCommandResolver.resolve(
            scriptConfig: .empty,
            workstreamID: workstreamID,
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertEqual(resolved?.command, "npm run dev")
        XCTAssertEqual(resolved?.source, .packageJSON)
    }

    func testNothingDetectedReturnsNil() {
        let resolved = DevCommandResolver.resolve(
            scriptConfig: .empty,
            workstreamID: workstreamID,
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

        XCTAssertEqual(command.command, "process-compose up -U")
        XCTAssertEqual(command.source, .processCompose)
        XCTAssertEqual(command.sourceDescription, "process-compose.yaml")
        XCTAssertEqual(command.trustFilePath, tmpDir.appendingPathComponent("process-compose.yaml").path)
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

    func testProcessComposeLeadsPackageJSON() throws {
        try writePackageJSON(["dev": "vite"])
        try writeProcessCompose(named: "process-compose.yaml")

        let resolved = DevCommandResolver.resolve(
            scriptConfig: .empty,
            workstreamID: workstreamID,
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertEqual(resolved?.source, .processCompose)
    }

    func testSelectedRunnerOverridesDetectionOrder() throws {
        try writePackageJSON(["dev": "vite"])
        try writeProcessCompose(named: "process-compose.yaml")
        DevCommandResolver.selectRunner(.packageJSON, for: tmpDir.path)

        let resolved = DevCommandResolver.resolve(
            scriptConfig: .empty,
            workstreamID: workstreamID,
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertEqual(resolved?.source, .packageJSON)
    }

    /// A stored choice for a runner the worktree no longer has must not leave
    /// the pane with no command at all.
    func testSelectedRunnerFallsBackWhenAbsent() throws {
        try writePackageJSON(["dev": "vite"])
        DevCommandResolver.selectRunner(.processCompose, for: tmpDir.path)

        let resolved = DevCommandResolver.resolve(
            scriptConfig: .empty,
            workstreamID: workstreamID,
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertEqual(resolved?.source, .packageJSON)
    }

    func testCandidatesListsBothRunners() throws {
        try writePackageJSON(["dev": "vite"])
        try writeProcessCompose(named: "process-compose.yaml")

        let candidates = DevCommandResolver.candidates(in: tmpDir.path, projectDirectory: tmpDir.path)

        XCTAssertEqual(candidates.map(\.source), [.processCompose, .packageJSON])
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
        XCTAssertEqual(command.trustFilePath, project.appendingPathComponent("process-compose.yaml").path)
    }

    /// Naming the base config with `-f` turns off discovery, so a worktree
    /// override has to be named too — but only when it is really there, since
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

    /// A worktree carrying its own config is saying something deliberate, and
    /// keeps discovery — so no `-f`, and its override auto-loads.
    func testWorktreeConfigWinsOverProjectDirectory() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)
        try writeProcessCompose(named: "process-compose.yaml")

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertEqual(command.command, "process-compose up -U")
        XCTAssertEqual(command.trustFilePath, tmpDir.appendingPathComponent("process-compose.yaml").path)
    }

    /// A plain checkout passes the same path for both. The fallback must not
    /// then re-find the worktree's own config and switch to the `-f` form.
    func testProjectDirectoryEqualToWorktreeIsNotSearchedTwice() throws {
        try writeProcessCompose(named: "process-compose.yaml")

        let command = try XCTUnwrap(
            DevCommandResolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path)
        )

        XCTAssertEqual(command.command, "process-compose up -U")
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
