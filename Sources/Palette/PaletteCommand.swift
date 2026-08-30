// ABOUTME: One command in the command palette, plus the context that gates availability.
// ABOUTME: Commands act by closure — the built-ins post the same notifications menu items post.

import Foundation

/// App state a command's availability may depend on. Computed fresh by the
/// palette's presenter each time it opens, so predicates never capture stale
/// view state.
struct PaletteContext {
    var workstreamActive: Bool
    var editorActive: Bool
    /// Whether the active workstream's Coding Agent can accept typed input
    /// right now (see `PromptInjector.canInject`). Gates stored-prompt commands.
    var agentCanReceivePrompt: Bool = false
}

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    /// Display-only shortcut badge, e.g. "⌘W". The real key binding lives on
    /// the menu item in AtelierApp; nil for palette-only commands.
    let shortcut: String?
    let isAvailable: @MainActor @Sendable (PaletteContext) -> Bool
    let action: @MainActor @Sendable () -> Void

    init(
        id: String,
        title: String,
        category: String,
        shortcut: String? = nil,
        isAvailable: @escaping @MainActor @Sendable (PaletteContext) -> Bool = { _ in true },
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.isAvailable = isAvailable
        self.action = action
    }
}
