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
- **AppConstants** (`appID`, `appName`, `configDirectory`, `cacheDirectory`)
- **No update checking** — no in-app updater and no release polling; upgrade by downloading a new DMG from GitHub Releases, or by building locally
- **prek** pre-commit hooks (`prek.toml`)

### Key directories
- `Sources/Models/` - Data models, git operations, tmux, name generator, app constants
- `Sources/Terminal/` - Ghostty integration (TerminalApp singleton, TerminalView NSView)
- `Sources/Views/` - SwiftUI views (sidebar, settings, project overview, workspace, browser, editor)
- `Localization/en.lproj/` - Localizable.strings and InfoPlist.strings (English only)
- `Resources/` - Entitlements, bridging header, Assets.xcassets, CLI script
- `Resources/MonacoEditor/` - Built Monaco editor bundle (gitignored, built by `scripts/build-editor.sh`)
- `editor/` - Monaco editor Vite project (source for `Resources/MonacoEditor/`). Built with bun.
- `ghostty/` - Git submodule (do not modify, pinned to stable release tag)
- `scripts/` - Release and build automation
- `docs/` - Distribution guide and reference docs

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

### Workstream lifecycle
1. Creating a workstream: generates name, runs `git worktree add`, symlinks .env (if enabled)
2. Workspace view: only Info (Cmd+I) and Agent (Cmd+Return) are permanent; Changes and Environment open by default but close, reopen, and reorder like terminals/browsers, which are added on demand
3. Tmux mode: wraps Coding Agent only in `tmux new-session -A` on socket `-L atelier`
4. Terminal tabs: close on shell exit (Ctrl+D). Agent respawns.
5. Archiving: runs teardown script, then `git worktree remove` + `tmux kill-session`

### Script configuration
Scripts are loaded from `.atelier.json` in the project directory:
```json
{ "setup": "cmd", "run": "cmd", "teardown": "cmd" }
```
Falls back to `.emdash.json`, `conductor.json`, or `.superset/config.json` if not found.
When using a fallback config, compatibility env vars are injected (e.g. `CONDUCTOR_*`, `EMDASH_*`, `SUPERSET_*`).

These commands come from the repository, so none of them run until the user approves them.
`ScriptTrust` stores approval per project directory against a SHA-256 fingerprint of the
commands and their source file, so an edited config has to be approved again. The gate covers
`setup` (`SetupGateState.resolve`), `run` (`shouldRestoreRunSession` and the Environment tab
controls), and `teardown` (`ScriptConfig.runTeardown`). Any new execution path for
repository-provided commands must check `ScriptTrust.isApproved` first.

### Port detection
Run scripts are wrapped in the `atelier-run` launcher binary (bundled at `Contents/Helpers/atelier-run`).
The launcher monitors the child process tree for listening TCP ports using `libproc` and writes
state to `~/Library/Caches/atelier/run-state/<workstream-id>.json`. The app watches these files
via FSEvents and retargets the embedded browser when a port is detected.

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
4. Update `README.md` (shortcut table)

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
- **TODO.md**: Track bugs, features, and future work. Add items when you discover issues or defer work.
