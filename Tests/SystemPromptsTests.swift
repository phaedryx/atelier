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

    /// A spawned agent asked to "report back to whoever started you" has no
    /// way to work that out from `list_peers` — it guessed the coordinator in
    /// an end-to-end run. The id is what `send_message` takes, so it has to be
    /// there, not just the name.
    func test_agentIPCPrompt_namesTheSpawnerByNameAndID() {
        let spawner = SystemPrompts.Spawner(name: "another-verify", id: "0204CF64-9B32-4768-B36B-A835A4B86AD1")
        let prompt = SystemPrompts.agentIPCPrompt(workstreamName: "another-verify-cursor", spawnedBy: spawner)

        XCTAssertTrue(prompt.contains("\"another-verify\""))
        XCTAssertTrue(prompt.contains("0204CF64-9B32-4768-B36B-A835A4B86AD1"))
    }

    func test_agentIPCPrompt_withoutASpawner_saysNothingAboutOne() {
        XCTAssertFalse(SystemPrompts.agentIPCPrompt(workstreamName: "x").contains("started by"))
    }

    /// Asserting only that the path appears would pass just as well for a prompt that
    /// told the agent it may work anywhere, including that path. The constraint and
    /// the path have to arrive in the same clause.
    func test_restrictToWorktreePrompt_forbidsWritesOutsideTheDirectoryItNames() {
        let prompt = SystemPrompts.restrictToWorktreePrompt(worktreePath: "/repos/atelier/tad@feature")

        XCTAssertTrue(
            prompt.contains(
                "MUST NOT create, edit, delete, or modify any files outside of the following "
                    + "directory: /repos/atelier/tad@feature"
            ),
            "the prohibition must name the directory it excludes: \(prompt)"
        )
        XCTAssertTrue(
            prompt.contains("All file operations MUST target paths within /repos/atelier/tad@feature"),
            "the positive restatement is the half an agent acts on: \(prompt)"
        )
    }
}
