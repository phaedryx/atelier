// ABOUTME: Tests that Start never runs the un-`-n`'d process-compose command.
// ABOUTME: One invariant, enumerated over every way the gated path can fail.

@testable import Atelier
import XCTest

final class RunCommandPlanTests: XCTestCase {
    private let config = ProcessCompose.Config(
        path: "/repo/ws/process-compose.yaml",
        isRepositoryProvided: true
    )

    /// The string a `.processCompose` source carries, for reference. It is what
    /// the Execution pane *displays*; nothing may execute it.
    private let displayCommand = "process-compose up -U -f /repo/ws/process-compose.yaml"

    private func processComposeCommand() -> DevCommand {
        DevCommand(
            command: displayCommand,
            source: .processCompose,
            sourceDescription: "process-compose.yaml"
        )
    }

    // MARK: - Temp configs

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func writtenConfig(_ body: String) throws -> ProcessCompose.Config {
        let path = tmpDir.appendingPathComponent("process-compose.yaml")
        try body.write(to: path, atomically: true, encoding: .utf8)
        return ProcessCompose.Config(path: path.path, isRepositoryProvided: true)
    }

    // MARK: - The execute namespace has to exist

    /// `up -n execute` against a namespace no process declares does not fail and
    /// does not exit — measured against v1.122.0, it idles indefinitely with no
    /// output. Start would open a TUI with an empty process list and nothing to
    /// read. A project declaring only `verify` is the realistic shape.
    func testAConfigDeclaringNoExecuteProcessesProducesNothing() throws {
        let config = try writtenConfig("""
        processes:
          rspec:
            namespace: verify
            command: "true"
        """)

        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: "/opt/homebrew/bin/process-compose"
        )

