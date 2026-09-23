# Views, data flow and the command palette

Where state lives, what redraws, the palette's three availability cases, and the
keyboard shortcut tables that have to be reconciled by hand.

### Data flow
- **Projects/workstreams** stored in UserDefaults (`atelier.projects`), accessed via `ProjectStore`. Wrapped in `ProjectList: ObservableObject` for reference-type semantics.
- **Settings** use `@AppStorage` (UserDefaults), keyed as `atelier.*`
- **Terminal surfaces** cached in `TerminalSurfaceCache` (keyed by UUID)
- **`TerminalView.workstreamID` is a *surface* id**, and only the Coding Agent tab's is also a
  workstream id — every other surface is `derivedUUID(from: workstreamID, salt:)`.
  `.terminalTitleChanged` posts that field and its receiver keys tab titles by surface id, so the
  name is wrong and the meaning is load-bearing: do not repurpose it. `.terminalActivity` needs the
  other thing, because **both** its receivers key by workstream id — `ProjectSidebar`'s Recent
  ordering and `TerminalContainerView`'s worktree-state refresh — so posting the field meant
  nothing but the Coding Agent tab ever counted as activity, and an hour's work in a terminal tab
  moved no row and refreshed no quick-action state. `TerminalSurfaceCache.workstreamID(owningSurface:)`
  resolves it at post time, through `TerminalView.activityOwner`, and resolving *there* rather than
  recording an owner at creation is what makes it hold for surfaces this file does not create —
  `open_agent_tab`'s terminal tab has no view at all. A derivation cannot be inverted, so it asks the
  three things that hold a surface: a workstream's own id, a terminal tab, and a run session's
  current generation. An unclaimed surface falls back to the surface id, which is what the receivers
  already ignore — and is what keeps the agent surface reporting before its `WorkspaceModel` exists.
- **Git repo info** cached in `AppEnvironment`, refreshed async every 15s
- **What is known about a worktree is one value, `Worktree.Facts`**, keyed by worktree path
  and read through `AppEnvironment.facts(for:)`. It replaced five path-keyed dictionaries —
  branch, path validity, task description, Shortcut story id, active port — plus
  `Worktree.State`, each with its own accessor, and the older accessors survive as thin
  wrappers over it so the defaults they encode (an unswept path is *valid*) stay in one place.
  Three things about it are load-bearing:
  - **Two facts deliberately stayed out.** A **pull request** is a *branch* fact and stays in
    `githubBranchPRCache` keyed `"dir|branch"`, because `ProjectOverviewView`'s worktree list
    renders a PR badge for worktrees that are not workstreams at all — rows fed by
    `listWorktreesWithInfo`, which a cache filled from `project.workstreams` can never cover.
    `AppEnvironment.pullRequest(forWorktree:in:)` is the one place the two lookups are
    composed; it replaced `branch.flatMap { appEnv.githubPR(for: dir, branch: $0) }` written
    out verbatim at six call sites. `hasGitHubRemote` and the GitHub browser URL are **project**
    facts keyed by `directory`, for the reason the sidebar's branch button already documents.
  - **The sweep folds rather than assigns.** `Worktree.Facts.applying(_:to:)` is pure and is the
    only place each field's carry-forward rule is written down, because the six caches it
    replaced disagreed: four were `merge`d and two were assigned wholesale. `shortcutStoryID`
    appears nowhere in `Swept` — no sweep can learn it, `ContentView.syncShortcutStoryIDs`
    writes it — so it survives only by being carried, and an assignment would have dropped
    every workstream's story on the next tick. Paths the sweep did not visit are kept, never
    pruned: a sweep carries the project snapshot it started with, so a workstream created while
    it was in flight is not in it.
  - **`Facts` is `Equatable` and the sweep compares before publishing.** `commitChanges` sends
    `objectWillChange` as its *first* act, so a guard inside it publishes anyway; the sweep runs
    every fifteen seconds and almost always finds nothing moved, so an unconditional publish
    redrew every row in the app on a timer. `mutateFacts` applies the same rule to the
    single-field writers — `refreshBranchName` off the HeadWatcher, `refreshWorktreeState`,
    `registerShortcutStory`.
  Dirtiness rides in as a **tri-state** (`Worktree.Cleanliness`), taken from the `repoInfo` the
  sweep already ran and threw away. That is what let `WorkstreamInfoView` stop shelling out for
  its own branch and dirtiness into view-local `@State` — a second, quietly divergent copy of
  both — and it stopped that tab rendering a green "Clean" for a `git status` that never ran.
  Its appearance still probes, through `refreshGitFacts(for:)` — `refreshBranchName`'s wider
  sibling, and deliberately not what the HeadWatcher calls.
