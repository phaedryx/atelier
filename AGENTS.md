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
4. If you changed the tmux config: `rm -f ~/Library/Caches/atelier/tmux.conf`

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
- Branch names: `feat/description`, `fix/description`, `refactor/description`
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
quarantine attribute that only downloads carry. The workflow needs no secrets;
`SENTRY_AUTH_TOKEN` is optional and its step warns rather than fails.
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
- **Branch renames** land immediately: `WorktreeHeadWatcher` watches each worktree's resolved
  git directory (the one holding `HEAD`, which for a linked worktree is *not* `<worktree>/.git`)
  and fires a debounced callback, which re-reads that one branch via
  `AppEnvironment.refreshBranchName(for:)`. The 15s poll stays as the backstop; the watcher only
  makes the common case instant. The callback fires on any git activity in the worktree, so
  anything hung off it must stay cheap and no-op when the branch has not changed.
- **Tool detection** runs at startup in `AppEnvironment.refresh()`
- **Sidebar state** (selection, expanded sections) stored in UserDefaults (`atelier.selection`, `atelier.expandedProjects`)
- **Process-compose approval** stored in UserDefaults (`atelier.approvedConfigFiles`), keyed by project directory against a SHA-256 of every repository-provided file the config will load

### Workstream lifecycle
1. Creating a workstream: generates name, runs `git worktree add`; `AsyncSetupService` then runs the project's `bootstrap` namespace in the background
2. Workspace view: only Info (Cmd+I) and Agent (Cmd+Return) are permanent; Changes and Environment open by default but close, reopen, and reorder like terminals/browsers, which are added on demand
3. Tmux mode: wraps Coding Agent only in `tmux new-session -A` on socket `-L atelier`
4. Terminal tabs: close on shell exit (Ctrl+D). Agent respawns.
5. Archiving: runs the project's `dispose` namespace, then `git worktree remove` + `tmux kill-session`

