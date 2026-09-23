# Atelier - Project Instructions

## Reference docs — load these as needed

This file carries the rules that apply everywhere. Everything else lives in
`docs/agents/`, split by what you are working on. **Read the matching file
before changing code under those paths** — each one is largely a record of
decisions whose rationale is not in the diff, and most sections exist because
the obvious thing was tried and was wrong.

| Working on | Read |
|---|---|
| `Sources/Models/IPC/**`, `Sources/MCPHelper/**`, any `atelier-ipc` tool | [`docs/agents/ipc.md`](docs/agents/ipc.md) |
| `Sources/Models/ProcessCompose/**`, `Sources/WorktreeSetup/**`, `execution.process-compose.yaml`, `initialization.yaml`, `verification.yaml`, `ports.yaml` | [`docs/agents/execution-and-config.md`](docs/agents/execution-and-config.md) |
| `Sources/Views/**`, `Sources/Palette/**`, UserDefaults keys, keyboard shortcuts | [`docs/agents/ui.md`](docs/agents/ui.md) |
| `Sources/Models/Whiteboard*`, `editor/src/whiteboard.jsx` | [`docs/agents/whiteboard.md`](docs/agents/whiteboard.md) |
| `Sources/PixelAgents/**`, agent state, hooks, the status line | [`docs/agents/agent-status.md`](docs/agents/agent-status.md) |
| `git worktree`, workstream creation, archive/purge, base branch | [`docs/agents/worktrees.md`](docs/agents/worktrees.md) |
| `Sources/Terminal/**`, `TerminalSurfaceCache`, surface ids | [`docs/agents/ui.md`](docs/agents/ui.md) |
| `ProcessRunner`, `AppleScriptRunner`, `Sources/Launcher/**`, cache paths | [`docs/agents/processes.md`](docs/agents/processes.md) |

If a change spans two rows, read both. If you are about to add a second copy of
a decision that already exists somewhere, the file for that area almost
certainly says why there is only one.

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
./scripts/build-editor.sh           # rebuild Monaco editor bundle (dev.sh runs it every time)
```

`dev.sh build`, `br`, `test` and `release` call `scripts/build-editor.sh`
**unconditionally**, and it decides for itself whether a rebuild is needed —
about 0.02s when the bundle is current. It used to be called only when the
bundle was **missing**, which meant an edit to `editor/src/` was never picked
up: the suite ran against the previous bundle and passed, which is worse than
failing, and the whiteboard tests drive a real `Whiteboard.Host` that loads it.
Do not put an existence check back in front of that call — two staleness
policies is how this broke, and the wrong one wins in exactly the case that
matters.

### After code changes
1. If you added/removed files or changed `project.yml`: run `xcodegen generate` first
2. Build and run: `./scripts/dev.sh br`
3. If tmux mode was on: `tmux -L atelier-debug kill-server`
4. If you changed the tmux config: `rm -f ~/Library/Caches/atelier-debug/tmux.conf`

Steps 3 and 4 both name the **debug** spellings, because step 2 built a debug
app. Both the tmux socket and the cache directory are `AppConstants.appID`, which
is `atelier-debug` under `#if DEBUG` and `atelier` otherwise — so a release build
is `tmux -L atelier kill-server` and `~/Library/Caches/atelier/`.

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
nowhere else. That script has three callers, and the bump is never
committed by any of them. The two local ones restore `project.yml` on exit via a
`trap` — `scripts/release.sh`, which passes the version derived from the tag, and
`./scripts/dev.sh release`, which passes `git describe`. The third, the release
workflow, stamps and does not restore: it runs on a throwaway checkout and has
nothing to commit back. (It used to carry `0.1.79`, inherited from Factory Floor, which
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
  three exemptions are marked at their spawn sites (see `docs/agents/processes.md`)
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
  targets, which compile individual model files by path (the `includes:` blocks
  of the `AtelierMCP` and `AtelierRun` targets in `project.yml` — named rather
  than cited by line, because any target added above them moves the range). `Port` is deliberately partial: it covers `Port.Allocator`,
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
