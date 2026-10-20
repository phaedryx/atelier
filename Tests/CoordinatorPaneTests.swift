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

    func testPlanWrapsInTmuxUnderTheGroupIDsSession() throws {
        let plan = try XCTUnwrap(CoordinatorLaunch.plan(
            project: project,
            group: group,
            inputs: inputs(tmuxPath: "/opt/homebrew/bin/tmux", tmuxMode: true),
            mcpConfigPath: nil,
            settingsPath: nil
        ))
        let segment = "group-" + group.id.uuidString.lowercased().prefix(8)
        XCTAssertTrue(plan.command.contains("/\(segment)/agent"), plan.command)
        XCTAssertFalse(plan.command.contains("group-Billing"), plan.command)
        XCTAssertTrue(plan.command.contains(group.coordinatorSessionName(projectName: project.name)), plan.command)
    }

    /// Keyed on the id, not the free-text name: `TmuxSession.sanitize` maps only
    /// a few characters, so "Q4 audit" and "Q4-audit" used to share one session,
    /// and a rename made Remove kill a session that no longer existed.
    func testCoordinatorSessionIgnoresTheNameAndSurvivesARename() throws {
        let id = try XCTUnwrap(UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890"))
        let spaced = Workstream.Group(name: "Q4 audit", id: id)
        var hyphened = Workstream.Group(name: "Q4-audit")
        XCTAssertNotEqual(
            spaced.coordinatorSessionName(projectName: "app"),
            hyphened.coordinatorSessionName(projectName: "app")
        )
        XCTAssertEqual(spaced.coordinatorTmuxSegment, "group-abcdef12")
        let before = hyphened.coordinatorSessionName(projectName: "app")
        hyphened.name = "renamed"
        XCTAssertEqual(hyphened.coordinatorSessionName(projectName: "app"), before)
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
