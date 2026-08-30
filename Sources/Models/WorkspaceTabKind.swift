// ABOUTME: Per-kind metadata for workspace tabs: identity, closeability, icon, label, badge.
// ABOUTME: The single place a tab kind's static facts live; the tab bar reads it via WorkspaceTab.kind.

import Foundation

/// The static facts about one kind of workspace tab. The tab bar renders from
/// this table instead of switching on the enum at every call site, so adding a
/// kind means one entry here, one case in `WorkspaceTab`, and one case in
/// `tabContent` — nothing else.
struct WorkspaceTabKind: Equatable, Hashable {
    /// Stable identifier; doubles as the drag identifier for pinned tabs.
    let id: String
    let isCloseable: Bool
    /// SF Symbol name.
    let icon: String
    /// Fixed tab title for pinned kinds; nil when the title is per-tab
    /// (terminal process title, browser page title, editor filename).
    let staticLabel: String?
    /// Display-only shortcut badge shown in the tab bar. The real key binding
    /// lives on the menu item in AtelierApp; these two must be kept in step.
    let shortcutBadge: String?

    static let info = WorkspaceTabKind(
        id: "info", isCloseable: false, icon: "info.circle",
        staticLabel: NSLocalizedString("Info", comment: ""), shortcutBadge: "1"
    )
    static let agent = WorkspaceTabKind(
        id: "agent", isCloseable: false, icon: "sparkle",
        staticLabel: NSLocalizedString("Agent", comment: ""), shortcutBadge: "\u{21A9}"
    )
    static let changes = WorkspaceTabKind(
        id: "changes", isCloseable: false, icon: "arrow.triangle.branch",
        staticLabel: NSLocalizedString("Changes", comment: ""), shortcutBadge: "D"
    )
    static let terminal = WorkspaceTabKind(
        id: "terminal", isCloseable: true, icon: "terminal",
        staticLabel: nil, shortcutBadge: nil
    )
    static let browser = WorkspaceTabKind(
        id: "browser", isCloseable: true, icon: "globe",
        staticLabel: nil, shortcutBadge: nil
    )
    static let editor = WorkspaceTabKind(
        id: "editor", isCloseable: true, icon: "doc.text",
        staticLabel: nil, shortcutBadge: nil
    )
}
