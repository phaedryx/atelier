// ABOUTME: Tests for the group coordinator's launch command, environment and system prompt.
// ABOUTME: Pure builders only; nothing here launches a coordinator.

@testable import Atelier
import XCTest

final class CoordinatorCommandTests: XCTestCase {
    func testCoordinatorVariablesCarryTheGroupAndNoWorktree() {
        let g = UUID()
        let vars = Workstream.Environment.coordinatorVariables(groupID: g, groupName: "Billing", projectName: "P", projectDirectory: "/p", defaultBranch: "main")
        XCTAssertEqual(vars["ATELIER_GROUP_ID"], g.uuidString.lowercased())
        XCTAssertEqual(vars["ATELIER_GROUP"], "Billing")
        XCTAssertEqual(vars["ATELIER_SURFACE_ID"], g.uuidString)
        XCTAssertEqual(vars["ATELIER_PROJECT_DIR"], "/p")
        XCTAssertEqual(vars["FF_GROUP"], "Billing")
        for absent in ["ATELIER_WORKSTREAM_ID", "ATELIER_WORKSTREAM", "ATELIER_WORKTREE_DIR", "ATELIER_PORT", "ATELIER_SLOT"] {
            XCTAssertNil(vars[absent], absent)
        }
    }

    func testCoordinatorPromptNamesRootCheckoutAndMembers() {
        let p = SystemPrompts.coordinatorPrompt(groupName: "Billing", projectName: "P", rootDirectory: "/p", checkoutDirectory: "/p/main", members: [.init(name: "fix-a", worktreePath: "/p/fix-a")])
        for s in ["Billing", "/p/main", "CLAUDE.md", "fix-a at /p/fix-a", "list_peers", "create_workstream"] {
            XCTAssertTrue(p.contains(s), s)
        }
    }

    func testCoordinatorPromptSaysNoneYetWithoutMembers() {
        let p = SystemPrompts.coordinatorPrompt(groupName: "B", projectName: "P", rootDirectory: "/p", checkoutDirectory: "/p/main", members: [])
        XCTAssertTrue(p.contains("none yet"))
    }

    func testCoordinatorSystemPromptOmitsTheWorktreeRestrictionAndRename() {
        let p = Workstream.AgentCommand.coordinatorSystemPrompt(groupName: "B", projectName: "P", rootDirectory: "/p", checkoutDirectory: "/p/main", members: [], mcpConfigWritten: true)
        XCTAssertFalse(p.contains("CRITICAL FILESYSTEM CONSTRAINT")); XCTAssertFalse(p.contains("git branch -m"))
        XCTAssertTrue(p.contains("register_peer"))
    }

    func testCoordinatorSystemPromptOmitsIPCPromptWithoutMCPConfig() {
        let p = Workstream.AgentCommand.coordinatorSystemPrompt(groupName: "B", projectName: "P", rootDirectory: "/p", checkoutDirectory: "/p/main", members: [], mcpConfigWritten: false)
        XCTAssertFalse(p.contains("register_peer"))
    }

    func testCoordinatorCommandResumesThenStartsFreshWithTheGroupSession() {
        let g = UUID()
        let cmd = Workstream.AgentCommand.coordinator(claudePath: "/usr/bin/claude", groupID: g, groupName: "Billing", supportsSessionName: true, bypassPermissions: false, systemPrompt: "x", mcpConfigPath: nil, settingsPath: nil)
        XCTAssertTrue(cmd.contains("--resume \(g.uuidString.lowercased())")); XCTAssertTrue(cmd.contains("--session-id \(g.uuidString.lowercased())")); XCTAssertTrue(cmd.contains("--name 'Billing'") || cmd.contains("--name Billing"))
    }

    func testAgentIPCPromptNoLongerClaimsEveryAgentHasAWorktree() {
        let p = SystemPrompts.agentIPCPrompt(workstreamName: "w")
        XCTAssertTrue(p.contains("You are one of several coding agents running in Atelier on this project."))
        XCTAssertFalse(p.contains("each in its own git worktree"))
    }
}
