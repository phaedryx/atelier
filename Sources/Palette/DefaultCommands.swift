// ABOUTME: The built-in palette command set — every workspace action the menus expose.
// ABOUTME: Each action does exactly what its menu item does: sends an AppCommand, or posts
// ABOUTME: the notification the tab and sidebar families still use. Guards in the receiving
// ABOUTME: views make the notification half safe no-ops when nothing relevant is mounted.

import Foundation

@MainActor
func defaultPaletteCommands() -> [PaletteCommand] {
    let workstream: @MainActor @Sendable (PaletteContext) -> Bool = { $0.workstreamActive }
    let editor: @MainActor @Sendable (PaletteContext) -> Bool = { $0.workstreamActive && $0.editorActive }

    // Two helpers, because the conversion to `AppCommand` is half done by
    // design: `send` is for the commands `ContentView` receives, `post` for the
    // families still received in `ProjectSidebar` and `TerminalContainerView`.
    func send(_ command: AppCommand) -> @MainActor @Sendable () -> Void {
        { AppCommandChannel.shared.send(command) }
    }

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
    let git = NSLocalizedString("Git", comment: "Palette category")

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
        // The two variants the sidebar's add menu offers. `.addNew` carries the
        // choice as its payload; with no payload it means "whatever the
        // `atelier.bypassPermissions` default says", which is what `create.new`
        // above posts and what every other producer of this notification wants.
        PaletteCommand(id: "create.newFullPermissions",
                       title: NSLocalizedString("New Workstream (Full Permissions)", comment: ""),
                       category: create, action: {
                           NotificationCenter.default.post(name: .addNew, object: true)
                       }),
        PaletteCommand(id: "create.newWithPrompts",
                       title: NSLocalizedString("New Workstream (With Prompts)", comment: ""),
                       category: create, action: {
                           NotificationCenter.default.post(name: .addNew, object: false)
                       }),

        PaletteCommand(id: "tab.info", title: NSLocalizedString("Show Info", comment: ""), category: tabs,
                       shortcut: "⌘I", isAvailable: workstream, action: post(.toggleInfo)),
        PaletteCommand(id: "tab.agent", title: NSLocalizedString("Show Coding Agent", comment: ""), category: tabs,
                       shortcut: "⌘↩", isAvailable: workstream, action: post(.focusAgent)),
        // No badge: these three close and reorder like any other tab, so the ⌘N
        // that reaches them moves — and once closed, no number reaches them at
        // all. The palette and the tab bar's reopen buttons are their surface.
        PaletteCommand(id: "tab.changes", title: NSLocalizedString("Show Changes", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleChanges)),
        PaletteCommand(id: "tab.execution", title: NSLocalizedString("Show Execution", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleExecution)),
        PaletteCommand(id: "tab.verification", title: NSLocalizedString("Show Verification", comment: ""), category: tabs,
                       isAvailable: workstream, action: post(.toggleVerification)),
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
        // `execute`, this is initialization. No badge, because setup is not a
        // thing you reach for often enough to spend a chord on — the palette
        // and the Info tab's own Rerun button are its surface. Workstream-gated
        // only; whether initialization can start *right now* is the receiver's
        // question, the same split `tab.close` is commented for above.
        PaletteCommand(id: "run.rerunInitialization", title: NSLocalizedString("Rerun Initialization", comment: ""), category: run,
                       isAvailable: workstream, action: post(.rerunInitialization)),

        PaletteCommand(id: "changes.submitReview", title: NSLocalizedString("Submit Review Comments", comment: ""), category: changes,
                       isAvailable: workstream, action: post(.submitChangeReview)),

        // Acts on the selected workstream, resolved by the receiver in
        // `ContentView` — the sidebar's own context-menu items read row-local
        // values the palette has no access to.
        PaletteCommand(id: "workstream.revealInFinder", title: NSLocalizedString("Reveal in Finder", comment: ""),
                       category: external, isAvailable: workstream, action: send(.revealInFinder)),
        // Hidden rather than disabled when there is nothing to open, the same
        // choice the sidebar's context menu makes by omitting the item: a
        // workstream with no pull request has no reason for the row to exist,
        // and "there is no PR" is not a condition the user acts on from here.
        PaletteCommand(id: "workstream.openOnGitHub", title: NSLocalizedString("Open on GitHub", comment: ""),
                       category: external,
                       isAvailable: { $0.workstreamActive && $0.hasGitHubRemote }, action: send(.openOnGitHub)),
        PaletteCommand(id: "workstream.openPullRequest", title: NSLocalizedString("Open Pull Request", comment: ""),
                       category: external,
                       isAvailable: { $0.workstreamActive && $0.hasPullRequest }, action: send(.openPullRequest)),
        PaletteCommand(id: "workstream.openInShortcut", title: NSLocalizedString("Open in Shortcut", comment: ""),
                       category: external,
                       isAvailable: { $0.workstreamActive && $0.hasShortcutStory }, action: send(.openInShortcut)),
        PaletteCommand(id: "workstream.copyBranchName", title: NSLocalizedString("Copy Branch Name", comment: ""),
                       category: navigation, isAvailable: workstream, action: send(.copyBranchName)),
        PaletteCommand(id: "workstream.copyWorktreePath", title: NSLocalizedString("Copy Worktree Path", comment: ""),
                       category: navigation, isAvailable: workstream, action: send(.copyWorktreePath)),

        PaletteCommand(id: "external.browser", title: NSLocalizedString("Open in External Browser", comment: ""), category: external,
                       shortcut: "⌘⌥B", isAvailable: workstream, action: post(.openExternalBrowser)),
        PaletteCommand(id: "external.terminal", title: NSLocalizedString("Open in External Terminal", comment: ""), category: external,
                       shortcut: "⌘⌥T", isAvailable: workstream, action: send(.openExternalTerminal)),

        PaletteCommand(id: "nav.backToProject", title: NSLocalizedString("Back to Project", comment: ""), category: navigation,
                       shortcut: "⌘0", isAvailable: workstream, action: send(.switchToProject)),
        // Not workstream-gated: all four work from a selected project row too,
        // and their receivers in `ContentView` already refuse when there is
        // nothing to cycle. Gating on `workstreamActive` would hide them in
        // exactly the view where "next workstream" is the obvious next move.
        PaletteCommand(id: "nav.nextWorkstream", title: NSLocalizedString("Next Workstream", comment: ""),
                       category: navigation, shortcut: "⌘]", action: send(.nextWorkstream)),
        PaletteCommand(id: "nav.previousWorkstream", title: NSLocalizedString("Previous Workstream", comment: ""),
                       category: navigation, shortcut: "⌘[", action: send(.prevWorkstream)),
        PaletteCommand(id: "nav.nextProject", title: NSLocalizedString("Next Project", comment: ""),
                       category: navigation, shortcut: "⌘↓", action: send(.nextProject)),
        PaletteCommand(id: "nav.previousProject", title: NSLocalizedString("Previous Project", comment: ""),
                       category: navigation, shortcut: "⌘↑", action: send(.prevProject)),
        PaletteCommand(id: "workstream.rename", title: NSLocalizedString("Rename Workstream", comment: ""), category: navigation,
                       shortcut: "⌘⇧R", isAvailable: workstream, action: post(.renameWorkstream)),
        PaletteCommand(id: "workstream.archive", title: NSLocalizedString("Archive Workstream", comment: ""), category: navigation,
                       shortcut: "⌘⇧W", isAvailable: workstream, action: send(.archiveWorkstream)),
        // Destructive, and sitting one fuzzy match away from Archive — but the
        // receiver is `ContentView.confirmPurge`, the same entrance the sidebar's
        // context menu uses, so `purgeWarning` and `destroyableWorktreePath` still
        // stand between this row and `git worktree remove`. Posted with no payload:
        // the receiver reads the current selection, because a palette command
        // closure is built once and cannot know which workstream is active.
        PaletteCommand(id: "workstream.purge", title: NSLocalizedString("Purge Workstream", comment: ""), category: navigation,
                       isAvailable: workstream, action: send(.purgeWorkstream(nil))),

        PaletteCommand(id: "app.toggleSidebar", title: NSLocalizedString("Toggle Sidebar", comment: ""), category: app,
                       shortcut: "⌘⇧C", action: send(.toggleSidebar)),
        PaletteCommand(id: "app.settings", title: NSLocalizedString("Settings", comment: ""), category: app,
                       shortcut: "⌘,", action: send(.openSettings(pane: nil))),
        // Deep-links straight to the Prompts pane. Note this is `app.` and not
        // `prompt.`: ids under that prefix belong to the stored-prompt family
        // and are replaced wholesale on every store change.
        PaletteCommand(id: "app.editPrompts", title: NSLocalizedString("Edit Stored Prompts...", comment: ""),
                       category: app, action: send(.openSettings(pane: .prompts))),
        PaletteCommand(id: "app.help", title: NSLocalizedString("Help", comment: ""), category: app,
                       shortcut: "⌘/", action: send(.openHelp)),
    ]

    return commands + quickActionCommands(category: git) + settingsPaneCommands(category: app)
}

