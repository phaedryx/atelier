// ABOUTME: Tests the one decision the Shortcut button and create_shortcut_workstream share.
// ABOUTME: Which name a story's workstream gets, and the three collisions that refuse it.

@testable import Atelier
import XCTest

/// `Shortcut.WorkstreamName.resolve` is the sidebar's guards lifted out of the
/// view so the IPC handler runs the same ones. The order of the refusals is the
/// part worth pinning: the two collisions are distinct on purpose, and checking
/// the name first let one story through twice under a changed template.
final class ShortcutWorkstreamNameTests: XCTestCase {
    private func story(
        id: Int = 17411,
        name: String = "Org Import run card reads as nothing happened",
        branchName: String = "tadthorley/sc-17411/org-import-run-card-reads"
    ) -> Shortcut.Story {
        let json = """
        {
          "id": \(id),
          "name": \(jsonString(name)),
          "description": null,
          "story_type": "bug",
          "app_url": "https://app.shortcut.com/sixfifty/story/\(id)",
          "formatted_vcs_branch_name": \(jsonString(branchName)),
          "workflow_state_id": 500000030
        }
        """
        return try! JSONDecoder().decode(Shortcut.Story.self, from: Data(json.utf8))
    }

    private func jsonString(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    private func workstream(_ name: String, storyID: Int? = nil) -> Workstream {
        Workstream(name: name, shortcutStoryID: storyID)
    }

    // MARK: - The name

    func testRendersTheNameFromTheTemplate() {
        let resolved = Shortcut.WorkstreamName.resolve(
            template: "tad@sc-${STORY_ID}-${SLUG}",
            story: story(),
            existing: []
        )

        XCTAssertEqual(try? resolved.get(), "tad@sc-17411-org-import-run-card-reads-as")
    }

    func testAnEmptyTemplateTakesShortcutsOwnBranchName() {
        let resolved = Shortcut.WorkstreamName.resolve(
            template: "",
            story: story(),
            existing: []
        )

        XCTAssertEqual(try? resolved.get(), "tadthorley/sc-17411/org-import-run-card-reads")
    }

    // MARK: - The refusals

    func testRefusesANameGitWillNotAccept() {
        let resolved = Shortcut.WorkstreamName.resolve(
            template: "not a branch ${STORY_ID}",
            story: story(),
            existing: []
        )

        XCTAssertEqual(resolved.refusal, .invalidBranchName("not a branch 17411"))
    }

    func testRefusesAStoryThatAlreadyHasAWorkstream() {
        let resolved = Shortcut.WorkstreamName.resolve(
            template: "sc-${STORY_ID}",
            story: story(id: 17411),
            existing: [workstream("something-else", storyID: 17411)]
        )

        XCTAssertEqual(resolved.refusal, .storyAlreadyHasWorkstream("something-else"))
    }

    func testRefusesANameAnUnrelatedWorkstreamAlreadyHolds() {
        let resolved = Shortcut.WorkstreamName.resolve(
            template: "sc-${STORY_ID}",
            story: story(id: 17411),
            existing: [workstream("sc-17411")]
        )

        XCTAssertEqual(resolved.refusal, .nameInUse("sc-17411"))
    }

    /// The order the sidebar's comment justifies: checking the name first blamed
    /// the story when an unrelated workstream happened to match, and let the same
    /// story through twice once the template changed.
    func testTheStoryCollisionIsReportedBeforeTheNameCollision() {
        let resolved = Shortcut.WorkstreamName.resolve(
            template: "sc-${STORY_ID}",
            story: story(id: 17411),
            existing: [workstream("sc-17411", storyID: 17411)]
        )

        XCTAssertEqual(resolved.refusal, .storyAlreadyHasWorkstream("sc-17411"))
    }

    // MARK: - Two audiences

    /// The wordings are deliberately different — the sidebar's is user copy and
    /// the handler's tells an agent what to do differently — so a test that only
    /// checked one would let the other go missing.
    func testEveryRefusalCarriesBothWordings() {
        let refusals: [Shortcut.WorkstreamName.Refusal] = [
            .invalidBranchName("not a branch"),
            .storyAlreadyHasWorkstream("sc-17411"),
            .nameInUse("sc-17411"),
        ]

        for refusal in refusals {
            XCTAssertFalse(refusal.localizedMessage.isEmpty, "\(refusal) has no message for the sheet")
            XCTAssertFalse(refusal.agentMessage.isEmpty, "\(refusal) has no message for an agent")
        }
    }
}

private extension Result where Failure == Shortcut.WorkstreamName.Refusal {
    var refusal: Failure? {
        guard case let .failure(refusal) = self else { return nil }
        return refusal
    }
}