- **Branch renames** land immediately: `Worktree.HeadWatcher` watches each worktree's resolved
  git directory (the one holding `HEAD`, which for a linked worktree is *not* `<worktree>/.git`)
  and fires a debounced callback, which re-reads that one branch via
  `AppEnvironment.refreshBranchName(for:)`. The 15s poll stays as the backstop; the watcher only
  makes the common case instant. The callback fires on any git activity in the worktree, so
  anything hung off it must stay cheap and no-op when the branch has not changed.
- **Blocked-agent notification**: `Workstream.AgentStateTracker` posts
  `.agentBlockedOnPermission` / `.agentPermissionResolved` on the *edges* into and out of
  `.needsAttention(.permission)` — an edge because Claude's `Notification` hook repeats while one
  prompt sits unanswered. `ContentView` receives them, because the banner needs the workstream's
  name and the current selection and the tracker knows workstreams only by id; a closure
  installed from there would capture a stale snapshot of both.
  `Workstream.PermissionNotifier` decides whether to show (suppressed only when the workstream is
  selected *and* the app is frontmost), keys the request by the workstream's UUID so a second
  prompt replaces the banner rather than stacking one, and withdraws it when the block clears.
  Clicking it goes back through `AppDelegate`'s `didReceive` as `.focusWorkstream`, which selects
  that workstream. Gated by `atelier.notifyOnPermission`, which **defaults on**.
- **Tool detection** runs at startup in `AppEnvironment.refresh()`, and `ToolStatus`,
  `BinaryStatus` and `AppInfo` live in `Sources/Models/ToolStatus.swift`. They spawn child
  processes and `AppEnvironment`, `OnboardingView`, `TerminalContainerView` and the IPC layer
  all read them, so they are model types; they sat in `SettingsView.swift` because Settings was
  the first thing to render them. `ToolRow` and `PrerequisiteRow` are the two views that do,
  and **both resolve the auth dot through `ToolRow.authenticationDotColor`** rather than
  re-deriving it — `ghAuthDetail` is display-only and free to be reworded, and each view in
  turn shipped a `detail != "Not authenticated"` comparison that turned the dot green for an
  unauthenticated `gh`. The process-compose row is fed by
  `ProcessCompose.Settings.resolveBinary()` and never by `ToolStatus.findBinary`, for the
  reason **Detected Tools** gives at length in `docs/agents/execution-and-config.md`.
- **Sidebar state** (selection, expanded sections) stored in UserDefaults (`atelier.selection`, `atelier.expandedProjects`)
- **Process-compose approval is gone**, with `ScriptTrust` and `ConfigApprovalView`.
  `atelier.approvedConfigFiles` held a SHA-256 of every repository-provided file a config would
  load, keyed by project directory, and gated `bootstrap` and `dispose`. It gated the two
  work-tree tiers of `ProcessCompose.Config.locate`, and went when they did: the config is
  `execution.process-compose.yaml` in the **project directory** and nowhere else, so it cannot
  have arrived with a clone and there is nothing left to approve. Do not reintroduce the key,
  do not read a stale copy as meaning anything, and do not add a gate back without first
  putting a work-tree tier back in `locate` — location is the whole of the trust decision
- **Verification** keeps **one** per-workstream key, `atelier.verifyChecks.<workstreamID>`:
  one blob keyed by check name, carrying each check's latest verdict, duration, stamp and
  run id. A run started for one check contains only that check, so rows read off a run's
  own list lost every other check's verdict the moment a single row's Run was pressed —
  which is why the record, not the run, is what a row renders.
  `atelier.verifyRun.<workstreamID>` is **gone**, with `Verification.Store`. Runs live in
  the runner's memory for the session: what persisting one bought was resolving a run id
  across a restart, and a check's *output* — the thing that made that worth doing — now
  lives in a terminal surface that does not survive a restart either.
  `atelier.verifySelection.<workstreamID>` is **gone** too, with the checklist it served.
  Do not reintroduce either, and do not read a stale copy as meaning anything.
