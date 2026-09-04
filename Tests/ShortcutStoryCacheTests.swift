// ABOUTME: Tests AppEnvironment's Shortcut story cache and its staging handoff.
// ABOUTME: Creation fetches a story before the worktree path exists, so it is staged by id first.

@testable import Atelier
import XCTest

@MainActor
final class ShortcutStoryCacheTests: XCTestCase {
    private func makeStory(id: Int, name: String = "A story", stateID: Int = 500_000_030) -> Shortcut.Story {
        let json = """
        {
          "id": \(id),
          "name": "\(name)",
          "description": "the body",
          "app_url": "https://app.shortcut.com/sixfifty/story/\(id)",
          "formatted_vcs_branch_name": "tadthorley/sc-\(id)/a-story",
          "workflow_state_id": \(stateID)
        }
        """
        // Decoding rather than a memberwise init keeps the fixture honest about the wire shape.
        return try! JSONDecoder().decode(Shortcut.Story.self, from: Data(json.utf8))
    }

    func testNoStoryForUnknownPath() {
        let env = AppEnvironment()
        XCTAssertNil(env.shortcutStory(for: "/tmp/nowhere"))
    }

    func testNilPathIsSafe() {
        let env = AppEnvironment()
        XCTAssertNil(env.shortcutStory(for: nil))
    }

    func testStagedStoryBecomesVisibleOnceThePathIsKnown() {
        // This is the creation flow: the story is fetched to get its branch name, but
        // `git worktree add` has not run yet, so there is no path to key it by.
        let env = AppEnvironment()
        env.stageShortcutStory(makeStory(id: 17411))
        XCTAssertNil(env.shortcutStory(for: "/tmp/wt"), "not visible before a path is registered")

        env.registerShortcutStory(id: 17411, for: "/tmp/wt")
        XCTAssertEqual(env.shortcutStory(for: "/tmp/wt")?.id, 17411)
        XCTAssertEqual(env.shortcutStory(for: "/tmp/wt")?.description, "the body",
                       "the description fetched at creation must survive, not be refetched")
    }

    func testRegisteringWithoutAStagedStoryLeavesCacheEmpty() {
        // The restore-on-launch path: ids come from the project list with nothing staged,
        // so the story stays nil until the info tab refreshes it.
        let env = AppEnvironment()
        env.registerShortcutStory(id: 17411, for: "/tmp/wt")
        XCTAssertNil(env.shortcutStory(for: "/tmp/wt"))
    }

    func testStateNameIsNilUntilWorkflowsAreLoaded() {
        let env = AppEnvironment()
        env.stageShortcutStory(makeStory(id: 1))
        env.registerShortcutStory(id: 1, for: "/tmp/wt")
        XCTAssertNotNil(env.shortcutStory(for: "/tmp/wt"))
        XCTAssertNil(env.shortcutStateName(for: "/tmp/wt"), "no workflows fetched yet")
    }

    func testPruningDropsStoriesForWorktreesThatAreGone() {
        // Archiving a Shortcut workstream and creating a plain one that reuses the path
        // would otherwise render the archived story — likelier now that worktree
        // directories are named after the branch.
        let env = AppEnvironment()
        env.stageShortcutStory(makeStory(id: 1))
        env.registerShortcutStory(id: 1, for: "/tmp/gone")
        XCTAssertNotNil(env.shortcutStory(for: "/tmp/gone"))

        env.pruneShortcutStories(keeping: ["/tmp/still-here"])
        XCTAssertNil(env.shortcutStory(for: "/tmp/gone"))
    }

    func testPruningKeepsLivePaths() {
        let env = AppEnvironment()
        env.stageShortcutStory(makeStory(id: 1))
        env.registerShortcutStory(id: 1, for: "/tmp/live")

        env.pruneShortcutStories(keeping: ["/tmp/live"])
        XCTAssertEqual(env.shortcutStory(for: "/tmp/live")?.id, 1)
    }

    func testPrunedPathDoesNotResurrectFromStaging() {
        // The staged copy must have been consumed by the first registration, not left
        // behind to reappear the next time the same path is registered.
        let env = AppEnvironment()
        env.stageShortcutStory(makeStory(id: 1))
        env.registerShortcutStory(id: 1, for: "/tmp/reused")
        env.pruneShortcutStories(keeping: [])

        // Nothing was staged for id 2, so the old `XCTAssertNil` was the expected
        // result whether or not story 1 resurrected — the assertion could not fail.
        // Staging id 2 makes the path resolve to *something* either way, and which
        // story it is is the actual contract.
        env.stageShortcutStory(makeStory(id: 2))
        env.registerShortcutStory(id: 2, for: "/tmp/reused")
        XCTAssertEqual(env.shortcutStory(for: "/tmp/reused")?.id, 2,
                       "story 1 must not come back on a reused path")
    }

    /// `shortcutStateName` has no positive case through `AppEnvironment`: the workflow
    /// list is private and only the network path fills it, and adding an injection
    /// point to production for one test is not worth it (the same call this file's
    /// `ProcessComposeSettings` sibling makes about search paths). The lookup is where
    /// the logic lives — a state id is unique workspace-wide, not per workflow, so it
    /// has to search all of them rather than only the first.
    func testStateNameSearchesEveryWorkflowForTheStateID() {
        let workflows = [
            Shortcut.Workflow(id: 1, name: "Design", states: [
                Shortcut.Workflow.State(id: 500_000_010, name: "Sketching", type: "started"),
            ]),
            Shortcut.Workflow(id: 2, name: "Engineering", states: [
                Shortcut.Workflow.State(id: 500_000_020, name: "Ready for Dev", type: "unstarted"),
                Shortcut.Workflow.State(id: 500_000_030, name: "In Progress", type: "started"),
            ]),
        ]

        XCTAssertEqual(workflows.stateName(for: 500_000_030), "In Progress",
                       "a state in the second workflow must still resolve")
        XCTAssertEqual(workflows.stateName(for: 500_000_010), "Sketching")
        XCTAssertNil(workflows.stateName(for: 500_000_999))
    }

    func testRepeatedRegistrationIsStable() {
        let env = AppEnvironment()
        env.stageShortcutStory(makeStory(id: 17411))
        env.registerShortcutStory(id: 17411, for: "/tmp/wt")
        // ContentView re-registers on every project-list change; that must not clear the cache.
        env.registerShortcutStory(id: 17411, for: "/tmp/wt")
        XCTAssertEqual(env.shortcutStory(for: "/tmp/wt")?.id, 17411)
    }
}
