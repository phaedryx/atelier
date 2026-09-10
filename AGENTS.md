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
placeholder `0.0.0` / `0.0.0-dev`, and it means nothing: any build made outside
the release workflow reports it. Do not read it as the current version, and do
not bump it to "keep it current" — the value is overwritten by
`scripts/set-version.sh` during a tagged release and nowhere else. (It used to
carry `0.1.79`, inherited from Factory Floor, which made every local build claim
a released version it had long since diverged from.) `CFBundleVersion` stays
numeric because it must be period-separated integers; only the display string
carries the `-dev` marker.

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
- `Sources/Models/ProcessCompose/` - The process-compose integration (config location, phases, ports, the process table)
- `Sources/Terminal/` - Ghostty integration (TerminalApp singleton, TerminalView NSView)
- `Sources/Views/` - SwiftUI views (sidebar, settings, project overview, workspace, browser, editor)
- `Sources/Palette/` - Command palette (registry, default commands, fuzzy matcher)
- `Sources/PixelAgents/` - Claude Code hook receiver, router, and installer; transcript context
- `Sources/WorktreeSetup/` - Background worktree setup (the `bootstrap` phase, and the policy that gates it)
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
- **Process-compose approval** stored in UserDefaults (`atelier.approvedConfigFiles`), keyed by project directory against a SHA-256 of every repository-provided file the config will load
- **Verification** keeps two per-workstream keys, both in `Verification.Store`.
  `atelier.verifyRun.<workstreamID>` holds the most recent run, stamp included —
  only the latest, deliberately: history needs a retention policy and would be
  read by nothing, since the tab shows one run and an agent resolving an older
  id is worth less than a store that cannot grow without bound.
  `atelier.verifySelection.<workstreamID>` holds which checks the next run
  starts; empty means all, stored as the *absence* of the key, not an empty
  array. This is a **different key** from `atelier.processSelection.<id>`
  (`ProcessTableModel`'s, for the Execution tab's checklist) — one key for both
  would make checking a check in Verification uncheck a process in Execution.

### Workstream lifecycle
1. Creating a workstream: generates name, runs `git worktree add`; `AsyncSetupService` then runs the project's `bootstrap` namespace in the background
2. Workspace view: a workstream opens with only Info (Cmd+I) and Agent (Cmd+Return), which are also the only permanent tabs. Changes, Execution and Verification are singletons — at most one of each — opened on demand from the tab bar's quick-add buttons, the command palette, or their toggles, and they close and reorder like terminals/browsers once open. `startupWorkspaceTabState` seeds the two permanent tabs and clamps the restored `activeTab` into that list; the seed and the clamp move together, because a saved `.changes` restored onto a strip with no Changes tab renders the pane with nothing selected
3. Tmux mode: wraps Coding Agent only in `tmux new-session -A` on socket `-L atelier`
4. Terminal tabs: close on shell exit (Ctrl+D). Agent respawns.
5. Ending a workstream: two operations, not one — see below.

### Two ways to create a worktree, and they are not interchangeable
`Git.Operations.createWorktree` cuts a **new** branch from `BaseBranchSetting`. The GitHub
button on a project row goes through `createWorktreeTrackingRemote` instead, which checks out a
branch that already exists on origin. Do not merge them or reroute one through the other:
`createWorktree` runs `worktree add -b <name> <dir> <base>`, so handing it a branch that lives
only as `origin/<name>` **succeeds** and produces a worktree named for that branch while holding
the base branch's code — and its `-b`-less fallback only rescues a *local* branch of the name.

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

### Remove vs purge
`Workstream.Archiver` exports both, and they are not the same thing.

