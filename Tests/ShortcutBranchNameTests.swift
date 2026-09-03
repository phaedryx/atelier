// ABOUTME: Tests the branch-name template that turns a Shortcut story into a git branch.
// ABOUTME: Template lives in Settings, e.g. tad@sc-${STORY_ID}-${SLUG}.

@testable import Atelier
import XCTest

final class ShortcutBranchNameTests: XCTestCase {
    private func story(
        id: Int = 17411,
        name: String = "Org Import run card reads as nothing happened on an unchanged re-upload",
        type: String = "bug",
        branchName: String = "tadthorley/sc-17411/org-import-run-card-reads-as-nothing-happened"
    ) -> Shortcut.Story {
        let json = """
        {
          "id": \(id),
          "name": \(jsonString(name)),
          "description": null,
          "story_type": \(jsonString(type)),
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

    // MARK: - The template the justfile uses

    func testReproducesTheJustfileConvention() {
        let name = Shortcut.BranchName.render("tad@sc-${STORY_ID}-${SLUG}", story: story())
        XCTAssertEqual(name, "tad@sc-17411-org-import-run-card-reads-as")
    }

    func testJustfileConventionHasNoSlashes() {
        // The point of the @ form: no slashes means the worktree directory keeps this name.
        let name = Shortcut.BranchName.render("tad@sc-${STORY_ID}-${SLUG}", story: story())
        XCTAssertFalse(name.contains("/"))
    }

    // MARK: - Empty template falls back to Shortcut

    func testEmptyTemplateUsesShortcutsOwnSuggestion() {
        XCTAssertEqual(
            Shortcut.BranchName.render("", story: story()),
            "tadthorley/sc-17411/org-import-run-card-reads-as-nothing-happened"
        )
        XCTAssertEqual(
            Shortcut.BranchName.render("   ", story: story()),
            "tadthorley/sc-17411/org-import-run-card-reads-as-nothing-happened"
        )
    }

    // MARK: - Variables

    func testStoryIDSubstitution() {
        XCTAssertEqual(Shortcut.BranchName.render("sc-${STORY_ID}", story: story(id: 42)), "sc-42")
    }

    func testSlugIsTitleTruncatedToSixWords() {
        let name = Shortcut.BranchName.render("${SLUG}", story: story(id: 1, name: "one two three four five six seven eight"))
        XCTAssertEqual(name, "one-two-three-four-five-six")
    }

    func testSlugFullKeepsTheWholeTitle() {
        let name = Shortcut.BranchName.render("${SLUG_FULL}", story: story(id: 1, name: "one two three four five six seven eight"))
        XCTAssertEqual(name, "one-two-three-four-five-six-seven-eight")
    }

    func testSlugCollapsesPunctuation() {
        let name = Shortcut.BranchName.render(
            "${SLUG}",
            story: story(id: 3, name: "Add Actionable convention: fields[include]/fields[only]")
        )
        // "fields" appears twice, so the six-word cut keeps both — same as the justfile's
        // sed collapse followed by `cut -d- -f1-6`.
        XCTAssertEqual(name, "add-actionable-convention-fields-include-fields")
    }

    func testMentionComesFromShortcutsSuggestedName() {
        // Shortcut leads its suggestion with the member's mention name, which is the only
        // place to learn it without a second API call.
        XCTAssertEqual(Shortcut.BranchName.render("${MENTION}", story: story()), "tadthorley")
    }

    func testTypeSubstitution() {
        XCTAssertEqual(Shortcut.BranchName.render("${TYPE}/sc-${STORY_ID}", story: story(type: "feature")), "feature/sc-17411")
    }

    func testAVariableMayAppearMoreThanOnce() {
        XCTAssertEqual(Shortcut.BranchName.render("${STORY_ID}-${STORY_ID}", story: story(id: 7)), "7-7")
    }

    // MARK: - Robustness

    func testUnknownVariableIsLeftAloneRatherThanBlanked() {
        // Silently dropping it would produce a plausible-looking wrong branch; leaving it
        // visible means the Settings preview shows the typo.
        XCTAssertEqual(Shortcut.BranchName.render("x-${NOPE}", story: story()), "x-${NOPE}")
    }

    func testTemplateWithNoVariablesIsUsedLiterally() {
        XCTAssertEqual(Shortcut.BranchName.render("fixed-branch", story: story()), "fixed-branch")
    }

    func testEmptySlugDoesNotLeaveATrailingSeparator() {
        let name = Shortcut.BranchName.render("tad@sc-${STORY_ID}-${SLUG}", story: story(id: 9, name: "!!! ???"))
        XCTAssertEqual(name, "tad@sc-9", "a title with no usable characters must not leave a dangling dash")
    }

    func testRenderedNamesAreValidGitBranchNames() {
        let awkward = story(id: 4, name: "  ...Leading dots & --dashes-- everywhere...  ")
        for template in ["tad@sc-${STORY_ID}-${SLUG}", "${MENTION}/sc-${STORY_ID}/${SLUG}", "", "${TYPE}/${SLUG_FULL}"] {
            let name = Shortcut.BranchName.render(template, story: awkward)
            XCTAssertTrue(GitOperations.isValidBranchName(name), "template \(template) produced invalid branch: \(name)")
        }
    }

    // MARK: - Unknown variable detection

    func testKnownVariablesReportNothingUnknown() {
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: "tad@sc-${STORY_ID}-${SLUG}"), [])
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: "${MENTION}/${TYPE}/${SLUG_FULL}"), [])
    }

    func testUnknownVariableIsReported() {
        // Settings warns on this. A typo renders literally and is a *valid* git branch name,
        // so validation alone would never catch it.
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: "x-${NOPE}"), ["NOPE"])
    }

    func testEveryUnknownVariableIsReportedInOrder() {
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: "${AAA}-${SLUG}-${BBB}"), ["AAA", "BBB"])
    }

    func testTemplateWithoutVariablesReportsNothing() {
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: "fixed-branch"), [])
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: ""), [])
    }

    func testLoneDollarOrBraceIsNotTreatedAsAVariable() {
        XCTAssertEqual(Shortcut.BranchName.unknownVariables(in: "cost-$5-{x}"), [])
    }

    func testStorageKeyIsStable() {
        XCTAssertEqual(Shortcut.Settings.branchTemplateKey, "atelier.shortcutBranchTemplate")
    }
}
