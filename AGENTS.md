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
- `Sources/Models/ProcessCompose/` - The process-compose layer (config location, phases, ports, the process table)
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
- `scripts/` - Release and build automation
- `.hooks/` - Claude Code hooks for this repository. `worktree-create.sh` runs on
  worktree creation: it inits the ghostty submodule against the main checkout,
  symlinks the build artifacts that are not in git (`zig-out`,
  `GhosttyKit.xcframework`), and kicks off a background build so SourceKit can
  resolve symbols. A worktree made without it will not build until you repeat
  those steps by hand.
- `docs/` - Distribution guide and reference docs. Anything not describing the
  app as it is carries a status line saying so.

### Data flow
- **Projects/workstreams** stored in UserDefaults (`atelier.projects`), accessed via `ProjectStore`. Wrapped in `ProjectList: ObservableObject` for reference-type semantics.
- **Settings** use `@AppStorage` (UserDefaults), keyed as `atelier.*`
- **Terminal surfaces** cached in `TerminalSurfaceCache` (keyed by UUID)
- **Git repo info** cached in `AppEnvironment`, refreshed async every 15s
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
branch that already exists on origin. Do not merge them or reroute one through the other:
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
it. `TerminalContainerView.runnableExecuteSelection` stays in the view, reading the selection
store per render, and is one expression with two consumers — the
Start button's `.disabled` and `resolvedRunCommand`'s guard — which is the same one-decision rule
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

Each writer lives on its config type beside that type's `fileNames`, so only one place
knows each filename, and each refuses when **either** spelling is already present —
seeding a `ports.yaml` beside an existing `ports.yml` would win the lookup and hide the
project's real declarations. The refusals are per file, not all-or-nothing: a project
that already carries its own `ports.yml` still gains the templates it lacks.

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

Two sites are exempt and say so where they spawn: `BareRepoClone.run` and
`QuickAction.Runner.runShellCommand`. Both run work with no honest deadline and
both give the user a cancel instead. If you add a third, it needs the same two
properties and the same comment.

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

**`.purgeWorkstream` and `.addNew` gained optional payloads**, and the absent case is
load-bearing in both. A nil `.purgeWorkstream` object means "the selected workstream" —
a command closure is built once and never learns which one is active — and it still
lands on `confirmPurge`, so `purgeWarning` and `destroyableWorktreePath` stand where
they always did. A nil `.addNew` object means "the `atelier.bypassPermissions` default",
which is what ⌘N and every other producer wants; the palette's two variant rows post
`true` and `false`. Reading a missing payload as `false` would silently strip
permissions from ⌘N.

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

`IPC.Tool` is three groups, not one, and `Tool.surface` makes the grouping a value the compiler
checks rather than a comment:

| Group | Tools | Trust story |
|---|---|---|
| Messaging | `register_peer`, `list_peers`, `send_message`, `receive_messages`, `broadcast`, `get_peer_status` | none needed — text between agents, nothing a user can see |
| Workspace reads | `list_tabs`, `read_review_comments`, `check_verification`, `list_verification_checks` | none needed — answers about the caller's own workstream |
| Workspace actions | `open_agent_tab`, `open_editor`, `open_tab`, `request_attention`, `create_workstream`, `start_verification` | see below |

The messaging six were once the whole enum. Calix's IPC core is the same six, and everything it
grew on top — pane/tab control, LSP, shell integration — arrived as separate tool surfaces with
separate gates. This is where Atelier takes that step.

**No approval gate, and that is a decision rather than an omission.** Calix gates its
`pane_run` because it can target any pane in any window, including one the caller does not own.
Every tool here acts on the caller's *own* workstream and no other, which is the same
attended-ness argument that leaves `execute` ungated. `atelier.agentIPC` already defaults off
and already gates whether an agent knows these tools exist. Do not add an approval inbox here
without a reason that survives that comparison; `PermissionApprovalStore` in particular is the
wrong type to reuse — its expiry resolves to "no decision, let Claude Code ask in the terminal",
a fallback an MCP tool call does not have.

**A `Tool` case is not a tool an agent can see.** `toolDefinitions` in
`Sources/MCPHelper/main.swift` is what is advertised; a case with no entry there is dispatchable
but undiscoverable, and `IPC.Service.notImplemented` fails loudly for it. That is what lets the
shared enum and the exhaustive dispatch switch land ahead of the handlers.
`IPCServerTests.test_helperBinary_answersToolsCallOverStdio` pins both directions — every
advertised name is a real `Tool`, and the unadvertised set is exactly the expected one — so a
tool cannot be advertised before its handler exists or stay hidden after.

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
   seconds it replaced.

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

**`create_workstream` inherits `bootstrap`'s policy by not touching it.** Creating a
workstream runs the project's `bootstrap` namespace — the thing `PhasePolicy.plan` exists to
decide. The
handler never calls `AsyncSetupService.setupExistingWorktree`. It posts `.workstreamCreated`,
does the git work off the main thread, and posts `.workstreamWorktreeReady`; `ContentView`'s
handler for that notification is what calls `Initialization.Runner`. Those three notifications are the seam — `ProjectSidebar.launchWorkstream` and
`ProjectOverviewView` are the other two producers — and going through them is also what gets
path persistence, the HeadWatcher, the agent-state lookup and the Shortcut story id, none of
which a second creation path would remember. Calling `Initialization.Runner.run` directly here
is the inlined second copy that section forbids.

Two further things about it that are not guesses:

- **It does not take the selection.** `.workstreamCreated` carries an optional `select` key,
  defaulting to true so every UI producer is unchanged; the launcher passes false. An agent
  spinning up a workstream must not pull the user out of the pane they are working in, and the
  sidebar row appears optimistically either way.
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

## Localization

All user-facing strings MUST use localization. Never hardcode strings directly in SwiftUI views or code.

### Rules
- **SwiftUI Text/Button/Label**: Use string literals directly (e.g., `Text("Cancel")`). SwiftUI automatically treats these as `LocalizedStringKey`.
- **AppKit APIs** (NSOpenPanel, NSAlert, etc.): Use `NSLocalizedString("string", comment: "")`.
- **String interpolation with Images**: Split into `Text` concatenation. E.g., `(Text("Press ") + Text(Image(systemName: "command")) + Text(" N"))`.
- **Every new user-facing string** must be added to `Localization/en.lproj/Localizable.strings`.
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
