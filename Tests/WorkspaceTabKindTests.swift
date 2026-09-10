// ABOUTME: Tests for WorkspaceTabKind, the per-kind metadata table behind the tab bar.
// ABOUTME: Pins each kind's identity, closeability, icon, label, badge, and drag id.

@testable import Atelier
import XCTest

final class WorkspaceTabKindTests: XCTestCase {
    func testOnlyInfoAndAgentArePermanent() {
        for kind in [WorkspaceTabKind.info, .agent] {
            XCTAssertFalse(kind.isCloseable, "\(kind.id) must be permanent")
        }
        // Singletons: one of each, fixed label, but they close like any tab.
        for kind in [WorkspaceTabKind.changes, .execution] {
            XCTAssertTrue(kind.isCloseable, "\(kind.id) must be closeable")
            XCTAssertNil(kind.shortcutBadge, "\(kind.id) badges are positional")
        }
        for kind in [WorkspaceTabKind.info, .agent, .changes, .execution] {
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
        // ⌘I is the dedicated binding; ⌘1 still works positionally.
        XCTAssertEqual(WorkspaceTabKind.info.shortcutBadge, "I")
        XCTAssertEqual(WorkspaceTabKind.agent.shortcutBadge, "\u{21A9}")
        // No static badge: Changes and Execution move and close, so the tab
        // bar derives their ⌘N from the live tab order instead.
        XCTAssertNil(WorkspaceTabKind.changes.shortcutBadge)

        XCTAssertEqual(WorkspaceTab.execution.kind, .execution)
        XCTAssertEqual(WorkspaceTabKind.execution.icon, "play.circle")
        XCTAssertNil(WorkspaceTabKind.execution.shortcutBadge)
    }

    func testDragIdentifierIsUUIDForInstancedAndKindIDForSingletons() {
        let id = UUID()
        XCTAssertEqual(WorkspaceTab.terminal(id).dragIdentifier, id.uuidString)
        XCTAssertEqual(WorkspaceTab.browser(id).dragIdentifier, id.uuidString)
        XCTAssertEqual(WorkspaceTab.editor(id).dragIdentifier, id.uuidString)
        XCTAssertEqual(WorkspaceTab.info.dragIdentifier, "info")
        XCTAssertEqual(WorkspaceTab.agent.dragIdentifier, "agent")
        XCTAssertEqual(WorkspaceTab.changes.dragIdentifier, "changes")
        XCTAssertEqual(WorkspaceTab.execution.dragIdentifier, "execution")
    }

    func testIsCloseableDelegatesToKind() {
        XCTAssertFalse(WorkspaceTab.info.isCloseable)
        XCTAssertTrue(WorkspaceTab.changes.isCloseable)
        XCTAssertTrue(WorkspaceTab.terminal(UUID()).isCloseable)
    }

    /// Verification is the third singleton: exactly one per workstream, a fixed
    /// label, and no named key of its own — so its badge is positional like
    /// Changes' and Execution's.
    func test_verificationKind_isACloseableSingleton() {
        XCTAssertEqual(WorkspaceTabKind.verification.id, "verification")
        XCTAssertTrue(WorkspaceTabKind.verification.isCloseable)
        XCTAssertNotNil(WorkspaceTabKind.verification.staticLabel)
        XCTAssertNil(WorkspaceTabKind.verification.shortcutBadge)
        XCTAssertEqual(WorkspaceTabKind.verification.icon, "checkmark.circle")
        XCTAssertEqual(WorkspaceTab.verification.kind, .verification)
        XCTAssertEqual(WorkspaceTab.verification.dragIdentifier, "verification")
    }
}
