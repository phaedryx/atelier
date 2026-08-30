// ABOUTME: The built-in palette command set — every workspace action the menus expose.
// ABOUTME: Each action posts the same notification its menu item posts; guards in the
// ABOUTME: receiving views make them safe no-ops when nothing relevant is mounted.

import Foundation

@MainActor
func defaultPaletteCommands() -> [PaletteCommand] {
    let workstream: @MainActor @Sendable (PaletteContext) -> Bool = { $0.workstreamActive }
    let editor: @MainActor @Sendable (PaletteContext) -> Bool = { $0.workstreamActive && $0.editorActive }

    func post(_ name: Notification.Name) -> @MainActor @Sendable () -> Void {
        { NotificationCenter.default.post(name: name, object: nil) }
    }

    let tabs = NSLocalizedString("Tabs", comment: "Palette category")
    let editorCategory = NSLocalizedString("Editor", comment: "Palette category")
    let run = NSLocalizedString("Run", comment: "Palette category")
    let changes = NSLocalizedString("Changes", comment: "Palette category")
    let external = NSLocalizedString("External", comment: "Palette category")
    let navigation = NSLocalizedString("Navigation", comment: "Palette category")
    let app = NSLocalizedString("Application", comment: "Palette category")

    return [
        PaletteCommand(id: "tab.info", title: NSLocalizedString("Show Info", comment: ""), category: tabs,
                       shortcut: "⌘1", isAvailable: workstream, action: post(.toggleInfo)),
        PaletteCommand(id: "tab.agent", title: NSLocalizedString("Show Coding Agent", comment: ""), category: tabs,
                       shortcut: "⌘↩", isAvailable: workstream, action: post(.focusAgent)),
        // Positional badges (⌘3/⌘4) reflect the switchByNumber monitor; the
        // open-tab commands have no binding at all — the palette IS their surface.
        PaletteCommand(id: "tab.changes", title: NSLocalizedString("Show Changes", comment: ""), category: tabs,
                       shortcut: "⌘3", isAvailable: workstream, action: post(.toggleChanges)),
        PaletteCommand(id: "tab.environment", title: NSLocalizedString("Show Environment", comment: ""), category: tabs,
                       shortcut: "⌘4", isAvailable: workstream, action: post(.toggleEnvironment)),
        PaletteCommand(id: "tab.newTerminal", title: NSLocalizedString("New Terminal", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleTerminal)),
        PaletteCommand(id: "tab.newBrowser", title: NSLocalizedString("New Browser", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleBrowser)),
        PaletteCommand(id: "tab.newEditor", title: NSLocalizedString("New Editor", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleEditor)),
        PaletteCommand(id: "tab.close", title: NSLocalizedString("Close Tab", comment: ""), category: tabs,
                       shortcut: "⌘W", isAvailable: workstream, action: post(.closeTerminal)),

        PaletteCommand(id: "editor.findFile", title: NSLocalizedString("Find File", comment: ""), category: editorCategory,
                       shortcut: "⌘P", isAvailable: editor, action: post(.toggleFileFinder)),
        PaletteCommand(id: "editor.save", title: NSLocalizedString("Save", comment: ""), category: editorCategory,
                       shortcut: "⌘S", isAvailable: editor, action: post(.saveEditor)),
        PaletteCommand(id: "editor.saveAs", title: NSLocalizedString("Save As...", comment: ""), category: editorCategory,
                       shortcut: "⌘⇧S", isAvailable: editor, action: post(.saveEditorAs)),

        PaletteCommand(id: "run.startRerun", title: NSLocalizedString("Start/Rerun", comment: ""), category: run,
                       shortcut: "⌘⇧↩", isAvailable: workstream, action: post(.rerunScript)),

        PaletteCommand(id: "changes.submitReview", title: NSLocalizedString("Submit Review Comments", comment: ""), category: changes,
                       isAvailable: workstream, action: post(.submitChangeReview)),

        PaletteCommand(id: "external.browser", title: NSLocalizedString("Open in External Browser", comment: ""), category: external,
                       shortcut: "⌘⌥B", isAvailable: workstream, action: post(.openExternalBrowser)),
        PaletteCommand(id: "external.terminal", title: NSLocalizedString("Open in External Terminal", comment: ""), category: external,
                       shortcut: "⌘⌥T", isAvailable: workstream, action: post(.openExternalTerminal)),

        PaletteCommand(id: "nav.backToProject", title: NSLocalizedString("Back to Project", comment: ""), category: navigation,
                       shortcut: "⌘0", isAvailable: workstream, action: post(.switchToProject)),
        PaletteCommand(id: "workstream.rename", title: NSLocalizedString("Rename Workstream", comment: ""), category: navigation,
                       shortcut: "⌘⇧R", isAvailable: workstream, action: post(.renameWorkstream)),
        PaletteCommand(id: "workstream.archive", title: NSLocalizedString("Archive Workstream", comment: ""), category: navigation,
                       shortcut: "⌘⇧W", isAvailable: workstream, action: post(.archiveWorkstream)),

        PaletteCommand(id: "app.settings", title: NSLocalizedString("Settings", comment: ""), category: app,
                       shortcut: "⌘,", action: post(.openSettings)),
        // Deep-links straight to the Prompts pane. Note this is `app.` and not
        // `prompt.`: ids under that prefix belong to the stored-prompt family
        // and are replaced wholesale on every store change.
        PaletteCommand(id: "app.editPrompts", title: NSLocalizedString("Edit Stored Prompts...", comment: ""),
                       category: app, action: {
                           NotificationCenter.default.post(
                               name: .openSettings,
                               object: SettingsPane.prompts.rawValue
                           )
                       }),
        PaletteCommand(id: "app.help", title: NSLocalizedString("Help", comment: ""), category: app,
                       shortcut: "⌘/", action: post(.openHelp)),
    ]
}

/// Id prefix reserved for the stored-prompt command family. `CommandRegistry.sync`
/// replaces every command under it wholesale, so no other command may be named
/// with this prefix — a built-in called `prompt.something` would be silently
/// dropped on the store's first emission.
let storedPromptCommandPrefix = "prompt."

/// Palette commands for the user's stored prompts, rebuilt whenever the store
/// changes (`CommandRegistry.sync`). Each command posts the prompt's id;
/// the active `TerminalContainerView` resolves it, switches to the Agent tab,
/// and types the prompt via `PromptInjector`. Hidden unless that workstream's
/// agent pane can actually take the text, so the palette never offers a prompt
/// that would land in someone's work — or vanish into a pane with no surface.
@MainActor
func promptPaletteCommands(for prompts: [StoredPrompt]) -> [PaletteCommand] {
    let category = NSLocalizedString("Prompts", comment: "Palette category")
    return prompts.map { prompt in
        PaletteCommand(
            id: "\(storedPromptCommandPrefix)\(prompt.id.uuidString.lowercased())",
            title: prompt.label,
            category: category,
            isAvailable: { $0.workstreamActive && $0.agentCanReceivePrompt },
            action: {
                NotificationCenter.default.post(name: .runStoredPrompt, object: prompt.id.uuidString)
            }
        )
    }
}
