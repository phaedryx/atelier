// ABOUTME: Tests decoding of Shortcut API payloads and mapping of HTTP status to ShortcutError.
// ABOUTME: Fixtures are trimmed from real responses for story sc-17411 in the Sixfifty workspace.

@testable import Atelier
import XCTest

final class ShortcutAPITests: XCTestCase {
    // MARK: - Story

    private let storyJSON = """
    {
      "id": 17411,
      "name": "Org Import run card reads as nothing happened on an unchanged re-upload",
      "description": "Two problems, one file.\\n\\n**1.** `rows_parsed` is never rendered.",
      "app_url": "https://app.shortcut.com/sixfifty/story/17411",
      "formatted_vcs_branch_name": "tadthorley/sc-17411/org-import-run-card-reads-as-nothing-happened",
      "workflow_id": 500000023,
      "workflow_state_id": 500000030,
      "story_type": "bug"
    }
    """

    func testDecodesStory() throws {
        let story = try JSONDecoder().decode(ShortcutStory.self, from: Data(storyJSON.utf8))
        XCTAssertEqual(story.id, 17411)
        XCTAssertEqual(story.name, "Org Import run card reads as nothing happened on an unchanged re-upload")
        XCTAssertEqual(story.branchName, "tadthorley/sc-17411/org-import-run-card-reads-as-nothing-happened")
        XCTAssertEqual(story.appURL, "https://app.shortcut.com/sixfifty/story/17411")
        XCTAssertEqual(story.workflowStateID, 500000030)
        XCTAssertTrue(story.description?.contains("rows_parsed") == true)
    }

    func testDecodesStoryWithNullDescription() throws {
        let json = """
        {
          "id": 1,
          "name": "No body",
          "description": null,
          "app_url": "https://app.shortcut.com/x/story/1",
          "formatted_vcs_branch_name": "someone/sc-1/no-body",
          "workflow_state_id": 5
        }
        """
        let story = try JSONDecoder().decode(ShortcutStory.self, from: Data(json.utf8))
        XCTAssertNil(story.description)
        XCTAssertEqual(story.branchName, "someone/sc-1/no-body")
    }

    // MARK: - Workflows

    private let workflowsJSON = """
    [
      {
        "id": 500000023,
        "name": "Engineering Workflow",
        "states": [
          { "id": 500000027, "name": "Backlog", "type": "backlog" },
          { "id": 500000030, "name": "In Progress", "type": "started" },
          { "id": 500000026, "name": "Prod/Done", "type": "done" }
        ]
      },
      {
        "id": 500001689,
        "name": "Access Requests Workflow",
        "states": [
          { "id": 500001691, "name": "Started", "type": "started" }
        ]
      }
    ]
    """

    func testResolvesStateNameAcrossWorkflows() throws {
        let workflows = try JSONDecoder().decode([ShortcutWorkflow].self, from: Data(workflowsJSON.utf8))
        XCTAssertEqual(workflows.stateName(for: 500000030), "In Progress")
        XCTAssertEqual(workflows.stateName(for: 500001691), "Started", "must search every workflow, not just the first")
    }

    func testUnknownStateIDResolvesToNil() throws {
        let workflows = try JSONDecoder().decode([ShortcutWorkflow].self, from: Data(workflowsJSON.utf8))
        XCTAssertNil(workflows.stateName(for: 999))
    }

    // MARK: - Member

    func testDecodesCurrentMember() throws {
        let json = """
        {
          "id": "69e653a0-a0bd-4687-b19e-bef6057510da",
          "mention_name": "tadthorley",
          "name": "Tad Thorley",
          "workspace2": { "name": "Sixfifty", "url_slug": "sixfifty" }
        }
        """
        let member = try JSONDecoder().decode(ShortcutMember.self, from: Data(json.utf8))
        XCTAssertEqual(member.name, "Tad Thorley")
        XCTAssertEqual(member.mentionName, "tadthorley")
        XCTAssertEqual(member.workspaceName, "Sixfifty")
    }

    // MARK: - Error mapping

    func testSuccessStatusMapsToNoError() {
        XCTAssertNil(ShortcutError.forStatus(200))
        XCTAssertNil(ShortcutError.forStatus(201))
    }

    func testUnauthorizedStatusMaps() {
        XCTAssertEqual(ShortcutError.forStatus(401), .unauthorized)
        XCTAssertEqual(ShortcutError.forStatus(403), .unauthorized)
    }

    func testNotFoundStatusMaps() {
        XCTAssertEqual(ShortcutError.forStatus(404), .notFound)
    }

    func testOtherFailureStatusesCarryTheCode() {
        XCTAssertEqual(ShortcutError.forStatus(500), .http(500))
        XCTAssertEqual(ShortcutError.forStatus(429), .http(429))
    }
}