- **`atelier.processSelection.<id>` carries three states, not two**, and the encoding is
  `ProcessSelection`: **key absent** means all, **key present holding an empty
  array** means *nothing selected*, and names mean that subset. Two were not
  enough because `PhaseRunner` reads an empty name list as *start everything* —
  `up -n execute` with no names runs the whole namespace — so a stored empty
  selection read back as "all": every checkbox re-checked itself and Start ran
  everything, the opposite of what was asked. That was first patched by refusing
  the click, disabling the last checked box, which left a checkbox dimmed for a
  reason nothing on the pane gave. Now the box can be unchecked and the
  **button** is what goes quiet — Start is disabled, with a line beside it
  saying why. Verification has no checklist, no selection, no Run all and no top-bar
  Stop: every row carries its own run/re-run/stop button, gated on whether *that check*
  is running. `ProcessSelection.namesToRun` is where
  the distinction stops being losable: `.all` gives `[]` and `.nothing` gives
  **nil**, so a caller cannot flatten them without the compiler objecting. No
  migration was needed, because the empty case used to *remove* the key.

### The command palette, and what a missing row means

`PaletteCommand.availability` returns **three** cases, not two: `.available`,
`.hidden`, and `.disabled(reason)`. The `isAvailable:` initializer is sugar over the
first two and is what nearly every built-in uses — a command for a surface that is not
on screen (Save, with no editor) has nothing to explain. `.disabled` is for a command
the user is deliberately reaching for, refused by a condition they can act on: the
Coding Agent is mid-turn, `gh` is not installed. `CommandRegistry.search` drops
`.hidden` and keeps `.disabled` **below every runnable result**, whatever it scores,
and `runSelected` refuses it *without dismissing* — the palette stays up with the
reason on screen, which is the whole point of listing it.

**The row itself is never `.disabled()`, and that is the invariant to keep.** The
palette and the editor's ⌘P file finder share one `FilterResultList` — a
`List(selection:)` keyed on the item's id, rows as real `Button`s — and a `List` row
marked `.disabled()` may stop being selectable at all, which would take away the only
way to reach a refused row and read why. So the refusal stays in one place at the
consumer, `CommandPaletteView.run`, and the reason reaches VoiceOver as an
`.accessibilityHint` instead. The row's `Button` also sets the selection *before*
activating, because a `Button` filling a `List` row swallows the click the list would
otherwise have selected with.

**Selection is an id, never an index**, in both surfaces: `results` is recomputed on
every keystroke, and an index into an array that no longer exists is how the finder's
lazy container ended up with two competing identity systems and desynced rendering.
`neighbouringSelection(from:in:delta:)` is the one place the arrows are resolved — it
clamps at both ends rather than wrapping, and treats an id the results no longer
contain as no selection. Focus stays in the filter field, so the arrows are read there
with `.onKeyPress` and the list is `.focusable(false)`; the finder is the exception
only in *how* — its query and arrows come from an `NSEvent` local monitor, with the
field as pure display. `FilterResultList` deliberately draws **no** empty state,
because the finder distinguishes three (scanning, no match, nothing typed yet) and a
component owning one would collapse them.

**That distinction exists because of the stored prompts.** They were `.hidden`
whenever `PromptInjector` would refuse, which is the common case — an agent is mid-turn
most of the time you reach for a prompt — so the palette simply came up shorter, with
nothing to say why. Worse, `surfaceStates` has **no decay path**: the only things that
move a surface off `.working` are `agentIdle`, `agentSessionStarted` and
`agentSessionEnded`, and `sweepForStalls` writes `rosters` and the workstream-level
`states` without ever touching it. So a `Stop` that is lost or never sent — and
`atelier-hook` fails silently by construction, `curl --max-time 1` — is unrecoverable
for the session: the surface reads `.working` until the agent restarts, and every
stored prompt was gone with it. Do not put the gate back as a hide.

