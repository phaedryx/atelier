// ABOUTME: Per-kind metadata for workspace tabs: identity, closeability, icon, label, badge.
// ABOUTME: The single place a tab kind's static facts live; the tab bar reads it via WorkspaceTab.kind.

import Foundation

/// The static facts about one kind of workspace tab. The tab bar renders from
/// this table instead of switching on the enum at every call site, so adding a
/// kind means one entry here, one case in `WorkspaceTab`, and one case in
/// `tabContent`; the remaining per-kind switches (restore mapping, occlusion,
/// seeding, removal) are exhaustive, so the compiler walks you to each one.
///
/// Only Info and Agent are permanent. Changes and Environment are singletons —
/// there is exactly one of each — but they close and reopen like any terminal
/// or browser, and they sit in the same draggable strip.
struct WorkspaceTabKind: Equatable, Hashable {
    /// Stable identifier; doubles as the drag identifier for the singleton
    /// kinds, which have no instance UUID to drag by.
    let id: String
    let isCloseable: Bool
    /// SF Symbol name.
    let icon: String
    /// Fixed tab title for the singleton kinds; nil when the title is per-tab
    /// (terminal process title, browser page title, editor filename). Doubles
    /// as the test for whether a tab counts toward compact mode — only tabs
    /// whose label is per-tab lose it.
    let staticLabel: String?
    /// Display-only shortcut badge shown in the tab bar, for the kinds with a
    /// dedicated named binding. The real key binding lives on the menu item in
    /// AtelierApp; these two must be kept in step. Closeable kinds leave this
    /// nil and fall through to a positional badge — their ⌘N depends on what
    /// else is open, so the tab bar derives it from the live tab order.
    let shortcutBadge: String?

    /// ⌘I is the dedicated menu binding; ⌘1 still reaches Info positionally
    /// through the switchByNumber monitor, but the badge shows the named key —
    /// the same precedence Agent's ↩ badge takes over its positional ⌘2.
    static let info = WorkspaceTabKind(
        id: "info", isCloseable: false, icon: "info.circle",
        staticLabel: NSLocalizedString("Info", comment: ""), shortcutBadge: "I"
    )
    static let agent = WorkspaceTabKind(
        id: "agent", isCloseable: false, icon: "sparkle",
        staticLabel: NSLocalizedString("Agent", comment: ""), shortcutBadge: "\u{21A9}"
    )
    static let changes = WorkspaceTabKind(
        id: "changes", isCloseable: true, icon: "arrow.triangle.branch",
        staticLabel: NSLocalizedString("Changes", comment: ""), shortcutBadge: nil
    )
    static let environment = WorkspaceTabKind(
        id: "environment", isCloseable: true, icon: "play.circle",
        staticLabel: NSLocalizedString("Environment", comment: ""), shortcutBadge: nil
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
