<p align="center">
  <img src="https://raw.githubusercontent.com/phaedryx/atelier/main/Resources/Assets.xcassets/AppIconDebug.appiconset/256.png" width="128" height="128" alt="Atelier">
</p>

<h1 align="center">Atelier</h1>

<p align="center">
  <strong>AI-powered development workspace for macOS</strong><br>
  Git worktrees, Claude Code sessions, and dev servers in a single native app.
</p>

<p align="center">
  <a href="https://github.com/phaedryx/atelier/releases/latest">Download</a> &middot;
  <a href="https://github.com/phaedryx/atelier/issues">Issues</a>
</p>

<p align="center">
  <img src="https://img.shields.io/github/license/phaedryx/atelier?color=5B2333" alt="License">
  <img src="https://img.shields.io/github/stars/phaedryx/atelier?color=5B2333" alt="Stars">
</p>

---

> Atelier is a hard fork of [Factory Floor](https://github.com/alltuner/factoryfloor)
> by David Poblador i Garcia / All Tuner Labs, by way of
> [VibeFloor](https://github.com/AndresGonzalez5/vibefloor). It is maintained
> independently and is not affiliated with either project.

## Get Started

Install via Homebrew:

```bash
brew install --cask phaedryx/tap/atelier
```

Or [download the latest release](https://github.com/phaedryx/atelier/releases/latest).

Then:

1. **Open Atelier** and add a project by clicking the `+` button in the sidebar, then selecting a repository directory.
2. **Create a workstream** with `Cmd+N`. Atelier sets up a git worktree and launches a Claude Code agent automatically.
3. **Start building.** Add terminals (`Cmd+T`), browsers (`Cmd+B`), editors (`Cmd+O`), or configure [run scripts](#script-configuration) to auto-detect your dev server.

---

## What is Atelier?

Atelier is a native macOS app built on [Ghostty](https://ghostty.org)'s GPU-rendered terminal. It manages multiple parallel development tasks, each in its own git worktree with a dedicated Claude Code agent, terminal, and browser.

**One project, many workstreams, all at native speed.**

### Features

- **Git Worktrees** &mdash; Each workstream gets its own branch and worktree. Switch between tasks without stashing.
- **Claude Code** &mdash; Integrated AI agent with session persistence. Resume conversations across app restarts.
- **Tmux Persistence** &mdash; Agent sessions survive app restarts via tmux on a dedicated socket.
- **Setup & Run Scripts** &mdash; Configure setup, run, and teardown scripts per project via `.atelier.json`. Environment tab with split-pane terminals, Start/Rerun (⌘⇧⏎).
- **Embedded Browser** &mdash; WKWebView tab with automatic port detection. The browser navigates to the port your run script opens.
- **Code Editor** &mdash; Built-in Monaco editor (same engine as VS Code) embedded via WKWebView. Syntax highlighting, IntelliSense, and file tree. One file per tab, shared undo history.
- **GitHub Integration** &mdash; Repo info, open PRs, and branch PR status via the `gh` CLI.
- **Dynamic Tabs** &mdash; Open as many terminals, browsers, and editors as you need. Close with Cmd+W or Ctrl+D.
- **Update Notifications** &mdash; Checks for new versions and shows a badge in the sidebar.
- **Keyboard-first** &mdash; Every action has a shortcut. Cmd+1-9 for tabs, Cmd+Return for agent, Cmd+T for terminal, Cmd+B for browser, Cmd+O for editor, Cmd+P to jump to any file in the editor.

### Tmux Mode

When tmux mode is enabled (Settings > Terminal), Atelier wraps Coding Agent sessions in tmux using a dedicated socket (`atelier`). This keeps sessions alive across app restarts without interfering with your personal tmux setup.

The tmux config strips all UI chrome (status bar, prefix key, keybindings) since Atelier manages the terminal directly. Sessions are still fully accessible from any external terminal:

```bash
# List active sessions
tmux -L atelier list-sessions

# Attach to a session
tmux -L atelier attach-session -t <session-name>
```

Note that because keybindings are removed, you will need to detach with `tmux -L atelier detach-client` from another terminal, or use the standard `kill-session` command.

### Script Configuration

Add a `.atelier.json` to your project root to automate your workstream lifecycle. All fields are optional.

```json
{
  "setup": "npm install",
  "run": "PORT=$ATELIER_PORT npm run dev",
  "teardown": "docker-compose down"
}
```

| Hook | When it runs | Example use case |
|---|---|---|
| `setup` | Once, when a workstream is created | Install deps, copy .env, run build steps |
| `run` | On demand via the Environment tab | Start dev server, docker-compose up |
| `teardown` | When a workstream is archived | docker-compose down, clean temp files |

Scripts run in the workstream directory using your login shell. The `run` script is wrapped in the `atelier-run` launcher for automatic port detection.

These commands come from the repository, so Atelier asks you to approve them before it runs any of them. The workspace shows each command and the file it was read from, and nothing executes until you approve. Approval is remembered per repository and requested again whenever the commands change. You can withdraw it from the Info tab.

### Environment Variables

Every workstream terminal has access to:

| Variable | Description |
|---|---|
| `ATELIER_PROJECT` | Project name |
| `ATELIER_WORKSTREAM` | Workstream name |
| `ATELIER_PROJECT_DIR` | Main repository path |
| `ATELIER_WORKTREE_DIR` | Worktree path for this workstream |
| `ATELIER_PORT` | Deterministic port (40001-49999) |

### Keyboard Shortcuts

#### Global

| Shortcut | Action |
|---|---|
| `Cmd+N` | New workstream or project |
| `Cmd+Shift+N` | New project |
| `Cmd+,` | Settings |
| `Cmd+/` | Help |
| `Cmd+Shift+C` | Toggle sidebar |

#### Workstream

| Shortcut | Action |
|---|---|
| `Cmd+1` | Info |
| `Cmd+2` | Coding Agent |
| `Cmd+D` | Changes |
| `Cmd+3-9` | Switch tab |
| `Cmd+Shift+[` / `]` | Cycle tabs |
| `Cmd+Return` | Focus Coding Agent |
| `Cmd+T` | New Terminal |
| `Cmd+B` | New Browser (starts the dev server) |
| `Cmd+O` | New Editor |
| `Cmd+P` | Find File (Editor) |
| `Cmd+S` | Save (Editor) |
| `Cmd+Shift+S` | Save As (Editor) |
| `Cmd+W` | Close tab |
| `Cmd+Shift+W` | Archive workstream |
| `Cmd+L` | Address bar (browser) |
| `Cmd+Shift+Return` | Start/Rerun |

#### Navigation

| Shortcut | Action |
|---|---|
| `Cmd+[` / `]` | Cycle workstreams |
| `Cmd+Up` / `Down` | Cycle projects |
| `Cmd+0` | Back to project |

#### External Apps

| Shortcut | Action |
|---|---|
| `Cmd+Option+B` | Open in external browser |
| `Cmd+Option+T` | Open in external terminal |

### Supported Languages

English, Catalan, Spanish, Swedish.

---

## Install

```bash
brew install --cask phaedryx/tap/atelier
```

Or [download the latest release](https://github.com/phaedryx/atelier/releases/latest).

### Upgrade

```bash
brew upgrade --cask atelier
```

### CLI

Homebrew automatically installs the `ff` command. If you installed via DMG, install the CLI from Settings > Environment.

---

## Development

Requires: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), [Zig](https://ziglang.org) (`brew install zig`).

```bash
# First time: build the Ghostty terminal engine
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast && cd ..

# Build
./scripts/dev.sh build

# Build and run
./scripts/dev.sh br

# Kill and relaunch
./scripts/dev.sh run

# Run with a specific directory
./scripts/dev.sh run ~/repos/myproject

# Run tests
./scripts/dev.sh test

# Clean
./scripts/dev.sh clean

# Release (sign, notarize, DMG)
./scripts/release.sh 0.1.0
```

See [CLAUDE.md](CLAUDE.md) for development workflow, architecture, and conventions.

### Website

The website lives in `website/` and is built with [Hugo](https://gohugo.io) + [Tailwind CSS](https://tailwindcss.com).

```bash
cd website && bun install && bun run dev
```

### Localization

All strings are localized. To add a language:

1. Copy `Localization/en.lproj` to `Localization/xx.lproj`
2. Translate all values in `Localizable.strings`
3. Add the path to `project.yml` and run `xcodegen generate`

## Credits

Atelier is built on the shoulders of these projects:

- **[Ghostty](https://ghostty.org)** — GPU-accelerated terminal engine (Metal-rendered via libghostty)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview)** — AI coding agent by Anthropic
- **[tmux](https://github.com/tmux/tmux/wiki)** — Terminal multiplexer for session persistence
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — Xcode project generation from `project.yml`
- **[cmark-gfm](https://github.com/github/cmark-gfm)** — GitHub Flavored Markdown rendering (via [swift-cmark](https://github.com/swiftlang/swift-cmark))

## Support the project

Atelier is a fork of [Factory Floor](https://github.com/alltuner/factoryfloor), built by [David Poblador i Garcia](https://davidpoblador.com/) through [All Tuner Labs](https://alltuner.com/) and extended by [Andrés González](https://github.com/AndresGonzalez5).

If this project helped you ship faster, automate your workflow, or experiment with coding agents, consider supporting its development.

❤️ **Sponsor development**
https://github.com/sponsors/phaedryx

If you would rather support the original authors, sponsor [All Tuner Labs](https://github.com/sponsors/alltuner) instead.

## License

[MIT](LICENSE)

---

<p align="center">
  Forked from <a href="https://github.com/alltuner/factoryfloor">Factory Floor</a>, built by
  <a href="https://davidpoblador.com">David Poblador i Garcia</a> with the support of
  <a href="https://alltuner.com">All Tuner Labs</a>.<br>
</p>