| | `Archiver.remove` | `Archiver.purge` |
|---|---|---|
| Alert | "Remove Workstream" | "Purge Workstream" |
| Reached by | ⌘⇧W, the menu's "Archive Workstream", the palette, the sidebar context menu's "Remove" | the sidebar context menu's "Purge", and the Purge button on `WorkstreamInfoView`'s merged-PR banner |
| Runs `dispose`? | no | yes, before the worktree goes |
| Files on disk | **kept** | `git worktree remove`, local branch deleted, default branch re-fetched |
| Also | kills tmux sessions, evicts surfaces, drops `IPC.Config` and the launch log | same, plus cancels a running `bootstrap` and stops the dev stack first |
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

**Known limitation, deliberate and unfixed:** three comparison sites in `Git.Operations` call
`defaultBranch(at:)` directly and do *not* consult this setting — `mergeBase` (the Changes tab's
diff base), `hasBranchCommits` (the ahead count), and the unmerged-commit log inside
`worktreeDetail`. So with the setting on `develop` in a repository whose git default is `main`,
a worktree is cut from `develop` while its diff and its ahead count are measured against `main`.
Two reviewers disagreed on whether those sites should follow the setting — a diff base and a
creation base are arguably different questions — so it stays a follow-up rather than a
half-migration finished in the dark. Do not "fix" one of the three; either all of them move or
none do.

**Only two of the three are visible to anyone.** `worktreeDetail` still computes
`unmergedCommits`, but the view that rendered them — `WorktreeDetailSheet` — was deleted in
2e6f2f8, and no view reads the field now. `worktreeDetail` itself is still live:
`ProjectOverviewView` calls it for the project's own repository, and uses the file changes, not
the commit log. So the wrong-base symptom a user can actually hit is the diff base and the ahead
count. Do not take that as licence to migrate those two and leave the third — the all-or-none
rule is about keeping one question answered one way, and a dead field is the cheapest of the
three to move. Either delete `unmergedCommits` or move all three; do not quietly drop it from
the count.

`defaultBranch(at:)` is also read to export `ATELIER_DEFAULT_BRANCH` (`TerminalContainerView`,
and `ProcessCompose.PhaseEnvironment`'s four callers — `AsyncSetupService` for `bootstrap`,
`WorkstreamArchiver` for `dispose`, `WorkspaceActions` for `open_agent_tab`'s spawned terminal, and
`Verification.Runner` for `verify`). Those are *not* part of that follow-up: the variable means
"what git thinks this repository's default branch is", and all five deliberately agree with each
other rather than with the setting.

