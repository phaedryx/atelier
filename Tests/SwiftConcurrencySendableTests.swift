// ABOUTME: Compile-time checks for types that cross concurrency boundaries.
// ABOUTME: Ensures the Swift 6 migration keeps key models Sendable.

@testable import Atelier
import XCTest

final class SwiftConcurrencySendableTests: XCTestCase {
    func testCoreModelsAreSendable() {
        assertSendable(Project(name: "project", directory: "/tmp/project"))
        assertSendable(Workstream(name: "workstream"))
        assertSendable(Project.SortOrder.recent)
        assertSendable(Git.RepoInfo(isRepo: true, branch: "main", remoteURL: nil, commitCount: 1, isDirty: false))
        assertSendable(Worktree.Info(path: "/tmp/project", branch: "main", isDirty: false, isMain: true, hasUnpushedCommits: false, hasBranchCommits: false))
        assertSendable(GitHub.RepoInfo(name: "repo", url: "https://example.com", description: nil, stars: 1, forks: 2, openIssues: 3))
        assertSendable(GitHub.PR(number: 1, title: "Title", state: "OPEN", branch: "main", url: "https://example.com/pr/1"))
        assertSendable(ToolStatus())
        assertSendable(SidebarSelection.settings)
        assertSendable(WorkspaceTab.info)
        assertSendable(AppInfo(name: "Terminal", bundleID: "com.apple.Terminal"))
    }

    private func assertSendable(_ value: some Sendable) {
        _ = value
    }
}