**`PromptInjector.deliverability` is the one decision, and `channelDown` masks
`.working` and `.stalled` — nothing else.** That is the same rule `AgentStatusLabel`
applies to the sidebar's status word, for the same reason: both states are held up by
the *continued arrival* of hook events, and neither survives learning that the app has
stopped hearing. `.needsAttention(.permission)` is deliberately **not** masked — it is a
positive fact a delivered hook established, and typing there answers the prompt.
`ChangesView.submitBlocker` routes through the same function rather than re-deciding,
so the Changes tab's Submit and the palette's prompts cannot drift apart.

**Three dynamic families, each owning an id prefix that `CommandRegistry.sync` clears
wholesale**: `goto.`, `prompt.`, and `verify.check.`. A static command named under one
of those is silently deleted on that family's first emission, which is why none of them
is spelled `workstream.`, `project.` or `run.` — `workstream.rename`, `workstream.purge`
and `run.startRerun` are built-ins. The verification family is rebuilt **per selection**,
not per project, and off the main thread because it reads `verification.yaml`; a
generation counter drops a load that finished after the selection moved on. The list is
advisory — `Verification.Runner.start` loads the config again and is the only thing that
may refuse — and the receiver opens the Verification tab before starting, because a
check's output lives only in its own surface and the runner's refusals are states that
tab already draws.

**Commands that act on the selected workstream are received in `ContentView`**, not in
the sidebar: Reveal in Finder, Open on GitHub, Open Pull Request, Open in Shortcut, Copy
Branch Name, Copy Worktree Path. The sidebar's context menu reads row-local values
(`worktreePath`, `githubURL`, `branchName`) that nothing outside that row can see;
`ContentView.workstreamActionTarget` resolves the same facts from the selection, out of
`AppEnvironment`'s caches, and backs **both** the availability decision and the action,
so a row offering "Open Pull Request" and a receiver finding no URL cannot happen. The
three "open" rows are `.hidden` with nothing to open, the same choice the context menu
makes by omitting the item.

**`AppCommand.purgeWorkstream` and `.addNew` carry optional payloads**, and the absent
case is load-bearing in both. `purgeWorkstream(nil)` means "the selected workstream" —
a command closure is built once and never learns which one is active — and it still
lands on `confirmPurge`, so `purgeWarning` and `destroyableWorktreePath` stand where
they always did. A nil `.addNew` object means "the `atelier.bypassPermissions` default",
which is what ⌘N and every other producer wants; the palette's two variant rows post
`true` and `false`. Reading a missing payload as `false` would silently strip
permissions from ⌘N.

The two are on different transports, and the split is by *receiver*, not by importance.
**`AppCommand` is the typed channel for the commands `ContentView` receives** — the
twenty-one app-level ones, and the grouping is the source's own `// MARK`s: the six
application cases, the seven navigation cases, archive and purge, and the six
selected-workstream actions above.
`AppCommandChannel.shared.send(_:)` replaces the post, `ContentView.handle(_:)` is the
single exhaustive switch that replaces twenty-one `.onReceive`s, and there is no `default:`,
so a case nothing handles does not compile. That is the property a `Notification.Name`
could never have: an unreceived post was a silent no-op, and an `.onReceive` installed in
a `@ViewBuilder` branch that happened to be unmounted was the same thing again,
intermittently. It is scoped to `ContentView` because `ContentView` is the always-mounted
root — the mount guarantee, not the transport, is what makes a single receiver safe.

**`.addNew` stays a notification because its receiver is `ProjectSidebar`**, along with
`.addProject`, `.renameWorkstream` and `.openDirectory`; the tab family
(`.toggleInfo`, `.focusAgent`, the toggles, `.switchByNumber`, `.openExternalBrowser`,
`.rerunScript` and the rest) stays because its receiver is `TerminalContainerView`. Each
of those is a second phase with its own always-mounted receiver, not an exception to this
one. Everything with more than one receiver or a genuinely broadcast meaning stays on
`NotificationCenter` permanently: the launcher seam
(`.workstreamCreated`/`.workstreamWorktreeReady`/`.workstreamCreationFailed`,
`.projectCreated`), `.agentBlockedOnPermission`/`.agentPermissionResolved`,
`.terminalActivity`, `.initializationStateChanged`, `.archivingDidStart`/`.archivingDidComplete`,
`.terminalSurfaceClosed`, `.worktreeGitActivity` and `Shortcut.Settings.tokenChanged`.