/// The four quick actions the GitHub toolbar menu runs, as palette commands.
///
/// Disabled rather than hidden when a tool is missing, because the reason is
/// something the user can act on. `QuickAction.unavailableReason` is the one
/// copy of that decision — shared with the menu's `.disabled` and with the
/// receiver that runs them — so a row cannot offer what the runner refuses.
///
/// What this deliberately does *not* mirror is the menu's repo-state filtering
/// (offering Push only when something is unpushed). That is the menu choosing a
/// single primary action for a toolbar button; a palette searched by name should
/// find "Commit" whether or not the tree is dirty, and a no-op `git push` says
/// so in its own output.
@MainActor
private func quickActionCommands(category: String) -> [PaletteCommand] {
    QuickAction.allCases.map { action in
        PaletteCommand(
            id: "git.\(action.rawValue)",
            title: action.label,
            category: category,
            availability: { context in
                guard context.workstreamActive else { return .hidden }
                if let reason = QuickAction.unavailableReason(
                    for: action,
                    claudeInstalled: context.claudeInstalled,
                    ghInstalled: context.ghInstalled,
                    bypassPermissions: context.bypassPermissions
                ) {
                    return .disabled(reason)
                }
                return .available
            },
            action: {
                NotificationCenter.default.post(name: .runQuickAction, object: action.rawValue)
            }
        )
    }
}

