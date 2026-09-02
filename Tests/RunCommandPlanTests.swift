// ABOUTME: Tests that Start never runs the un-`-n`'d process-compose command.
// ABOUTME: One invariant, enumerated over every way the gated path can fail.

@testable import Atelier
import XCTest

final class RunCommandPlanTests: XCTestCase {
    private let config = ProcessComposeConfig(
        path: "/repo/ws/process-compose.yaml",
        isRepositoryProvided: true,
        overridePath: nil
    )

    /// The string a `.processCompose` source carries, for reference. It is what
    /// the Environment pane *displays*; nothing may execute it.
    private let displayCommand = "process-compose up -U -f /repo/ws/process-compose.yaml"

    private func processComposeCommand() -> DevCommand {
        DevCommand(
            command: displayCommand,
            source: .processCompose,
            sourceDescription: "process-compose.yaml"
        )
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
        let plan = RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: nil
        )

        XCTAssertEqual(plan, .nothing)
    }

    /// The same hole from the other side: a config that could not be located
    /// while the dev command still claims a process-compose source.
    func testMissingConfigProducesNothingRatherThanTheUngatedCommand() {
        let plan = RunCommandPlan.plan(
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
                let plan = RunCommandPlan.plan(
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

        let plan = RunCommandPlan.plan(
            devCommand: processComposeCommand(), config: config, binary: binary
        )

        XCTAssertEqual(plan, .phaseScoped(config: config, binary: binary))
    }

    /// The override is the user's own text, gated by nothing, and it must keep
    /// working whatever state process-compose is in — otherwise the escape
    /// hatch would close exactly when it is needed.
    func testOverrideRunsLiterallyEvenWithNoBinaryOrConfig() {
        let plan = RunCommandPlan.plan(
            devCommand: DevCommand(command: "npm run dev", source: .override, sourceDescription: nil),
            config: nil,
            binary: nil
        )

        XCTAssertEqual(plan, .literal("npm run dev"))
    }

    func testOverrideStillWinsWhenProcessComposeIsFullyUsable() {
        let plan = RunCommandPlan.plan(
            devCommand: DevCommand(command: "just dev", source: .override, sourceDescription: nil),
            config: config,
            binary: "/opt/homebrew/bin/process-compose"
        )

        XCTAssertEqual(plan, .literal("just dev"))
    }

    func testNoDevCommandIsNothing() {
        XCTAssertEqual(
            RunCommandPlan.plan(devCommand: nil, config: config, binary: "/bin/pc"),
            .nothing
        )
    }
}