        XCTAssertEqual(plan, .nothing)
    }

    func testAConfigDeclaringExecuteRuns() throws {
        let config = try writtenConfig("""
        processes:
          bff:
            namespace: execute
            command: "true"
        """)

        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: "/opt/homebrew/bin/process-compose"
        )

        XCTAssertEqual(plan, .phaseScoped(config: config, binary: "/opt/homebrew/bin/process-compose"))
    }

    /// `.empty` only, never `.unknown`. A config Atelier cannot decode but
    /// process-compose accepts must still start: refusing on a failure to *read*
    /// turns a parse gap into a permanently dead Start button, which is worse
    /// than letting process-compose have its own opinion. Same asymmetry
    /// `PhaseRunner.startCommand` applies to `prepare`.
    func testAnUnparseableConfigStillRuns() throws {
        let config = try writtenConfig("""
        version: "0.5"
        """)
        XCTAssertEqual(config.namespacePresence("execute"), .unknown, "precondition")

        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: "/opt/homebrew/bin/process-compose"
        )

        XCTAssertEqual(plan, .phaseScoped(config: config, binary: "/opt/homebrew/bin/process-compose"))
    }

    /// **Nothing but this test enforces the agreement.** `unavailableReason`
    /// hand-mirrors `plan`'s preconditions in the same order; a sixth added to
    /// one and not the other compiles fine and renders an enabled Start button
    /// that does nothing in silence — the exact disagreement this type exists to
    /// prevent.
    func testCanRunAndUnavailableReasonAgreeOnAnEmptyExecuteNamespace() throws {
        let config = try writtenConfig("""
        processes:
          rspec:
            namespace: verify
            command: "true"
        """)
        let binary = "/opt/homebrew/bin/process-compose"

        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: binary
        )
        let reason = ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: processComposeCommand(), config: config, binary: binary, isEnabled: true
        )

        XCTAssertFalse(plan.canRun)
        XCTAssertEqual(reason?.contains("no execute processes"), true, String(describing: reason))
    }

    /// The other half of the same agreement: a config that can run must not be
    /// explained away as unavailable.
    func testARunnableConfigHasNoUnavailableReason() throws {
        let config = try writtenConfig("""
        processes:
          bff:
            namespace: execute
            command: "true"
        """)
        let binary = "/opt/homebrew/bin/process-compose"

        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: binary
        )
        let reason = ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: processComposeCommand(), config: config, binary: binary, isEnabled: true
        )

        XCTAssertTrue(plan.canRun)
        XCTAssertNil(reason)
    }

    // MARK: - The invariant

    /// The state that reopened the bypass after the toggle guard closed it:
    /// integration on, a worktree config present, and `resolveBinary()` nil
    /// because process-compose sits somewhere the search list does not look
    /// (`go install`, nix, mise and asdf shims are all on PATH but outside
    /// `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`).
    ///
    /// The old code fell through to the display string here. Since that string
    /// has no `-n`, process-compose would run every namespace — `bootstrap` and
    /// `dispose` included — with no approval; and because `scriptCommand` wraps
    /// it in `$SHELL -lic`, PATH would resolve the very binary `resolveBinary`
    /// had just failed to find.
    func testUnresolvableBinaryProducesNothingRatherThanTheUngatedCommand() {
        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: nil
        )

        XCTAssertEqual(plan, .nothing)
    }

    /// The same hole from the other side: a config that could not be located
    /// while the dev command still claims a process-compose source.
    func testMissingConfigProducesNothingRatherThanTheUngatedCommand() {
        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: nil, binary: "/opt/homebrew/bin/process-compose"
        )

        XCTAssertEqual(plan, .nothing)
    }

    /// The property that makes this structural rather than another precondition
    /// guard: **no** combination of inputs may yield the display string. If a
    /// future precondition is added and forgotten, this still holds, because
    /// there is no branch that returns it.
    func testNoInputCombinationEverYieldsTheDisplayCommand() {
        for configOption in [config, nil] {
            for binaryOption in ["/opt/homebrew/bin/process-compose", nil] {
                let plan = ProcessCompose.RunCommandPlan.plan(
                    devCommand: processComposeCommand(),
                    config: configOption,
                    binary: binaryOption
                )
                XCTAssertNotEqual(
                    plan, .literal(displayCommand),
                    "config: \(String(describing: configOption?.path)), binary: \(String(describing: binaryOption))"
                )
            }
        }
    }

    // MARK: - The paths that should work

    func testFullyUsableProcessComposeRunIsPhaseScoped() {
        let binary = "/opt/homebrew/bin/process-compose"

        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: binary
        )

        XCTAssertEqual(plan, .phaseScoped(config: config, binary: binary))
    }

    /// The override is the user's own text, gated by nothing, and it must keep
    /// working whatever state process-compose is in — otherwise the escape
    /// hatch would close exactly when it is needed.
    func testOverrideRunsLiterallyEvenWithNoBinaryOrConfig() {
        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: DevCommand(command: "npm run dev", source: .override, sourceDescription: nil),
            config: nil,
            binary: nil
        )

        XCTAssertEqual(plan, .literal("npm run dev"))
    }

    func testOverrideStillWinsWhenProcessComposeIsFullyUsable() {
        let plan = ProcessCompose.RunCommandPlan.plan(
            devCommand: DevCommand(command: "just dev", source: .override, sourceDescription: nil),
            config: config,
            binary: "/opt/homebrew/bin/process-compose"
        )

        XCTAssertEqual(plan, .literal("just dev"))
    }

    func testNoDevCommandIsNothing() {
        XCTAssertEqual(
            ProcessCompose.RunCommandPlan.plan(devCommand: nil, config: config, binary: "/bin/pc"),
            .nothing
        )
    }

    // MARK: - One decision, not two

    /// `canRun` exists so the Start button's enablement and `doStartRun`'s guard
    /// read the same value. This pins it to the plans that actually yield a
    /// command: a `canRun` that drifted from that would put the pane back where
    /// it was, enabling Start for a plan that runs nothing.
    func testCanRunIsTrueForExactlyThePlansThatYieldACommand() {
        XCTAssertTrue(ProcessCompose.RunCommandPlan.literal("npm run dev").canRun)
        XCTAssertTrue(ProcessCompose.RunCommandPlan.phaseScoped(config: config, binary: "/bin/pc").canRun)
        XCTAssertFalse(ProcessCompose.RunCommandPlan.nothing.canRun)
    }

    /// The C2 state in full: integration on, config present, binary
    /// unresolvable. Start must be *both* disabled and explained — it used to be
    /// neither, rendering an enabled button that did nothing in silence.
    func testAnUnresolvableBinaryIsBothRefusedAndExplained() {
        let devCommand = processComposeCommand()

        XCTAssertFalse(
            ProcessCompose.RunCommandPlan.plan(devCommand: devCommand, config: config, binary: nil).canRun
        )
        XCTAssertNotNil(ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: devCommand, config: config, binary: nil, isEnabled: true
        ))
    }

    func testAMissingConfigIsAlsoExplained() {
        XCTAssertNotNil(ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: processComposeCommand(), config: nil, binary: "/bin/pc", isEnabled: true
        ))
    }

    /// A switched-off integration and a project with no config both arrive as
    /// `devCommand == nil`, and they want opposite advice — turn the setting on,
    /// versus write a config. Only the first gets a reason; the second is what
    /// the pane's own "add a process-compose.yaml" copy already says.
    func testTheSwitchedOffIntegrationSaysSoRatherThanLookingLikeAMissingConfig() {
        XCTAssertNotNil(ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: nil, config: nil, binary: nil, isEnabled: false
        ))
        XCTAssertNil(ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: nil, config: nil, binary: nil, isEnabled: true
        ))
    }

    /// A usable run has nothing to explain, and neither does the user's own
    /// override — no precondition of theirs can fail.
    func testAUsableRunAndAnOverrideNeedNoExplanation() {
        XCTAssertNil(ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: processComposeCommand(), config: config, binary: "/bin/pc", isEnabled: true
        ))
        XCTAssertNil(ProcessCompose.RunCommandPlan.unavailableReason(
            devCommand: DevCommand(command: "npm run dev", source: .override, sourceDescription: nil),
            config: nil, binary: nil, isEnabled: true
        ))
    }
}