### The process-compose integration
Everything a project asks Atelier to run lives in one **`process-compose.yaml`**, read by
[process-compose](https://f1bonacc1.github.io/process-compose/). `atelier.processCompose.enabled`
gates the whole integration and **defaults off**; with it off, a worktree gets no setup at all,
because there is no other setup path left. `ProcessComposeSettings.resolveBinary()` finds the
binary: a configured path is used or fails, and never falls back to a search — silently running
a different binary than the one named is worse than reporting the named one is gone.

The switch is checked in three places: `PhasePolicy.plan` (so no unattended phase runs),
`refreshConfigApproval` (so nothing asks for approval it will not use), and
`DevCommandResolver.detectProcessCompose` (so Start has nothing to detect). The first two are
about correctness. The third is one half of a security boundary whose other half is
`RunCommandPlan` — see below.

**The un-`-n`'d command must never be executed.** `DevCommandResolver.detectProcessCompose`
builds `process-compose up -U -f <files>` for the Environment pane to *display*, so the user
can see which files are in play. It carries no `-n`, so running it would run **every**
namespace — `bootstrap` and `dispose` included — without passing through `PhasePolicy` or
`ScriptTrust`. It is a display string, not a runnable one.

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
on the dev command's source, in `RunCommandPlan.plan`**: a `.processCompose` source has exactly
one legal command — the phase-scoped one — and if that cannot be built the answer is `.nothing`
and Start reports it. There is no branch that returns the display string, so a precondition
added tomorrow makes Start inert rather than reopening the bypass. `Tests/RunCommandPlanTests.swift`
pins it, including a test that no combination of inputs yields the display string; three of
those fail if the fallback is put back. Do not replace this with another precondition check.

**Four namespaces**, driven by `PhaseRunner` and `PhaseExecutor`:

| Namespace | When | Interactive? |
|-----------|------|--------------|
| `bootstrap` | once, in the background, at worktree creation (`AsyncSetupService`) | no |
| `prepare` | to completion before each Start, chained `&&` ahead of `execute` | no |
| `execute` | the long-lived stack, attached to a terminal surface and a process table | yes |
| `dispose` | once, at archive (`WorkstreamArchiver.runDispose`) | no |

`prepare` is chained only when the config actually declares a process for it:
process-compose does not exit when told to run an empty namespace, it idles forever, so an
unconditional `up -n prepare` would hang Start for every config that has not adopted it.
`execute` is never conditional — skipping it would make Start silently do nothing.

Three facts about this are load-bearing and easy to lose:

1. **`$$`, not `$`, inside a `command:`.** process-compose runs the whole command body through
   envsubst before the shell sees it, and envsubst eats `${VAR}` *and* bare `$VAR`. A shell
   variable in a command body must be written `$$VAR`. A backslash does not escape it.
2. **Every file is named with `-f`, always** (`PhaseRunner.command`, `DevCommandResolver.detectProcessCompose`).
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
   about. `execute` is never gated in either case — it is a deliberate press on a command the
   Environment tab is already displaying.

`ProcessComposeConfig.locate` looks in the **worktree first, then the project directory**, and
records `loadedFiles` (base plus the one override process-compose prefers) and
`repositoryProvidedFiles` (the subset needing approval). The project directory is the better
home in the bare-repo layout: it sits outside every worktree, so git cannot see it, no ignore
rule is needed, and one file serves every worktree. A config in the worktree still wins,
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
`WorkstreamArchiver` could not be tested and would not follow a change made here. Any new
unattended execution path for repository-provided commands must go through it.

### ports.yaml
A **`ports.yaml`** in the project directory declares the port variables Atelier supplies, so
two worktrees of one project can run the same stack at once:

```yaml
ports:
  WEB_PORT: { assigned: true, browser: true }
  API_PORT: { assigned: true }
  OAUTH_PORT: { fixed: 4000 }
```

`PortsConfig` parses it and `PortPlan.resolve` turns it into numbers for one worktree. An
`assigned` port starts from `PortAllocator.port(for:salt:)` — the same DJB2 hash that produces
`ATELIER_PORT`, salted with the variable's name — then walks forward past anything already
claimed in this pass or already bound. Deterministic-first matters: a port that changed every
run would break bookmarks, OAuth redirect URIs, and CORS allowlists. The probe only covers the
common case; nothing can close the window between checking a port and a child binding it. A
`fixed` port is that number everywhere, for values registered off the machine.

At most one entry may set `browser: true`; that port is what the embedded browser opens, and it
wins over detection — Atelier assigned it, so there is nothing to infer. Entries are sorted by
name before allocation, so an assigned port does not move because a YAML key was reordered.
`assigned: false` is an error rather than a no-op, because it reads like it means something.

Every declared name reaches **every** terminal surface via `WorkstreamEnvironment.variables`,
not just the run pane — a port visible only to the run pane is invisible to a test run in a
terminal tab. Declarations merge *over* Atelier's own variables, so a project that wants
`ATELIER_PORT` to mean something specific may say so, and the legacy `FF_*` mirror is built
last so it never lags behind.

### Dev command resolution
`DevCommandResolver` picks what the Environment tab's Start button runs, in order: the
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
managers. The distinction that matters is not local-versus-remote but whether the
repository's size sets the duration: `git status` is `local`, while `git worktree
add` checks out a whole tree and goes through `GitOperations.runOnWholeTree`. Git spawns also set `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`, because
a GUI app has no terminal on which to answer a credential prompt, so the prompt
is itself a hang.

Two sites are exempt and say so where they spawn: `BareRepoClone.run` and
`QuickActionRunner.runShellCommand`. Both run work with no honest deadline and
both give the user a cancel instead. If you add a third, it needs the same two
properties and the same comment.

### Paths
- Persistent data: UserDefaults (projects, sidebar state, workspace tabs)
- Cache: `~/Library/Caches/atelier/` (run-state, tmux.conf)
- Worktrees: beside the repository when the project uses the README's bare-repo layout
  (a `.bare` directory with a `.git` file next to it), so a worktree for `/repos/app` is
  created at `/repos/app/<name>`. Any other layout — an ordinary clone, a plain
  `git clone --bare`, a submodule — falls back to `~/.atelier/worktrees/<project>/<name>`,
  because there the equivalent directory is the working tree or a git directory, and a
  worktree must not be created inside either. See `GitOperations.worktreeDestination`.
- URL scheme: `atelier://`
- Bundle ID: `com.github.phaedryx.atelier`

### System prompts

The Coding Agent receives additional system prompts via `--append-system-prompt` based on
user settings. Prompts are defined in `Sources/Models/SystemPrompts.swift` and assembled in
`TerminalContainerView.buildClaudeCommand()`.

**Important**: Claude Code only accepts a single `--append-system-prompt` flag per invocation.
Multiple flags do not stack; the last one wins. When multiple prompts are active, they must be
concatenated into a single string before passing to the CLI.

Active prompts (combined when multiple are enabled):
- **Restrict to worktree** (default: on, setting: `atelier.allowOutsideWorktree`): constrains file writes to the worktree directory.
- **Auto-rename branch** (setting: `atelier.autoRenameBranch`): renames the git branch to match the task on first request.

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
- **Cmd+1-9**: Switch tab (all tabs in display order). Changes and Environment
  start at ⌘3/⌘4 but they close and reorder like any other tab, so nothing is
  bound to them by name — reopen from the tab bar or the command palette.
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
