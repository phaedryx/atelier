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
    let create = NSLocalizedString("Create", comment: "Palette category")
    let browser = NSLocalizedString("Browser", comment: "Palette category")

    let commands: [PaletteCommand] = [
        // Ungated, and `.addNew` is the reason: its receiver already decides
        // what "new" means from the current selection — a workstream in the
        // selected project, or, with nothing selected at all, the add-project
        // sheet. The title names the common case rather than the File menu's
        // bare "New", which says nothing in a list searched by title.
        PaletteCommand(id: "create.new", title: NSLocalizedString("New Workstream", comment: ""), category: create,
                       shortcut: "⌘N", action: post(.addNew)),
        PaletteCommand(id: "create.newProject", title: NSLocalizedString("New Project", comment: ""), category: create,
                       shortcut: "⌘⇧N", action: post(.addProject)),

        PaletteCommand(id: "tab.info", title: NSLocalizedString("Show Info", comment: ""), category: tabs,
                       shortcut: "⌘I", isAvailable: workstream, action: post(.toggleInfo)),
        PaletteCommand(id: "tab.agent", title: NSLocalizedString("Show Coding Agent", comment: ""), category: tabs,
                       shortcut: "⌘↩", isAvailable: workstream, action: post(.focusAgent)),
        // No badge: these two close and reorder like any other tab, so the ⌘N
        // that reaches them moves — and once closed, no number reaches them at
        // all. The palette and the tab bar's reopen buttons are their surface.
        PaletteCommand(id: "tab.changes", title: NSLocalizedString("Show Changes", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleChanges)),
        PaletteCommand(id: "tab.environment", title: NSLocalizedString("Show Environment", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleEnvironment)),
        PaletteCommand(id: "tab.newTerminal", title: NSLocalizedString("New Terminal", comment: ""), category: tabs,
                       shortcut: "⌘T", isAvailable: workstream, action: post(.toggleTerminal)),
        PaletteCommand(id: "tab.newBrowser", title: NSLocalizedString("New Browser", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleBrowser)),
        PaletteCommand(id: "tab.newEditor", title: NSLocalizedString("New Editor", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleEditor)),
        // Gated on a workstream only, deliberately, even though the active tab
        // may be Info or Agent and therefore not closeable. That is this file's
        // consistent split: availability answers "is there a workspace to act
        // on", and the receiver answers "is there something to act on right
        // now" — `.closeTerminal`'s handler already checks `isCloseable`, the
        // same way `.rerunScript`'s checks for a resolved run command. Narrowing
        // this one would need the active tab plumbed into `PaletteContext`,
        // which `ContentView` cannot see, and would leave the rest inconsistent.
        PaletteCommand(id: "tab.close", title: NSLocalizedString("Close Tab", comment: ""), category: tabs,
                       shortcut: "⌘W", isAvailable: workstream, action: post(.closeTerminal)),
        // Two chords reach each of these — the Tabs menu binds ⌘⌥→/← and
        // `ContentView`'s key monitor takes ⌘⇧]/[ — and the badge advertises the
        // documented pair, the one README and HelpView list.
        PaletteCommand(id: "tab.next", title: NSLocalizedString("Next Tab", comment: ""), category: tabs,
                       shortcut: "⌘⇧]", isAvailable: workstream, action: post(.nextTab)),
        PaletteCommand(id: "tab.previous", title: NSLocalizedString("Previous Tab", comment: ""), category: tabs,
                       shortcut: "⌘⇧[", isAvailable: workstream, action: post(.prevTab)),

        PaletteCommand(id: "editor.findFile", title: NSLocalizedString("Find File", comment: ""), category: editorCategory,
                       shortcut: "⌘P", isAvailable: editor, action: post(.toggleFileFinder)),
        PaletteCommand(id: "editor.save", title: NSLocalizedString("Save", comment: ""), category: editorCategory,
                       shortcut: "⌘S", isAvailable: editor, action: post(.saveEditor)),
        PaletteCommand(id: "editor.saveAs", title: NSLocalizedString("Save As...", comment: ""), category: editorCategory,
                       shortcut: "⌘⇧S", isAvailable: editor, action: post(.saveEditorAs)),

        // Workstream-gated only, and receiver-guarded past that: `BrowserView`
        // is the only listener, so with no browser tab open this posts into
        // nothing — the same split `tab.close` is commented for above.
        PaletteCommand(id: "browser.addressBar", title: NSLocalizedString("Focus Address Bar", comment: ""),
                       category: browser, shortcut: "⌘L", isAvailable: workstream, action: post(.focusAddressBar)),

        PaletteCommand(id: "run.startRerun", title: NSLocalizedString("Start/Rerun", comment: ""), category: run,
                       shortcut: "⌘⇧↩", isAvailable: workstream, action: post(.rerunScript)),
        // The other half of Run, and a different phase: `.rerunScript` is
        // `execute`, this is `bootstrap`. No badge, because bootstrap is not a
        // thing you reach for often enough to spend a chord on — the palette
        // and the Info tab's own Rerun button are its surface. Workstream-gated
        // only; whether a bootstrap can start *right now* is the receiver's
        // question, the same split `tab.close` is commented for above.
        PaletteCommand(id: "run.rerunBootstrap", title: NSLocalizedString("Rerun Bootstrap", comment: ""), category: run,
                       isAvailable: workstream, action: post(.rerunBootstrap)),

        PaletteCommand(id: "changes.submitReview", title: NSLocalizedString("Submit Review Comments", comment: ""), category: changes,
                       isAvailable: workstream, action: post(.submitChangeReview)),

        PaletteCommand(id: "external.browser", title: NSLocalizedString("Open in External Browser", comment: ""), category: external,
                       shortcut: "⌘⌥B", isAvailable: workstream, action: post(.openExternalBrowser)),
        PaletteCommand(id: "external.terminal", title: NSLocalizedString("Open in External Terminal", comment: ""), category: external,
                       shortcut: "⌘⌥T", isAvailable: workstream, action: post(.openExternalTerminal)),

        PaletteCommand(id: "nav.backToProject", title: NSLocalizedString("Back to Project", comment: ""), category: navigation,
                       shortcut: "⌘0", isAvailable: workstream, action: post(.switchToProject)),
        // Not workstream-gated: all four work from a selected project row too,
        // and their receivers in `ContentView` already refuse when there is
        // nothing to cycle. Gating on `workstreamActive` would hide them in
        // exactly the view where "next workstream" is the obvious next move.
        PaletteCommand(id: "nav.nextWorkstream", title: NSLocalizedString("Next Workstream", comment: ""),
                       category: navigation, shortcut: "⌘]", action: post(.nextWorkstream)),
        PaletteCommand(id: "nav.previousWorkstream", title: NSLocalizedString("Previous Workstream", comment: ""),
                       category: navigation, shortcut: "⌘[", action: post(.prevWorkstream)),
        PaletteCommand(id: "nav.nextProject", title: NSLocalizedString("Next Project", comment: ""),
                       category: navigation, shortcut: "⌘↓", action: post(.nextProject)),
        PaletteCommand(id: "nav.previousProject", title: NSLocalizedString("Previous Project", comment: ""),
                       category: navigation, shortcut: "⌘↑", action: post(.prevProject)),
        PaletteCommand(id: "workstream.rename", title: NSLocalizedString("Rename Workstream", comment: ""), category: navigation,
                       shortcut: "⌘⇧R", isAvailable: workstream, action: post(.renameWorkstream)),
        PaletteCommand(id: "workstream.archive", title: NSLocalizedString("Archive Workstream", comment: ""), category: navigation,
                       shortcut: "⌘⇧W", isAvailable: workstream, action: post(.archiveWorkstream)),

        PaletteCommand(id: "app.toggleSidebar", title: NSLocalizedString("Toggle Sidebar", comment: ""), category: app,
                       shortcut: "⌘⇧C", action: post(.toggleSidebar)),
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

    return commands + settingsPaneCommands(category: app)
}

