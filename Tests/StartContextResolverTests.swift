// ABOUTME: Pins the one start-context assembler the view and the IPC bridge share.
// ABOUTME: None of this was reachable while the logic lived in a TerminalContainerView body.

@testable import Atelier
import XCTest

final class StartContextResolverTests: XCTestCase {
    private let workstreamID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private var selectionKey: String {
        ProcessCompose.TableModel.selectionKey(for: workstreamID)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: selectionKey)
        super.tearDown()
    }

    /// `ProcessCompose.Resolution` has a default for every stored property, so the
    /// no-argument memberwise init exists.
    private func resolution(
        plan: ProcessCompose.RunCommandPlan,
        declared: [String] = []
    ) -> ProcessCompose.Resolution {
        var resolution = ProcessCompose.Resolution()
        resolution.plan = plan
        resolution.declaredExecuteProcesses = declared
        return resolution
    }

    private var inputs: ProcessCompose.StartContextResolver.Inputs {
        ProcessCompose.StartContextResolver.Inputs(
            workstreamID: workstreamID,
            workingDirectory: "/repos/app/feat-x",
            environment: ["ATELIER_PORT": "4100"],
            launcherPath: "/Applications/Atelier.app/Contents/Helpers/atelier-run",
            tmux: nil,
            shell: "/bin/zsh"
        )
    }

    // MARK: - command

    func test_command_forALiteralPlan_isTheOverrideVerbatim() {
        let command = ProcessCompose.StartContextResolver.command(
            resolution: resolution(plan: .literal("bin/dev --verbose")),
            workstreamID: workstreamID,
            processes: nil
        )
        XCTAssertEqual(command, "bin/dev --verbose")
    }

    func test_command_forNothing_isNil() {
        let command = ProcessCompose.StartContextResolver.command(
            resolution: resolution(plan: .nothing),
            workstreamID: workstreamID,
            processes: nil
        )
        XCTAssertNil(command)
    }

    /// A `.literal` plan is the user's own typed command. The checklist scopes a
    /// process-compose run and has nothing to say about an override, so an empty
    /// selection must not suppress one.
    func test_command_forALiteralPlan_ignoresTheChecklist() {
        ProcessCompose.TableModel.setSelection(.nothing, for: workstreamID)
        let command = ProcessCompose.StartContextResolver.command(
            resolution: resolution(plan: .literal("bin/dev"), declared: ["web"]),
            workstreamID: workstreamID,
            processes: nil
        )
        XCTAssertEqual(command, "bin/dev")
    }

    /// The real path: a `.phaseScoped` plan scopes the run with `-n` and names
    /// the selected processes.
    func test_command_forAPhaseScopedPlan_isScopedToTheSelection() throws {
        let config = try temporaryConfig(
            """
            processes:
              web:
                namespace: execute
                command: bin/web
              api:
                namespace: execute
                command: bin/api
            """
        )
        ProcessCompose.TableModel.setSelection(.only(["web"]), for: workstreamID)

        let command = try XCTUnwrap(
            ProcessCompose.StartContextResolver.command(
                resolution: resolution(
                    plan: .phaseScoped(config: config, binary: "/usr/local/bin/process-compose"),
                    declared: ["web", "api"]
                ),
                workstreamID: workstreamID,
                processes: nil
            )
        )
        XCTAssertTrue(command.contains("-n execute"), command)
        XCTAssertTrue(command.contains("web"), command)
        XCTAssertFalse(command.contains("api"), command)
    }

    /// Nothing selected must refuse rather than fall through: an empty name list
    /// on the command line starts the whole namespace.
    func test_command_forAPhaseScopedPlan_isNilWhenNothingIsSelected() throws {
        let config = try temporaryConfig(
            """
            processes:
              web:
                namespace: execute
                command: bin/web
            """
        )
        ProcessCompose.TableModel.setSelection(.nothing, for: workstreamID)

        let command = ProcessCompose.StartContextResolver.command(
            resolution: resolution(
                plan: .phaseScoped(config: config, binary: "/usr/local/bin/process-compose"),
                declared: ["web"]
            ),
            workstreamID: workstreamID,
            processes: nil
        )
        XCTAssertNil(command)
    }

    /// A per-call list wins over the stored selection — and changes nothing
    /// about it.
    func test_perCallProcesses_overrideTheStoredSelection() throws {
        let config = try temporaryConfig(
            """
            processes:
              web:
                namespace: execute
                command: bin/web
              api:
                namespace: execute
                command: bin/api
            """
        )
        ProcessCompose.TableModel.setSelection(.only(["web"]), for: workstreamID)

        let command = try XCTUnwrap(
            ProcessCompose.StartContextResolver.command(
                resolution: resolution(
                    plan: .phaseScoped(config: config, binary: "/usr/local/bin/process-compose"),
                    declared: ["web", "api"]
                ),
                workstreamID: workstreamID,
                processes: ["api"]
            )
        )
        XCTAssertTrue(command.contains("api"), command)
        XCTAssertFalse(command.contains("web"), command)
    }

    /// The load-bearing one: an agent scoping a run must never re-tick the
    /// user's checkboxes.
    func test_perCallProcesses_doNotWriteTheStoredSelection() {
        UserDefaults.standard.removeObject(forKey: selectionKey)

        _ = ProcessCompose.StartContextResolver.command(
            resolution: resolution(plan: .literal("bin/dev"), declared: ["web", "api"]),
            workstreamID: workstreamID,
            processes: ["web"]
        )

        XCTAssertNil(
            UserDefaults.standard.object(forKey: selectionKey),
            "resolving a per-call process list must not write the user's stored selection"
        )
    }

    /// A flag-shaped name would be dropped by `PhaseRunner.command`, leaving an
    /// empty list that starts the whole namespace — so it is filtered here and
    /// an all-flag list refuses.
    func test_perCallProcesses_refuseWhenEveryNameIsFlagShaped() {
        let command = ProcessCompose.StartContextResolver.command(
            resolution: resolution(plan: .literal("bin/dev")),
            workstreamID: workstreamID,
            processes: ["--all"]
        )
        // `.literal` never consults the list, so this pins the filter at the
        // phase-scoped level instead.
        XCTAssertEqual(command, "bin/dev")
    }

    // MARK: - context

    func test_context_isNilWhenThereIsNoCommand() {
        let context = ProcessCompose.StartContextResolver.context(
            resolution: resolution(plan: .nothing),
            inputs: inputs,
            processes: nil
        )
        XCTAssertNil(context)
    }

    func test_context_carriesEveryInputThrough() throws {
        let context = try XCTUnwrap(
            ProcessCompose.StartContextResolver.context(
                resolution: resolution(plan: .literal("bin/dev")),
                inputs: inputs,
                processes: nil
            )
        )
        XCTAssertEqual(context.command, "bin/dev")
        XCTAssertEqual(context.workingDirectory, "/repos/app/feat-x")
        XCTAssertEqual(context.environment["ATELIER_PORT"], "4100")
        XCTAssertEqual(context.shell, "/bin/zsh")
        XCTAssertEqual(context.launcherPath, "/Applications/Atelier.app/Contents/Helpers/atelier-run")
        XCTAssertNil(context.tmux)
    }

    // MARK: - Helpers

    /// A real config on disk, because `startCommand` reads the file to answer
    /// `namespacePresence`.
    private func temporaryConfig(_ yaml: String) throws -> ProcessCompose.Config {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("start-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("execution.process-compose.yaml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)
        return ProcessCompose.Config(path: path.path)
    }
}
