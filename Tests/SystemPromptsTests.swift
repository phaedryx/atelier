// ABOUTME: Tests the system prompts appended to a Coding Agent's launch command.
// ABOUTME: These are agent-facing instructions, so the assertions are about what they promise.

@testable import Atelier
import XCTest

final class SystemPromptsTests: XCTestCase {
    func test_agentIPCPrompt_tellsTheAgentToRegisterUnderItsWorkstreamName() {
        let prompt = SystemPrompts.agentIPCPrompt(workstreamName: "bold-crimson-parser")

        XCTAssertTrue(prompt.contains("register_peer"), "an unregistered agent is invisible to everyone else")
        XCTAssertTrue(prompt.contains("bold-crimson-parser"), "the agent should know the name it will appear under")
    }

    func test_agentIPCPrompt_saysDeliveryIsAPullAndNamesTheDrainingCall() {
        let prompt = SystemPrompts.agentIPCPrompt(workstreamName: "wry-amber-lexer")

        XCTAssertTrue(prompt.contains("receive_messages"))
        XCTAssertTrue(prompt.contains("pull"), "an agent that expects to be interrupted will never read its inbox")
    }

    func test_agentIPCPrompt_explainsTheInjectedNotice() {
        // The nudge types this marker into the agent's own input; without
        // context an agent reads it as something the user typed.
        XCTAssertTrue(SystemPrompts.agentIPCPrompt(workstreamName: "x").contains("[Atelier]"))
    }

    func test_restrictToWorktreePrompt_namesTheDirectoryItConstrains() {
        let prompt = SystemPrompts.restrictToWorktreePrompt(worktreePath: "/repos/atelier/tad@feature")
        XCTAssertTrue(prompt.contains("/repos/atelier/tad@feature"))
    }
}
