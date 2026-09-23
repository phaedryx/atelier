# Atelier - Project Instructions

## Development Workflow

### Build, Test, Run
```bash
./scripts/dev.sh build              # debug build (xcodegen + xcodebuild)
./scripts/dev.sh br                 # build and run
./scripts/dev.sh run [dir]          # kill and relaunch (optionally with a directory)
./scripts/dev.sh test               # run XCTest suite
./scripts/dev.sh release            # release build matching CI (hardened runtime)
./scripts/dev.sh release --run      # release build and run
./scripts/dev.sh clean              # clean build artifacts
./scripts/release.sh <version>      # signed+notarized DMG — needs a Developer ID, unusable here
./scripts/set-version.sh 0.2.0      # stamp a version into project.yml (build-time only)
./scripts/build-editor.sh           # rebuild Monaco editor bundle (auto-run by dev.sh)
```

### After code changes
1. If you added/removed files or changed `project.yml`: run `xcodegen generate` first
2. Build and run: `./scripts/dev.sh br`
3. If tmux mode was on: `tmux -L atelier kill-server`
4. If you changed the tmux config: `rm -f ~/Library/Caches/atelier-debug/tmux.conf`
   (a debug build; a release build uses `atelier`)

### When to regenerate the Xcode project
Run `xcodegen generate` when:
- Adding or removing Swift source files
- Adding or removing localization files (lproj)
- Changing `project.yml` (build settings, dependencies, targets)

Do NOT edit `Atelier.xcodeproj` directly. It is generated from `project.yml`.

### Developer setup
```bash
uvx prek install                    # install pre-commit hooks
uvx prek run --all-files            # run hooks on all files (optional)
```

### Release build
```bash
./scripts/dev.sh release         # ad-hoc signed Release build — this is the one that works
```

It stamps the version from `git describe` before building, so a local Release
build reports what it actually is — `0.2.1-20-gbe4598ac`, or `0.2.1-dirty` when
built over uncommitted changes — rather than the `0.0.0-dev` placeholder. That
matters because a local Release build is one somebody installs and then has to
identify weeks later. `project.yml` is copied aside and restored on exit,
including when the stamp fails, so the bump is never left in the working tree.
Debug builds are untouched and still report `0.0.0-dev (Debug)`.

**The count is `--first-parent`, so it means "PRs merged since the tag".** Plain
`git describe` counts every commit reachable from HEAD that the tag cannot
reach, which includes each commit that arrived *inside* a merged PR branch —
three days and 27 merges past v0.2.1 described as `0.2.1-95`, a number that
reads like months of history. The identifying part of the string is the `-g<sha>`
suffix; the count only says roughly how far past the tag a build is, and it
should stay on the same scale as the release notes. Do not drop the flag to
"match what git does by default". One consequence, harmless and one-time: across
the change a build stamped `-95` is followed by a later build stamped `-27`, and
it resets at the next tag.

`./scripts/release.sh <version>` builds a signed, notarized DMG, but requires
`ATELIER_SIGNING_IDENTITY` and `ATELIER_TEAM_ID` and refuses to run without
them. This project has no Developer ID, so it is kept only for if that changes.

## Git Workflow

### Branching
- Work on feature branches, not directly on `main`
- Branch names are hyphenated, not slashed: `feat-description`,
  `fix-description`, `refactor-description`. A worktree is added as a peer of
  `main` at a path spelled like its branch, so `feat/thing` puts the checkout a
  directory deeper instead of beside `main` — and `worktree add <path>` on its
  own infers the branch from the path's last component, `thing`
  (`Sources/Models/BareRepoClone.swift`).
- Open PRs against `main`

### Releasing
Releases are tag-driven. There is no automatic version bump:

1. Add the new version's entries to `CHANGELOG.md` by hand and merge them
2. Tag `main`: `git tag v0.2.0 && git push origin v0.2.0`
3. `.github/workflows/release.yml` derives the version from the tag, stamps it
   into `project.yml` via `scripts/set-version.sh`, builds, packages the DMG,
   uploads it, and publishes the release

Builds are **ad-hoc signed and not notarized** — this project has no Apple
Developer account, and a free Apple ID cannot notarize. Ad-hoc signing is still
mandatory (arm64 binaries will not run without it); what is missing is an
identity, so a *downloaded* DMG is refused on first launch until quarantine is
cleared. A locally built app is unaffected, because Gatekeeper acts on the
quarantine attribute that only downloads carry. The workflow needs no secrets at
all — it uses the automatic `GITHUB_TOKEN` and nothing else. (Sentry went in #24,
so there is no dSYM upload step and no `SENTRY_AUTH_TOKEN`; do not add one back
on the assumption that crash symbolication is wired up.)
See `docs/distribution.md`.

The tag is the single source of truth for the version; `project.yml` is only
rewritten at build time and the bump is never committed.

Because of that, the version committed in `project.yml` is the deliberate
placeholder `0.0.0` / `0.0.0-dev`, and it means nothing: it is what a debug build
reports. Do not read it as the current version, and do not bump it to "keep it
current" — it is overwritten at build time by `scripts/set-version.sh` and
nowhere else. That script has three callers, and all of them restore
`project.yml` afterwards so the bump is never committed: the release workflow and
`scripts/release.sh`, which pass the version derived from the tag, and
`./scripts/dev.sh release`, which passes `git describe`. (It used to carry `0.1.79`, inherited from Factory Floor, which
made every local build claim a released version it had long since diverged from.)
`CFBundleVersion` stays numeric because it must be period-separated integers, so
it receives only the `X.Y.Z` core; the suffix naming the commit rides on
`CFBundleShortVersionString`, which is the string the app displays.

## Architecture

- **SwiftUI sidebar** + **AppKit terminal views** (Metal GPU-rendered via libghostty)
- **XcodeGen** for project generation (`project.yml` -> xcodeproj)
- **Ghostty** as git submodule (pinned to stable tags), xcframework built with `zig build`
- **Bridging header** at `Resources/Atelier-Bridging-Header.h`
- **Single-window** app via `Window` (not `WindowGroup`)
- **`atelier://`** URL scheme for single-instance behavior
- **AppConstants** (`appID`, `appName`, `cacheDirectory`) — there is no config
  directory; persistent state is UserDefaults and transient state is Caches
- **ProcessRunner** — every child process goes through it, with a deadline. The
  two exemptions are marked at their spawn sites (see Child processes below)
- **No update checking** — no in-app updater and no release polling; upgrade by downloading a new DMG from GitHub Releases, or by building locally
- **prek** pre-commit hooks (`prek.toml`)

### Key directories
- `Sources/Models/` - Data models, git operations, tmux, name generator, app constants
- `Sources/Models/IPC/` - Agent-to-agent messaging (server, store, protocol, nudges)
- **Model types are namespaced**, not prefixed: `IPC.Request`, `Git.RepoInfo`,
  `Shortcut.Story`, `ProcessCompose.Config`. Fourteen namespaces —  `IPC`,
  `Shortcut`, `Git`, `GitHub`, `Worktree`, `Workstream`, `Project`, `RunState`,
  `Port`, `Usage`, `QuickAction`, `DevCommand`, `ProcessCompose`, `Verification`. Each is
  declared once, in the file owning most of its members; every other file
  extends it. For `IPC` and `RunState` that host file is fixed by the helper
  targets, which compile individual model files by path (`project.yml:179-181`
  and `198-200`). `Port` is deliberately partial: it covers `Port.Allocator`,
  `Port.Detector`, and `Port.Status` — the port mechanism itself.
  `RunState.PortSelection` and `RunState.PortSelectionTracker` stay under
  `RunState` because they are declared in `RunState.swift`, one of the three
  model files `AtelierRun` compiles; moving them would force `enum Port` to be
  declared there too. `ProcessCompose.PortPlan`, `.PortEntry`, and
  `.PortsConfig` are that subsystem's config schema and follow its directory.
  Types that do not cluster stay top-level — do not invent a `Core` bucket for
  them. `ProcessRunner` and `AppEnvironment` stay top-level permanently:
  `Process` and `Environment` would collide with Foundation and SwiftUI.
- `Sources/Models/ProcessCompose/` - The process-compose layer (config location, phases, ports, the process table, the per-workstream run session)
- `Sources/Terminal/` - Ghostty integration (TerminalApp singleton, TerminalView NSView)
- `Sources/Views/` - SwiftUI views (sidebar, settings, project overview, workspace, browser, editor)
- `Sources/Palette/` - Command palette (registry, default commands, fuzzy matcher)
- `Sources/PixelAgents/` - Claude Code hook receiver, router, and installer; the status line channel and the transcript reader behind it
- `Sources/WorktreeSetup/` - `initialization.yaml`: the steps run once behind a new worktree, and `PhasePolicy`, which now gates `dispose` alone
- `Sources/Launcher/` - `atelier-run` helper binary (port detection)
- `Sources/MCPHelper/` - `atelier-mcp` helper binary (IPC bridge for agents)
- `Localization/en.lproj/` - Localizable.strings and InfoPlist.strings (English only)
- `Resources/` - Entitlements, bridging header, Assets.xcassets, CLI script
- `Resources/MonacoEditor/` - Built Monaco editor bundle (gitignored, built by `scripts/build-editor.sh`)
- `editor/` - Monaco editor Vite project (source for `Resources/MonacoEditor/`). Built with bun.
- `ghostty/` - Git submodule (do not modify, pinned to stable release tag)
- `scripts/` - Release and build automation. `setup.sh` is what a new worktree
  needs — the ghostty submodule, the symlinks to the build artifacts that are not
  in git (`zig-out`, `GhosttyKit.xcframework`), the Monaco bundle, prek, and a
  build so SourceKit can resolve symbols. It takes **no environment variables**
  and resolves the repository's home from git itself, and it takes a subcommand
  (`ghostty`, `editor`, `hooks`, `build`; no argument runs all four in order) so
  the project's `initialization.yaml` can name one step per phase. **Nothing runs
  it automatically for you** — a worktree Atelier creates runs it only if this
  project's `initialization.yaml` is in place, and a worktree made any other way
  (`git worktree add`, or Adopt, which deliberately skips initialization) needs it
  run by hand. See `docs/worktree-setup.md`.
- `docs/` - Distribution guide and reference docs. Anything not describing the
  app as it is carries a status line saying so.

### Data flow
- **Projects/workstreams** stored in UserDefaults (`atelier.projects`), accessed via `ProjectStore`. Wrapped in `ProjectList: ObservableObject` for reference-type semantics.
- **Settings** use `@AppStorage` (UserDefaults), keyed as `atelier.*`
- **Terminal surfaces** cached in `TerminalSurfaceCache` (keyed by UUID)
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
- **Tool detection** runs at startup in `AppEnvironment.refresh()`
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

### Workstream lifecycle
1. Creating a workstream: generates name, runs `git worktree add`; `Initialization.Runner` then runs the project's `initialization.yaml` steps in the background
2. Workspace view: a workstream opens with only Info (Cmd+I) and Agent (Cmd+Return), which are also the only permanent tabs. Changes, Execution and Verification are singletons — at most one of each — opened on demand from the tab bar's quick-add buttons, the command palette, or their toggles, and they close and reorder like terminals/browsers once open. `startupWorkspaceTabState` seeds the two permanent tabs and clamps the restored `activeTab` into that list; the seed and the clamp move together, because a saved `.changes` restored onto a strip with no Changes tab renders the pane with nothing selected
3. Tmux mode: wraps Coding Agent only in `tmux new-session -A` on socket `-L atelier`
4. Terminal tabs: close on shell exit (Ctrl+D). Agent respawns.
5. Ending a workstream: two operations, not one — see below.

### Two ways to create a worktree, and they are not interchangeable
`Git.Operations.createWorktree` cuts a **new** branch from `BaseBranchSetting`. The GitHub
button on a project row goes through `createWorktreeTrackingRemote` instead, which checks out a
branch that already exists on origin. **Which one runs is named, once, as a value** —
`Workstream.Launcher.WorktreeSource`, dispatched by `Launcher.gitWorktreeCreator`, because a
choice assembled inline in a view is one no test can read back; the `create_workstream` section
has the rest of that story. Do not merge them or reroute one through the other:
`createWorktree` runs `worktree add --no-track -b <name> <dir> <start>`, so handing it a branch
that lives only as `origin/<name>` **succeeds** and produces a worktree named for that branch
while holding the base branch's code — and its `-b`-less fallback only rescues a *local* branch
of the name.

`createWorktreeTrackingRemote` fetches the branch, then `worktree add --track -b <branch> <dir>
origin/<branch>`. **In the `.bare` container layout the `-b` always fails and the fallback is the
ordinary path**, which is the non-obvious part: `git clone --bare` writes every branch into
`refs/heads`, and the refspec `BareRepoClone` configures afterwards only ever updates
`refs/remotes/origin/*`. So for every branch the clone captured, `refs/heads/<branch>` exists,
carries no upstream, and is as old as the clone. `adoptRemoteBranch` is what stops that becoming
"the worktree says `renovate/x` and holds three-week-old code": it sets the upstream and runs
`merge --ff-only origin/<branch>`, which advances a branch that is merely behind and refuses to
move one carrying unpushed commits. Do not "simplify" that to a `reset --hard`.

`remoteBranchTip` and `worktreePath(forBranch:)` are the dialog's pre-flight, and they run before
anything is created on purpose: git reports a missing branch and an already-checked-out branch as
ordinary failures, which arrive after the optimistic sidebar row is already drawn.

**The button that reaches all of this is gated on `AppEnvironment.hasGitHubRemote`, and which
cached fact that is matters more than it looks.** The whole flow is git: a typed branch name,
`remoteBranchTip`, `createWorktreeTrackingRemote`. None of it calls `gh`. It was gated on
`githubURL(for:)` instead, and that hid the button outright for every container-layout project —
`githubRepoCache` is written *only* by `refreshGitHubInfo`, which runs from `ProjectOverviewView`,
`WorkstreamInfoView` and `TerminalContainerView` and from nothing the sidebar draws, and the other
fallback is keyed by the project's *checkout*, so a lookup by `directory` cannot hit it however
many views have appeared. The feature shipped invisible. `hasGitHubRemote` and the GitHub browser
URL are now both filled by `refreshPathValidity`'s own sweep from one `git remote get-url`
(`GitHub.Operations.githubRemoteURL`), keyed by `directory`, so the row never depends on which
view the user happened to open — and `GitHub.Operations.shouldShowBranchButton` names the gate's
inputs outside the view body, the shape `Shortcut.Settings.shouldShowButton` already uses, because
a decision spelled inline in a row body is one nothing can pin.

### Remove vs purge
`Workstream.Archiver` exports both, and they are not the same thing.

| | `Archiver.remove` | `Archiver.purge` |
|---|---|---|
| Alert | "Remove Workstream" | "Purge Workstream" |
| Reached by | ⌘⇧W, the menu's "Archive Workstream", the palette, the sidebar context menu's "Remove" | the sidebar context menu's "Purge", and the Purge button on `WorkstreamInfoView`'s merged-PR banner |
| Runs `dispose`? | no | yes, before the worktree goes |
| Files on disk | **kept** | `git worktree remove`, local branch deleted, default branch re-fetched |
| Also | kills tmux sessions, evicts surfaces (including check terminals, via `Verification.Runner.forget` — nothing else can reach them), drops `IPC.Config` and the launch log, and clears the workstream's agent state (`Workstream.AgentStateTracker.clear`, passed in the way `Verification.Runner` is — it was copied into both call sites and a third archive path would forget it) | same, plus cancels a running initialization through `Initialization.Runner.cancel`, stops the dev stack, waits out running verification checks through `Verification.Runner.stopAndWait`, then `forget`s that workstream in the runner and drops the Execution checklist's selection key and the per-check verification records |
| Guarded by | nothing — it destroys nothing | `purgeWarning` / `destroyableWorktreePath` |

The naming is not self-consistent and reading it as such is the trap: the *menu*
says "Archive", its *alert* says "Remove", and the one that actually deletes work
is neither. `purge` is the destructive path, and everything in this document
about `dispose` running at the end of a workstream's life describes `purge`
alone.

`destroyableWorktreePath` returns nil when the resolved path is the project
directory itself, and every destructive step is scoped to it. The `?? projectDir`
fallback that used to stand there reached `removeWorktree`, `deleteLocalBranch`
and `dispose` against the user's main checkout. `purgeOrphanWorktree` is the same
operation for a worktree no workstream owns, with its own `orphanPurgeWarning`.

### Base branch
`BaseBranchSetting` (`atelier.baseBranch`, Settings → General) chooses the branch new worktrees
are cut from: `main`, `master`, `trunk`, `develop`, or `repositoryDefault`, which asks
`Git.Operations.defaultBranch`. It defaults to `.main`, and it replaced `.atelier.json`'s
`base_branch` when that reader was deleted.

It has **exactly one production reader**: `Git.Operations.createWorktree`, via
`BaseBranchSetting.resolve(for:)`. `fetchDefaultBranch` takes an optional `branch:` so the
branch that is fetched and the branch the worktree is cut from are the same one — swapping the
selection without that gave "pick develop, fetch main".

**The setting names a branch; the worktree is cut from `origin/<branch>`.** That indirection is
`Git.Operations.creationStartPoint`, and it is what makes the fetch above mean anything. A fetch
only ever writes `refs/remotes/origin/<base>`, while the bare name `main` resolves the *local*
`refs/heads/main` first — and in the container layout that ref is the trunk checkout's own
branch, which moves only when somebody pulls. So for a year the fetch updated a ref the
`worktree add` never read, and every workstream started from whenever main was last pulled. The
start point falls back to the name as given when origin has no such branch (no remote, a
local-only base) and when the name already carries an `origin/` prefix, which `repositoryDefault`
usually does. The local ref is deliberately **not** advanced the way `adoptRemoteBranch` advances
one: here that ref belongs to the trunk checkout the user has open, and moving it under them is a
larger promise than cutting one worktree from origin's tip. `Tests/WorktreeBaseBranchTests.swift`
pins the three cases, and `fetchDefaultBranch`'s own "local main must not move" test
(`Tests/GitOperationsTests.swift`) is still correct and still passing — it asserts what a *fetch*
does, which this did not change.

The `--no-track` on that `worktree add` is not decoration. `startPoint` is normally a
remote-tracking ref, and git's default `branch.autoSetupMerge` would give the new branch an
upstream of `origin/<base>` — a different name from the branch itself, which makes a bare
`git push` in the workstream's terminal fail under `push.default=simple` and empties the
`@{upstream}..HEAD` range `hasUnpushedCommits` guards a purge with. `pushCurrentBranch` passes
`-u`, so the app's own push still sets an upstream when there is something to push.

**Known limitation, deliberate and unfixed:** **two** comparison sites in `Git.Operations` call
`defaultBranch(at:)` directly and do *not* consult this setting — `mergeBase` (the Changes tab's
diff base) and `hasBranchCommits` (the ahead count). So with the setting on `develop` in a
repository whose git default is `main`, a worktree is cut from `develop` while its diff and its
ahead count are measured against `main`. Two reviewers disagreed on whether those sites should
follow the setting — a diff base and a creation base are arguably different questions — so it
stays a follow-up rather than a half-migration finished in the dark. Do not "fix" one of the two;
either both move or neither does.

**It was three, and the third was deleted rather than migrated.** `worktreeDetail` computed an
unmerged-commit log against `defaultBranch(at:)`, but the view that rendered it —
`WorktreeDetailSheet` — went in 2e6f2f8, and nothing read the field afterwards. So the rule was
discharged the way it always allowed: `unmergedCommits`, `unmergedCommitsUnavailable`, the
`UnmergedCommit` type and the `git log base..HEAD` call are **gone**, along with
`worktreeDetail`'s `mainRepoPath:` parameter, which existed only to resolve that base.
`worktreeDetail` itself is still live and still takes `at:` — `ProjectOverviewView` calls it for
the project's own repository and uses the file changes — it simply no longer resolves a base
branch at all, so it is not a comparison site and must not be counted as one.

That is the *only* sanctioned way to reduce the count. The all-or-none rule is about keeping one
question answered one way: a site may leave it by being **deleted**, never by being quietly
migrated on its own. Both survivors are load-bearing and user-visible, so neither has that exit —
if `mergeBase` or `hasBranchCommits` is ever pointed at `BaseBranchSetting`, the other moves in
the same change. And if the commit log is ever wired up again, it rejoins the count and the rule
binds three once more.

