// ABOUTME: Tests for WorkspaceTabKind, the per-kind metadata table behind the tab bar.
// ABOUTME: Pins each kind's identity, closeability, icon, label, badge, and drag id.

@testable import Atelier
import XCTest

final class WorkspaceTabKindTests: XCTestCase {
    func testPinnedKindsAreNotCloseable() {
        for kind in [WorkspaceTabKind.info, .agent, .changes] {
            XCTAssertFalse(kind.isCloseable, "\(kind.id) must be pinned")
            XCTAssertNotNil(kind.staticLabel, "\(kind.id) has a fixed label")
        }
    }

    func testInstancedKindsAreCloseableWithDynamicLabels() {
        for kind in [WorkspaceTabKind.terminal, .browser, .editor] {
            XCTAssertTrue(kind.isCloseable, "\(kind.id) must be closeable")
            XCTAssertNil(kind.staticLabel, "\(kind.id) labels are per-tab")
            XCTAssertNil(kind.shortcutBadge, "\(kind.id) badges are positional")
        }
    }

    func testKindMappingMatchesLegacyMetadata() {
        let id = UUID()
        XCTAssertEqual(WorkspaceTab.info.kind, .info)
        XCTAssertEqual(WorkspaceTab.agent.kind, .agent)
        XCTAssertEqual(WorkspaceTab.changes.kind, .changes)
        XCTAssertEqual(WorkspaceTab.terminal(id).kind, .terminal)
        XCTAssertEqual(WorkspaceTab.browser(id).kind, .browser)
        XCTAssertEqual(WorkspaceTab.editor(id).kind, .editor)

        // Values the tab bar rendered before the table existed.
        XCTAssertEqual(WorkspaceTabKind.info.icon, "info.circle")
        XCTAssertEqual(WorkspaceTabKind.agent.icon, "sparkle")
        XCTAssertEqual(WorkspaceTabKind.changes.icon, "arrow.triangle.branch")
        XCTAssertEqual(WorkspaceTabKind.terminal.icon, "terminal")
        XCTAssertEqual(WorkspaceTabKind.browser.icon, "globe")
        XCTAssertEqual(WorkspaceTabKind.editor.icon, "doc.text")
        XCTAssertEqual(WorkspaceTabKind.info.shortcutBadge, "1")
        XCTAssertEqual(WorkspaceTabKind.agent.shortcutBadge, "\u{21A9}")
        XCTAssertEqual(WorkspaceTabKind.changes.shortcutBadge, "D")
    }

    func testDragIdentifierIsUUIDForInstancedAndKindIDForPinned() {
        let id = UUID()
        XCTAssertEqual(WorkspaceTab.terminal(id).dragIdentifier, id.uuidString)
        XCTAssertEqual(WorkspaceTab.browser(id).dragIdentifier, id.uuidString)
        XCTAssertEqual(WorkspaceTab.editor(id).dragIdentifier, id.uuidString)
        XCTAssertEqual(WorkspaceTab.info.dragIdentifier, "info")
        XCTAssertEqual(WorkspaceTab.agent.dragIdentifier, "agent")
        XCTAssertEqual(WorkspaceTab.changes.dragIdentifier, "changes")
    }

    func testIsCloseableDelegatesToKind() {
        XCTAssertFalse(WorkspaceTab.info.isCloseable)
        XCTAssertTrue(WorkspaceTab.terminal(UUID()).isCloseable)
    }
}