/// One deep-link per Settings pane, so the palette reaches a named pane rather
/// than only "Settings" — `.openSettings` already carries a pane's raw value,
/// so nothing new is needed on the receiving side.
///
/// `.prompts` is skipped because `app.editPrompts` above already opens it under
/// a title that says what the pane is for; two rows opening one pane is noise,
/// and the one with the better title should win.
@MainActor
private func settingsPaneCommands(category: String) -> [PaletteCommand] {
    SettingsPane.allCases.filter { $0 != .prompts }.map { pane in
        PaletteCommand(
            id: "app.settingsPane.\(pane.rawValue)",
            title: String(
                format: NSLocalizedString("Settings: %@", comment: "Palette command opening one Settings pane"),
                pane.title
            ),
            category: category,
            action: {
                NotificationCenter.default.post(name: .openSettings, object: pane.rawValue)
            }
        )
    }
}

/// Id prefix reserved for the go-to command family: one command per project and
/// one per workstream, rebuilt whenever the project list changes.
///
/// Deliberately not `workstream.` or `project.`. `CommandRegistry.sync` clears
/// every id carrying the prefix it is handed, and `workstream.rename` and
/// `workstream.archive` are static built-ins — a dynamic family under
/// `workstream.` would delete both on its first emission, which is the same
/// hazard `storedPromptCommandPrefix` documents below.
let gotoCommandPrefix = "goto."

