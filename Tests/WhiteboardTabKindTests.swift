// ABOUTME: Pins the whiteboard tab's static facts and its place among the singletons.
// ABOUTME: In particular that it has no shortcut badge and does not start open.

@testable import Atelier
import XCTest

final class WhiteboardTabKindTests: XCTestCase {
    func test_whiteboardIsACloseableSingleton() {
        XCTAssertEqual(WorkspaceTabKind.whiteboard.id, "whiteboard")
        XCTAssertTrue(WorkspaceTabKind.whiteboard.isCloseable)
        // A static label is what makes it a singleton rather than an instanced
        // kind: only tabs whose label is per-tab lose it in compact mode.
        XCTAssertNotNil(WorkspaceTabKind.whiteboard.staticLabel)
    }

    func test_whiteboardHasNoShortcutBadge() {
        // Deliberate, and asserted alongside its three peers so a later "just
        // give it ⌘B" has to change this test on purpose: it matches the other
        // closeable singletons and keeps the five-file shortcut checklist out of
        // this change entirely.
        XCTAssertNil(WorkspaceTabKind.whiteboard.shortcutBadge)
        XCTAssertNil(WorkspaceTabKind.changes.shortcutBadge)
        XCTAssertNil(WorkspaceTabKind.execution.shortcutBadge)
        XCTAssertNil(WorkspaceTabKind.verification.shortcutBadge)
    }

    func test_workspaceTabMapsToItsKind() {
        XCTAssertEqual(WorkspaceTab.whiteboard.kind, .whiteboard)
        // Singleton kinds have no instance UUID, so the kind id is the drag
        // identifier.
        XCTAssertEqual(WorkspaceTab.whiteboard.dragIdentifier, "whiteboard")
    }

    func test_theBoardStartsClosed() {
        // startupWorkspaceTabState is unchanged and must stay so: the board is
        // opened from the tab bar's quick-add button or the palette, like
        // Changes, Execution and Verification.
        let state = startupWorkspaceTabState(savedTab: nil)
        XCTAssertEqual(state.tabs, [.info, .agent])
        XCTAssertFalse(state.tabs.contains(.whiteboard))
    }

    func test_aRestoredWhiteboardIsClampedBackToInfo() {
        // The clamp is what holds activeTab inside tabs. A saved .whiteboard
        // restored onto a strip with no whiteboard tab would render that pane
        // with nothing selected in the strip, and with the quick-add button
        // still offering to open what is already on screen.
        let state = startupWorkspaceTabState(savedTab: .whiteboard)
        XCTAssertEqual(state.activeTab, .info)
        XCTAssertFalse(state.tabs.contains(.whiteboard))
    }

    func test_restorableRoundTripsThroughItsCases() {
        XCTAssertEqual(RestorableWorkspaceTab(activeTab: .whiteboard), .whiteboard)
        XCTAssertEqual(RestorableWorkspaceTab.whiteboard.workspaceTab(), .whiteboard)
    }

    @MainActor
    func test_theBoardTabOpensAndCloses() {
        let model = WorkspaceModel(
            workstreamID: UUID(),
            snapshot: startupWorkspaceTabState(savedTab: nil)
        )
        model.ensureSingleton(.whiteboard)
        XCTAssertTrue(model.tabs.contains(.whiteboard))
        XCTAssertTrue(model.removeTab(.whiteboard))
        XCTAssertFalse(model.tabs.contains(.whiteboard))
    }

    @MainActor
    func test_ensureSingletonDoesNotStealTheSelection() {
        // The same rule open_tab states: opening a pane is not a reason to pull
        // someone off what they are working in.
        let model = WorkspaceModel(
            workstreamID: UUID(),
            snapshot: startupWorkspaceTabState(savedTab: nil)
        )
        model.activeTab = .agent
        model.ensureSingleton(.whiteboard)
        XCTAssertEqual(model.activeTab, .agent)
    }
}
