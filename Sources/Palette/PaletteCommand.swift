// ABOUTME: One command in the command palette, plus the context that gates availability.
// ABOUTME: Commands act by closure — the built-ins post the same notifications menu items post.

import Foundation

/// App state a command's availability may depend on. Computed fresh by the
/// palette's presenter each time it opens, so predicates never capture stale
/// view state.
struct PaletteContext {
    var workstreamActive: Bool
    var editorActive: Bool
    /// Why the active workstream's Coding Agent cannot take typed input right
    /// now, or `.ready` when it can (see `PromptInjector.deliverability`).
    /// Stored-prompt commands render their reason rather than disappearing.
    var promptDelivery: PromptInjector.Deliverability = .ready
    /// The Claude Code CLI is installed. Gates the quick actions that fork an
    /// agent, the same way `GitHubActionMenu` gates its buttons.
    var claudeInstalled: Bool = true
    /// The `gh` CLI is installed.
    var ghInstalled: Bool = true
    /// The active workstream's own `bypassPermissions` — the flag it was created
    /// with, not a global setting. A quick action that forks an agent needs it,
    /// because nobody is watching that agent's permission prompts.
    var bypassPermissions: Bool = false
    /// The active workstream's project has a GitHub remote.
    var hasGitHubRemote: Bool = false
    /// A pull request is known for the active workstream's branch.
    var hasPullRequest: Bool = false
    /// A Shortcut story is attached to the active workstream.
    var hasShortcutStory: Bool = false
}

/// Whether a command may run, and if not, whether the palette should say so.
///
/// Three cases, not two, because "hidden" and "disabled" answer different
/// questions. A command for a surface that is not on screen (Save, with no
/// editor) has nothing to explain and is `.hidden`. A command the user is
/// deliberately reaching for, refused by a condition they can act on — the
/// agent is mid-turn, `gh` is not installed — is `.disabled(reason)`, and
/// disappearing silently is the failure mode that makes the feature look
/// broken rather than gated.
enum PaletteAvailability: Equatable {
    case available
    case hidden
    case disabled(String)

    var reason: String? {
        if case let .disabled(reason) = self {
            return reason
        }
        return nil
    }
}

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    /// Display-only shortcut badge, e.g. "⌘W". The real key binding lives on
    /// the menu item in AtelierApp; nil for palette-only commands.
    let shortcut: String?
    let availability: @MainActor @Sendable (PaletteContext) -> PaletteAvailability
    let action: @MainActor @Sendable () -> Void

    /// The common case: a command is either offered or not shown at all.
    init(
        id: String,
        title: String,
        category: String,
        shortcut: String? = nil,
        isAvailable: @escaping @MainActor @Sendable (PaletteContext) -> Bool = { _ in true },
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.init(
            id: id,
            title: title,
            category: category,
            shortcut: shortcut,
            availability: { isAvailable($0) ? .available : .hidden },
            action: action
        )
    }

    /// For a command that stays visible while refused, carrying the reason.
    init(
        id: String,
        title: String,
        category: String,
        shortcut: String? = nil,
        availability: @escaping @MainActor @Sendable (PaletteContext) -> PaletteAvailability,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.availability = availability
        self.action = action
    }

    /// Whether the command can run in `context`. A disabled command is listed
    /// but not runnable, so this is false for it.
    @MainActor
    func isAvailable(_ context: PaletteContext) -> Bool {
        availability(context) == .available
    }
}
