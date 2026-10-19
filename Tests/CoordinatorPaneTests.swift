// ABOUTME: Tests for CoordinatorLaunch, the pure half of the group coordinator's pane.
// ABOUTME: What the pane will run and where; nothing here creates a terminal surface.

@testable import Atelier
import XCTest

final class CoordinatorPaneTests: XCTestCase {
    private let group = Workstream.Group(name: "Billing")

    private var project: Project {
        Project(name: "P", directory: "/p", checkoutDirectory: "/p/main", groups: [group])
    }

    private func inputs(
        claudePath: String? = "/usr/bin/claude",
        tmuxPath: String? = nil,
        tmuxMode: Bool = false
    ) -> CoordinatorLaunch.Inputs {
        CoordinatorLaunch.Inputs(
            claudePath: claudePath,
            tmuxPath: tmuxPath,
            tmuxMode: tmuxMode,
            supportsSessionName: true,
            agentIPC: false,
            defaultBranch: "main"
        )
    }

    func testPlanIsNilWithoutClaude() {
        XCTAssertNil(CoordinatorLaunch.plan(
            project: project,
            group: group,
            inputs: inputs(claudePath: nil),
            mcpConfigPath: nil,
            settingsPath: nil
        ))
    }

    func testPlanRunsAtTheProjectRootNotTheCheckout() throws {
        let plan = try XCTUnwrap(CoordinatorLaunch.plan(
            project: project,
            group: group,
            inputs: inputs(),
            mcpConfigPath: nil,
            settingsPath: nil
        ))
        XCTAssertEqual(plan.workingDirectory, "/p")
        XCTAssertEqual(plan.environment["ATELIER_PROJECT_DIR"], "/p")
        XCTAssertEqual(plan.environment["ATELIER_SURFACE_ID"], group.id.uuidString)
        XCTAssertNil(plan.environment["ATELIER_WORKTREE_DIR"])
    }

    func testPlanWrapsInTmuxUnderAGroupPrefixedSession() throws {
        let plan = try XCTUnwrap(CoordinatorLaunch.plan(
            project: project,
            group: group,
            inputs: inputs(tmuxPath: "/opt/homebrew/bin/tmux", tmuxMode: true),
            mcpConfigPath: nil,
            settingsPath: nil
        ))
        XCTAssertTrue(plan.command.contains("/group-Billing/agent"), plan.command)
    }

    func testPlanDoesNotWrapWhenTmuxModeIsOff() throws {
        let plan = try XCTUnwrap(CoordinatorLaunch.plan(
            project: project,
            group: group,
            inputs: inputs(tmuxPath: "/opt/homebrew/bin/tmux", tmuxMode: false),
            mcpConfigPath: nil,
            settingsPath: nil
        ))
        XCTAssertFalse(plan.command.contains("group-Billing"), plan.command)
        XCTAssertTrue(plan.command.contains("--session-id \(group.id.uuidString.lowercased())"), plan.command)
    }
}