/// Palette commands that jump straight to one named project or workstream,
/// rebuilt from the project list by `CommandRegistry.sync`.
///
/// This is the palette's only route to a *named* destination — every other
/// navigation command cycles (`nav.nextWorkstream` and friends) or goes up one
/// level (`nav.backToProject`), so without these the sidebar is the only way to
/// reach a specific workstream.
///
/// A workstream's title carries its project's name ahead of its own, so two
/// projects holding a workstream of the same name stay distinguishable and
/// typing either half finds it. `/` is not alphanumeric, so `FuzzyMatcher`
/// treats the workstream name as starting a word and scores it accordingly.
///
/// Ungated, unlike every other dynamic family: jumping to a workstream is how
/// you *reach* one, so requiring an active workstream would defeat the point.
@MainActor
func gotoPaletteCommands(for projects: [Project]) -> [PaletteCommand] {
    let category = NSLocalizedString("Go To", comment: "Palette category")
    return projects.flatMap { project -> [PaletteCommand] in
        let projectCommand = PaletteCommand(
            id: "\(gotoCommandPrefix)project.\(project.id.uuidString.lowercased())",
            title: project.name,
            category: category,
            action: {
                NotificationCenter.default.post(name: .focusProject, object: project.id)
            }
        )
        return [projectCommand] + project.workstreams.map { workstream in
            PaletteCommand(
                id: "\(gotoCommandPrefix)workstream.\(workstream.id.uuidString.lowercased())",
                title: "\(project.name) / \(workstream.label)",
                category: category,
                action: {
                    NotificationCenter.default.post(name: .focusWorkstream, object: workstream.id)
                }
            )
        }
    }
}

/// Id prefix reserved for the stored-prompt command family. `CommandRegistry.sync`
/// replaces every command under it wholesale, so no other command may be named
/// with this prefix — a built-in called `prompt.something` would be silently
/// dropped on the store's first emission.
let storedPromptCommandPrefix = "prompt."

/// The one canonical spelling of a stored prompt's identity in the palette: the
/// part of the command id after `storedPromptCommandPrefix`, and the whole of
/// the `.runStoredPrompt` payload.
///
/// The two used to be derived separately and disagreed on case — the id
/// lowercased the UUID, the payload used `uuidString`, which is uppercase. It
/// went unnoticed because the sole receiver reparses the payload as a `UUID`
/// and `UUID(uuidString:)` is case-insensitive; anything correlating a posted
/// notification back to its command by string comparison missed every time.
func storedPromptCommandKey(_ promptID: UUID) -> String {
    promptID.uuidString.lowercased()
}

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
            id: "\(storedPromptCommandPrefix)\(storedPromptCommandKey(prompt.id))",
            title: prompt.label,
            category: category,
            isAvailable: { $0.workstreamActive && $0.agentCanReceivePrompt },
            action: {
                NotificationCenter.default.post(
                    name: .runStoredPrompt,
                    object: storedPromptCommandKey(prompt.id)
                )
            }
        )
    }
}
