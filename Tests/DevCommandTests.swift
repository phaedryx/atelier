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
        DevCommand.Resolver.saveOverride(nil, for: workstreamID)
        for container in projectContainers {
            try? FileManager.default.removeItem(at: container)
        }
        projectContainers = []
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Detection is not gated on a switch

    // There used to be five tests here, all about
    // `ProcessCompose.Settings.isEnabled` gating `detectProcessCompose`. They
    // are gone with the switch: process-compose is a requirement rather than an
    // integration, so a located config is always detected.
    //
    // Nothing they were protecting was lost. The security case they stated —
    // that `detectProcessCompose` emits `process-compose up -U -f <files>` with
    // no `-n`, so running it would run `bootstrap` and `dispose` past
    // `PhasePolicy` — does not rest on this guard and has not since
    // `ProcessCompose.RunCommandPlan` took the invariant to the consumer. The
    // switch being off was *itself* one of the four routes by which that hole
    // reopened, which is the point: `RunCommandPlanTests` pins that no
    // combination of inputs yields the un-`-n`'d string, and removing a
    // precondition cannot reopen what is no longer defended by enumerating
    // preconditions.
    //
    // The one case worth keeping is the override, because it is the escape
    // hatch and it must still win over a config that is now always found.

    func testTheOverrideStillBeatsAnAlwaysDetectedConfig() throws {
        try writeProcessCompose(named: "process-compose.yaml")
        DevCommand.Resolver.saveOverride("npm run dev", for: workstreamID)

        let resolved = DevCommand.Resolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: DevCommand.Resolver.savedOverride(for: workstreamID)
        )

        XCTAssertEqual(resolved?.command, "npm run dev")
        XCTAssertEqual(resolved?.source, .override)
    }

    /// A config in the project directory is the user's own and is detected the
    /// same way a worktree's is — there is no switch left that could make one
    /// invisible.
    func testAProjectDirectoryConfigIsDetected() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)

        XCTAssertEqual(
            DevCommand.Resolver.detectProcessCompose(
                in: tmpDir.path, projectDirectory: project.path
            )?.source,
            .processCompose
        )
    }

    // MARK: - Resolution precedence

    func testOverrideBeatsDetection() throws {
        try writeProcessCompose(named: "process-compose.yaml")
        DevCommand.Resolver.saveOverride("npm run dev -- --port 3000", for: workstreamID)

        let resolved = DevCommand.Resolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: DevCommand.Resolver.savedOverride(for: workstreamID)
        )

        XCTAssertEqual(resolved?.command, "npm run dev -- --port 3000")
        XCTAssertEqual(resolved?.source, .override)
    }

    func testLocatedConfigUsedWhenNoOverride() throws {
        try writeProcessCompose(named: "process-compose.yaml")

        let resolved = DevCommand.Resolver.resolve(
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

        XCTAssertNil(DevCommand.Resolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        ))
    }

    func testNothingDetectedReturnsNil() {
        let resolved = DevCommand.Resolver.resolve(
            workingDirectory: tmpDir.path,
            projectDirectory: tmpDir.path,
            override: nil
        )

        XCTAssertNil(resolved)
    }

    // MARK: - process-compose detection

    func testDetectsProcessComposeConfig() throws {
        try writeProcessCompose(named: "process-compose.yaml")

        let command = try XCTUnwrap(DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path))

        XCTAssertEqual(
            command.command,
            "process-compose up -U -f \(CommandBuilder.shellQuote(tmpDir.appendingPathComponent("process-compose.yaml").path))"
        )
        XCTAssertEqual(command.source, .processCompose)
        XCTAssertEqual(command.sourceDescription, "process-compose.yaml")
    }

    func testDetectsShortYamlExtension() throws {
        try writeProcessCompose(named: "process-compose.yml")

        let command = try XCTUnwrap(DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path))

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

        XCTAssertNil(DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path))
    }

    // MARK: - Config in the project directory

    /// The bare-repo layout keeps one config beside the worktrees, where git
    /// cannot see it and every worktree shares it.
    func testFindsConfigInProjectDirectory() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)

        let command = try XCTUnwrap(
            DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertEqual(
            command.command,
            "process-compose up -U -f \(CommandBuilder.shellQuote(project.appendingPathComponent("process-compose.yaml").path))"
        )
    }

    /// One config is one file. A `process-compose.override.yaml` in the
    /// worktree is not merged into a project-directory base any more — a
    /// worktree that wants its own arrangement names its own
    /// `atelier.process-compose.yaml` instead — so the override name must not
    /// reach the command.
    func testDoesNotPassAWorktreeOverrideAlongsideProjectConfig() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)
        try writeProcessCompose(named: "process-compose.override.yaml")

        let command = try XCTUnwrap(
            DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertFalse(command.command.contains("override"), command.command)
        XCTAssertTrue(command.command.hasSuffix(
            "-f \(CommandBuilder.shellQuote(project.appendingPathComponent("process-compose.yaml").path))"
        ), command.command)
    }

    /// An `atelier.`-prefixed file in the worktree outranks everything, so it is
    /// the one Start's file list names.
    func testAtelierNamedWorktreeConfigWins() throws {
        let project = try makeProjectContainer()
        try writeProcessCompose(named: "process-compose.yaml", in: project)
        try writeProcessCompose(named: "atelier.process-compose.yaml")

        let command = try XCTUnwrap(
            DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
        )

        XCTAssertTrue(command.command.hasSuffix(
            "-f \(CommandBuilder.shellQuote(tmpDir.appendingPathComponent("atelier.process-compose.yaml").path))"
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
            DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path)
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
            DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path)
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
            ProcessCompose.Config.locate(worktree: tmpDir.path, projectDirectory: tmpDir.path)
        )

        let command = try XCTUnwrap(
            DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: tmpDir.path)
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

        XCTAssertNil(DevCommand.Resolver.detectProcessCompose(in: tmpDir.path, projectDirectory: project.path))
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
        DevCommand.Resolver.saveOverride("bun run dev", for: workstreamID)

        XCTAssertEqual(DevCommand.Resolver.savedOverride(for: workstreamID), "bun run dev")
    }

    func testEmptyOverrideClearsSavedValue() {
        DevCommand.Resolver.saveOverride("bun run dev", for: workstreamID)
        DevCommand.Resolver.saveOverride(nil, for: workstreamID)

        XCTAssertNil(DevCommand.Resolver.savedOverride(for: workstreamID))
    }

    func testBlankOverrideIsTreatedAsAbsent() {
        DevCommand.Resolver.saveOverride("   ", for: workstreamID)

        XCTAssertNil(DevCommand.Resolver.savedOverride(for: workstreamID))
    }

    // MARK: - Helpers

    private func writePackageJSON(_ scripts: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["scripts": scripts])
        try data.write(to: tmpDir.appendingPathComponent("package.json"))
    }

    // MARK: - The stored-override corpse of route five

    /// The exact shape `detectProcessCompose` builds. A value like this saved
    /// before the Customize seeding was fixed would otherwise be rehydrated as
    /// an `.override` and run literally, past PhasePolicy, on every Start.
    func testAStoredUnscopedProcessComposeCommandIsIgnored() throws {
        let dir = try makeWorktreeWithConfig()

        let resolved = DevCommand.Resolver.resolve(
            workingDirectory: dir,
            projectDirectory: dir,
            override: "process-compose up -U -f '\(dir)/process-compose.yaml'"
        )

        XCTAssertEqual(resolved?.source, .processCompose, "must not be honoured as an override")
    }

    func testAnOverrideThatNamesANamespaceIsHonoured() throws {
        let dir = try makeWorktreeWithConfig()

        let resolved = DevCommand.Resolver.resolve(
            workingDirectory: dir,
            projectDirectory: dir,
            override: "process-compose up -n execute -f x.yaml"
        )

        XCTAssertEqual(resolved?.source, .override)
    }

    func testAnOrdinaryOverrideIsUntouched() throws {
        let dir = try makeWorktreeWithConfig()

        let resolved = DevCommand.Resolver.resolve(
            workingDirectory: dir,
            projectDirectory: dir,
            override: "pnpm dev"
        )

        XCTAssertEqual(resolved?.command, "pnpm dev")
        XCTAssertEqual(resolved?.source, .override)
    }

    func testSavingAnUnscopedProcessComposeCommandIsRefused() {
        let id = UUID()
        defer { DevCommand.Resolver.saveOverride(nil, for: id) }

        DevCommand.Resolver.saveOverride("process-compose up -U -f a.yaml", for: id)

        XCTAssertNil(DevCommand.Resolver.savedOverride(for: id))
    }

    func testSavingAScopedCommandStillWorks() {
        let id = UUID()
        defer { DevCommand.Resolver.saveOverride(nil, for: id) }

        DevCommand.Resolver.saveOverride("process-compose up -n execute", for: id)

        XCTAssertEqual(DevCommand.Resolver.savedOverride(for: id), "process-compose up -n execute")
    }

    /// Word boundaries: a path or process name containing "up" is not the
    /// subcommand, and must not make an ordinary command look dangerous.
    /// Verified against process-compose 1.122.0: with no subcommand the root
    /// command runs the project, and a `bootstrap` process in the named file
    /// executes. Requiring the word `up` let this straight through.
    func testABareInvocationWithNoSubcommandIsUnscoped() {
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose -f a.yaml"))
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose"))
        XCTAssertTrue(
            DevCommand.Resolver.isUnscopedProcessComposeCommand("/opt/homebrew/bin/process-compose -U -f a.yaml")
        )
    }

    /// Splitting on whitespace and quotes alone read this as the word `up;`.
    func testShellPunctuationDoesNotHideTheSubcommand() {
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose up; echo done"))
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose up&"))
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("(process-compose up)"))
    }

    /// pflag shorthand: both of these do scope the run.
    func testAttachedNamespaceShorthandCountsAsScoped() {
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose up -nexecute"))
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose up -n=execute"))
        XCTAssertFalse(
            DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose up --namespace=execute")
        )
    }

    /// A real subcommand is not the root command and does not run the project.
    func testANonRunningSubcommandIsNotUnscoped() {
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose down"))
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose version"))
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose attach"))
    }

    func testTheShapeCheckDoesNotFireOnLookalikes() {
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("pnpm dev"))
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("./bin/upload --all"))
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose down"))
        XCTAssertFalse(DevCommand.Resolver.isUnscopedProcessComposeCommand("cd up-tools && process-compose down"))
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("process-compose up -U -f a.yaml"))
        XCTAssertTrue(DevCommand.Resolver.isUnscopedProcessComposeCommand("PROCESS-COMPOSE UP"))
    }

    private func makeWorktreeWithConfig() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "processes:\n  web:\n    namespace: execute\n    command: \"true\"\n"
            .write(to: dir.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8)
        return dir.path
    }
}