### The process-compose integration
Everything a project asks Atelier to run lives in one **`process-compose.yaml`**, read by
[process-compose](https://f1bonacc1.github.io/process-compose/). `atelier.processCompose.enabled`
gates the whole integration and **defaults off**; with it off, a worktree gets no setup at all,
because there is no other setup path left. `ProcessCompose.Settings.resolveBinary()` finds the
binary: a configured path is used or fails, and never falls back to a search — silently running
a different binary than the one named is worse than reporting the named one is gone.

The switch is checked in three places: `PhasePolicy.plan` (so no unattended phase runs),
`refreshConfigApproval` (so nothing asks for approval it will not use), and
`DevCommand.Resolver.detectProcessCompose` (so Start has nothing to detect). The first two are
about correctness. The third is one half of a security boundary whose other half is
`ProcessCompose.RunCommandPlan` — see below.

**The un-`-n`'d command must never be executed, and is no longer displayed either.**
`DevCommand.Resolver.detectProcessCompose` builds `process-compose up -U -f <files>` as the
`.processCompose` source's `command`. It carries no `-n`, so running it would run **every**
namespace — `bootstrap` and `dispose` included — without passing through `PhasePolicy` or
`ScriptTrust`. It is not a runnable string, and the pane no longer renders it: for a
`.processCompose` source `devCommandDisplayText` shows the *files* that will be loaded, which
is what the user needed to see. Rendering the command was a copy-paste hazard on its own, and
Customize seeded its editable field from it — and Save turns that field into an `.override`,
which `ProcessCompose.RunCommandPlan` runs literally. Do not put a runnable process-compose command back into
`DevCommand.command`'s display path.

That invariant was defended four times by guarding *preconditions*, and reopened four times by
a different route each time: a worktree override process-compose discovered but Atelier never
showed; `compose.yaml` winning discovery outright; the integration switch being off; and — with
the switch **on** — `resolveBinary()` returning nil, which is ordinary rather than exotic,
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
did nothing in silence. `TerminalContainerView.refreshDevCommand` resolves the dev command, the
plan and the reason together, in one function, because *agreement* is the invariant here rather
than freshness. `ProcessCompose.RunCommandPlan.unavailableReason` explains a `.nothing`, and
`ExecutionTabView.scriptInstructions` — the surface that already drew for "nothing to run" —
renders it: the integration switched off, a config that cannot be located, a binary that is not
where the search looks. Background setup's own outcome, including `.completedWithNote`, is
rendered on the Info tab, which is permanent; nothing observed `.asyncSetupStateChanged` before,
so those notes were written and discarded.

**Five namespaces**, driven by `ProcessCompose.PhaseRunner` and `ProcessCompose.PhaseExecutor`:

| Namespace | When | Interactive? |
|-----------|------|--------------|
| `bootstrap` | once, in the background, at worktree creation (`AsyncSetupService`) | no |
| `prepare` | to completion before each Start, chained `&&` ahead of `execute` | no |
| `execute` | the long-lived stack, attached to a terminal surface and a process table | yes |
| `dispose` | once, at archive (`Workstream.Archiver.runDispose`) | no |
| `verify` | on demand, from the Verification tab | no |

`prepare` is chained only when `namespacePresence` says `.present` — never on `.unknown`.
process-compose does not exit when told to run an empty namespace, it idles forever, so
chaining `up -n prepare` for a namespace that turns out not to exist hangs Start with no output.
`execute` is never conditional — skipping it would make Start silently do nothing.

**`.unknown` fails closed here and open in `ProcessCompose.PhaseExecutor`, and that asymmetry is deliberate.**
A config Yams cannot decode still gets its `bootstrap` or `dispose` run, because refusing would
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
   `ScriptTrust` fingerprints, `ConfigApprovalView` displays, and process-compose executes is
   then one set. Do not reintroduce discovery. Leaving a worktree config unnamed so discovery
   could pick up its sibling override made the approval gate a *mirror* of discovery's rules,
   and a mirror can be stepped around — discovery also loads `compose.yaml`, a name Atelier
   deliberately does not detect, so a repository could ship a benign `process-compose.yaml` to
   be approved and a `compose.yaml` to be run. Verified against v1.122.0.
3. **Approval is gated by the config's *location*, not its content.** A config in the worktree
   arrived with the repository and requires approval before `bootstrap` or `dispose` runs; a
   config in the project directory was placed there by hand, outside git, and is never asked
   about. `execute` is never gated in either case, because it is **attended**: a deliberate
   press, output in a terminal surface in front of the user, Stop to hand. That, and not "the
   pane shows the command Start runs", is the reason — the pane shows the loaded *files*, and
   even before that it showed a display-only string rather than what Start runs. The false
   version of this sentence was load-bearing in four places (`ScriptTrust`,
   `ConfigApprovalView`, `ExecutionTabView`, `WorkstreamInfoView`) and is corrected in all of
   them. The decision to leave `execute` ungated stands; only its stated reason was wrong.

`ProcessCompose.Config.locate` looks in the **worktree first, then the project directory**, and
records `loadedFiles` (base plus the one override process-compose prefers) and
`repositoryProvidedFiles` (the subset needing approval). The project directory is the better
home in the bare-repo layout: it sits outside every worktree, so git cannot see it, no ignore
rule is needed, and one file serves every worktree.

**Which directory that is, is load-bearing.** `Project.directory` means the repository's
*home* — the `.bare` container, not the default checkout inside it — and every caller that
locates a config or reads `ports.yml` passes exactly that. `Project.checkout` is the other
half of the pair, and is for git work-tree reads only. They were one field until this was
fixed: `projectLocation` resolved a container forward to its checkout, so the lookups ran
against `<container>/main` and a config placed where the README says was never found. Passing
`checkout` to `Config.locate` or `PortsConfig.load` reintroduces exactly that bug.

A config in the worktree still wins,
because a worktree carrying its own is saying something deliberate. Either way process-compose
runs with the *worktree* as cwd and resolves a relative `working_dir` against its own cwd, so
`working_dir: apps/api` lands inside the worktree from either home.

`-u <path>` names the control socket explicitly. `-U` alone generates a path containing
process-compose's PID, which Atelier cannot predict and so cannot connect to. The headless
phases get namespace-suffixed paths, because a `bootstrap` still running when the user presses
Start would otherwise rebind `execute`'s socket and strand the first server.

**The one gate.** `PhasePolicy.plan` answers the four preconditions — integration on, a config
located, a binary to run it with, and approval of every repository-provided file — for both
unattended phases. It is deliberately the *only* copy: a second, inlined set in
`Workstream.Archiver` could not be tested and would not follow a change made here. Any new
unattended execution path for repository-provided commands must go through it.
`Verification.Runner.start` calls it too (`VerificationRunner.swift:347-363`), not because `verify`
runs automatically the way `bootstrap` and `dispose` do, but on the same underlying argument its own
comment gives: captured output means nobody is watching a TTY, so the reasoning that leaves
`execute` ungated does not apply — to a user press or to an agent call. See below.

### The verify namespace
Eight decisions from writing `verify` cost a review round each, and each is the kind of thing a
later reader would plausibly "simplify" away without knowing why:

1. **The log window is one-shot.** Per-check output lives in the control server that ran the
   namespace, and the run loop (`Verification.Runner.execute`, `VerificationRunner.swift:438-499`)
   tears that server down only after `seal` has returned — so the 200-line tail
   `captureFailedOutput` fetches first (`VerificationRunner.swift:604-655`) is all that exists
   anywhere afterward. No UI or agent-facing copy may imply a fuller log can be fetched later; the
   tab's own truncation notice says as much ("There is nothing more to fetch: the run's own output
   no longer exists anywhere", `VerificationTabView.swift:498`). 200 lines is not an arbitrary
   round number — it was sized against `IPC.Store`'s 65,536-byte-per-message cap
   (`IPCStore.swift:62`), which *throws rather than truncating* (`IPCStore.swift:176` and `:196`),
   so an oversized completion notice would be lost silently while an agent waits for it.
   `outputTruncated` means "there was more at capture time", never "more is retrievable".
2. **Teardown has exactly one owner.** `spawner.shutDown` is called once, from the run loop, only
   after `seal` returns (`VerificationRunner.swift:484-490`). Not from a `defer` — that can run
   before the log fetch, and the output is gone by the time `seal` wants it. Not from
   `stop(workstreamID:)` (`VerificationRunner.swift:250-253`) — Stop and the run loop would then
   race two teardowns on one socket, the hazard `shutDownWhenDone: false` exists to avoid; `stop`
   only sets a flag. A missed trailing teardown is recoverable because `ProcessCompose.PhaseExecutor.run`
   shuts the socket down again at its own top, before spawning, the next time `start` is called.
3. **A Stop is not acted on until the control server has answered.** `shouldStop` withholds a
   pending Stop until `state.sawServer` is true (`VerificationRunner.swift:517-537`), because
   `PhaseExecutor.shutDown` returns immediately when the socket file does not exist yet
   (`PhaseExecutor.swift:452-453`) — a Stop observed before `up` binds would make that teardown a
   no-op while the suite kept running: `isLive` would clear while the suite was still live, and a
   second `start` would be admitted onto the same socket.
4. **Liveness is `Verification.Runner.isLive(_:)`, never `Run.isFinished`.** The run loop publishes
   each check's state as the poll sees it, so a run's rows can all read terminal while the spawn is
   still winding down and nothing has been sealed or persisted — `isFinished` goes true at that
   moment; `isLive` does not (`VerificationRunner.swift:201-214`). `verificationCanRun`
   (`VerificationTabView.swift:32-43`) gates the Run button on `isLive` for the same reason.
   `Run.isFinished` is a row-state property, not a liveness signal: using it here would let a second
   `start` rebind `<id>-verify.sock` while the first run's spawn is still winding down and its
   server is still there — the reason `isLive` is keyed on `sealedRunIDs` instead.
5. **The Verification tab's availability decision is `PhasePolicy.plan`'s; only the wording is
   separate.** `verificationAvailability` calls `plan(phase: .verify, …)` for the decision and
   `verificationUnavailableReason` only to phrase it in the present tense
   (`VerificationTabView.swift:113-245`), because `Plan.nothingToDo` carries a past-tense string and
   no discriminated case. **Nothing enforces the agreement** —
   `verificationUnavailableReason` hand-mirrors `plan`'s four preconditions in the same order; a
   fifth precondition added to `plan` has to be added here too, by hand, and nothing will fail to
   compile if that step is missed. `.run` is not by itself availability, either: `plan` knows nothing
   about namespace *contents*, so an empty or unparseable `verify` namespace still returns `.run` —
   `verificationAvailability` reads the declared list off `plan`'s own returned config as a fifth
   fact, so Run cannot be enabled for a project `start` would refuse.
6. **A parse failure is not "declares nothing".** `declaredProcesses(in:)` returns nil, not `[]`,
   when a file cannot be parsed (`ProcessComposeConfig.swift:107-134`). `Verification.Runner.start`
   throws `Failure.unavailable` on that nil rather than letting `resolveChecks` see an empty list
   (`VerificationRunner.swift:374-386`), and `verificationUnavailableReason` keeps `declared` as an
   `Optional` through its own guard chain for the same reason (`VerificationTabView.swift:113-162`).
   Coalescing either one to `[]` early would report a broken config to the user as "this project
   declares no verify checks" — the same message a project with genuinely no verify checks gets,
   and the only diagnostic either path gives.
7. **`seal` never overwrites a state the live rows established.** A check missing from the final
   `processes()` read keeps what the polls saw; only a row still `.pending` (or `.running`) is
   relabelled, by the switch below the mapping. The `else { .notRun }` that used to stand there was
   false whenever the read *failed*, because `execute` passes `verifyProcesses(...) ?? []` — and it
   fails routinely: `PhaseExecutor.PollResult.serverGone` records that a project may shut itself
   down, and `restart: exit_on_failure` does exactly that **even with `--keep-project`**. A
   fail-fast verify suite therefore published `.failed(1)`, self-terminated, and sealed every check
   `.notRun`, discarding the failure the user had just watched. For the same reason the
   `failureDetail` banner is gated on the *rows* — `Runner.serverReportedAnyCheck`, i.e. some row is
   no longer `.pending` — and not on `entries.isEmpty`, which was the same question only while an
   empty read also meant empty rows. **That predicate is "was any check ever reported", never "did
   any check finish"**: `PhaseExecutor.run` returns `.failed` with the checks still executing when
   its own deadline ends a run, so a terminal-states test would fire "the run itself failed to start
   its checks" over a suite that ran for its whole `Timeout.suite`. Cost, accepted and unfixable
   here: when the server is genuinely gone `captureFailedOutput` gets nothing, so the preserved
   `.failed` row carries no log.
8. **A check named like a flag is filtered out at the verify layer, not at `PhaseRunner.command`.**
   That filter — trailing process names beginning with `-` are dropped — is a load-bearing
   flag-injection guard shared with `execute` and must not be weakened. But it did not compose with
   `resolveChecks`, which refused only names that were *not declared*: a process genuinely named
   `-n` is legal YAML, so it was declared, offered in the checklist, resolved, and then silently
   dropped on the way to the shell. As the *only* selection it was worse than a missing row —
   `selectedProcesses` became empty and `up -n verify` ran the **whole namespace**, inverting the
   user's selection through a security guard. `Verification.Runner.runnableChecks` is the one copy
   of the filter and both `start` and `verificationAvailability` call it, so the checklist and the
   runner cannot disagree about what exists; `resolveChecks` applies it to its own `declared`
   argument too, so the guarantee does not depend on a caller remembering, and additionally refuses
   such a name asked for explicitly, with `Failure.unrunnableChecks` rather than "No such check",
   which would be a lie about a name the YAML really declares.

**No agent can start a verify run yet.** `Verification.Runner`'s own doc already talks about "a run
an agent started through `start_verification`" (`VerificationRunner.swift:12-17`), and that is why
the type is app-level rather than owned by the tab — so an IPC adapter can attach to `runs` and
`onFinish` later without moving ownership. But no such tool exists today: `IPC.Tool`
(`IPCProtocol.swift`) has no `start_verification` or `check_verification` case, and nothing under
`Sources/MCPHelper` mentions verification. The Verification tab is the only caller right now.

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

Every declared name reaches **every** terminal surface via `Workstream.Environment.variables`,
not just the run pane — a port visible only to the run pane is invisible to a test run in a
terminal tab. Declarations merge *over* Atelier's own variables, so a project that wants
`ATELIER_PORT` to mean something specific may say so, and the legacy `FF_*` mirror is built
last so it never lags behind.

**And every declared name reaches all five namespaces.** `prepare` and `execute` run in a
Ghostty surface, which is handed those variables when it is created; `bootstrap`, `dispose` and
`verify` spawn through `ProcessCompose.PhaseExecutor`, and until `ProcessCompose.PhaseEnvironment` existed their children inherited
only the app's own environment. One `process-compose.yaml` therefore ran under two different
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
deadline and drains stdout and stderr on separate threads. Both halves matter:
`readDataToEndOfFile()` followed by `waitUntilExit()` never returns if the child
hangs, and draining one stream while the other fills deadlocks any child whose
output passes the ~64 KB pipe buffer — reachable for `git fetch` on a
many-branch repository, or any package-manager install.

Pick a deadline from `ProcessRunner.Timeout` rather than inlining a number:
`local` for reads and ref-level writes, `network` for anything reaching a remote,
`userCommand` for work whose size the user controls, `install` for package
managers, `suite` for a project's own test or lint suite run through the `verify`
namespace. `suite` is 1800s, the same bound as `install`, because `userCommand`'s
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

### Agent workspace tools (IPC)

`IPC.Tool` is three groups, not one, and `Tool.surface` makes the grouping a value the compiler
checks rather than a comment:

| Group | Tools | Trust story |
|---|---|---|
| Messaging | `register_peer`, `list_peers`, `send_message`, `receive_messages`, `broadcast`, `get_peer_status` | none needed — text between agents, nothing a user can see |
| Workspace reads | `list_tabs`, `read_review_comments` | none needed — answers about the caller's own workstream |
| Workspace actions | `open_agent_tab`, `open_editor`, `request_attention`, `create_workstream`, `start_verification`, `check_verification` | see below |

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

**`open_agent_tab` spawns the surface already running the agent** —
`TerminalSurfaceCache.surface(for:…command:)`, not a paste into a shell. There is no synthetic
Return, no timing heuristic, and no question of whether the pane was interruptible. Two
consequences worth keeping:

- **The session id is the *surface's*, never the workstream's.** The workstream id is the Coding
  Agent tab's own Claude session; a second agent handed it fights that tab over one transcript.
- **Surfaces are created eagerly, outside any render pass** (the same construction
  `TerminalSurfaceCache.retrySurface` already does), so a tab can be spawned into a workstream
  the user is not looking at. What is view-bound is *rendering*, not surface creation.

**`create_workstream` inherits `bootstrap`'s approval gate by not touching it.** Creating a
workstream runs the project's `bootstrap` namespace, which is repository-provided
process-compose commands — the thing `ProcessCompose.PhasePolicy.plan` exists to gate. The
handler never calls `AsyncSetupService.setupExistingWorktree`. It posts `.workstreamCreated`,
does the git work off the main thread, and posts `.workstreamWorktreeReady`; `ContentView`'s
handler for that notification is what calls `AsyncSetupService`, and therefore what runs
`PhasePolicy`. Those three notifications are the seam — `ProjectSidebar.launchWorkstream` and
`ProjectOverviewView` are the other two producers — and going through them is also what gets
path persistence, the HeadWatcher, the agent-state lookup and the Shortcut story id, none of
which a second creation path would remember. Adding a `PhasePolicy` check here, or calling
`setupExistingWorktree` directly, is the inlined second copy that section forbids.

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

`start_verification` runs the project's `verify` namespace against the caller's own
worktree and answers with a **run id**, never a result: a real suite outlives an MCP
tool call. The result reaches the agent two ways — a summary posted into its inbox
when the run ends, and `check_verification(run_id)`, which exists because delivery is
a pull and the nudge is best-effort, so an agent that never reads its inbox must
still be able to find out.

**The seam is declared on the IPC side and the runner conforms**:
`IPC.VerificationControlling` (`Sources/Models/IPC/VerificationControlling.swift`),
mirroring `ProcessCompose.Controlling`. It carries `IPC.VerificationRunInfo` rather
than the runner's `Verification.Run` — the projection `PeerInfo` is to the store's
`Peer`, and for the same reasons: seconds-ago instead of a `Date` needing a shared
encoding strategy on both ends, a bounded output tail instead of a suite's whole log,
`isStale` instead of the stamp. The `CheckResult.State` → `VerificationCheckState`
mapping is therefore the runner's, which is where the two measured process-compose
traps already live. Its doc comment carries the rest of the contract, and two clauses
there are load-bearing: a start must **refuse while a run is in flight** for that
workstream, because `PhaseExecutor.run` calls `shutDown` at the *top* and a second
start would kill the first mid-suite; and `onFinish` must fire on every terminal path,
because a path that does not is a completion notice that never arrives.

**Approval is not rechecked here.** `ProcessCompose.PhasePolicy.plan` is the gate and
it lives behind the seam; the handler passes the runner's refusal through verbatim.
Adding a check in `IPC.Service` is the inlined second copy that section forbids.

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

**The notice is addressed by surface, and the peer is resolved when it is posted.**
Two agents in one worktree report the same workstream name, so the surface id is the
only discriminator; and a helper whose old socket has not closed yet re-registers under
a *new* peer id, so an id captured when the run started can be dead while its pane has
an agent sitting in it.

**Two bounds that are not tuning.** `IPC.Store` refuses content over 64KB outright, so
an oversized notice is not trimmed on delivery — it is lost, silently, exactly when the
agent is waiting for it; `VerificationSummary` assembles against a 6KB budget, verdicts
before output, and points at `check_verification` for the rest. And a run that finished
having run **nothing** must never render as a pass: `up -n` on an empty namespace never
exits so `PhaseExecutor` returns `.skipped` without spawning, and an undecodable config
declares no processes at all, which makes "0 of 0 failed" both true and a green suite.

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
Bugs, features, and deferred work go in GitHub issues at
https://github.com/phaedryx/atelier/issues — there are templates for bug
reports, feature requests, and fix prompts under `.github/ISSUE_TEMPLATE/`.
There is no `TODO.md`; do not create one.