**`commandKeyAction` is one table across both transports**, deliberately. The ⌘-chords
the key monitor swallows are mixed — `⌘[`/`⌘]` are `AppCommand`s and `⌘{`/`⌘}`/`⌘W` are
still notifications — so it returns a `CommandKeyAction` naming which, rather than
forking into two lookup functions that can disagree about which chords exist.

**`QuickAction.unavailableReason` is the one copy of the quick actions' gate**, read by
the toolbar menu's `.disabled`, by the palette row that shows it, and by the receiver in
`TerminalContainerView` that runs the action. The palette deliberately does *not* mirror
the menu's repo-state filtering (offering Push only when something is unpushed): that is
the menu choosing a single primary action for one button, while a palette searched by
name should find "Commit" whether or not the tree is dirty.

## Keyboard Shortcuts
When adding, removing, or changing keyboard shortcuts:
1. Update `AtelierApp.swift` (menu commands)
2. Update `TerminalContainerView.swift` (workspace tab handling)
3. Update `HelpView.swift` (shortcut reference)
4. Update the shortcut table in `README.md`
5. Update the list below
6. Check the **two key monitors**, because half the real bindings are not in
   the menu at all: `AppDelegate`'s `NSEvent.addLocalMonitorForEvents`
   (Cmd+1-9, Cmd+L) and `ContentView.commandKeyAction` (Cmd+[/], Cmd+Shift+{/},
   Cmd+W). A chord one of those swallows never reaches a menu item, so adding it
   to the menu alone does nothing.

**`HelpView.swift` is the list to reconcile against.** It is the one a user can
read, and every other list here has drifted from it at least once — this section
and README's table were both missing Cmd+N, Cmd+Shift+N and Cmd+comma, and this
one was also missing Cmd+T. The exception is Cmd+Option+←/→, which the menu
binds and *no* list carried, HelpView's included.

Current shortcuts:

Global — available everywhere:
- **Cmd+comma**: Settings
- **Cmd+/**: Help
- **Cmd+N**: New workstream, or new project when none is selected. The absent
  payload means "the `atelier.bypassPermissions` default" — see `AppCommand`.
- **Cmd+Shift+N**: New project, always
- **Cmd+Shift+C**: Toggle sidebar
- **Cmd+Shift+P**: Command Palette

Workstream — when a workstream is active:
- **Cmd+I**: Info
- **Cmd+1-9**: Switch tab (all tabs in display order). Positional, so no
  number reaches a closed tab — and every singleton but Info and Agent starts
  closed. Open them from the tab bar's quick-add buttons or the command
  palette; nothing is bound to them by name. Do not spell that set out here:
  `WorkspaceTabKind` is where `isCloseable` is declared, and Info and Agent are
  the only two that are `false`. It read "Changes, Execution and Verification"
  until Whiteboard became the fourth.
- **Cmd+Shift+[/]**: Cycle tabs
- **Cmd+Option+Left/Right**: Cycle tabs, the menu's own binding for the same
  two commands. `AtelierApp.swift`'s "Previous Tab" / "Next Tab" items carry it
  because `ContentView.commandKeyAction` reads the bracket chords off a monitor
  and a menu item cannot be given a chord a monitor swallows.
- **Cmd+Return**: Focus Coding Agent
- **Cmd+T**: New terminal tab
- **Cmd+P**: Find File (Editor)
- **Cmd+S**: Save (Editor)
- **Cmd+Shift+S**: Save As (Editor)
- **Cmd+W**: Close tab
- **Cmd+Shift+R**: Rename workstream
- **Cmd+Shift+W**: Archive workstream
- **Cmd+L**: Address bar (browser)
- **Cmd+Shift+Return**: Start/Rerun

Navigation:
- **Cmd+[/]**: Cycle workstreams
- **Cmd+Up/Down**: Cycle projects
- **Cmd+0**: Back to project

External apps — open the current workstream's directory:
- **Cmd+Option+B**: External browser
- **Cmd+Option+T**: External terminal
