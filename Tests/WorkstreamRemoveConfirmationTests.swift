// ABOUTME: Tests where the selection lands when a workstream is removed.
// ABOUTME: The rule the two copies of performRemove disagreed about, now in one place.

@testable import Atelier
import XCTest

/// `Workstream.RemoveConfirmation` folded the Remove alert and its
/// `performRemove` out of `ContentView` and `ProjectSidebar`. `perform` proper
/// cannot be driven here — it reaches `Archiver.remove`, which needs a live
/// `TerminalSurfaceCache` — so what is pinned is the decision the two copies
/// had actually drifted on.
@MainActor
final class WorkstreamRemoveConfirmationTests: XCTestCase {
    private let projectID = UUID()

    /// The bug: `ContentView.performRemove` left `selection` naming the
    /// workstream it had just archived, so `activeProject` resolved nil and the
    /// detail pane fell through to `OnboardingView` beside a populated sidebar.
    func test_selectionMovesToASiblingWhenTheSelectedWorkstreamIsRemoved() {
        let removed = UUID()
        let sibling = UUID()

        let result = Workstream.RemoveConfirmation.selectionAfterRemoving(
            removed,
            from: .workstream(removed),
            projectID: projectID,
            nextWorkstreamID: sibling
        )

        XCTAssertEqual(result, .workstream(sibling))
    }

    /// With nothing left in the project, the project itself — never the dead id.
    func test_selectionFallsBackToTheProjectWhenNothingIsLeft() {
        let removed = UUID()

        let result = Workstream.RemoveConfirmation.selectionAfterRemoving(
            removed,
            from: .workstream(removed),
            projectID: projectID,
            nextWorkstreamID: nil
        )

        XCTAssertEqual(result, .project(projectID))
    }

    /// Removing a row from the sidebar's context menu while looking at a
    /// different workstream must not move the user.
    func test_anotherWorkstreamsSelectionIsLeftAlone() {
        let watching = UUID()

        let result = Workstream.RemoveConfirmation.selectionAfterRemoving(
            UUID(),
            from: .workstream(watching),
            projectID: projectID,
            nextWorkstreamID: UUID()
        )

        XCTAssertEqual(result, .workstream(watching))
    }

    func test_aNonWorkstreamSelectionIsLeftAlone() {
        for selection: SidebarSelection? in [.project(projectID), .settings, .help, nil] {
            let result = Workstream.RemoveConfirmation.selectionAfterRemoving(
                UUID(),
                from: selection,
                projectID: projectID,
                nextWorkstreamID: UUID()
            )

            XCTAssertEqual(result, selection)
        }
    }
}