/// One deep-link per Settings pane, so the palette reaches a named pane rather
/// than only "Settings" — `AppCommand.openSettings` already carries a pane, so
/// nothing new is needed on the receiving side.
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
                AppCommandChannel.shared.send(.openSettings(pane: pane))
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
                AppCommandChannel.shared.send(.focusProject(project.id))
            }
        )
        return [projectCommand] + project.workstreams.map { workstream in
            PaletteCommand(
                id: "\(gotoCommandPrefix)workstream.\(workstream.id.uuidString.lowercased())",
                title: "\(project.name) / \(workstream.label)",
                category: category,
                action: {
                    AppCommandChannel.shared.send(.focusWorkstream(workstream.id))
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
/// and types the prompt via `PromptInjector`.
///
/// **Disabled with its reason, never dropped.** These used to disappear whenever
/// the pane could not take the text, which is the common case — an agent is
/// mid-turn most of the time you reach for a prompt — and the palette simply
/// came up shorter, with nothing to say why. Worse, `surfaceStates` has no decay
/// path, so a single `Stop` hook lost by `atelier-hook`'s one-second curl hid
/// every prompt for the rest of the session. The gate itself is unchanged and
/// still lives in `PromptInjector`, which re-checks at delivery; what changed is
/// that a refusal is now something the user can read.
@MainActor
func promptPaletteCommands(for prompts: [StoredPrompt]) -> [PaletteCommand] {
    let category = NSLocalizedString("Prompts", comment: "Palette category")
    return prompts.map { prompt in
        PaletteCommand(
            id: "\(storedPromptCommandPrefix)\(storedPromptCommandKey(prompt.id))",
            title: prompt.label,
            category: category,
            availability: { context in
                guard context.workstreamActive else { return .hidden }
                if let reason = context.promptDelivery.reason {
                    return .disabled(reason)
                }
                return .available
            },
            action: {
                NotificationCenter.default.post(
                    name: .runStoredPrompt,
                    object: storedPromptCommandKey(prompt.id)
                )
            }
        )
    }
}

/// Id prefix reserved for the verification-check family: one command per check
/// the active project's `verification.yaml` declares, rebuilt whenever the
/// selection changes.
///
/// Deliberately not `verify.` alone and not `run.`: `CommandRegistry.sync`
/// clears every id carrying the prefix it is handed, and `run.startRerun` and
/// `run.rerunInitialization` are static built-ins — a family under `run.` would
/// delete both on its first emission, the hazard `gotoCommandPrefix` documents.
let verificationCommandPrefix = "verify.check."

/// Palette commands that start one declared verification check in the active
/// workstream, rebuilt from the project's config by `CommandRegistry.sync`.
///
/// Verification has no Run-all and no top-bar Stop by design — every row carries
/// its own button — so a keyboard route to a single named check is the palette's
/// to provide. The names are read from the config for the *list*; the run itself
/// goes through `Verification.Runner.start`, which loads the config again and is
/// the only thing that may refuse. The list is therefore advisory, the same split
/// `tab.close` is commented for above: availability answers "is there a workspace
/// to act on", the receiver answers "can this run right now".
@MainActor
func verificationPaletteCommands(for checkNames: [String]) -> [PaletteCommand] {
    let category = NSLocalizedString("Verification", comment: "Palette category")
    return checkNames.map { name in
        PaletteCommand(
            id: "\(verificationCommandPrefix)\(name)",
            title: String(
                format: NSLocalizedString("Run Check: %@", comment: "Palette command running one verification check"),
                name
            ),
            category: category,
            isAvailable: { $0.workstreamActive },
            action: {
                NotificationCenter.default.post(name: .runVerificationCheck, object: name)
            }
        )
    }
}