`defaultBranch(at:)` is also read to export `ATELIER_DEFAULT_BRANCH` (`TerminalContainerView`,
and `ProcessCompose.PhaseEnvironment`'s four callers — `Initialization.Runner` for a step,
`WorkstreamArchiver` for `dispose`, `WorkspaceActions` for `open_agent_tab`'s spawned terminal, and
`WorkspaceActions.verificationTarget` for a check's environment). Those are *not* part of that
follow-up: the variable means
"what git thinks this repository's default branch is", and all five deliberately agree with each
other rather than with the setting.

**`defaultBranch(at:)` is cached, per directory, inside `Git.Operations` itself.** Resolving costs up
to six sequential probes and the answer is a property of the repository, but both comparison
sites are called *per worktree*: `refreshPathValidity` runs `hasBranchCommits` for every
worktree on a 15-second timer, and `listWorktreesWithInfo` does the same on every project-overview
refresh. Twelve workstreams in two projects meant ~72 subprocesses a tick resolving two strings.
(There was a third caller on that hot path, `worktreeDetail`'s commit log, until it was deleted;
the cache predates that and is not affected by it.)

The cache lives there rather than in `AppEnvironment`, which is where it started, because half the
callers structurally cannot reach a `@MainActor` type: `diffFingerprint` is called from
`Verification.Runner`, `IPC.VerificationRunnerBridge` and `VerificationTabView`, and
`ChangesView.baseRef` is `nonisolated`. The alternative — threading a resolved branch down as a
parameter — would have had to stop at those call sites or point `Verification.Runner` at
`AppEnvironment`, which is the wrong direction for that dependency.
`AppEnvironment.defaultBranch(for:)` now **delegates** here and keeps only the two things a
`@MainActor` caller needs on top: somewhere off the main thread to run a blocking probe, and
in-flight de-duplication, which a lock gives no help with. One cache, one policy.

It deliberately does **not** cache the literal `"HEAD"`: that is the sentinel for "resolved
nothing", which for a freshly added project usually means `origin/HEAD` has not been fetched yet —
and `fetchOrigin` is running concurrently to fix exactly that. There is no other invalidation and no
TTL; a repository whose default branch genuinely renames mid-session serves the old answer until
relaunch. Both halves are pinned in `Tests/GitOperationsTests.swift` and
`Tests/AppEnvironmentDefaultBranchTests.swift`.

None of this touches the all-or-none rule above. That rule governs *which* branch is compared — git's
default versus `BaseBranchSetting` — not who pays to resolve it, and a cache that returns exactly
what `defaultBranch(at:)` would have returned leaves the question byte-identical. Say so in any
commit that touches it, because a reviewer will pattern-match it to the forbidden migration.

### process-compose is a requirement, not an integration
Everything a project asks Atelier to run lives in one **`execution.process-compose.yaml`** in the
project directory, read by
[process-compose](https://f1bonacc1.github.io/process-compose/).
`ProcessCompose.Settings.resolveBinary()` finds the binary, and **there is no process-compose
setting of any kind** — no switch, no path. Two UserDefaults keys were removed, and neither
should come back or be read as meaning anything if a stale copy is found:

- `atelier.processCompose.enabled` defaulted off, which made "off" a supported state in which a
  worktree got no setup at all, nothing ran, and five surfaces each explained the silence a
  different way.
- `atelier.processCompose.binaryPath` named a binary explicitly, took precedence over the search,
  and deliberately *failed* rather than falling back to it — on the argument that silently running
  a different binary than the one named is worse than reporting the named one is gone. That
  argument was sound and the setting still went: the binary is auto-detected, first match on
  `searchPaths` wins.

process-compose now sits in Settings → Environment under **Detected Tools**, between `git` and
`tmux`, and on the onboarding screen as a required prerequisite with an install link. The only
interaction left is that pane's refresh button.

**The Detected Tools row is fed by `resolveBinary()`, never by `ToolStatus.findBinary`.** Those
two search different places — `resolveBinary` walks three fixed directories,
`CommandLineTools.path(for:)` walks the login PATH and six known locations — so a row fed by the
generic search reads green above a Start button reporting "process-compose was not found", the
button-versus-run disagreement `ProcessCompose.RunCommandPlan` exists to prevent, only spread
across two windows. Whatever `resolveBinary` searches, every surface must keep asking *it*. The
version probe is `version -s`: there is no `--version` flag, and bare `version` prints six lines
whose first is the product name.

**Detection is now an input to `runPlan`, and `TerminalContainerView` observes it.** The binary
path key was an `@AppStorage` there precisely so that Start became enabled when the user followed
the plan's own "go and fix this in Settings" advice; with the key gone,
`.onChange(of: appEnv.toolStatus.processCompose.path)` is what carries an install through to
Start, and the refresh button is what triggers detection. Removing that observer without putting
another trigger in its place leaves Start disabled after the user has done exactly what it asked.

`resolveBinary(searchPaths:)` takes the list as a defaulted parameter, injected only by tests.
`ProcessComposeSettingsTests` declined that seam while the search was merely the fallback behind
a configured path — "adding a search-paths injection point to production for one test" — and the
ruling flipped when the search became the only resolution path there is, because declining it
left the whole of resolution unassertable on any host. `WorkstreamArchiverDisposeTests` cannot
use the seam (it goes through `disposePlan`, which calls `resolveBinary()` with no arguments on
purpose) and `XCTSkipIf`s instead; that is safe only because `ci.yml` installs process-compose
and hard-fails if it is not on `searchPaths`, in the same job and immediately before the tests.

Removing the flag took out a guard in each of three places — `PhasePolicy.plan` (so no
unattended phase runs), the approval resolution (since removed outright) and
`DevCommand.Resolver.detectProcessCompose` (so Start has nothing to detect). Only the third was
ever near a security boundary, and it stopped being the boundary when
`ProcessCompose.RunCommandPlan` took the invariant to the consumer — see below.

**The un-`-n`'d command must never be executed, and is no longer displayed either.**
`DevCommand.Resolver.detectProcessCompose` builds `process-compose up -U -f <files>` as the
`.processCompose` source's `command`. It carries no `-n`, so running it would run **every**
namespace — `dispose` included — without passing through `PhasePolicy`. It is
not a runnable string, and the pane no longer renders it: for a
`.processCompose` source `devCommandDisplayText` shows the *files* that will be loaded, which
is what the user needed to see. Rendering the command was a copy-paste hazard on its own, and
Customize seeded its editable field from it — and Save turns that field into an `.override`,
which `ProcessCompose.RunCommandPlan` runs literally. Do not put a runnable process-compose command back into
`DevCommand.command`'s display path.

That invariant was defended four times by guarding *preconditions*, and reopened four times by
a different route each time: a worktree override process-compose discovered but Atelier never
showed; `compose.yaml` winning discovery outright; the process-compose switch — since removed —
being off; and — with that switch **on** — `resolveBinary()` returning nil, which is ordinary rather than exotic,
since process-compose is not in homebrew-core and `go install`, nix, mise and asdf shims all
sit on PATH but outside the three searched directories. That last one was additionally nasty
because `scriptCommand` wraps the fallback in `$SHELL -lic`, so PATH would resolve the very
binary `resolveBinary` had just failed to find, defeating that function's own promise that a
configured-but-missing path fails rather than letting a substitute run.

The fallback is reachable whenever *any* precondition of the gated path fails, so enumerating
preconditions can only ever be one behind. **So the invariant now lives at the consumer, keyed
on the dev command's source, in `ProcessCompose.RunCommandPlan.plan`**: a `.processCompose` source has exactly
one legal command — the phase-scoped one — and if that cannot be built the answer is `.nothing`.
There is no branch that returns the display string, so a precondition added tomorrow makes
Start inert rather than reopening the bypass. `Tests/RunCommandPlanTests.swift` pins it,
including a test that no combination of inputs yields the display string; three of those fail
if the fallback is put back. Do not replace this with another precondition check.

**One decision, and it is reported.** `ProcessCompose.RunCommandPlan.canRun` is what enables the Execution
pane's Start button, and `doStartRun` refuses on the same stored plan, so the two cannot
disagree — they did, for a round: the button was enabled on `devCommand?.command != nil` while
the run guarded the resolved command, and an unresolvable binary rendered an enabled Start that
did nothing in silence. `ProcessCompose.ResolutionModel` resolves the dev command, the plan, the
reason, the execute checklist and the declared verification checks together and publishes
them as **one `Resolution` value**, because *agreement* is the invariant here rather than
freshness — one struct assigned in one statement holds by construction what eight separate
`@State`s in `TerminalContainerView.refreshDevCommand` held by convention. That is also what
makes it safe for the resolution to run off the main actor, which it now does: a consumer reading
mid-flight reads the previous pass whole rather than a half-updated one. The **first** resolution
is synchronous, in the model's `init`, because a pane with nothing resolved is not neutral — a nil
verification reason reads as "everything is fine" and put an enabled Run over an empty check list. `refreshNow` exists for a caller that needs the result of a write it just made rather than the
world before it. `ProcessCompose.RunCommandPlan.unavailableReason` explains a `.nothing`, and
`ExecutionTabView.scriptInstructions` — the surface that already drew for "nothing to run" —
renders it, naming `execution.process-compose.yaml` where there is no config: a config that
cannot be located, a binary that is not where the search looks, an `execute` namespace nothing
declares. Initialization's own outcome, including `.completedWithNote`, is
rendered on the Info tab, which is permanent; nothing observed `.initializationStateChanged` before,
so those notes were written and discarded.

**The checklist's own gate is deliberately *not* in that plan**, and a reviewer will
pattern-match it to the second copy this document forbids, so say so in any commit that touches
it. **The rule is that the selection never enters `RunCommandPlan`** — not that it lives in any
particular file. `runnableExecuteSelection` reads the selection store per render in the view for
the Start button's `.disabled`, and `ProcessCompose.StartContextResolver` reads the same store for
the command itself, so the view and the IPC bridge share one assembler rather than two. (It used
to say "stays in the view", which was that rule's implementation while the view was the only
thing that could start a run; `start_execution` needed a second caller, and only the location of
the read changed.) It is the same one-decision rule
applied to the other half: the plan answers "is there a safe command for this source", and this
answers "is there anything selected to run it for". Folding the selection into
`RunCommandPlan.plan` was tried on paper and is worse in a way that is not obvious:
`Resolution.declaredExecuteProcesses` is derived by matching on `.phaseScoped`, so a plan that went
`.nothing` for an empty selection would take the **checklist** with it, hiding the checkboxes the user needs in order to
tick one again — and `canRun` removes the Start button rather than disabling it, so the pane would
answer "nothing to run" where the honest answer is "nothing selected". The two gates dim different
things on purpose.

**Three namespaces**, driven by `ProcessCompose.PhaseRunner` and `ProcessCompose.PhaseExecutor`.
There were five. `verify` went when verification stopped running through process-compose, and
`bootstrap` went when worktree setup did — see **verification.yaml** and **initialization.yaml**
below:

| Namespace | When | Interactive? |
|-----------|------|--------------|
| `prepare` | to completion before each Start, chained `&&` ahead of `execute` | no |
| `execute` | the long-lived stack, attached to a terminal surface and a process table | yes |
| `dispose` | once, at archive (`Workstream.Archiver.runDispose`) | no |

`prepare` is chained only when `namespacePresence` says `.present` — never on `.unknown`.
process-compose does not exit when told to run an empty namespace, it idles forever, so
chaining `up -n prepare` for a namespace that turns out not to exist hangs Start with no output.
`execute` is conditional on `.empty` and **only** `.empty`, and the gate lives in
`ProcessCompose.RunCommandPlan.plan` rather than in `PhaseRunner.startCommand`. It had to exist
because `up -n execute` against a namespace nobody declares does not fail and does not exit —
measured against v1.122.0, it idles indefinitely with no output — so Start opened a TUI with an
empty process list and Stop as the only way out. It had to go in `RunCommandPlan` because
`canRun` is what enables the Start button; deciding it in `startCommand` would leave the button
enabled over a run that does nothing, the exact disagreement that type exists to prevent.
`unavailableReason` carries the wording and `ExecutionTabView.scriptInstructions` renders it, so
the refusal is stated rather than silent — which is what makes this safe: the objection to
gating `execute` was that skipping it would make Start *silently* do nothing, and it is the
silence, not the skip, that was the problem. **Nothing but a test enforces that `plan` and
`unavailableReason` agree** — they hand-mirror each other in the same order, as
`verificationUnavailableReason` does; `Tests/RunCommandPlanTests.swift` pins both directions.

**`.unknown` fails closed here and open in `ProcessCompose.PhaseExecutor`, and that asymmetry is deliberate.**
A config Yams cannot decode still gets its `dispose` run, because refusing would
silently skip work the project may really have declared — and being wrong there costs a bounded
wait, `min(timeout, userCommand)` plus a grace period that ends in `.skipped`. Nothing bounds
the chained Start command: it runs in a terminal surface with no deadline, so failing open
there trades "a declared prepare was skipped" for "Start never returns". Do not make the two
consistent with each other; they are answering the same question under opposite costs.

Three facts about this are load-bearing and easy to lose:

1. **`$$`, not `$`, inside a `command:`.** process-compose runs the whole command body through
   envsubst before the shell sees it, and envsubst eats `${VAR}` *and* bare `$VAR`. A shell
   variable in a command body must be written `$$VAR`. A backslash does not escape it.
2. **Every file is named with `-f`, always** (`ProcessCompose.PhaseRunner.command`, `DevCommand.Resolver.detectProcessCompose`).
   That turns process-compose's own discovery *off*, which is the point: the set of files
   Atelier locates, displays and executes is then one set. Do not reintroduce discovery.
   Leaving a config unnamed so discovery could pick up a sibling file made the displayed set a
   *mirror* of discovery's rules, and a mirror can be stepped around — discovery also loads
   `compose.yaml`, a name Atelier deliberately does not detect, so a repository could ship a
   benign `process-compose.yaml` to be shown and a `compose.yaml` to be run. Verified against
   v1.122.0.
3. **The config's *location* is the trust decision, and there is no approval gate left.**
   `execute` was never gated, because it is **attended**: a deliberate press, output in a
   terminal surface in front of the user, Stop to hand. That, and not "the pane shows the
   command Start runs", is the reason — the pane shows the loaded *file*, and even before that
   it showed a display-only string rather than what Start runs. `dispose` *was* gated, because a
   config could arrive with a clone; now it cannot, so it is not. See below.

**`ProcessCompose.Config.locate` reads one name in one place**: `execution.process-compose.yaml`
in the **project directory**, then `execution.process-compose.yml`. Nothing inside a work tree is
read, and `Config` carries a `path` and nothing else — `isRepositoryProvided`,
`repositoryProvidedFiles` and `requiresApproval` are gone with the tiers that produced them.

**That is a trust decision, and it is the same one `Verification.Config` states.**
`Project.directory` is the repository's *home*, so a file there sits outside every work tree and
cannot have arrived with a clone: it was placed by hand. So `dispose` runs the project's
commands unattended with **no approval step at all** — no `ScriptTrust` fingerprint, no approval
sheet, no precondition in `PhasePolicy.plan`. That is the same rule `initialization.yaml` and
`verification.yaml` already state, so it is now three files answering to one rule rather than one
file with an exemption. Two consequences, both wanted: one config
serves every worktree, and an agent confined to its worktree by the "Restrict to worktree" prompt
cannot edit what runs there. The known hole, stated rather than papered over: for an ordinary
clone `Project.directory` *is* the checkout, so the file can be committed. `Verification.Config`
accepts the same hole and the rule is applied here unchanged rather than half-tightened —
sniffing whether the file is git-tracked would make the gate depend on a fact the user cannot
see. **Do not add a work-tree tier back**, and do not add an approval gate without adding one
first; each is the other's only justification.

**The `execution.` prefix is what makes a single name safe to demand.** A repository may run
process-compose for its own reasons — an instance manager, a docker-free dev stack — and that
file declares the project's own namespaces, not Atelier's three. Such a file was once
indistinguishable from an Atelier config and won the lookup outright: `prepare`
silently did nothing, and Start ran `up -n execute` against a namespace nobody had declared —
which does not fail, it **idles forever with no output** (measured against v1.122.0). No generic
name is read now, so that cannot recur.

**This replaced a four-tier search**, and the break is hard: `atelier.process-compose.y*ml` and
`process-compose.y*ml`, in the worktree and then the project directory, are all inert. A project
still carrying one gets `nil` from `locate`, and the wording is the whole migration story —
`RunCommandPlan.unavailableReason` and `ExecutionTabView.scriptInstructions` both name
`execution.process-compose.yaml` and the project directory. Do not reintroduce a deprecated
fallback tier; the precedence a reader has to hold in their head is what this removed.

**There is no override file.** An earlier design merged a worktree `process-compose.override.yml`
into a project-directory base, and a later one gave the worktree its own
`atelier.process-compose.yaml`. Both are gone. `loadedFiles` stays an array because it, not
`path`, is what `PhaseRunner.command` names with `-f`, so the located set and the executed set
are the same *set*. `Tests/ProcessComposeConfigTests.swift` pins that an override file beside the
config is never loaded, and that nothing in a work tree is.

**A newly created project starts with one.** `ProcessCompose.Config.writeDefault` drops a
commented template carrying one example process, called through `Project.seedDefaultConfigs`
(see **Seeded config templates** below) from the two paths that *create* the project
directory, and deliberately not from the two that adopt a directory the user already had.
Same rule, same entry point, as `Verification.Config.writeDefault`. **New Project seeds into a work tree** — that path runs
`git init` on the directory it made, so `Project.directory` is the checkout — and that is the
known hole above rather than a new one: a hand-written config in the same place is read
identically, and `verification.yaml`, whose checks are commands too, is seeded on the same terms.
Clone Repository is unaffected, because a committed config lands in the worktrees, where nothing
reads it. **The template's example process is real and uncommented, and
that is load-bearing**: a comments-only file — or one whose `processes:` key is null — fails to
decode, so `namespacePresence` answers `.unknown`, and `RunCommandPlan` gates `execute` on
`.empty` and *only* `.empty`. A commented-out template would ship every new project with an
enabled Start that idles forever.

**Which directory that is, is load-bearing.** `Project.directory` means the repository's
*home* — the `.bare` container, not the default checkout inside it — and every caller that
locates a config or reads `ports.yml` passes exactly that. `Project.checkout` is the other
half of the pair, and is for git work-tree reads only. They were one field until this was
fixed: `projectLocation` resolved a container forward to its checkout, so the lookups ran
against `<container>/main` and a config placed where the README says was never found. Passing
`checkout` to `Config.locate` or `PortsConfig.load` reintroduces exactly that bug.

Wherever the config lives, process-compose runs with the *worktree* as cwd and resolves a
relative `working_dir` against its own cwd, so `working_dir: apps/api` lands inside the
worktree.

`-u <path>` names the control socket explicitly. `-U` alone generates a path containing
process-compose's PID, which Atelier cannot predict and so cannot connect to. The headless
phases get namespace-suffixed paths, because a phase still running when the user presses Start
would otherwise rebind `execute`'s socket and strand the first server. `dispose` is the only
headless phase left and the suffix stays regardless — `prepare` is chained into `execute`'s own
command and shares its socket by design.

**The one gate.** `PhasePolicy.plan` answers the two preconditions — a config located and a
binary to run it with — for both unattended phases. There were four: the process-compose switch
went first, then approval of every repository-provided file went with the work-tree tiers.
`RunCommandPlan.unavailableReason` hand-mirrors the surviving two and does not fail to compile
when it disagrees, which is what `Tests/RunCommandPlanTests.swift` pins in both directions. It is
deliberately the *only* copy: a second, inlined set in
`Workstream.Archiver` could not be tested and would not follow a change made here. Any new
unattended execution path for repository-provided commands must go through it.
**Verification does not go through it**, and that is not an omission: a check's commands come
from `verification.yaml` in the *project directory*, which is outside every work tree, so the
location rule this gate implements already answers the question. See **verification.yaml** below.

### Seeded config templates
The two paths that *create* the project directory — "New Project" and Clone Repository,
both in `ProjectSidebar` — call **`Project.seedDefaultConfigs`**, which writes one
commented template per config file the app reads from the project directory:
`verification.yaml`, `initialization.yaml`, `ports.yaml` and
`execution.process-compose.yaml`. The two paths that *adopt* a
directory the user already had (the picker and the drag-and-drop) deliberately do not:
writing there would leave untracked files in a repository they merely registered.

Each file is **declared** on its config type as a `Project.ConfigFile` — its two
spellings, its template, and its parser — so only one place knows each filename, and
`Project.configFiles` is the list `seedDefaultConfigs` loops over. The **mechanism** is
`Project.ConfigFile`'s and is written once (`Sources/Models/ProjectConfigFile.swift`):
first spelling present wins, nothing inside a work tree is read, and a template is
written only when **neither** spelling is already present — seeding a `ports.yaml`
beside an existing `ports.yml` would win the lookup and hide the project's real
declarations. The refusals are per file, not all-or-nothing: a project that already
carries its own `ports.yml` still gains the templates it lacks. Each config type keeps
its own `locate`/`load`/`writeDefault` names and delegates, so nothing outside had to
move; `ProcessCompose.PortsConfig` keeps its `LoadError` and wraps rather than adopts
`ConfigLoad`, and `ProcessCompose.Config`'s declaration carries a trivial parser whose
`load` is never called — `namespacePresence` still answers `.unknown` for a file it
cannot decode, which is what `RunCommandPlan`'s `.empty`-and-only-`.empty` gate needs.

`Project.ConfigLoad` is the three-case `Load` shared by `Verification.Config` and
`Initialization.Config` (each a `typealias` onto it), with the *wording* —
`unavailableReason` — in a constrained extension per file, because verification's is
present tense for the tab and initialization's is past tense for the Info row. The node
walk both share is `Project.parseCommandEntries`.

**Whether a template's example is commented out is a per-file safety decision, not
style.** `verification.yaml`'s example check is uncommented (a check runs only on a
deliberate press, and an all-comments file would render the dead-end "declares no
checks" instead of the actionable empty state), and so is
`execution.process-compose.yaml`'s example process — there a comments-only file fails to
decode, `namespacePresence("execute")` answers `.unknown`, and Start runs a namespace
nobody declared, which idles forever (see the process-compose section).
`initialization.yaml`'s and
`ports.yaml`'s examples are commented out, because an uncommented step would *execute*
behind every new worktree and an uncommented port entry would claim a real port and
inject its variable into every terminal surface. The round-trip tests in
`InitializationConfigTests`, `PortsConfigTests` and `VerificationConfigTests` pin each
template to the loading behavior its choice depends on.

### initialization.yaml
Worktree setup does **not** go through process-compose. A project declares what a new
worktree needs in an `initialization.yaml`, and the steps run once, in the background,
the moment the worktree exists.

```yaml
deps:
  command: bundle install
assets:
  shell: fish
  command: bun install && bun run build
```

**The file lives in the project directory and nowhere else**, on exactly the trust
argument `verification.yaml` makes and for the same reasons: `Project.directory` is the
repository's *home*, so a file there sits outside every work tree and cannot have arrived
with the repository, and the existing rule therefore settles it — approval is gated by a
config's **location**, not its content. So there is **no `ScriptTrust` fingerprint and no
`PhasePolicy` gate** on this path. Two consequences, both wanted: one set of steps serves
every worktree, and an agent confined to its worktree by the "Restrict to worktree" prompt
cannot rewrite what runs when the next worktree is made. There is deliberately **no
worktree tier** mirroring `ProcessCompose.Config.locate`'s. The known hole is the same one
`verification.yaml` documents and is left unchanged rather than half-tightened: for an
ordinary clone `Project.directory` *is* the checkout.

**A newly created project starts with one**, all comments, via `Project.seedDefaultConfigs`
(see **Seeded config templates** above) — it loads as "declares no steps", the benign
Info-tab note, where an uncommented example would run behind every new worktree.

**Atelier's own project needs one, and it is not in this repository** — by design,
since the file lives in the project directory, outside every worktree, which is
what lets it run unattended. `docs/worktree-setup.md` carries the exact content to
place there and explains what happens without it: `ghostty/` stays empty and the
build fails with `error: Ghostty resources not found at ghostty/zig-out/share/`.

`Initialization.Config.load` returns **three** cases and never two — `.missing`,
`.invalid(reason:)`, `.loaded` — because a file Atelier cannot read must never render as
"this project declares no setup", which is the same sentence a project with genuinely none
gets and, here, the *only* diagnostic either one has: one line on the Info tab.
`Load.unavailableReason` **is** the availability decision rather than a mirror of one.
Parsed as YAML nodes rather than decoded as a dictionary, and here order is not cosmetic
the way it is for verification's rows — it is run order.

**Sequential, file order, halt on first failure.** This is the one deliberate difference
from `Verification.Runner`, whose checks are independent and run at once. Setup steps are
the opposite: `bundle install` before `rails db:prepare` is the ordinary case, and it is
what the `depends_on: process_completed_successfully` graphs in the old `bootstrap`
namespace existed to express. Running the rest after a failure works against a half-built
worktree and buries the error that mattered under the ones it caused.
`Initialization.Run.drive` is the pure loop; `Initialization.Runner` is the actor.

**Each step is `<shell> -lc '<command>'` through `ProcessRunner.capture`**, with the
worktree as cwd, `ProcessCompose.PhaseEnvironment`'s variables layered by
`childEnvironment`, and `Timeout.install` — the same deadline `bootstrap` had. **`-lc`,
not the `-lic` a verification check gets**, and the difference is the terminal: a check
runs in a Ghostty surface where `-i` is honest and is what makes a zsh user's `.zshrc`
PATH apply, while a step here has no tty and an interactive shell without one prints
job-control warnings to stderr — the stream a failure's message is read from. The PATH
`-i` was there for arrives another way, through `childEnvironment`'s injected login PATH.
There is no `sh -c` wrapper, no pid file and no status file: `capture` returns the exit
code, so the three layers `Verification.Spawn` needs have nothing to do here.
`CommandBuilder.resolveShell` is shared by both files, because both offer `shell:` and it
has to mean the same thing in each.

**There is no UI**, and that is the design rather than an omission. Setup is something that
happens to a worktree, not a pane anyone works in. The Info tab's **Setup** row is the only
surface — `initializationRow(for:)` and `canRerunInitialization(_:)` — fed by
`Initialization.State` over `.initializationStateChanged`, with a Rerun button and a
`Rerun Initialization` palette command. `.inProgress` names the running step and its
position; `.failed` names the step and carries the tail of its output; `.completedWithNote`
covers no file, an unreadable file, a file declaring no steps, and a cancelled run.

**Progress crosses back from the worker thread through an `AsyncStream`, not a `Task` per
report.** `Task { await updateState(...) }` per step has no ordering against the final
`updateState`, so a late one overwrote `.completed` and left the row stuck on "Running
“assets” (2 of 2)" for a run that had finished — and it reported to `Runner.shared` rather
than to the instance running, which is invisible in production and wrong under test. The
stream is ordered, and `finish()` plus awaiting the consumer is what makes "every progress
update has been applied" something the method can wait for.

**A purge cancels through `ProcessRunner.Cancellation`.** `Archiver.purge` calls
`Initialization.Runner.cancel`, which terminates the running step's process *group* —
`ProcessRunner`'s own kill, so a step that backgrounded a server goes with it — making
`capture` return and the loop finish as `.cancelled`. The poll watches for the
`Cancellation` it fired leaving `running`, which `run`'s `defer` clears, so it observes the
real end of the work rather than the signal, and it is bounded at 30s because a step wedged
past SIGKILL must not block an archive forever.

**The poll compares run *identity* (`running[id] === cancellation`), never slot presence.**
`run`'s `defer` frees the slot and a new run may claim it in the same breath — a manual
Rerun from the Info tab, or a late `.workstreamWorktreeReady` racing the purge — so a poll
that waited for the slot to be empty went on waiting on a run whose handle it had never
fired, burned the full 30s and answered `.timedOut` for a run that had already let go. The
archive then reached `git worktree remove --force` having been told the opposite of the
truth. A claimant is deliberately **not** cancelled in turn: `cancel` answers "the run you
asked me to stop has let go", and chasing claimants would put the exit condition back on
the slot being empty, where an arriving stream of them can still burn the bound. The
residual is stated rather than closed — a run that claims the slot during a purge is still
running in a tree about to be removed — and it is unchanged by this, which only stops
`cancel` from stalling and from misreporting. The `Cancellation` class was lifted out of `BareRepoClone`, which still
uses it: that type's exemption from `ProcessRunner` is about a clone having no honest
deadline, not about cancelling, so sharing the handle does not narrow it.

**`isCancelled` is consulted before each step and again when one fails, never after one
succeeds.** A cancel kills the running command, so it comes back as an ordinary non-zero
exit and the flag is the only discriminator; asking after a step that *succeeded* would
name it as the one stopped, when the step actually stopped is the one that never started. A
cancel arriving after the last step has already succeeded yields `.succeeded`, and that is
right rather than a gap — every step ran and the cancel was too late to stop anything.

**A project that still declares a `bootstrap` namespace is told so.** Setup would otherwise
stop happening in silence, since the namespace is simply never named on a command line
again. `Run.nothingToDoNote` keys on `namespacePresence("bootstrap") == .present` and
replaces only the "there is no file" reason — a file that is present and broken has its own,
and that is the one the user needs. `.unknown` deliberately gets the generic note: this one
makes a factual claim about the user's file, and `.unknown` is exactly where that claim is
unverified.

**The `bootstrap` namespace is gone** from `ProcessCompose.Phase`, and with it
`AsyncSetupService`, `AsyncSetupState`, `.asyncSetupStateChanged`, `cancelBootstrap` and its
socket-shutdown-and-poll, `runningBootstraps`, and `PhasePolicy.state(for:)` — which mapped
a `PhaseExecutor.Outcome` into `AsyncSetupState` and was bootstrap's alone. `PhasePolicy.plan`
survives with `dispose` as its **only** caller; the name stays phase-neutral rather than
becoming `DisposePolicy`, because naming a gate for its single caller is what invites the next
unattended phase to inline a second copy of it. Approving a repository's process-compose
config no longer reruns anything: `approveProcessConfig` used to call `rerunBootstrap`, and
worktree setup is not gated any more, so rerunning from there would run the project's setup a
second time for a reason that no longer exists.

### verification.yaml
Verification does **not** go through process-compose. A project declares its checks in a
`verification.yaml` and each one runs as a single command in its own Ghostty terminal surface.

```yaml
rubocop:
  shell: fish
  command: bundle exec rubocop
rspec:
  command: bundle exec rspec
```

**The file lives in the project directory and nowhere else** — beside `.bare`,
`execution.process-compose.yaml` and `ports.yml` — and that is a trust decision rather than a
convenience. `Project.directory` is the repository's *home*, so a file there sits outside every
work tree and cannot have arrived with the repository. It was placed there by hand, so there is
**no approval gate** on this path and adding one would be answering a question that cannot arise.
Two consequences, both wanted: one set of checks serves every worktree, and an agent confined to
its worktree by the "Restrict to worktree" prompt cannot edit the file that decides whether its
own work passes. There is deliberately **no worktree tier**, the same decision
`ProcessCompose.Config.locate` now makes — adding one would hand it exactly that. The known hole,
stated rather than papered over: for an ordinary clone `Project.directory` *is* the checkout, so
the file can be committed. Both configs accept that hole rather than half-tightening it.

This rule used to run the other way: process-compose *did* read the worktree, and a config found
there was gated by a `ScriptTrust` fingerprint the user approved in a sheet. Verification was
written to the project-directory-only rule first; the execution config then followed it, and the
gate went with the tiers it existed for.

**A newly created project starts with one**, seeded through `Project.seedDefaultConfigs`
(see **Seeded config templates** below). The template's example check is **uncommented on
purpose**: a file of nothing but comments composes to nil, which loads as "declares no
checks", so an all-comments template would have replaced the actionable empty state with a
dead-end one. Uncommented is safe *here* because a check runs only when somebody presses
Run — the templates that run unattended make the opposite choice.

`Verification.Config.load` returns **three** cases and never two: `.missing`, `.invalid(reason:)`
and `.loaded`. A file Atelier cannot read must never render as "this project declares no checks",
which is the same sentence a project with genuinely none gets and the only diagnostic either one
has — the same rule `ProcessCompose.Config.declaredProcesses` follows by returning nil rather
than `[]`. `Load.unavailableReason` **is** the availability decision rather than a mirror of one:
there is no binary to resolve and no approval to check, so "can a check run" is exactly "did this
file parse and does it declare anything", and `Runner.start` performs the same load and refuses on
the same three cases. That retires the hand-mirrored `verificationUnavailableReason` that nothing
made agree with `PhasePolicy.plan`.

**And `Verification.Runner.loadConfig` now *renders* `unavailableReason` rather than wording its
own refusal.** For two of the three cases it did not: `.missing` threw "This project has no
verification.yaml." where the tab says "Add a verification.yaml to this project's directory to
declare checks.", and `.invalid` threw the bare parse reason where the tab wraps it as "This
project's verification.yaml could not be read: …". An agent reading a refusal and a user reading
the tab were told different things about one file, under a doc comment claiming they could not be.
The empty-checks case deliberately stays worded at `start`'s own call site, because that site also
has to refuse an explicit empty `checks:` list and those are different sentences.

**Parsed as YAML nodes, not decoded as a dictionary**, so rows appear in **file order**. A Swift
dictionary has no order and rows would shuffle between launches. Yams refuses a duplicated key
itself, as a parse error — a hand-written duplicate guard was written here first and never fired.

**Each check runs `<shell> -lic '<command>'`** with the worktree as cwd and
`ProcessCompose.PhaseEnvironment`'s variables, so `ATELIER_*` and every `ports.yaml` name reach a
check exactly as they reach the other phases. `-lic` and not `-lc`: zsh users put PATH in
`.zshrc`, which only an interactive shell reads, and a check that cannot find `bundle` fails for
a reason nothing on the row could explain. `shell:` defaults to `$SHELL`; a bare name is resolved
against four common prefixes, because the wrapper inherits a GUI app's minimal PATH.

**The wrapper, and why it has three layers** (`Verification.Spawn.build`):

```sh
sh -c 'ps -o pgid= -p $$ | tr -d " " > <pid>; <shell> -lic "<command>"; echo $? > <status>'
```

1. **`sh -c` outside**, because the wrapper needs `$?` and redirection and the user's shell may be
   fish, where `$?` is `$status`.
2. **The process *group* id, recorded before anything runs.** Ghostty exposes no pid for a
   surface's child, so this is the only handle on a running check, and the group is what `stop`
   signals. **`ps -o pgid=`, never `$$`** — measured: a backgrounded `sh -c` reported `$$` as
   56980 while its real pgid was 56974, and `kill(-56980, 0)` answered ESRCH. Under `$$` both
   halves fail together and both fail *silently*: `stop` signals a group that does not exist so
   nothing dies, and `isAlive` reads the same ESRCH as "gone" so every check is recorded finished
   the moment the completion pass first looks. Production is the case where they most likely
   coincide, which is exactly what would make it pass in testing and break elsewhere.
3. **The exit code goes to a file**, not to Ghostty's `GHOSTTY_ACTION_SHOW_CHILD_EXITED`. That
   action does fire, but its code cannot be trusted here — Ghostty's own source says so where it
   builds the message: "On macOS, our exit code detection doesn't work, possibly because of our
   `login` wrapper" (`ghostty/src/Surface.zig:1208`).

The outermost token is **POSIX-quoted, never fish-quoted**: Ghostty runs a surface command through
`/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c` on macOS, so bash reads it before any
shell of ours does — the same rule `CommandBuilder.inLoginShell` states at its own quoting.

**Checks are independent.** No control server, no socket, no suite. Any number run at once, each
with its own surface and its own stop, and starting or stopping one says nothing about any other.
So `Runner.isLive(workstreamID)` means "is *anything* running here" — what a purge waits on — and
`isRunning(_:check:)` is what gates a start. A `Run` survives only as the unit one press started,
which is what `start_verification` answers with.

**A check with no pid file yet is starting, never finished.** The completion pass reads the
wrapper's two files: a status file is a verdict, and a process group that is gone *with a pid file
present* is a check that died or was killed. Reading a **missing** pid as "gone" would record every
check as finished before it had run anything, silently. `stopRequested` is the only thing that
distinguishes a killed check from one that died on its own, because killing the group takes the
wrapper with it before it can write a status.

**And "starting" is bounded, by `startupGrace` (30s, injectable beside `killGrace`).** The rule
above is about what a *missing* pid means, not about how long it may go on meaning it, and nothing
used to bound it: `SurfaceHosting.startSurface` returning true is not the wrapper having run, so a
surface that failed to spawn its child — or was torn down before exec — left a check that never
wrote a pid and could not leave the starting state. The row showed Running for the rest of the
session, `stop` no-op'd because there was no group to signal and the grace's `SIGKILL` no-op'd
with it, and `stopAndWait` burned the whole of `ProcessRunner.Timeout.userCommand` before an
archive could proceed. Past the grace the pid file is not late, it is never coming, so the check
is recorded exactly as the process-is-gone branch records one — `.failed(-1)`, or `.stopped` if a
stop was asked for. **The bound is an upper limit on the window, never a change to what a missing
pid means inside it**: within the grace a check with no pid is still starting and must never be
read as finished, which `test_completionPass_leavesACheckThatHasNotWrittenItsPIDAlone` pins on the
production default. The number is a two-sided tradeoff and is chosen from the second side: the
real path is fork → `login` → bash → `sh` → `ps`, milliseconds, so thirty seconds is three orders
of magnitude of headroom — and because `stopAndWait` drives `completionPass`, it is also the
ceiling on how long an archive can pause for a check started a moment earlier. Do not shorten it
towards the measured path; the headroom is what keeps a loaded machine from having its checks
killed off for being slow.

**`stop`'s kill after the grace belongs to the *run*, not to the check.** `stop` sends `SIGTERM`
and schedules a `SIGKILL` `killGrace` (5s) later; the task fires only while the live check is
still the same **run id**. Guarding it on `isRunning(_:check:)` — "is *a* run of this check
going" — killed the *next* run when a stop and a re-run fell inside one grace, and capturing the
`Spawn` is no defence: `Verification.Spawn.fileStem` is the workstream id and a hash of the check's
name with no run id in it, so both runs share one pid file and the stale task reads the new group
out of it. The damage was silent and misattributed — the new `LiveCheck` has `stopRequested` false
and a killed wrapper writes no status, so the row recorded `.failed(-1)`, a check apparently
crashing, with nothing tying it to a Stop press two runs ago. `killGrace` is injectable through
`Runner.init` for the regression test alone; production takes `Runner.defaultKillGrace`.

**Output lives in the surface and nowhere else.** It is never captured, never persisted, and does
not survive the app — which is the whole bargain this design makes, and it retired
`outputTruncated`, the 200-line tail, the one-shot log window, and the "there is nothing more to
fetch" copy along with it. `Verification.CheckRecord` carries a verdict, a duration, a stamp and a
run id, and that is all that outlives a session. **No output crosses the IPC boundary either**:
`IPC.VerificationCheckInfo` has no `outputTail`, and every string an agent sees points at the
Verification tab or at re-running the one check. A re-run **destroys the previous surface**, so
the last run's output is gone the moment the next one starts.

**`Runner.forget` is called by both archive paths, not just `purge`.** A check's surface id comes
from `Verification.Spawn.surfaceID` — derived from the workstream id *and* the check's name, so it
cannot collide with the workstream's own id, which is the Coding Agent's surface — and
`TerminalSurfaceCache.removeWorkstreamSurfaces` sweeps only ids derived from `WorkspaceModel`'s
counters. So nothing else can reach a check's terminal: a workstream *removed* with rspec running
would otherwise leave that terminal and its process alive for the session.

**A purge stops checks through the runner and the wait is bounded.**
`Archiver.quiesceVerification` calls `Runner.stopAndWait`, because `stop` only *asks* — it signals
the group and returns. A purge that signalled and moved on would reach `git worktree remove
--force` with the command still running in that tree. The bound is
`ProcessRunner.Timeout.userCommand`, the same tier the next step uses; on expiry the purge logs and
proceeds, because a workstream stranded half-archived is worse than cleanup that did not happen.
`forget` runs **before** the destructive work, so a check outliving an expired wait finishes into
nothing rather than announcing a result for a worktree being deleted.

**The `verify` namespace is gone** from `ProcessCompose.Phase`, and with it the socket, the
control server, `liveClients`, `sealedRunIDs`, `tearingDown`, the `sawServer` guard, the
one-owner-of-`shutDown` rule, the `restart: exit_on_failure` trap that sealed watched failures as
`.notRun`, and the empty-namespace idle gate. `shutDownWhenDone: false` survives on
`PhaseExecutor.run` with **no production caller**: it is the only thing standing between
`--keep-project` and a report, and `Tests/PhaseExecutorTests.swift` keeps it covered for whoever
needs a server to outlive its namespace next.

**`CheckResult.State` keeps seven cases, two of which have no producer.** `.pending` and
`.skipped` described a process-compose dependency graph that checks no longer have. They stay
because the glyph table, the state words and the row's accessibility labels are a fixed set the UI
is specified against, and because a queued check is the obvious next thing this could grow.
Nothing may start *reading* them as reachable.

**The Verification tab is one row per declared check**, and the row is:

```
▸  ◯ rspec ▶                                        stale   12.4s
```

The **triangle is the only toggle** — clicking the glyph or the name does nothing, which is a
deliberate reversal of the shape this replaced, where the whole row was an invisible button and
there was no triangle at all. The **run button follows the name** rather than the trailing edge,
so it is unmistakably *this check's* button, and the column it forms is ragged by design; the
trailing edge belongs to the stale marker and the duration, which are what a user scans down.
Expanding shows that check's terminal at a fixed height, read-only and scrolling inside itself —
fixed rather than grown to fit, because a terminal has its own scrollback and the rows live in a
`ScrollView`.

**Three glyphs for three offers**, and `verificationRowAction` is the pure function that picks:
green `play.fill` for a check with no result, `arrow.clockwise` for one that produced a verdict,
`stop.fill` while it runs. **A stopped check offers Run, not Re-run** — a stop is the user
deciding this check should not have run, so the honest next offer is the one an untouched check
gets. Green is only ever for starting.

**There is no Run all and no top-bar Stop.** Every row has its own button, and the action row went
with them.

`VerificationSurfaceView` attaches an **existing** surface and never creates one — deliberately
not `SingleTerminalView`, which creates on a miss: a row for a check that has never run would
otherwise spawn a terminal running the wrapper the moment its group was opened. A missing surface
is an ordinary state the row draws a sentence for, and the runner is the only thing that starts
one. `TerminalView.isReadOnly` swallows `keyDown`, `insertText` and drops while leaving selection,
copy and scrollback working — it is a flag on the write paths rather than
`acceptsFirstResponder` returning false, because a surface that cannot be focused cannot be
selected from the keyboard either. It is set at creation *and* on every attach, since the runner
makes the surface and has no opinion about who renders it.


### ports.yaml
A **`ports.yaml`** in the project directory declares the port variables Atelier supplies, so
two worktrees of one project can run the same stack at once:

```yaml
ports:
  WEB_PORT: { assigned: true, browser: true }
  API_PORT: { assigned: true }
  OAUTH_PORT: { fixed: 4000 }
```

`ProcessCompose.PortsConfig` parses it and `ProcessCompose.PortPlan.resolve` turns it into numbers for one worktree. An
`assigned` port starts from `Port.Allocator.port(for:salt:)` — the same DJB2 hash that produces
`ATELIER_PORT`, salted with the variable's name — then walks forward past anything already
claimed in this pass or already bound. Deterministic-first matters: a port that changed every
run would break bookmarks, OAuth redirect URIs, and CORS allowlists. The probe only covers the
common case; nothing can close the window between checking a port and a child binding it. A
`fixed` port is that number everywhere, for values registered off the machine.

At most one entry may set `browser: true`; that port is what the embedded browser opens, and it
wins over detection — Atelier assigned it, so there is nothing to infer. Entries are sorted by
name before allocation, so an assigned port does not move because a YAML key was reordered.
`assigned: false` is an error rather than a no-op, because it reads like it means something.

**A newly created project starts with one**, all comments, via `Project.seedDefaultConfigs`
(see **Seeded config templates** above) — it loads as "declares nothing", the ordinary state
for a project without ports, where an uncommented example would claim a real port.

Every declared name reaches **every** terminal surface via `Workstream.Environment.variables`,
not just the run pane — a port visible only to the run pane is invisible to a test run in a
terminal tab. Declarations merge *over* Atelier's own variables, so a project that wants
`ATELIER_PORT` to mean something specific may say so, and the legacy `FF_*` mirror is built
last so it never lags behind.

**And every declared name reaches all three namespaces, every initialization step and every
verification check.**
`prepare` and `execute` run in a Ghostty surface, which is handed those variables when it is
created; `bootstrap` and `dispose` spawn through `ProcessCompose.PhaseExecutor`, and until
`ProcessCompose.PhaseEnvironment` existed their children inherited only the app's own environment. One `execution.process-compose.yaml` therefore ran under two different
environments depending on which namespace was asked for: the documented replacement for the
seeding this integration removed, `rsync -rlpt --copy-links "$$ATELIER_PROJECT_DIR/seed-files/" .`,
rsynced from `/seed-files/`. `ProcessCompose.PhaseEnvironment.variables` assembles the same set for the
unattended phases, resolving `ports.yaml` itself because no call site has a plan to hand
over. `ProcessCompose.PhaseExecutor.run` takes it as a **required** parameter, and layers it over the inherited
environment with the login `PATH` applied last, so a declaration cannot displace `PATH`.
Allocation is deterministic per worktree and per name, so a plan resolved at worktree creation
lands on the same numbers Start does — modulo the liveness probe, which walks forward past a
port bound at the moment it looks, and which is why `fixed` exists for anything registered off
the machine.

### Dev command resolution
`DevCommand.Resolver` picks what the Execution tab's Start button runs, in order: the
**per-workstream override** the user typed (stored at `atelier.devCommand.<workstreamID>`),
then the located process-compose config. The override is the escape hatch for a project with no
config, and it is the only reason `DevCommand.Source` still has two cases.

There used to be a third source — a `dev` script in the repository's package.json — and a
picker to choose between it and process-compose. Both are gone. A `dev` script is
near-universal and almost always starts a subset of the stack, so it was a plausible-looking
wrong answer a project could not opt out of; the override covers the case it stood in for,
explicitly.

### The run lifecycle lives on a session, not on the view
**`ProcessCompose.RunSession` is the one place a workstream's dev-server run is started,
stopped, restarted or restored**, and it holds the state those decisions write.
`TerminalSurfaceCache.runSession(for:)` owns one per workstream, beside that workstream's
`WorkspaceModel` and for the same reason: `ContentView` keys `TerminalContainerView`
`.id(workstreamID)`, so the view is destroyed on navigation and anything the run needs to
outlive that cannot be the view's.

It was split across both. `runStarted`, `runStoppedManually`, `runGeneration` and
`runCommandString` lived on `WorkspaceModel` while every decision that set them —
`doStartRun`, `beginRun`, `stopRun`, `restartRun`, `restoreRunState` — was a private method on
the view, and four more pieces of run state never reached a model at all: `browserStartPending`,
`isReclaimingRunSocket`, the port plan and the port detector. That split has already produced
two shipped bugs of the same shape. `runGeneration` was view `@State` once, so navigating away
and back left the view believing a run was live with the generation reset to 0 and Stop removing
a surface nothing was using while a real server kept running; `browserStartPending` had exactly
that shape until this type existed. And `close_tab(kind: "execution")` was refused outright
because stopping a run meant reaching view-local `@State` — see **close_tab** above.

**The session consumes `ProcessCompose.RunCommandPlan`; it never re-decides one.** The resolved
command reaches it as a **non-optional** `StartContext.command`, assembled by
`TerminalContainerView.runStartContext` from the stored `Resolution`'s plan and the execute
checklist. That is what makes the one-decision rule structural here rather than a guard somebody
has to remember: `restart` cannot stop a run and then decline to start one, because there is no
optional left to decline on. **That command is assembled by
`ProcessCompose.StartContextResolver`, which the view and `IPC.ExecutionBridge` both call** — one
assembler, because a second one in the IPC layer is the drift this type exists to end. The
checklist's gate is still not in the plan; the process-compose section above explains why, and a
reviewer will pattern-match its absence from the session to the second copy this document
forbids.

**The tmux session a run is started in is recorded at `beginRun`, not read live at `stop`.**
That is what makes `stop()` self-contained enough for `WorkspaceActions` to call with no view
mounted, and it is strictly more correct than the live read it replaced: `killRunTmuxSession`
used to consult the *current* tmux mode and tool path, so a run started under tmux and stopped
after tmux mode was switched off killed nothing.

**The run surface's exit is the session's to observe, not the view's.** It subscribes to
`.terminalTabExited` in `init`, so a run whose last process dies while the user is looking at
another workstream is still recorded — it used to be an `.onReceive` on the container, which is
absent exactly then. The comparison is against the **current** `runID`, so the outgoing
generation's surface (which `beginRun` and `stop` both drop on their way past) cannot clear the
run that replaced it, and `runStoppedManually` is still deliberately left alone: the run died on
its own.

**What stayed in the view, and why.** `syncProcessPolling` reads `usesProcessCompose` off the
view-owned resolver and drives a `@StateObject` table, so it stays — rebound to
`.onChange(of: session.runStarted)`, which is still the right trigger because the tmux restore
sets that flag without going through start or stop. `Port.Detector` stays a view `@StateObject`
and writes `session.clearBrowserStartPending()` from its own `.onChange`; moving it would give
every visited workstream a permanent FSEvents source for no gain. Every remaining observer that
touches the run — the `.rerunScript` receiver, the `appEnv.isDetecting` change, `.onAppear` —
is on the always-mounted modifier chain, never inside a `@ViewBuilder` branch.

**Three seams are injected in `init` and defaulted**, the shape `Verification.Runner` uses for
`SurfaceHosting` and `killGrace`: creating and removing a surface and `ensureSingleton(.execution)`
(supplied by the cache, which owns both), the socket probe and reclaim, and the tmux
probe/kill. `TerminalSurfaceCache.terminalApp` exists for the same reason — it is the only place
in that type that needs `TerminalApp.shared`, and touching that initializes libghostty, which a
unit-test host cannot do. `Tests/RunSessionTests.swift` is what that buys.

**Nothing about a run is persisted.** `WorkspaceTabSnapshot` carries no run state at all now, and
never meaningfully did — it is a seed, not a store, and `WorkspaceStateStore` only ever wrote the
active tab. What made run state survive navigation was always that the cache owns the object
holding it. Across a *launch* no surface exists and a restored command string would be a lie, so
`restore`'s tmux probe is the only thing that carries a run over a relaunch.

**The editor tab answers the same question the same way, and it cost unsaved work to learn.**
`EditorView` is a `@ViewBuilder` branch of `TerminalContainerView`, so the rule above applies to
it unchanged: anything an editor tab needs to survive navigation belongs on `WorkspaceModel`,
which `TerminalSurfaceCache` owns, and not in view `@State`. `fileLoaded` was view `@State` — it
means "this tab's Monaco model already holds its file's contents" — so a fresh view read it as
`false`, `onAppear` read *that* as "never loaded", and reloaded the file from disk through
`openFile`, whose `model.setValue(text)` replaced whatever the user had been typing and reset the
model's clean version. Typing in a file and pressing ⌘⏎ lost the edits, the dirty dot and the ⌘W
save prompt together. It is now `WorkspaceModel.editorFileLoaded`, and `onAppear` calls
`switchModel` rather than reloading — which also keeps the undo stack, cursor and scroll position
across a switch on a clean tab. `currentFilePath` did **not** have to move: it is already durable
as `editorFilePaths[id]`, arrives as `initialFilePath`, and is kept current by `onFileChanged`.

Three things about it are load-bearing. The flag is **not** `@Published`, for the reason
`hasBeenPresented` and `editorInitialLines` give — nothing renders from it and it is written
inside a load the view is already performing. It is cleared in `removeTab` beside
`editorDirtyState`, and deliberately kept out of `WorkspaceTabSnapshot`, which carries no live
model state. And the attach branch is **gated on `initialFilePath` being present**: Save As to a
file outside the worktree removes that entry and detaches the editor, and there is nowhere
durable to record an absolute path, so that case keeps the do-nothing it has always had rather
than attaching the model underneath the opaque "Select a file to edit" placeholder. That gap is
known and open — a detached editor still loses its association across a navigation.

### Port detection
Run scripts are wrapped in the `atelier-run` launcher binary (bundled at `Contents/Helpers/atelier-run`).
The launcher monitors the child process tree for listening TCP ports using `libproc` and writes
state to `~/Library/Caches/atelier/run-state/<workstream-id>.json`. The app watches these files
via FSEvents and retargets the embedded browser when a port is detected.

### Child processes
Everything that spawns a child goes through `ProcessRunner`, which enforces a
deadline and drains stdout and stderr concurrently. Both halves matter:
`readDataToEndOfFile()` followed by `waitUntilExit()` never returns if the child
hangs, and draining one stream while the other fills deadlocks any child whose
output passes the ~64 KB pipe buffer — reachable for `git fetch` on a
many-branch repository, or any package-manager install.

**Concurrently, and without a single auxiliary thread** — `ProcessRunner.PipePump`
moves stdin, stdout and stderr together in one `poll(2)` loop on the **calling**
thread. The concurrency is not optional: reading stdout to EOF while stderr fills
deadlocks any child whose output passes the buffer, and a stdin payload past that
same buffer blocks the writer until the child reads. What is deliberate is that
none of it costs a thread, and two earlier shapes that bought it with threads
each starved a pool:

- `readDataToEndOfFile()` on two dispatch threads parked both for good whenever a
  grandchild held the write end open — EOF is not the child's to give, and `sh -c
  'server &'` is ordinary in a project's own command. Two per call against
  libdispatch's ~64-thread global pool, and a few dozen calls starved it.
- Replacing those with `DispatchSource` read sources fixed the *leak* and kept the
  *dependency*: the waiter still blocked a thread while the source's event handler
  needed one of its own to deliver EOF. When the callers are Swift `Task`s that
  pool is the cooperative one, `hw.ncpu` wide rather than 64, so the waiters
  consumed the very threads that would have completed them. Measured in 0.2.1: 14
  of 14 cooperative threads parked in `capture`, every child killed at its
  deadline — `tmux -V` blowing a 120s bound, which is the tell, since nothing
  about that child is slow. The user-visible symptom was a workstream stuck on
  "Preparing Coding Agent..." and git operations that had already succeeded on
  disk being reported as failures.

So the invariant is now **a capture pumps its pipes on exactly one thread, the
caller's, consulting no pool** — immunity by construction rather than by having
enough threads, and what `Tests/ProcessRunnerTests.swift`'s two
`ConcurrentCaptures…` tests pin. Do not reintroduce a queue, a source or a
detached drain here, however tidy it looks; the corollary for callers is that the
thread is blocked for the child's whole life, so `capture` belongs off the main
actor and off any pool narrow enough to matter.

State that invariant about the *pump* and not about the whole call, because one
off-thread dependency is left: `exited.wait` is signalled from
`process.terminationHandler`, which Foundation delivers on machinery
`ProcessRunner` does not own. The concurrency test is evidence it is not the
cooperative pool — fourteen captures parked at the exit wait with none to spare
would wedge identically — but that is one width measured, not a proof. The
practical consequence is diagnostic: a capture starved there parks at the *exit
wait*, which is a different stack from the pump and a different bug.

One behaviour change came with it: **writing stdin is part of finishing.** A
payload still unwritten at the deadline now fails the capture, where the abandoned
writer thread it replaced reported success and parked forever. That needs a
payload past the ~64 KB pipe buffer handed to a child that will not drain it, and
`HookChannelProbe` is the only `standardInput:` caller in the app, at a few
hundred bytes — so no caller today can reach it. `PipePump` never closes a
descriptor it did not open — the `Pipe`s own them — with one exception, the stdin
write end, whose close is what gives the child EOF.

**The deadline kills the process group, not just the child.** When the child
exits immediately and leaves a grandchild behind, Foundation has already reaped
the child by the time the deadline fires — `terminate()` has nothing to signal,
and the survivor goes on running. `Process` spawns each child as its own group
leader (`pgid == pid`, measured) and a backgrounded grandchild inherits that
group, so the group is the only handle left on it. Two facts make that safe, and
both were measured rather than reasoned about, because the cost of being wrong
is signalling a stranger:

- **A pid live as a group id is never reissued.** A group was orphaned, then
  ~98,000 forks drove the pid counter a full lap past it (`kern.maxproc` is
  12,000) and the number was never allocated. So `kill(-pid)` after the leader
  is reaped can only reach the group Atelier created; an empty group answers
  ESRCH and nothing happens. `ProcessRunner.kill` also guards `pid > 1`, because
  `kill` reads 0 as "my own group" and -1 as "everything" — and a `Process` that
  never launched reports 0.
- **A daemon is out of reach, which is the wanted behaviour.** Anything calling
  `setsid` leaves the group by definition. The tmux server is exactly that: it
  lands in its own group and survives this (verified), which it must, since it
  is meant to outlive the client command that started it.

Pick a deadline from `ProcessRunner.Timeout` rather than inlining a number:
`local` for reads and ref-level writes, `network` for anything reaching a remote,
`userCommand` for work whose size the user controls, `install` for package
managers, `suite` for a project's own test or lint suite. `suite` is 1800s, the
same bound as `install`, because `userCommand`'s
300s is too short for a real suite — the bound exists to break a wedge rather
than to enforce a pace, and Stop is the real escape for a run that is merely
slow. The distinction that matters is not local-versus-remote but whether the
repository's size sets the duration: `git status` is `local`, while `git worktree
add` checks out a whole tree and goes through `Git.Operations.runOnWholeTree`. Git spawns also set `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`, because
a GUI app has no terminal on which to answer a credential prompt, so the prompt
is itself a hang.

**Three** sites are exempt and say so where they spawn: `BareRepoClone.run`,
`QuickAction.Runner.runShellCommand` and `Whiteboard.Capture.run`. All three run
work with no honest deadline and all three give the user a cancel instead. If you
add a fourth, it needs the same two properties and the same comment.

The third is the one whose cancel is **in band**, and it is worth reading before
concluding that any long-running child qualifies. `screencapture -i` blocks until
the user drags a selection or presses Escape, which is unbounded human time — but
the capture overlay owns the screen while it is up, so there is no Atelier button
left to press. Escape, in the system's own UI, *is* the cancel, and it is the
child's own rather than one this app had to provide. What makes the exemption
cheap rather than a concession is that there is nothing to drain: `screencapture`
writes to a file and prints nothing, so `ProcessRunner`'s pipe pump would buy none
of its value while costing a blocked thread for the length of a human gesture —
exactly the corollary stated above for callers. `terminationHandler` blocks
nothing. A tier would have been defensible (`userCommand`, as a wedge-breaker)
and was rejected for paying that thread to bound something no wedge can reach.

### AppleScript

Everything that runs AppleScript goes through `AppleScriptRunner`, which is to
`NSAppleScript` what `ProcessRunner` is to `Process`: **the source is a constant
and every value travels as an `NSAppleEventDescriptor` parameter to a named
handler**. There are two call sites — `ExternalTerminal.run`, which opens a file
in an editor in Apple Terminal, and `SettingsView`'s CLI install, which runs
`do shell script … with administrator privileges`.

Interpolating into the source is what this replaced, and it is two nested
languages deep: a Swift value lands inside an AppleScript string literal, which
lands inside a shell command. Escaping for one layer looks exactly like escaping
for both, and only the shell layer was ever escaped. A file named
`z" & (do shell script "touch atelier-pwned") & "` closed the AppleScript literal and the
rest **compiled** — verified, along with the everyday half of the same bug: an
ordinary name like `say"hi.txt` produced a script that did not compile at all and
the row silently did nothing. Atelier runs coding agents against cloned
repositories, so every name in a work tree is untrusted input.

The shell layer is closed the same way rather than by a second escaper:
AppleScript's own `quoted form of` does the POSIX quoting **inside** the script,
so no Swift caller assembles a command line either. `CommandBuilder.shellQuote`
is deliberately not used here — it leaves a leading `~` unquoted on purpose,
which is right for the commands it serves and wrong for a file name.

Three things that are easy to undo:

- **A handler called inside a `tell application` block is dispatched to that
  application**, which answers "Can't continue" for a name it has never heard of.
  `ExternalTerminal.runScript` resolves the command *before* its `tell` block for
  exactly that reason. The unit tests do not catch this, because they call the
  command handler directly; only running it against Terminal does.
- **`AppleScriptRunner.run` compiles up front.** `NSAppleScript` otherwise
  compiles lazily on execute and reports a syntax error as an execution failure,
  hiding the one failure mode that is always a bug in Atelier's own constant
  source.
- **Failures are logged, never swallowed.** `runLoggingFailure` exists because
  discarding the error dictionary is precisely how the escaping bug presented —
  as ordinary files quietly failing to open.

`ExternalTerminal` also owns opening a *directory* in the user's terminal, which
is an `NSWorkspace` call carrying a `URL` and has no injection to speak of. It
lives there because the same eight lines had been copied into four views, and a
fifth copy is how the hardened path above eventually gets worked around.

### Paths
- Persistent data: UserDefaults (projects, sidebar state, workspace tabs)
- Cache: `~/Library/Caches/<AppConstants.appID>/` — `atelier` for a release
  build, `atelier-debug` for a debug one, `atelier-tests` under XCTest. Holds
  run-state, tmux.conf and the process-compose phase sockets. The split is
  load-bearing: both variants shared one directory, so quitting a debug build
  swept a release build's live phase servers.
- Worktrees: beside the repository when the project uses the README's bare-repo layout
  (a `.bare` directory with a `.git` file next to it), so a worktree for `/repos/app` is
  created at `/repos/app/<name>`. Any other layout — an ordinary clone, a plain
  `git clone --bare`, a submodule — falls back to `~/.atelier/worktrees/<project>/<name>`,
  because there the equivalent directory is the working tree or a git directory, and a
  worktree must not be created inside either. See `Git.Operations.worktreeDestination`.
- URL scheme: `atelier://`
- Bundle ID: `com.github.phaedryx.atelier`

### Agent status: silence, and what it is allowed to mean

Every signal Atelier has about an agent comes from a Claude Code hook, and no hook fires
*during* anything. `PreToolUse` fires when a tool starts and nothing else arrives until
`PostToolUse`; between two tool calls the model can generate for a minute with no hook at all.
So **silence is the app's only raw material, and silence is ambiguous** — a build, a long
response, a slow MCP call and a wedged agent are indistinguishable from the outside.

`Workstream.AgentStateTracker.sweepForStalls` therefore reads silence in two stages, and the
distinction is the whole point:

| | `silenceThreshold` (45s) | `wedgeThreshold` (300s) |
|---|---|---|
| Renders | **nothing** — the row stays Working | `.stalled`, the yellow dot |
| Does | asks `HookChannelProbe` whether events are still arriving | reports a wedge |

The 45-second mark used to set the yellow dot directly. That was wrong far more often than
right, because everything in the first sentence of this section passes 45 seconds routinely.
The question 45 seconds of silence actually raises is *whether the app is still listening*, and
no amount of further silence answers it — only the probe can.

Three exemptions keep the 300s tier honest, and each has a bound:

- **A tool in flight** (`AgentRun.isRunningTool`, set between `PreToolUse` and `PostToolUse`).
  This is the one the original complaint was about. Tracked separately from `activity` because
  `activity` is display text and may be nil for a tool the mapper had no phrase for; the sweep
  needs the fact.
- **Compaction** (`isCompacting`), which emits nothing between `PreCompact` and `PostCompact`.
- **A permission prompt**, which is waiting on the user, not stalling.

The first two are bounded by `longWorkGrace` (1800s), which must stay larger than
`wedgeThreshold` or it never binds. The bound exists because the event that would *lift* the
exemption may never arrive — the agent died mid-tool, or the POST carrying it was dropped — and
a missing end-event must not suppress the sweep for the rest of the session.

**`HookEventReceiver.isMetaTool` is consulted by both `PreToolUse` and `PostToolUse`, and that
is not an accident.** The two hooks bracket a running tool, and a bracket that opens without
closing — or closes without opening — is worse than no bracket. `mcp__*` was once filtered on
the `PreToolUse` side only, so an MCP call reported nothing going in and a stray `toolDone`
coming out; the sweep saw a silent agent with no tool in flight and had nothing to exempt,
which is why a slow MCP server read as a wedge. MCP calls are ordinary tool calls, frequently
the slowest, and belong inside a bracket. Only `Skill` and `ToolSearch` are filtered, on both
sides.

### The hook channel is checked, not assumed

`HookChannelProbe` answers the one question absence cannot: **are hook events arriving at all?**

`Resources/Scripts/atelier-hook` posts with `curl -s --max-time 1 -o /dev/null 2>/dev/null` and
exits 0 when the port file is missing. **Every channel failure is therefore silent by
construction** — an app that relaunched on a new port, a removed port file, hook entries another
Atelier install rewrote, or a POST that simply took longer than a second under load. All of them
render identically to a busy agent.

So the probe does not reason about silence. It writes a real payload to the real script's stdin
(`{"hook_event_name": "AtelierPing", "nonce": …}`, which the script wraps as `event_input` like
any hook event) and waits for that nonce to come back out of `HookEventReceiver.onPing`. A nonce
that returns has proved the whole path end to end: port file, curl, its timeout, the listener,
the parser. Calling the listener directly would prove only that the app can reach itself.

Facts worth keeping:

- **The ping produces no `AgentEvent`.** It is answered before `mapHookEvent`. An envelope that
  touched a roster would reset the very stall clock the probe was sent to explain, making the
  probe's own traffic the reason the channel looked healthy.
- **Real traffic is better evidence than a ping, and free.** Any delivered hook event calls
  `noteTraffic`, which verifies the channel, cancels a check in flight, and clears `.down` the
  moment events resume rather than at the end of the debounce. It runs on *every* event, so
  `State` deliberately carries no timestamps and `markVerified` publishes only on a transition —
  a date in the published state would invalidate the sidebar on every tool call. The timestamps
  live beside it, unpublished.
- **Two attempts, not one.** `curl --max-time 1` drops a slow POST, so a single unanswered ping
  is expected and must not repaint anything.
- **One rendezvous, and only its named owner may delete it.** `~/Library/Caches/atelier/hook-port`
  is deliberately outside `AppConstants.cacheDirectory` (`HookEventReceiver.writePortFile`), so
  debug and release share it and the last launch wins. Taking it is unconditional; giving it up is
  not. `stop()` used to unlink the file on quit whatever it held, so quitting a worktree's debug
  build deleted the *running* release app's port — and because `atelier-hook` exits 0 when the
  file is missing, that silenced hooks for every Claude Code session on the machine. The surviving
  app's probe reported "No Signal" and was right, with nothing able to say why. `removePortFile`
  now removes the file only when it still names that instance's own port
  (`HookEventReceiver.ownsPortFile`, pinned in `Tests/HookEventReceiverTests.swift`). The
  comparison is exact on the trimmed contents; a prefix match would read `607980` as `60798`.
  Overwriting on launch is untouched and still starves every other instance of events — that is
  the one-rendezvous decision, not this bug.
- **Checked at launch and on suspicion, never on a timer.** Launch (forced, past the debounce)
  is where a botched install or stale port file is most likely and most fixable; after that only
  when the sweep reports prolonged silence, debounced to `minimumInterval`. A healthy app spawns
  nothing. The sweep calls through `AgentStateTracker.onProlongedSilence` rather than the
  singleton, so the sweep stays testable and the tracker keeps knowing nothing about how the
  channel gets checked.

**Two surfaces, not one, and the second is not redundant.** `HookChannelBanner` sits in the
sidebar's bottom bar, gated on the probe's verdict and *nothing else*. A row only draws a status
line once `hasLiveSession` is true, and `liveSessionIDs` is only populated from `handle` — so a
channel that was already broken when the app launched leaves every row silent and would have had
nothing to speak through. `ensureSweepTimer` is called from `handle` too, so in that same case
the sweep never runs and `onProlongedSilence` never fires either: the forced launch check is the
only one that happens, and the banner is the only thing that can show it. Dropping the banner as
"redundant with the row word" is the mistake to avoid — it removes the surface for exactly the
case the probe exists to catch.

**`AgentStatusLabel` decides what a row may claim, and `channelDown` masks `.working` and
`.stalled` — nothing else.** Those two are held up by the *continued arrival* of events: "still
working" means no `Stop` has come in, and `.stalled` is inferred from absence outright. Neither
survives learning that the app has stopped hearing, so both become **No Signal** (grey, because
the fault is Atelier's own plumbing and nothing is asked of the user). The rest are positive
facts a delivered hook established, and losing the channel afterwards does not unmake them —
masking `.needsAttention(.permission)` would be the worst of it, since the agent is stopped
until someone answers. `AgentStatusLabel` also exists because the row and the roster cards had
already drifted: the row grew a permission state and a live-session-aware idle that the cards
never learned.

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
twenty app-level ones: the sidebar/palette/help/settings four, the six navigation cases,
archive and purge, and the six selected-workstream actions above.
`AppCommandChannel.shared.send(_:)` replaces the post, `ContentView.handle(_:)` is the
single exhaustive switch that replaces twenty `.onReceive`s, and there is no `default:`,
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

### System prompts

The Coding Agent receives additional system prompts via `--append-system-prompt` based on
user settings. Prompts are defined in `Sources/Models/SystemPrompts.swift` and assembled in
`Workstream.AgentCommand.systemPrompt` (`Sources/Models/AgentCommand.swift`), which
`TerminalContainerView.buildClaudeCommand()` calls for the Coding Agent tab and the
`open_agent_tab` tool calls for a tab it is about to spawn. It lives there rather than in the
view because there are now two callers and the *gating* is what they must agree on — a second
copy would drift on exactly the condition below.

**Important**: Claude Code only accepts a single `--append-system-prompt` flag per invocation.
Multiple flags do not stack; the last one wins. When multiple prompts are active, they must be
concatenated into a single string before passing to the CLI.

Active prompts (combined when multiple are enabled):
- **Restrict to worktree** (default: on, setting: `atelier.allowOutsideWorktree`): constrains file writes to the worktree directory.
- **Auto-rename branch** (setting: `atelier.autoRenameBranch`): renames the git branch to match the task on first request.
- **Agent IPC** (default: off, setting: `atelier.agentIPC`): tells the agent it has
  peers and how to reach them through the `atelier-ipc` MCP server. This one is
  **not** gated on the setting directly — it is gated on `IPC.Config.write`
  having returned a path, the same condition that adds `--mcp-config`. An agent
  told it has peers but handed no server would call tools that do not exist, so
  the prompt and the config must appear and disappear together. Keep any new
  gate on the written config, not on the setting.

There are three, and the list above is the whole of it. Two of them were once the
whole of it, which is why `SystemPrompts.swift` is worth reading before assuming.

### Where the context meter's numbers come from

The sidebar's context bar has two possible sources and they are not equal.

**The status line is the first choice.** Hook payloads carry no token or context
fields at all — `session_id`, `transcript_path`, `cwd`, `permission_mode`, the
event's own fields, and that is the whole documented set. Claude Code hands the
figures to exactly one interface, the status line command, which receives
`context_window.total_input_tokens` and `context_window.context_window_size`
already resolved, the second including whether the session is on a 1M window.
That single field is why this channel exists: `ContextLimits` can only *infer*
the window from a model string plus `ClaudeCodeSettings.configuredModel`, and it
is not consulted at all on this path.

**`statusLine` is a single command slot, so Atelier never writes it.** Unlike
`hooks`, which is a list Atelier merges an entry into, that key holds one
command — registering into it means taking it from whatever the user has.
Instead `StatusLine.Config.write` produces a settings file naming
`atelier-statusline`, and the agent is launched with `--settings <path>`
alongside the `--mcp-config` it already gets. That layer sits above user
settings, merges per key, lasts one session and writes to no file, so a Claude
session started anywhere else is untouched. The file carries `statusLine` and
nothing else, because a second key there would silently override the user's own
value for it.

Three consequences worth keeping:

1. **No configured status line means no registration**, and that session falls
   back to the transcript. Registering one anyway would give a user a status
   line they never asked for: Claude Code hides most of the footer's keyboard
   hints as soon as one is configured, and a script that prints nothing leaves
   the row blank. `ClaudeCodeSettings.statusLineCommand` is the gate, and it
   reads only `type: "command"` — an unrecognised shape has to mean "leave it
   alone", never "there is nothing there".
2. **The user's own status line is chained, and resolved at launch.**
   `atelier-statusline` POSTs the payload, then runs the command it was handed
   as `$1` with the same stdin and prints its output verbatim. The command is
   resolved in Swift when the agent starts rather than re-read on every render,
   because a `sh` script has no JSON parser — the same call `atelier-hook` makes
   by taking a flag instead of sniffing its own stdin. The cost, and it is real:
   a `/statusline` change reaches a running agent only when its surface
   respawns.
3. **Only the main session's reading is taken.** `open_agent_tab` registers
   the status line for the agent it spawns too, and two agents in one worktree
   report the same `project_dir` — so `handleStatusLine` drops a payload whose
   surface id is not the workstream's own, the same restriction the transcript
   path gets from `event.agentId == "main"`. The comparison is on `UUID` values,
   never on the strings: `ATELIER_SURFACE_ID` is exported uppercase and the
   workstream id is written lowercase, so comparing text would reject every real
   Coding Agent tab. A payload with no surface id at all is a session started by
   hand in the worktree and is taken.
4. **A status line reading does not mark a session live.**
   `AgentStateTracker.handleStatusLine` sets `contextUsage` and deliberately
   does not touch `liveSessionIDs`, the roster, or any stall clock. The status
   line renders on a timer as well as on a turn, so it is not evidence that an
   agent is alive in the sense the row's status word means — and `hasLiveSession`
   is what decides whether a row may speak at all, which `HookChannelBanner`
   depends on.

**The transcript is the fallback and stays one.** `TranscriptContextReader`
parses `message.usage` out of the JSONL tail, which works, but Claude Code's own
documentation says that entry format is internal and changes between versions.
`refreshContextUsage` returns early for a workstream whose source is already
`.statusLine` — before the throttle and before the read, since this is a channel
that has been superseded rather than an attempt to retry. It also logs a missing
or unreadable transcript on the *edge* only: the read is deliberately retried on
every hook event until it succeeds, so an unconditional line there would be one
per tool call for the whole life of the session it is meant to make
diagnosable.

### Agent workspace tools (IPC)

`IPC.Tool` is four groups, not one, and `Tool.surface` makes the grouping a value the compiler
checks rather than a comment:

| Group | Tools | Trust story |
|---|---|---|
| Messaging | `register_peer`, `list_peers`, `send_message`, `receive_messages`, `broadcast`, `get_peer_status` | none needed — text between agents, nothing a user can see |
| Workspace reads | `list_tabs`, `read_review_comments`, `check_verification`, `list_verification_checks`, `list_processes`, `read_process_logs`, `read_whiteboard`, `get_session_checkpoint`, `get_initialization_state`, `get_shortcut_story` | none needed — answers about the caller's own workstream |
| Workspace actions | `open_agent_tab`, `open_editor`, `open_tab`, `close_tab`, `request_attention`, `create_workstream`, `create_shortcut_workstream`, `start_verification`, `start_execution`, `stop_execution`, `start_process`, `stop_process`, `restart_process`, `whiteboard_add`, `whiteboard_update`, `whiteboard_delete`, `update_session_checkpoint` | see below |
| Project tasks | `add_task`, `get_pending_tasks`, `list_tasks`, `claim_task`, `complete_task`, `fail_task` | see "The project task queue" below — project-scoped, and ungated for a third reason distinct from the two above |

The messaging six were once the whole enum. Calix's IPC core is the same six, and everything it
grew on top — pane/tab control, LSP, shell integration — arrived as separate tool surfaces with
separate gates. This is where Atelier takes that step.

**No approval gate, and that is a decision rather than an omission.** Calix gates its
`pane_run` because it can target any pane in any window, including one the caller does not own.
Every workspace tool here acts on the caller's *own* workstream and no other, which is the same
attended-ness argument that leaves `execute` ungated — the project task queue is the one group
that is project-scoped rather than workstream-scoped, and it earns its own ungated argument
rather than inheriting this one; see "The project task queue" below. `atelier.agentIPC` already
defaults off and already gates whether an agent knows any of these tools exist. Do not add an
approval inbox here without a reason that survives that comparison; `PermissionApprovalStore` in
particular is the wrong type to reuse — its expiry resolves to "no decision, let Claude Code ask
in the terminal", a fallback an MCP tool call does not have.

**A tool is described once, in `IPC.ToolSpec` (`Sources/Models/IPC/IPCToolRegistry.swift`).**
That file is the second one `AtelierMCP` compiles out of `Models/IPC/` — `project.yml` lists
`IPCProtocol.swift` and `IPCToolRegistry.swift`, and nothing else from the app — so the app's
dispatch and the helper's advertised schema read one description rather than two lists that
agreed by convention. A spec carries the tool's `surface`, `replyDeadline`, `isSafeToReplay`,
the prose an agent reads, and its `[ArgumentSpec]`, from which `inputSchema` is **generated**.

`Tool.spec` is an **exhaustive `switch`**, deliberately, and not a lookup in the ordered
`ToolSpec.advertised` array. A dictionary keyed by `Tool` forces one of two bad endings for a
case somebody forgets — a force-unwrap that crashes, or a default that silently hands a tool the
wrong deadline, and a default of 15 would still satisfy every deadline assertion in
`IPCProtocolTests`. The `switch` makes a case without a spec a build failure. `advertised`
decides **order only**; it is not enum order and never has been, which is why it is written out
rather than derived from `allCases`.

Adding a tool is therefore **three compiler-enforced edit sites**: the `Tool` case, its `spec`,
and the handler plus its `Service.handle` arm. It used to be eight across four files, three of
them silent. There is a fourth, and it is the one exception: `advertisedOrder` is a plain
`[Tool]`, so a case left out of it **compiles** and is caught only by `IPCToolRegistryTests`,
which pins that the advertised list and `allCases` are the same set. That is the price of
writing the order out; do not read "three edit sites" as meaning the array maintains itself.

This retires a paragraph that said the opposite — that a case with no entry in the helper's
`toolDefinitions` table was "dispatchable but undiscoverable", justified as room for a tool to
land ahead of its handler, and citing an `IPC.Service.notImplemented` that has never existed.
That hole is now closed by construction: there is no table to leave a case out of.
`IPCServerTests.test_helperBinary_answersToolsCallOverStdio` still pins the advertised list end
to end (its `undefined == []` assertion is now tautological, and kept as the wire-level check
that the helper really advertises what the registry says).

**Arguments are typed at the boundary, by `IPC.ToolArguments`.** Handlers no longer read
`request.arguments["line"]` by literal key and parse it inline; they ask for `required`,
`nonEmpty`, `integer`, `boolean`, `list` or `uuid` and get an `IPC.ToolError` naming the
argument. That collapsed three ad-hoc list/bool parsers applied unevenly —
`Workstream.Launcher.parseBool` (deleted, along with the now-unreachable
`Launcher.Failure.invalidArgument`), `VerificationSummary.checks(from:)` and
`TaskSummary.tags(from:)` (both now delegating to `ToolArguments.parseList`).

**`IPC.ToolError` unifies the *type* that crosses into a `Response`, not every wording.**
`missingArgument`/`invalidArgument`/`notInWorkstream` moved off `WorkspaceActions.Failure`,
which keeps only what the live app can know (`unknownWorkstream`, `appNotReady`,
`surfaceAlreadyRunning`); `IPC.Error`, `VerificationFailure`, `TaskQueueFailure` and
`CheckpointStore.Error` stay as they are, because each carries meaning the boundary has no
business knowing. `ToolError.refused(_:)` is the escape hatch for a sentence an agent is already
reading — `send_message`'s "needs a `to` peer id" and `get_peer_status`'s "needs a `peer_id`"
travel through it unchanged rather than being renamed into `missingArgument`'s sentence.
`emptyArgument(tool:name:)` reproduces the three "x needs non-empty `y`." refusals exactly.
**No agent-facing string changed in this refactor.**

**Four things both processes have to agree on now live in `IPC.Vocabulary`**, because the helper
compiles none of the app's model files and each was previously a literal on both sides: the tab
kinds (`WorkspaceActions.openableTabs` is keyed by them, and `WorkspaceTabKindTests` pins each
still equals the matching `WorkspaceTabKind.id`), the two reserved senders
(`VerificationSummary.sender`, `TaskSummary.sender`) and the attention cooldown
(`Workstream.AttentionNotifier.cooldown` reads it; the tool's own description and the server
instructions interpolate it).

**And the helper no longer recognises a refusal by its sentence.** `IPC.Response` carries an
optional `code: ResponseCode?`, and the one case so far —
`peerOwnedByAnotherSession` — replaces `error.contains("belongs to another session")`, a
substring match across a process boundary against a string assembled in `IPC.Server`, where
rewording the message for a human would have silently disabled the re-registration it gates.
The field is optional on the wire, so a response carrying none decodes exactly as before. Add a
code only for a refusal the helper has to *act* on; an error an agent reads needs a sentence.

**`PeerInfo.lastUserPromptSecondsAgo` answers "has a human typed into this peer directly", and
Atelier deliberately has no notion of "since I dispatched it" to compare against.** It is
`nil` when no `UserPromptSubmit` hook event has been observed for that peer's surface this
session — which covers both "never happened yet" and "this peer has no surface at all"
(`surfaceID == nil`) — and otherwise the seconds since the most recent one, mirroring
`lastSeenSecondsAgo` rather than collapsing to a boolean: a boolean would force Atelier to
decide what "since dispatch" means, and dispatch is not a concept Atelier has. A coordinator
that just sent a peer a brief (via `send_message`, or an initial prompt through
`open_agent_tab`/`create_workstream`) knows its own dispatch time; comparing that against this
field is how it tells whether a human has since typed into that peer's own session — the
incident this field exists for: a coordinator saw a peer merge a PR, assumed it had gone off
brief, and broadcast that conclusion, when the user had in fact told the peer to do exactly
that in its own terminal. Tracked per **surface** (`Workstream.AgentStateTracker`'s
`surfaceLastUserPromptAt`, alongside `surfaceStates`), not per workstream, for the reason
`surfaceStates` already gives: two agents can share one workstream.

**The read is `nonisolated`, and that is not a style choice — a `MainActor.run` hop here
deadlocked a real socket round trip.** `IPC.Service` is an actor answering requests from
`IPC.Server`'s own dispatch queue, and `IPCServerTests` exercises it by blocking the *test's*
thread in a raw, untimed `recv()` waiting for the reply. `Workstream.AgentStateTracker` is
`@MainActor`, so producing that reply by hopping to the main actor works only if the main
thread is free to run the hop — and in that test it is the very thread parked in `recv()`.
Neither side can proceed: the reply can't be produced until the main thread goes idle, and the
main thread won't go idle until the reply arrives. `AgentStateTracker.lastUserPromptAt(forSurface:)`
is therefore `nonisolated`, backed by a lock-guarded box (`UserPromptClock`) rather than a plain
dictionary — the same reasoning as `Git.Operations.defaultBranch`'s cache living outside
`AppEnvironment`, for the same reason stated there: "half the callers structurally cannot reach
a `@MainActor` type." Writes still only ever happen from MainActor code, in `updateSurfaceState`.
Do not route this field back through a `MainActor.run` read to "simplify" it — that reintroduces
the deadlock, and `IPCServerTests` is what will hang to prove it.

**Not every synthetic keystroke should count, and the two Atelier already has disagree.**
`PromptInjector`'s stored prompts are a human's own decision — they choose, in the moment, which
saved prompt to send into which pane — so a `UserPromptSubmit` that follows one is genuinely
attributable to that human, however it was typed. `AgentNudge`'s unread-messages notice is the
opposite: fully autonomous text Atelier types on the recipient's behalf when nothing has been
read yet, and unrelated to the sender's own conduct. Left alone it would have made every
`send_message` to an idle peer look like a human just walked up to that peer's terminal, which is
the exact false positive this field exists to prevent, just self-inflicted rather than caused by
the coordinator's misreading — so `AgentNudge.nudge` calls
`Workstream.AgentStateTracker.shared.expectSyntheticPrompt(surfaceID:)` immediately before typing,
and `updateSurfaceState`'s `.agentWaiting` case consumes that marker instead of recording the
prompt, provided it arrives within `syntheticPromptWindow` (10s — generous headroom over
`typeAndSubmit`'s own ~1s of delay plus hook latency). Past the window an unconsumed marker is
discarded and the next prompt counts as human regardless: `typeAndSubmit`'s own safety check can
skip its Return keypress entirely if the pane stops looking idle mid-delivery, and a marker with
no expiry would then go on suppressing attribution for whatever genuinely human prompt eventually
arrived — silently, at an arbitrary point later in the session. Add a marker-and-consume pair like
this for any *other* future mechanism that submits synthetic text into a Coding Agent tab; do not
extend `PromptInjector`'s path the same way, since its submissions are the human input this field
is supposed to report.

**Known, accepted gap: the CLI-supplied initial prompt from `open_agent_tab`/`create_workstream`
may itself read as a human prompt.** If Claude Code's harness fires `UserPromptSubmit` for that
first turn the same way it does for one typed after the session starts, a peer's
`lastUserPromptSecondsAgo` will read as "just now" from the moment it is created by *another
agent's* dispatch, not a human's. This is deliberately not suppressed the way `AgentNudge`'s
notice is: the dispatching coordinator already knows exactly what it just sent and when, so its
own "since I dispatched" comparison naturally reads this as unremarkable rather than as evidence
of a human redirect. Suppressing it would also require assuming a fact about Claude Code's own
hook semantics for a CLI-argument-supplied first turn that has not been verified here.

**A tool call that is interrupted is never re-sent unless re-sending it changes nothing.**
`IPC.Tool` carries two properties the helper reads — `replyDeadline` and `isSafeToReplay` —
and both exist because one 15-second socket timeout with one reconnect-and-replay policy
covered a surface where neither is uniform. `create_workstream` does not answer until
`git worktree add` has, so the deadline fired while the app was still working, the helper read
that as a dead app, reconnected to the *same* app, re-registered under a new peer id and re-sent
the call. Silently: a generated name produced two worktrees and two branches, and an explicit
one produced a refusal — `nameInUse`, or `git worktree add failed … may already be checked out`,
depending on how far the first copy had got — reported to a caller whose workstream had in fact
been created.

Three things hold it shut, and each is easy to undo by accident:

1. **A timeout is not a disconnection.** `IPCTransport.roundTrip` returns `.timedOut` for
   `recv` = -1/`EAGAIN` and `.closed` for `recv` = 0 or a half-written frame. They were one case
   — a nil return — and merging them is the whole bug: a closed socket says the app hung up, a
   timeout says only that it has not answered *yet*, which is no evidence about whether it has
   already acted. A `.timedOut` is reported and never replayed, and the connection is deliberately
   left up, so the session keeps its peer id and a late reply is discarded by request id.
2. **`isSafeToReplay` is idempotence, not `Tool.surface`.** The two do not line up:
   `receive_messages` is messaging and *drains an inbox*, so a replay that lands after the app
   processed the first copy loses those messages for good; `open_editor` is a workspace action and
   puts the same file on screen however many times it runs. `register_peer` has to stay replayable
   because the reconnect path replays it by hand. Refusing a replay still reconnects and
   re-registers — only the call is abandoned, not the session.
3. **The deadlines are sized to the app-side work, and the cost is paid session-wide.** The helper
   is a single-threaded `readLine` loop, so it stops reading stdin for the length of a round trip:
   a wedged app blocks *all* MCP traffic for that long. Only `create_workstream` gets minutes
   (480s — `ProcessRunner.Timeout.userCommand` after a `.network` fetch, spelled as literals
   because `ProcessRunner` is not compiled into `AtelierMCP`). Nothing waits less than the 15
   seconds it replaced. That bound is on *total elapsed time since the call began*, not on the
   gap between chunks: `SO_RCVTIMEO` only ever bounds one `recv`, so `roundTrip` recomputes the
   remaining time before every `recv` rather than setting the timeout once — a reply (or a late
   frame for an abandoned request, still read and discarded per point 1) that trickles in under
   the per-chunk window would otherwise re-arm a fresh window on every chunk and run for
   chunks × timeout instead of `deadline`.
   `IPCServerTests.test_roundTrip_isBoundedByTheToolDeadline_evenWhenRepliesTrickleIn` pins it,
   against a stub that answers in gapped single-byte fragments and never completes the frame.

The timeout message has to **forbid** a retry rather than invite one, and that is the finding's
own conclusion rather than a style preference: the caller cannot tell a genuine `nameInUse` from
one its own second attempt caused, so "try again under another name" risks the duplicate this
rule exists to prevent. `IPCProtocolTests` pins the two tables and
`IPCServerTests.test_helper_doesNotReplayACreateWorkstreamAfterLosingTheConnection` pins that
`call()` consults them — against a listener that hangs up rather than a slow one, because both
reach the same branch and only one of them finishes in milliseconds.

**`open_tab` opens a singleton pane and deliberately does not take the selection.**
Changes, Execution and Verification start *closed* — `startupWorkspaceTabState` seeds Info and
Agent alone — so a tool an agent already has could produce something with no visible surface to
read it in, worst of all `start_verification`, whose per-check output lives only in those
terminals and never crosses IPC. It goes through `WorkspaceModel.ensureSingleton`, never
`activateSingleton`: opening a pane is not a reason to pull someone off what they are working
in, the same call the run pane already makes when a browser tab starts the dev server. The
answer says so in as many words, because an agent that reads "opened" as "they are looking at
it" waits for a reaction nobody had; `request_attention` is the tool for their eyes and the two
are meant to be paired.

`WorkspaceActions.openableTabs` is the table, **keyed by `WorkspaceTabKind.id`** — the same
string `list_tabs` reports as a tab's `kind`, so the name an agent reads off a tab is the name
it passes back, and there is no second vocabulary for anything to keep in step. The two
exclusions are different refusals rather than one: Info and Agent are **permanent**, so opening
them can neither fail nor do anything, while terminal, browser and editor are **instanced** —
"the" tab is meaningless, and two of the three already have a tool that says which one. The
kind is validated *before* the workstream is resolved, so a typo is answered with the legal
values rather than with whatever the app's readiness happens to be.

**`open_agent_tab` spawns the surface already running the agent** —
`TerminalSurfaceCache.surface(for:…command:)`, not a paste into a shell. There is no synthetic
Return, no timing heuristic, and no question of whether the pane was interruptible. Two
consequences worth keeping:

- **The session id is the *surface's*, never the workstream's.** The workstream id is the Coding
  Agent tab's own Claude session; a second agent handed it fights that tab over one transcript.
- **Surfaces are created eagerly, outside any render pass** (the same construction
  `TerminalSurfaceCache.retrySurface` already does), so a tab can be spawned into a workstream
  the user is not looking at. What is view-bound is *rendering*, not surface creation.

**`close_tab` is `open_tab`/`open_agent_tab`'s counterpart, for the pane an agent's own job
created rather than one the user did.** A controller that spawns a peer into a new tab for a
bounded task — a reviewer, a test-writer — had no way to tear that pane down once the job was
done, so it (or the peer itself) leaves it running for the user to close by hand. `close_tab`
closes a singleton by `kind` (`"changes"`, `"execution"` or `"verification"`) or a terminal by
`surface_id`, the same two vocabularies `open_tab` and `open_agent_tab`/`list_tabs` already
speak — no third one for anything to keep in step. It reuses `openableTabs` rather than a second
table keyed the same way, so a fourth singleton kind added there is closeable by default.

**Execution closes, and stops the run on its way out. It used to be refused by name, and what
changed is where the run lives.** `⌘W` on that tab also stops the running dev stack, and the
method that did it reached into view-local `@State` (`browserStartPending`) that
`WorkspaceActions` — a `MainActor` singleton with no view — could not reach; reimplementing it
there would have been the inlined second copy this document keeps warning about, so the refusal
stood until there was one copy to call. There is: `ProcessCompose.RunSession` owns the run and
`TerminalSurfaceCache` owns the session, so `stopIfTabOwnsRun` is the same call
`TerminalContainerView.forceCloseTab` makes and it works with nothing on screen. Both paths run
it *after* `removeTab`, and only when the tab was really open — `closingTabStopsRun` names
exactly one owner, so Changes and Verification reach it and it does nothing for them. A running
verification check in particular is unaffected either way, since its surface comes from
`Verification.Spawn` and only `Verification.Runner.forget` reaches it.

**Closing an already-closed tab, or a `surface_id` nothing currently owns, is success, not a
refusal.** `close_tab` is `isSafeToReplay`, the same as `open_tab`: a replay landing after the
first close already succeeded must answer the same way rather than erroring on a fact that is
merely no longer true. The unmatched-`surface_id` case reports no kind, deliberately — the id
may never have named a tab in this workstream at all, and asserting one it did not resolve
would be rendering a guess as a fact.

**The Agent tab is refused the same way Info would be, and for the same reason `open_tab`
already refuses them: they are permanent.** The Agent tab's surface id *is* the workstream id
(`WorkspaceActions.surfaceID(of:)`), so an agent naming its own main session's surface resolves
to `.agent`, and `removeTab`'s own `false` there would read identically to "not open" — the one
place this tool checks `WorkspaceTabKind.isCloseable` explicitly, because here the two answers
must not collide.

**Two gaps stay open, deliberately, rather than being half-closed.** Editor and browser tabs
have no id exposed over IPC — `surfaceID(of:)` returns nil for both, so `list_tabs` cannot
report one to close by — and giving them one is a `TabInfo` change, out of scope here. And
closing the terminal tab you are running in — the actual peer-teardown case — destroys your own
surface immediately, the same as a user's `⌘W`; you will not see the reply, because there is
nothing left to send it to.

**`create_shortcut_workstream` is `create_workstream` for work that has a Shortcut story**, and
the two share everything except two values. It parses `story` with `Shortcut.StoryID.parse` — the
same bare id / `sc-` / pasted-URL spellings the sheet takes, which is why the argument is a
**string** rather than an integer — fetches the story, resolves the name, stages the story so the
Info tab does not round-trip again, and hands off. It is `.workspaceAction`, on
`Deadline.worktreeCreation`, and **not replayable**: it is a create, and the duplicate-story guard
making a replay *look* idempotent is not a reason to flip that, since a caller cannot tell a
genuine collision from one its own retry caused.

Two things are shared rather than copied, and both are the second-copy trap this document keeps
naming:

- **The name/guard decision is `Shortcut.WorkstreamName.resolve`**, which `ProjectSidebar`'s sheet
  calls too. It renders the Branch Name Pattern, then refuses in a fixed order — an invalid branch
  name, the story already having a workstream, the rendered name being taken. The order is
  load-bearing for the reason the sidebar's comment always gave: checking the name first blamed the
  story when an unrelated workstream matched, and let one story through twice under a changed
  pattern. Only the *decision* is shared. The **wording is per consumer** —
  `Refusal.localizedMessage` for the sheet, `Refusal.agentMessage` for the tool — which is
  `Project.ConfigLoad`'s shape, and for the same reason: user copy and an instruction to an agent
  are different artifacts, and `Workstream.Launcher.Failure` already says IPC refusals are
  deliberately not localized. The rest of the sidebar's sequence deliberately stays in the view,
  because it is entangled with `shortcutFetching`, `shortcutErrorNeedsToken`, sheet dismissal and
  task cancellation, none of which belongs in a handler.
- **The handler's own tail is `IPC.Service.create(named:forStory:plan:request:)`**, with
  `creationPlan(for:)` in front of it. Everything from `AgentLaunchInputs.read()` down — the prompt
  pre-check, the `AgentStartOutcome` box, the `beforeReady` seeding closure and the three answer
  strings — is identical for both tools, and a sibling handler would have been sixty lines of it
  that nothing keeps in step. `creationPlan` is also what fixes the ordering: the argument, then
  the project, then the agent preconditions, **then** the fetch, so a caller that could never have
  succeeded spends no Shortcut round trip learning it.

**The story read is injected** (`Service.setStoryFetch`), for the reason `WorktreeCreator` is
injected on `launch`: this handler's whole job is the order it does things in, and none of that is
assertable if reaching the first guard costs a network round trip.
`Workstream.Launcher.Target` carries `existingWorkstreams` rather than a name set because the
story-collision guard asks *which* workstream already holds a story id — a question names cannot
answer, and one a second main-actor lookup would answer against a list that had moved on.
`existingWorkstreamNames` survives as a derived property.

**It is not gated on `atelier.shortcutButtonEnabled`.** That key is "the user's way to keep a
working key but hide the button" — chrome, not capability. The token is the real requirement, and
a missing or revoked one arrives as `Shortcut.Error`'s own message, which is the only thing that
says which of the two it is.

**`create_workstream` inherits `bootstrap`'s policy by not touching it.** Creating a
workstream runs the project's `bootstrap` namespace — the thing `PhasePolicy.plan` exists to
decide. The
handler never calls `AsyncSetupService.setupExistingWorktree`. It posts `.workstreamCreated`,
does the git work off the main thread, and posts `.workstreamWorktreeReady`; `ContentView`'s
handler for that notification is what calls `Initialization.Runner`. Those three notifications are
the seam, and going through them is also what gets path persistence, the HeadWatcher, the
agent-state lookup and the Shortcut story id, none of which a second creation path would remember.
Calling `Initialization.Runner.run` directly here is the inlined second copy that section forbids.

**There used to be three producers of that seam and now there is one.**
`ProjectSidebar.launchWorkstream` was a hand-rolled copy of the sequence on its own
`DispatchQueue`, with its own choice of git operation, its own rollback and its own alert, and
`ProjectOverviewView.adoptWorktree` was a third that posted `.workstreamCreated` alone and skipped
the ready notification because the path already existed — which skipped `attachWorktreePath`, the
half that persists the path, refreshes path validity, starts the HeadWatcher and promotes a staged
Shortcut story. Most of that is reached a second way, through `ContentView`'s `.onChange(of:
projectList.items)`, which is why nothing visibly broke; accidental redundancy of that kind is what
a third copy accumulates rather than a reason to keep it. Every producer now goes through
`Workstream.Launcher`: `launch` for the sidebar's three entry points and `create_workstream`,
`adopt` for the overview's Adopt button. The views keep what only a mounted view can do — sheets,
the expanded-project set, and the failure alert the launcher's `throw` raises. Do not add a fourth.

**Adoption posts the same pair as a creation, and differs by one key that states a fact rather
than a decision.** `Launcher.adopt` posts `.workstreamCreated` with a `nil` path and then
`.workstreamWorktreeReady`, so nothing downstream can tell an adopted workstream from a created
one — except for `worktreeIsPreexisting`, which says only that the tree was not made by this call.
`ContentView` is what decides what that means, the way `RunCommandPlan` keeps its invariant at the
consumer, and what it decides is **not** to run `initialization.yaml` in a directory the user
already had: adoption registers a worktree, it does not build one, and running a project's setup
commands unprompted in a tree that may hold work in progress is a side effect nobody asked for. It
renders as `.idle` on the Info tab — "Nothing reported this session.", benign, with Rerun enabled
beside it — so the steps stay one press away. Do not turn that key into a `runInitialization`
flag; the producer states what happened and the consumer states the policy.

**Which of the two git operations runs is a value, `Launcher.WorktreeSource`, not a closure a
caller assembles.** `ProjectSidebar` used to build the `createWorktreeTrackingRemote` call itself,
in a view no test mounts, so the rule in "Two ways to create a worktree, and they are not
interchangeable" had nothing pinning it. The sidebar now names `.existingRemoteBranch(branch)` or
`.newBranch` and `Launcher.gitWorktreeCreator` is the one place both operations are spelled — a
`switch` with no shared tail, so they still cannot be routed through each other. The branch travels
on the case rather than being read off the workstream name: they are equal in the only flow that
produces it, and that is that flow's choice rather than an invariant to inherit.
`Tests/WorkstreamLauncherTests.swift` pins the source reaching the creator in both directions.

Two further things about it that are not guesses:

- **It does not take the selection.** `.workstreamCreated` carries a `select` key that
  `Workstream.Launcher` always sets — true for the sidebar's entry points and for adoption, which
  are buttons the user just pressed, false for `create_workstream`. `ContentView`'s `?? true`
  survives as a defence, not as a description of a producer that omits it. An agent spinning up a
  workstream must not pull the user out of the pane they are working in, and the sidebar row
  appears optimistically either way.
- **Its agent goes in the Coding Agent tab**, on the surface whose id *is* the workstream id, so
  the user opening that workstream lands on the conversation. Nobody is looking at the workstream
  when it is created, so the surface has to exist before `TerminalContainerView` renders — and it
  runs a command carrying the initial prompt, which that view would never build.
  `TerminalContainerView.preloadSurfaces` then calls `ensureSurface` with `buildClaudeCommand`'s
  output, and `ensureSurface` destroys a surface whose stored command differs.
  **`TerminalSurfaceCache.seedSurface` is what makes that safe, and the mechanism is adoption,
  not agreement.** A seeded surface is marked once; the view's first `ensureSurface` for it
  records the view's command and clears the marker instead of comparing. From there it is an
  ordinary surface — a later settings change still respawns it, and a respawn after the agent
  exits uses the view's resume-first command rather than replaying the prompt. The rejected
  alternative was making the two commands *equal*, which would stake a running agent's life on
  byte-equality between two builders reading eight settings each; one divergence — an MCP config
  path resolving in one and not the other — is the same mid-turn kill, only harder to see. The
  invariant belongs at the consumer, the way `ProcessCompose.RunCommandPlan`'s does, rather than
  as an obligation on every future caller.
  **The seed runs before `.workstreamWorktreeReady`, and that ordering is load-bearing** — it is
  what `Launcher.launch`'s `beforeReady` hook exists for. That notification is what makes the
  workstream renderable; the optimistic sidebar row has been clickable since
  `.workstreamCreated`, seconds earlier, so a user who selects the new row is rendering it the
  instant the path lands. Seeding after the post is a race, and losing it means the view's
  surface wins and the prompt is dropped in silence. `seedSurface` returns whether it actually
  created the surface, and the handler reports "no agent was started" rather than the success it
  intended, because a lost prompt that reads as success is the worse half of the bug.
  Two things the handler must still get right on its own, because `ensureSurface` will not
  correct them: the **environment**, which is never compared, so a divergence is permanent —
  `WorkspaceActions.environment(for:surfaceID:)` is the wrong source here, because it blanks
  `TMUX`/`TMUX_PANE`, which is right for a terminal tab and wrong for the surface tmux mode
  wraps — and the **tmux session name**, which goes through
  `Workstream.AgentCommand.tmuxWrapped` so the seeded agent lands in the session
  `Workstream.Archiver` kills.

### The verification tools, and the first message Atelier sends itself

**`list_verification_checks` is how an agent learns a check's name at all**, and it is not a
convenience on top of `start_verification`. `verification.yaml` lives in the project directory,
outside every work tree, and the "Restrict to worktree" system prompt is on by default — so
before this tool a name could only be discovered by guessing one and reading the refusal. It
reads the same `Verification.Config.Load` the tab draws from and carries **both** halves of it:
the declarations in file order, and `Load.unavailableReason`, non-nil exactly when the list is
empty. That pairing is the point rather than tidiness — `.missing`, `.invalid` and a file
declaring nothing all yield no checks, and telling an agent "this project declares no checks"
for the middle one sends it looking for a file that is right there and broken. The wording is
`Load`'s own, never paraphrased, so an agent and its human are told the same thing about the
same file. It deliberately carries **no verdict and no staleness**: `check_verification` answers
verdicts, and a staleness read costs four-plus git spawns on a call an agent makes casually.

`start_verification` runs the project's `verification.yaml` checks against the caller's own
worktree and answers with a **run id**, never a result: a real suite outlives an MCP tool
call. The results reach the agent two ways — **one notice per check, posted as that check
finishes** — and `check_verification(run_id)`, which exists because delivery is a pull and
the nudge is best-effort, so an agent that never reads its inbox must still be able to find
out.

**The seam is declared on the IPC side and the runner conforms**:
`IPC.VerificationControlling` (`Sources/Models/IPC/VerificationControlling.swift`),
mirroring `ProcessCompose.Controlling`. It carries `IPC.VerificationRunInfo` rather
than the runner's `Verification.Run` — the projection `PeerInfo` is to the store's
`Peer`, and for the same reasons: seconds-ago instead of a `Date` needing a shared
encoding strategy on both ends, and `isStale` instead of the stamp. **No output crosses
this boundary at all** — a check's output lives in its terminal surface and Atelier keeps
no copy, so an agent gets verdicts, exit codes and durations, and every string points at
the Verification tab or at re-running the one check. Its doc comment carries the rest of
the contract, and two clauses there are load-bearing: a start must **refuse a check that
is already running**, per check rather than per workstream, since two *different* checks
at once is the design; and `onFinish` must fire on every terminal path, because a path
that does not is a completion notice that never arrives.

**Per check means a partial start, not a whole-call refusal**, and for one round the code
said otherwise — `Runner.start` threw `alreadyRunning` on the *first* clash while its own
doc comment and this section both said it should not. A call naming a live check and an
idle one starts the idle one and hands the refused name back on `Run.refused`; only a call
with nothing left to start throws, and that refusal names **every** one of them rather
than the first, so a caller does not retry into the second. The IPC path is where this bit
hardest: `start_verification` with no `checks` means *all* of them, so one running check
refused an agent's entire run. `Tests/VerificationRunnerTests.swift` pins the mixed call —
one running, one idle — which is the case that was untested and is how this shipped.

**The refused names are reported in `start_verification`'s answer and nowhere else.** They
are deliberately not on `VerificationRunInfo`: none of the seven `CheckResult.State` cases
honestly says "not part of this run", and a refused check's verdict is posted under the run
that *started* it — a different run id. So the answer has to say so in as many words, or an
agent waits for a notice that cannot arrive under the id it was handed, which is the same
silence the run-level notice exists to break. The two UI callers — the row's Run button and
the palette's per-check command — each name exactly one check, so they still throw exactly
as they did and their wording is unchanged.

**There is no approval gate to recheck.** `verification.yaml` lives in the project
directory, outside every work tree, so it cannot have arrived with the repository — the
same location rule that leaves the execution config unasked-about.
`Verification.Runner.start` is the only legal entrance to the runner and the handler passes
its refusals through verbatim; adding a check in `IPC.Service` is the inlined second copy
that section forbids.

**The bridge routes completions per run, because `Runner.onFinish` is one slot that fires
for every run the app performs** — including the ones the user pressed Run for.
`IPC.VerificationRunnerBridge` holds the callback `start_verification` was handed, keyed
by run id, so a run nobody asked about finishes silently. Two consequences: constructing
a second bridge silently unsubscribes the first, which is why `ContentView` builds exactly
one; and nothing may `await` between `Runner.start` returning and the callback being
registered, or a fast failure fires into a slot that is not there yet.

**A run's state is read from its own rows, never from `Runner.isLive`.** They answer
different questions: `isLive` means "is anything running in this workstream", which stays
true while a *sibling* check keeps going — so a state read from it would report this run as
still running in the very notice announcing it finished. `wasStopped` then `isFinished` is
the projection, and `isLive` is left to the thing it is for.

**`IPC.Message.from` is a `Sender` enum, and that is what an app-originated message
cost.** Every other message in the store has a peer on both ends; a run finishing has
no peer behind it. A reserved *peer* registered in the store would have to be filtered
out of `listPeers`, out of a `broadcast` audience and out of `peersBySurface`, each one
a place to forget; a sentinel UUID would let an agent try to `send_message` back to
something that cannot read. `Store.deliverSystemMessage` is the entry point, the label
an agent sees is `atelier/verification`, and the compiler walked every site that had
assumed a sender peer existed. The store's inbox scan is what keeps a queued notice
from being orphaned by its recipient's TTL — the same guarantee peer messages already
had.

**A run id resolves for the whole session and never past it.** Runs live in the runner's
memory and are not persisted: what they used to carry across a restart — a check's output —
now lives in a terminal surface that does not survive one either, and the verdicts are in
`CheckStore` regardless. So every run of this session resolves, rather than only the
newest. The scope check on a read is not a security boundary — every process in this feature runs as the user — it is there because a run
id is the tool's only argument and ids are short, so a stale one should be told it is
not this caller's run rather than handed somebody else's results.

**Notices are per check, and they are posted for every run — including the user's.**
`Runner.onCheckFinished` is the publication point, fired only by `recordCompletion`, and
`IPC.VerificationRunnerBridge` holds it. A run an agent started is addressed to the surface
that asked, because two agents in one worktree report the same workstream name and the
surface is the only discriminator; **a run nobody asked for is addressed to the Coding Agent
surface, whose id is the workstream id**. That fallback is what makes a run the user pressed
in the Verification tab reach the agent, where it used to finish silently. The peer is
resolved when the notice is posted, never when the run started — a helper whose old socket
has not closed yet re-registers under a *new* peer id, so an id captured when the run started
can be dead while its pane has an agent sitting in it. **A caller Atelier did not launch has
no surface of its own to fall back from**, so that same Coding Agent-surface fallback is a
different pane, not this caller's — which is why `startAnswer` still tells such a caller
"nothing will be posted to your inbox" rather than claiming a delivery that is not to it.

**One run-level notice survives, for a run that completed nothing and was not stopped.**
A press where every check failed to get a terminal leaves rows present and `.notRun`, so no
check reaches a terminal edge and there are no per-check notices — and "0 of 0 failed" is
both true and a green suite. The discriminator is exactly that: every check `.notRun`, which
is also exactly when `recordCompletion` wrote nothing. A run the user *stopped* before
anything started looks the same way and is excluded, because the notice exists to break a
silence rather than to report an action back to the person who took it.

**A check's output reaches no agent, ever.** It lives in that check's terminal surface and
Atelier keeps no copy at all, so there is nothing to send and nothing that could be fetched
later. Every string here says so: the tab, for as long as Atelier is running, and re-running
the one check are the two honest pointers.

**Two bounds that are not tuning.** `IPC.Store` refuses content over 64KB outright, so an
oversized notice is not trimmed on delivery — it is lost, silently, exactly when the agent is
waiting for it. With no output to carry, the two things that can still overshoot are the list
of verdicts (`VerificationSummary` assembles against a 6KB budget and says when it cut the
list) and a **check's name**, which is the user's and unbounded — a 200KB name in
`verification.yaml` is legal YAML. And a run that finished having run **nothing** must never
render as a pass, which is what the run-level notice above is for.

Two agents in one worktree is a supported shape, not a mistake — `/ping-pong`-style pairing
wants it. They are distinguishable because every Atelier-launched terminal exports its own
`ATELIER_SURFACE_ID`, which `IPC.Service.PeerContext` carries and `PeerInfo.surfaceID` reports.
That field is load-bearing: two agents in one workstream report the same workstream name, so it
is the only way a caller turns a tab it just created into a peer it can address. What one
worktree cannot hold is two *branches*, which is why work needing its own branch needs its own
workstream.

**Retiring a peer clears the tracker state for its surface — unless a live peer has already
taken that surface over.** Closing a helper's socket is how a peer is retired
(`IPC.Server.forget` → `retire` → `Service.release`), and the clear exists because a surface
left reporting its dead agent's last state — usually `.idle` — is a pane `AgentNudge` would
type into after the agent has gone. But the close is not ordered against the *next*
registration: the helper whose id is refused as belonging to another session drops that
identity, re-registers under a **new** peer id carrying the **same** `ATELIER_SURFACE_ID`, and
the old socket's close lands afterwards (`Sources/MCPHelper/main.swift`). `claim`'s
one-peer-per-connection rule is a second producer of exactly that shape. Retiring the older
peer must therefore reach past nobody: `release` consults `contexts` *after* removing the
departing peer's own entry, and skips the clear while any other context names that surface.

The two directions cost differently, which is why the guard errs towards "occupied".
Over-counting is one *missed* clear and is self-healing — `agentSessionEnded` clears the
surface, `Archiver` clears the workstream, and the successor's own release finds the
predecessor gone and clears it then. Under-counting is the bug: the nudge treats an unreported
surface as "do not interrupt", so a wiped state kills nudging for the rest of the session in
exactly the pane that is waiting on a message, and nothing restores it until a hook event that
the skipped nudge was meant to provoke. Contexts cannot outlive their peers for good in any
case — a connected helper's peer is pinned past the TTL, and the context goes with it in
`release`, in `touch`, or in `pruneContexts`. `releaseAll` clears unconditionally and stays
that way: at shutdown every context goes at once, so there is no successor to reach past.

### The execution tools, and the silence that is on purpose

Seven tools give an agent the Execution tab's capabilities, as the verification tools give it the
Verification tab's: `list_processes`, `read_process_logs`, `start_process`, `stop_process`,
`restart_process`, `start_execution`, `stop_execution`.

**No new `Surface` case, and that is a decision.** They act on the caller's own workstream and no
other, which is exactly what `.workspaceRead` and `.workspaceAction` already mean — `close_tab`
has stopped a run from `.workspaceAction` since it stopped being refused. A fifth surface needs a
trust argument distinct from the four that exist, and this has none; the reads sit in
`.workspaceRead` and the five mutators beside `start_verification` in `.workspaceAction`.

**No approval gate**, on the rule `verification.yaml` and `initialization.yaml` already state:
`execution.process-compose.yaml` lives in the project directory, outside every work tree, so it
cannot have arrived with a clone. The known hole is the one all three accept — for an ordinary
clone `Project.directory` *is* the checkout — and this does not reopen it.

**`list_processes` answers four states, not two.** `ProcessCompose.Client.ClientError.notRunning`
collapses "no config", "not started", "started but there is no control socket" and "running" into
one silence, and an agent told "nothing is running" is misled in three of them — the trap
`Verification.Config.Load`'s three cases exist to prevent. `IPC.ExecutionRunState` keeps them
apart, and `unavailableReason` is `Resolution.startUnavailableReason` **verbatim**, so an agent
and `ExecutionTabView.scriptInstructions` say the same thing about the same file.
`.runningWithoutProcessTable` is the user's own per-workstream dev-command override: there is no
control socket and never will be, so the five socket-backed tools refuse with that reason rather
than reporting an empty stack as a fact. `declaredProcesses` rides along in **every** state,
because this is also how an agent learns the names — the config is outside its worktree and the
"Restrict to worktree" prompt is on by default.

**There are no completion notices, and mirroring verification here is the mistake to avoid.**
Verification posts one per check because `Verification.Runner` already runs completions through
the app. The process table's polling (`TerminalContainerView.syncProcessPolling`) is view-owned by
design, so notices would mean a second per-workstream polling lifecycle *plus* a definition of
"finished" for a server that is meant to stay up. Agents poll `list_processes`, and
`start_execution`'s answer says so in as many words — an agent that waits for a notice waits for
the rest of the session.

**`IPC.ExecutionBridge` carries two guards `ProcessCompose.RunSession` does not, and they must not
move into it.** `RunSession.start` opens with `guard !isReclaimingSocket else { return }` and
returns *silently*, so a start reported as success would be a press that did nothing;
`RunSession.stop()` has no `runStarted` guard at all, because every caller today gates it
externally — the view's Stop button renders only when a run is up, and `close_tab` goes through
`stopIfTabOwnsRun`'s `closingTabStopsRun`. Called with nothing running it still sets
`runStoppedManually = true`, which **suppresses the tmux restore on the next launch**, and still
bumps `runGeneration`. Those two callers need `stop()` unconditional once their own question is
answered, so the guard belongs at the third caller.

**Every tool is on the `mainActorWork` (60s) tier, never `immediate`.**
`ProcessCompose.Client.requestTimeout` is 15 seconds, which is exactly what `immediate` is, so a
tool on that tier would have the helper abandon a call that was about to answer. The control
socket is behind all seven.

**`start_execution` is the one non-replayable tool here**, alongside `create_workstream` and
`add_task`. A replay during the socket reclaim runs a second `down` and a second `beginRun`, and
the later one bumps `runGeneration` and replaces the surface the first built —
`RunSession.isReclaimingSocket` documents that bug already. Its refusal **forbids** a retry rather
than inviting one, for the reason `create_workstream`'s timeout message does: the caller cannot
tell a genuine "already running" from one its own retry caused. The other six are replayable, and
that is load-bearing rather than incidental — stopping a run that is not up, and controlling a
process already in the asked-for state, are **success**, not refusals.

**`processes` scopes one run and never writes `atelier.processSelection.<id>`.** An agent
narrowing a run must not re-tick the user's checkboxes. Omitted, the stored selection is read
exactly as the Start button reads it, three-state encoding included.

**Output crosses IPC here and deliberately not for verification.** That is not an inconsistency:
a check's output exists only in a Ghostty surface Atelier keeps no copy of, so there is nothing to
send, while process-compose keeps its logs and serves them over the same control socket. The tail
is bounded twice — a line count (100 default, 1000 ceiling, clamped rather than refused) and a
64KB byte budget trimmed oldest-first, which says when it cut. The store's 64KB message cap is
**not** what binds: a tool response is not an inbox message. `IPC.Server.maxFrameBytes` and the
agent's own context are.

### The Info tab's two reads

`get_initialization_state` and `get_shortcut_story` are the Info tab over IPC. That tab was the
one pane with no IPC read at all, and of what it shows only two things are Atelier's alone: a
branch is `git`, dirtiness is `git`, a pull request is `gh`. **Setup state and the Shortcut story
are the facts an agent cannot get another way**, and they are all that was added — the tab's other
sections are deliberately not mirrored, because a tool that re-answers `git status` is a second
copy of a fact with no owner.

Both are `.workspaceRead`, both replayable, and neither gets a gate: they answer about the
caller's own workstream, which is what that surface already means.

**`.idle` is the case that decides whether `get_initialization_state` is honest.**
`Initialization.Runner.states` is in memory, so *every* workstream answers `.idle` after a
relaunch — including ones whose setup ran perfectly days ago. It is evidence of neither outcome,
and the tool's own description says so in as many words, because the sentence alone does not:
"Nothing reported this session." is true and still invites "so nothing needed doing". An agent
that reads `idle` as "setup never ran" and reruns it, or as "nothing to do" and debugs a missing
dependency for an hour, is the failure this ships with otherwise.

**The sentence is `Initialization.State.detail` and is written once.** It moved off
`initializationRow(for:)` when this became its second consumer: an agent and the user reading the
Setup row have to be told the same thing about the same run, which is the rule
`Verification.Runner.loadConfig` had to be corrected to after wording two of its three refusals
differently from the tab. The view keeps the icon and the tint, which are its own and which no
agent can read. `Initialization.State.key` is beside it and is the *other* half deliberately —
the key is a wire value that must stay stable, the sentence is copy that may be reworded, and
collapsing them would make either promise impossible to keep.

**`get_shortcut_story` fetches; it does not read the cache the Info tab fills.**
`shortcutStoryCache` is in memory and is only refilled when that tab appears, so a cache-only
read answers "no story" for any workstream whose Info tab has not been opened since launch —
a fact's availability depending on which pane the user happened to visit, which is exactly the
bug `hasGitHubRemote` was moved onto `refreshPathValidity`'s sweep to fix. It goes through
`AppEnvironment.refreshShortcutStory` rather than straight to `Shortcut.Client` so the tab and
the tool share one cache and one workflows lookup.

**The story id comes from `Workstream.shortcutStoryID`, not from `Worktree.Facts`.** That field
is persisted with the project list; the facts copy is written by `ContentView.syncShortcutStoryIDs`,
so reading it would make the answer depend on whether that sweep had run — and the wrong answer
would be "this workstream has no Shortcut story", which is unfalsifiable from the agent's side.
`refreshShortcutStory(for:storyID:)` exists for that, with the facts-reading version delegating
to it.

**Four ways to have no story, and they are four sentences.** No story linked; a story but no
API token; a story and a token the keychain would not release; a story, a token, and a fetch that
failed. The tab renders all four as an absent Shortcut section, which is fine for a section and
useless for a tool named `get_shortcut_story`. The third is not padding:
`KeychainTokenStore.ReadOutcome` already separates `.absent` from `.failed` precisely because
collapsing them told a user their token had vanished and sent them to re-paste one they still
had — flattening it back at the IPC boundary would undo that fix one layer up.
`refreshShortcutStory` logs and swallows its error, so an empty cache after a fetch is the only
evidence the fetch failed; that is what the fourth sentence is reading.
`WorkspaceActions.shortcutStoryInfo` is a pure static holding all of it, for the reason `resolve`
is one.

**A cached story is not a current one, and `isStale` is what keeps that from being a lie.**
`refreshShortcutStory`'s `catch` deliberately keeps any cached copy rather than blanking the tab,
and `registerShortcutStory` caches a story at *creation* — so every Shortcut-created workstream
has one before any pane is opened. Reading the cache after a failed fetch therefore hands an agent
an old copy under a tool description promising the answer is current, which is precisely the
failure a revoked token or a deleted story produces. So the refresh returns **whether the fetch
succeeded** — not whether it published anything, since an unchanged story is a successful fetch
that writes nothing — and a story returned over a failed fetch carries `isStale`, the same meaning
`VerificationRunInfo.isStale` has: this no longer describes reality. The tab ignores the return
value and goes on rendering the stale copy, which is right for a pane whose user can see it is not
moving.

Two lesser cases ride inside a successful answer. A story whose workflow **state name** is unknown,
because stories carry only a `workflow_state_id` and the workflow list is a second round trip that
fails on its own: `state` goes nil and `stateUnavailableReason` says why, rather than the field
simply being absent — `state` is one of the four things this tool exists to answer, and an absent
one with no reason reads as a story that has no state. And that reason names **which** of its two
causes actually happened — the list could not be fetched, or the list was fetched and does not
contain this story's state id. They are different facts, and asserting the likelier one is the
mistake `KeychainTokenStore.ReadOutcome` exists to prevent one layer down.

`description` rides along, clamped to 8KB with the cut reported the way `ExecutionLogs` reports a
trimmed tail — and trimmed from the **end**, the opposite of a log tail, because a story's first
paragraph is the one that says what the work is.

**Neither is tested through `IPCServerTests`' round-trip harness, and that is not laziness.**
That harness parks the test's own thread in an untimed `recv()` — the reason
`AgentStateTracker.lastUserPromptAt` is `nonisolated` — so a round trip through either handler's
`MainActor` hop would deadlock and read as a bug in the handler. The mappings are pure statics and
are asserted directly; `test_helperBinary_answersToolsCallOverStdio` still pins that both are
advertised on the wire.

### The whiteboard write tools

Three tools give an agent the board's write half, as `read_whiteboard` gave it the read half:
`whiteboard_add`, `whiteboard_update`, `whiteboard_delete`. They sit immediately after
`read_whiteboard` in `advertisedOrder`, so an agent that has found one has found all four.

**`.workspaceAction`, 15s, and no new `Surface` case.** They act on the caller's own workstream,
which that surface's charter already covers; a fifth case needs a trust argument distinct from the
four that exist, and this has none. There is no approval gate either, and here the question the
other configs answer does not even arise: a board is Atelier's own cache directory, not a file a
repository can ship.

**Swift validates and normalizes; the page expands.** `Whiteboard.Write`
(`Sources/Models/WhiteboardWrite.swift`) turns `{kind, text, at, from, to, color}` into an
Excalidraw *skeleton* and refuses everything outside the vocabulary; `convertToExcalidrawElements`
in `editor/src/whiteboard.jsx` turns a skeleton into a real element. The split falls there because
this half is where the mistakes live — an unknown kind, an arrow pointing at nothing, a colour that
is not a colour — and none of them need a webview to pin, while the expansion needs Excalidraw's
own `seed`, `versionNonce`, `groupIds` and `boundElements` and must never be hand-written.
It lives in `Sources/Models/` and **not** `Sources/Models/IPC/`: `project.yml` compiles
`IPCProtocol.swift` and `IPCToolRegistry.swift` out of that directory into the `AtelierMCP` helper,
which cannot see `Whiteboard` and would stop compiling.

**Swift mints the ids and Excalidraw keeps them**, because the page converts with
`regenerateIds: false` — measured against 0.18.1, a supplied id survives byte-identical. So
`whiteboard_add` answers with ids that *are* the real element ids, the same ones the digest reports
and `whiteboard_update` takes: no mapping table, and no display-id vocabulary for the two ends to
drift apart on. It is also what lets an arrow name a box created beside it, which is why `add`
takes a **list** — a whole diagram is one call rather than fourteen at the 15s tier. A *forward*
reference is refused rather than resolved, because resolving it would make a batch's meaning depend
on a reading order nothing states.

**What is on the board is read from the page, never from `board.excalidraw`.** The file lags by the
800ms save debounce, so an agent that adds a box and then updates it would be refused for naming an
id that is plainly there. `Host.liveState` reads `window.__whiteboardState()`, which also carries
the board's extent — Swift cannot compute that, and both are answers to the same instant. Passing
it in as a parameter is what keeps the validator pure and testable with no board on disk.

**`callAsyncJavaScript`, never `evaluateJavaScript`.** The latter does not await a returned promise;
it hands back the promise object, so an async page function reports success the instant it is
called, before anything has been applied. With the tab closed nothing would notice. Everything
crosses as a JSON string in both directions, which keeps the boundary `Sendable` and keeps the
reply out of `NSNumber`-versus-`Double` guesswork — a real hazard here, because every coordinate an
agent sends may be integral, the same trap `SceneLoad.number` documents on the read side.

**`whiteboard_add` is not replayable**, with `add_task` and `create_workstream`: it is a create, the
helper mints a fresh request id on every replay, and a replayed create draws the diagram twice. A
refusal whose **outcome is unknown** therefore forbids a retry rather than inviting one, because a
caller cannot tell a genuine failure from one its own retry caused. **Which refusals those are is
decided by whether the op was posted, not by how the failure looked**, and
`Whiteboard.Host.WriteFailure` is where the line is drawn: `.outcomeUnknown` for a `__whiteboardApply`
that was called and never answered for, `.notReady` — a readiness timeout, a page that would not
report its state, a state that would not decode — for every failure *before* that call, all of which
say they are safe to retry. The readiness timeout used to be on the forbidding side of that line, and
it is the one an agent meets most: a cold board has to mount before the session's first write, so the
first call of a session was the one most likely to be told, wrongly, that it might already have drawn
something. `update` and `delete` are
replayable, and `delete` is replayable *because* an id already gone is success; the answer reports
what was really removed rather than echoing back what it was asked for.

**Two Excalidraw behaviours this had to be built around.** Both were measured against the real
built bundle in an occluded offscreen window, and both *succeed* while leaving the board's picture
and its digest disagreeing — which is the worst state a board can be in, since the two halves of
the read path exist to corroborate each other:

- **An arrow does not bind to an endpoint outside its own batch.** `convertToExcalidrawElements`
  binds only within the array it is handed, so "connect the two boxes you can see" produced
  `startBinding` and `endBinding` both null. The referenced elements are therefore carried *into*
  that array and Excalidraw computes the binding itself. A carried element's `boundElements` is
  **unioned, never assigned**: a box already carries an entry for its own text label, and
  overwriting the list leaves that caption on the canvas attached to nothing.
- **Binding does not move an arrow to its endpoints.** One handed `(0,0)` with both bindings
  resolved stays at `(0,0)` with a stub 100px segment. So `edgePoints` computes the geometry in the
  page, and that is not a split of convenience: an arrow may name an endpoint already on the board,
  whose position Swift has no way to know.

**`update` and `delete` maintain the same binding invariants `add` does**, and neither did at
first — both were caught by the same harness, and both are the same silent shape as the two
Excalidraw behaviours above:

- **Moving a bound element drags its arrows.** Excalidraw binds but never moves, so a moved box
  left its arrow where it was — still bound, so the digest went on reporting `n1 → n2` quite
  correctly, while the picture showed an arrow pointing at empty space. `reflowArrowsTouching`
  re-runs `edgePoints` for every arrow attached to what moved.
- **Deleting an element unbinds the arrows that named it.** Otherwise an arrow survives holding
  `startBinding.elementId` for something that no longer exists, and the digest prints an endpoint
  id that appears nowhere else on the board — the digest lying, which is the one thing this feature
  is organized around not doing. Clearing the binding is Excalidraw's own semantics (the arrow
  survives, unattached) and needs no digest change: an unbound arrow already renders as its
  position rather than as an endpoint pair.

**The host is created eagerly by `WorkspaceActions`, not by a view.** The Whiteboard tab renders
only while the user is looking at that workstream, so relying on `ensureSingleton` to make a view
build the host would mean an agent's write silently doing nothing whenever the user is elsewhere —
most of the time, and the case the offscreen design exists for. `ensureSingleton` and never
`activateSingleton`, and every answer says the tab was opened **without taking the selection** and
names `request_attention`, the rule `open_tab` states.

**Building the host and opening the tab are two acts, and the order between them is
load-bearing.** The host is built before the write, because the offscreen page is what applies it;
the tab is opened only once `Host.apply` has returned. They were one act, in `whiteboardTarget`,
and a refused write therefore put a pane in the user's workspace for a change that never
happened — a typo'd `kind`, an id that is not on the board — while the refusal it answered with
said nothing about the pane and every success said "The Whiteboard tab is open". `openBoardTab` is
the call, and it is after `apply` in all three writes, `whiteboard_delete` included: a delete that
matched nothing still ran, so the tab still opens and that note stays true. `Tests/WhiteboardWriteTabTests.swift`
pins both directions, and it is the one XCTest file that drives a real `Whiteboard.Host` — which
works because `TEST_HOST` is `Atelier.app`, so `Bundle.main` resolves the built bundle. That does
not widen what belongs in XCTest: a claim about what the *page* does with what it is handed is
still the harness's, per `Tests/Harnesses/README.md`.

**The `note` kind is a rectangle**, since Excalidraw has none: a distinct background plus
`Whiteboard.Element.kindKey` (`"atelierKind"`) in `customData`, declared beside `authorKey` and
`captionKey` in `WhiteboardScene.swift`. **Both halves or neither** — the digest is taught to report
it as `note`, and without that a note round-trips as a box and the vocabulary silently has three
kinds instead of four. An annotation and a diagram node are different things, and reporting them
differently is what lets an agent re-read its own board and tell its commentary apart from the
structure it drew. Only a *rectangle* is promoted: the marker says how a rectangle was authored, not
a way to relabel any element.

**An unplaced element clears what its own batch placed.** `at` is optional and anything unplaced is
stacked in a column, whose floor is the lower of the board's own extent and the bottom of anything
this batch places by hand — scanned up front, so the answer does not depend on batch order. Without
it an agent that placed two boxes and added an unplaced note got the note dropped on top of them:
invisible in the digest, since the coordinates read exactly as asked, and wrong only in the picture.

**`mermaid` is the fifth kind, and it inverts the split above: Swift routes, the page validates.**
`Whiteboard.Write.plan` is the entry `WorkspaceActions.whiteboardAdd` calls, and it answers one of
two shapes — `.elements`, the batch `addPlan` has fully validated, or `.mermaid`, a definition Swift
cannot read. Only `parseMermaidToExcalidraw` can say whether a definition parses and only the page
learns how big the result is, so the page owns the parse, the placement (it translates the whole
diagram so its top-left lands on the origin Swift chose) and the refusal, which carries mermaid's own
message with the scene untouched. It is the same converter and the same three calls Excalidraw runs
when mermaid text is pasted onto the canvas, and the library is already in the bundle for that path;
`package.json` pins `@excalidraw/mermaid-to-excalidraw` at the version Excalidraw itself depends on
so the import shares the chunk rather than adding one. Four consequences, each pinned:

- **A mermaid entry stands alone in its call** (`Failure.mermaidStandsAlone`). Its height is not known
  until it is drawn, so the column layout for anything after it would be a guess, and a guess drops
  the next element on top of the diagram — invisible in the digest. `addPlan` refuses a mermaid entry
  on its own account too, so a direct caller cannot draw one as a box. `color`, `from` and `to` are
  **refused, not ignored** (`mermaidFieldRefused`): an agent whose red diagram came out black has been
  taught the field does nothing.
- **Ids are regenerated for this arm, the opposite of `add`'s `regenerateIds: false`.** Mermaid names
  its nodes `A` and `B`, and a second diagram keeping those ids would collide with the first; the
  converter remaps bindings and container ids along with them. So Swift mints nothing here, and the ids
  an agent gets back are whatever the page reports really landed — the return path `Host.apply`
  already had.
- **The author marker travels on the op**, the way `captionKey` does, because the page stamps every
  node and edge the diagram expands to and cannot spell a `customData` key. Spread onto each skeleton,
  never assigned. A bound label carries nothing, the same as on the `add` arm — the converter creates
  it fresh from `label`, and the digest folds it into its container rather than reporting it.
- **A diagram type the converter cannot express lands as one image** — flowcharts, sequence, class, ER
  and state diagrams become elements; everything else is an SVG mermaid rendered itself, returned as
  an image plus a file. That file is posted to `assets/` by the same `save()` loop a pasted image goes
  through, which is why the SVG extension fix (`image/svg+xml` must land as `.svg`) is load-bearing
  here and not a nicety. The image carries no words on the canvas, so its **caption is the
  definition**: the digest is not blind to it, and a later agent can re-read what was drawn.

`Tests/WhiteboardWriteTests.swift` pins the Swift half; section 10 of the harness pins what the page
does with it, from disk — including that the same diagram added twice yields disjoint ids and that a
definition that does not parse leaves `board.excalidraw` byte-identical.

### Image transcription, and the capture button

Two arms were added last, and both are **mutations of the board**, so both answer the standing pair
below.

**A caption is an argument on `whiteboard_update`, not a fifth tool.** It writes
`customData[Element.captionKey]`, which the digest has rendered since it was written — the write half
was the only part missing, and `update` was already `.workspaceAction` / 15s / replayable, which is
what a caption write is. The agent is the OCR: it opens the `board.png` that `read_whiteboard` names,
reads the screenshot, and stores what it says.

**Refused for anything that is not an image, and the refusal names `text`.** A caption is a
transcription of pixels nothing else can read; on a box it would be a second, invisible text
channel — present in the digest and absent from the picture, which is the disagreement the read
path's two halves exist to make impossible. `Whiteboard.Write.Live` carries `imageIDs` so Swift can
answer that at all, since it never reads the scene and the page is the only thing that knows. An
**absent** `imageIDs` fails *open* to the page rather than reading as "no images", which would refuse
every legitimate caption while naming the wrong cause.

**And the mirror of that refusal was the point of adding it.** `text` on an **image** is refused
too. An image carries no words on the canvas, so the page's `textTargetFor` found nothing to change
and the call still answered "Updated i1." — a silent success teaching an agent that its
transcription had landed. Reaching for `text` to describe a screenshot is the obvious first move,
which is exactly why it is the one that had to be answered; the refusal names `caption`. The two
refusals are symmetric and each names the other's field.

**It is deliberately not materialized as a real text element.** That would make ⌘F find it, at the
cost of a block of text under every screenshot on a board the user is sketching on. Canvas search
over screenshots is the accepted gap, stated in the design.

**The page spells no `customData` key: the key travels with the value.** `updatePlan` puts
`Element.captionKey` on the op and the page writes `data[op.captionKey]`. This is the first write of
one of these keys from the JavaScript side, which cannot import `Element` — so a literal there would
be a second spelling that nothing keeps in step, and a rename in Swift would leave the page writing
the old key: the caption would reach the board and vanish from the digest, written and invisible.
Same reasoning as `IPC.Vocabulary`, for a boundary that cannot import Swift.

**The page SPREADS `customData` rather than assigning it**, and this is the one line in the arm that
matters. A note carries `atelierKind` and an agent-drawn element carries `atelierAuthor` in that same
dictionary, so a fresh object would demote a note to a box in the digest and disown an agent's own
element — the shape of the `boundElements` overwrite above, invisible in the same way. Clearing
**removes the key** rather than storing `""`, which would leave a blank caption line under the image
forever.

**The capture button runs `screencapture -i`** and is the third `ProcessRunner` exemption — see
**Child processes**, which carries the argument. Its file is named by the **lowercase hex SHA-1 of
its bytes**, which is Excalidraw's own `fileId` convention: the stem of a file in `assets/` *is* the
`fileId` on its image element, and a captured image and a pasted one have to be named by one rule or
that join quietly has two. `Store.writeAsset` refuses a name it would have had to rewrite, and a
SHA-1 hex string can never be one. Capturing the same region twice writes one file.

It goes through the same `__whiteboardApply` and therefore the same `saveNow()` — one save path, one
render site. The file reaches Excalidraw as an **asset-scheme URL and never as bytes**, so
`board.excalidraw` stays free of image data, and `save()`'s `saveAsset` loop skips it for free
(`indexOf(',')` is -1 on such a URL). It is **placed below the board's own extent**, from the same
`Layout` an unpositioned agent element uses; a fixed origin would drop it on the user's diagram,
which reads perfectly well in the digest and ruins the picture. It carries no `atelierAuthor`,
because the user pressed the button. It is scaled to a long edge of `maxOnBoardEdge` on **placement
only** — the file keeps every captured pixel, so the image stays sharp zoomed in and the agent reads
the full-resolution original.

**Both arms, against the standing pair.** *Does it keep arrows attached to what moved?* A caption
moves nothing on its own, and a caption sent **together with `at`** still goes through the existing
move branch and its `reflowArrowsTouching`; a capture places a new element and moves nothing. *Does
it leave anything bound to what it removed?* Neither removes anything. Both are checked by the
harness rather than asserted — see `Tests/Harnesses/README.md`.

**Known limitation, measured and left alone: an arrow cannot bind to an image.**
`convertToExcalidrawElements` throws `TypeError: undefined is not an object (evaluating 't.id')` for
one, against 0.18.1. It predates these arms — a board has held pasted images since the tab shipped —
and the behaviour is honest: the op is refused whole and the board is untouched. The harness pins
that it stays a **refusal**, because what would be dangerous is it becoming a partial apply, which
would put an arrow on the board bound to nothing while the digest reported an endpoint.

### The project task queue

Six tools — `add_task`, `get_pending_tasks`, `list_tasks`, `claim_task`, `complete_task`,
`fail_task` (`IPC.Tool`, `Sources/Models/IPC/IPCProtocol.swift:121-133`) — give a project a
shared, claimable work queue: add several units of work once and let any peer in the project
pull the next one, instead of a coordinator hand-dispatching each with `create_workstream`. The
incident this answers: a coordinator once dispatched seven workstreams by hand, one per audited
finding, with no atomicity (two peers could claim the same finding), no pull (a peer finishing
early had to be noticed rather than ask), and no record (a dead peer's finding stayed silently
claimed). `list_tasks` is the one tool with no Scenius counterpart — a coordinator that's
mid-task when a completion notice arrives can miss it the way any pull-based inbox can be
missed, and this is how it recovers the whole picture without every notice having landed.

**A fourth `Surface` case, `.projectTasks`, and it is deliberately not `.messaging`.**
(`Surface`, `IPCProtocol.swift:265-290`, case at `:289`.) Messaging's trust story is "none
needed — nothing a user can see"; these six mutate durable, queryable state that *another
agent's correctness depends on* — a wrong claim is two agents doing the same audited finding,
not a stray chat message. It isn't `.workspaceRead`/`.workspaceAction` either: both those groups
are scoped to the caller's own workstream in their own doc comments, and this queue is
project-wide by design, the same scope peers and messages already have (a coordinator in one
workstream has to reach peers in others). **The ungating is a third argument, not a copy of
either existing one**: workspace actions go ungated because they're attended, messaging because
nothing here is visible to the user at all; project tasks go ungated because nothing in this
surface executes code, spawns a process, or touches the user's files or git state — it's
structured coordination data between peers already inside the one trust boundary
`atelier.agentIPC` draws around the whole IPC surface. All six sit in the 15s `replyDeadline`
tier with the messaging six and the workspace reads (`IPCProtocol.swift:192-196`): actor hops
over an in-memory dictionary, no shell, no process, no network.

**Ownership is keyed by surface id, never peer id, and that is the load-bearing decision.**
(`IPC.TaskStore`'s doc comment, `Sources/Models/IPC/IPCTaskStore.swift:93-107`; the actor at
`:108`.) CLAUDE.md already documents the reconnect race two sections up: a helper whose old
socket hasn't closed yet drops its identity and re-registers under a **new** peer id carrying
the **same** `ATELIER_SURFACE_ID`. Keying a claim on peer id would make that ordinary reconnect
look like a different actor attempting its own earlier claim — `claim_task` would refuse its own
replay, and `complete_task` would return `wrongClaimer` against its rightful claimer for the
rest of the session, deadlocking the task by machinery rather than by any agent's mistake.
`ATELIER_SURFACE_ID` is stable for the life of a terminal independent of how many times its
helper reconnects, so `claim_task`/`complete_task`/`fail_task` key on it via one shared guard,
`surfaceAndWorkstream(_:)` (`Sources/Models/IPC/IPCService.swift:1256-1261`), and refuse cleanly
when it's absent — an agent Atelier didn't launch has no surface for ownership to attach to. A
useful side effect: a claim is fully decoupled from `IPC.Store`'s own peer lifecycle (the 600s
TTL, `pin`/`release`) — a task stays claimed even if the claimer's peer entry itself expires or
is re-registered under a new id, because ownership was never routed through the peer store at
all.

**The cleanup hook is workstream teardown, never `IPC.Service.release(peerID:)`.**
`Service.release(peerID:)` fires on the ordinary reconnect race above, not only on a genuine
departure — and since surface id is exactly the identity a reconnect is designed to preserve,
hooking claim-release to peer release would spuriously un-claim a task the same agent is still
actively working, reintroducing the same race the surface-id decision exists to avoid. The real
"this claim can never be finished" signal is a workstream ceasing to exist:
`TaskState.claimed` carries `inWorkstreamID`, recorded at claim time from
`request.client.workstreamID` (`IPCTaskStore.swift:29`), precisely so the sweep doesn't need
to resolve individual surfaces back to a workstream. `TaskStore.releaseClaims(inWorkstreamID:)`
(`IPCTaskStore.swift:243-265`) reverts every task claimed there back to `.pending`, and
`IPC.Service.releaseTaskClaims(inWorkstream:)` (`IPCService.swift:1461-1469`) is called
fire-and-forget from both archive paths, `Workstream.Archiver.remove` and `.purge`
(`Sources/Models/WorkstreamArchiver.swift:61` and `:325`), the same two sites that already call
`verificationRunner?.forget(workstreamID:)`. It deliberately does **not** follow that call's
injected-optional-parameter pattern (`WorkstreamArchiver.swift:54-60`): that pattern exists
because verification teardown is heavyweight and ordered — killing running processes and
awaiting a bounded timeout the archive flow genuinely needs before `git worktree remove` — and
reverting a handful of in-memory dictionary entries to `.pending` carries none of that weight.
Calling the actor singleton from a plain, un-awaited `Task { ... }` is the same fire-and-forget
shape `Archiver.remove`'s own top already uses to kill tmux sessions, though that call is
`Task.detached` — the two share only "kicked off and not waited on," not the detached/
non-detached distinction itself; a plain `Task` is enough here because this has no captured
`@MainActor` state to escape the way the detached tmux kill does. A project with no tasks, or a
workstream with no claims, makes the call a genuine no-op, so neither archive path needs a new
precondition to add it safely.

**`add_task` is the one non-replayable tool in this group, alongside `create_workstream`.**
Every other tool here is `isSafeToReplay == true` (`IPCProtocol.swift:239-261`): a same-surface
replay of `claim_task`/`complete_task`/`fail_task` is a defined no-op, a different-surface replay
is a defined refusal, and the two reads are pure. `add_task` is a *create*, and creates don't get
to inherit that idempotence — the helper mints a fresh request id on every replay
(`attempt(...)`, `Sources/MCPHelper/main.swift:917-925`), so there is no id `IPC.Service` could
use to recognize "I already did this one." A duplicate-path `add_task` is refused rather than
silently re-executed, and the refusal message is written to forbid a retry rather than invite
one, the same rule the timeout message states above for `create_workstream`: "add_task is not
replayed automatically after a lost connection, so this may mean your earlier call already
succeeded — check list_tasks rather than retrying under the same path"
(`TaskQueueFailure.alreadyExists`, `Sources/Models/IPC/IPCTaskStore.swift:70-72`). A caller
cannot tell a genuine path collision from one its own retry caused, so the honest answer is
"don't," not "try a different path."

**Do not reintroduce persistence, an approval gate, a claim TTL, or task editing.** All four
were considered and declined, not overlooked:

- **No persistence.** `TaskStore` is in-memory and wiped exactly when `IPC.Store` is — at
  `Server.stop()`, via `Service.releaseAll()` — because this coordinates live agents in one
  Atelier session; if the app restarts, every workstream's Coding Agent process is gone too, and
  there is no restart-survival story worth building before anyone has asked for one.
- **No approval gate.** Restated from above: nothing here executes code, spawns a process, or
  touches the user's files or git state. Adding one needs a reason that survives the comparison
  to the two existing ungated groups, not just "it's new."
- **No claim TTL or heartbeat.** A claim lives until `complete_task`, `fail_task`, or the owning
  workstream is torn down. A time-based expiry needs a policy for "how long is too long" that
  nothing in the reported incident calls for, and risks yanking a claim out from under a peer
  doing genuinely slow work.
- **No task deletion or editing.** `add_task` creates; nothing removes a completed or failed
  task from the store. A long session accumulating a few dozen coordination tasks — audit
  findings, review items — is the expected scale, not a production job queue needing pruning.

## Localization

All user-facing strings MUST use localization. Never hardcode strings directly in SwiftUI views or code.

### Rules
- **SwiftUI Text/Button/Label**: Use string literals directly (e.g., `Text("Cancel")`). SwiftUI automatically treats these as `LocalizedStringKey`.
- **AppKit APIs** (NSOpenPanel, NSAlert, etc.): Use `NSLocalizedString("string", comment: "")`.
- **String interpolation with Images**: Split into `Text` concatenation. E.g., `(Text("Press ") + Text(Image(systemName: "command")) + Text(" N"))`.
- **Every new user-facing string** must be added to `Localization/en.lproj/Localizable.strings`.
- **The Monaco bundle (`editor/`) is the one carve-out, and it is narrow.** Labels
  registered with Monaco's own APIs — `editor.addAction`'s `label`, a context-menu
  entry — are JavaScript strings inside a Vite bundle that has no access to
  `NSLocalizedString` and no bundle-loading story of its own. "Paste to Agent"
  (`editor/src/main.js`) is the first and currently the only one. The carve-out is
  for labels Monaco itself owns; anything Swift hands the bridge is an ordinary
  Swift string and localizes normally. Adding a second locale makes this a real
  gap — the fix then is to pass these over the editor↔Swift bridge at init, not
  to widen the carve-out.
- English (en) is the only locale. The indirection is kept deliberately: it keeps strings out of
  call sites, so adding a locale later is a data-only change. Do not replace `NSLocalizedString`
  with hardcoded strings.

## Keyboard Shortcuts
When adding, removing, or changing keyboard shortcuts:
1. Update `AtelierApp.swift` (menu commands)
2. Update `TerminalContainerView.swift` (workspace tab handling)
3. Update `HelpView.swift` (shortcut reference)
4. Update the shortcut table in `README.md`
5. Update the list below

Current shortcuts:
- **Cmd+I**: Info
- **Cmd+1-9**: Switch tab (all tabs in display order). Positional, so no
  number reaches a closed tab — and Changes, Execution and Verification start
  closed. Open them from the tab bar's quick-add buttons or the command
  palette; nothing is bound to them by name.
- **Cmd+Shift+[/]**: Cycle tabs
- **Cmd+Return**: Focus Coding Agent
- **Cmd+P**: Find File (Editor)
- **Cmd+S**: Save (Editor)
- **Cmd+Shift+S**: Save As (Editor)
- **Cmd+W**: Close tab
- **Cmd+Shift+R**: Rename workstream
- **Cmd+Shift+W**: Archive workstream
- **Cmd+L**: Address bar (browser)
- **Cmd+Shift+Return**: Start/Rerun
- **Cmd+[/]**: Cycle workstreams
- **Cmd+Up/Down**: Cycle projects
- **Cmd+0**: Back to project
- **Cmd+Shift+C**: Toggle sidebar
- **Cmd+Shift+P**: Command Palette
- **Cmd+Option+B**: External browser
- **Cmd+Option+T**: External terminal
- **Cmd+/**: Help

## Naming
- The app is "Atelier". Internal ID is `atelier` (no hyphen).
- The project has no website; docs and downloads live at https://github.com/phaedryx/atelier.
- Use `AppConstants.appID` and `AppConstants.appName`, not hardcoded strings.
- Use "directory" not "folder" in all user-facing text.
- Use "Coding Agent" for the claude terminal tab.
- Use "workstream" for the sub-units of a project.

## Task Tracking
There is no tracker. Bugs, features and deferred work are raised in
conversation and acted on there — do not open a GitHub issue, and do not create
a `TODO.md` or any other list file to hold them.
