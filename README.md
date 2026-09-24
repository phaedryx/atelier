# Atelier

A macOS app for running several AI coding agents side by side, one per git
worktree. Each **workstream** is a branch, a worktree, and a terminal running the
Coding Agent, plus tabs for everything that branch needs. Terminals are
GPU-rendered through [libghostty](https://github.com/ghostty-org/ghostty).

This is a personal fork of [Factory Floor](https://github.com/alltuner/factoryfloor) and
[Vibefloor](https://github.com/AndresGonzalez5/vibefloor).

## What a workstream gives you

- **Coding Agent** — a terminal running Claude Code in that worktree, with the
  agent's state reflected in the sidebar.
- **Changes** — the branch's diff, with review comments you can leave on a line
  and hand to the agent.
- **Execution** — the project's dev stack, run through process-compose, with a
  port assigned per worktree so every workstream can run at once.
- **Verification** — the project's checks (lint, tests), each in its own terminal,
  run independently.
- **Whiteboard** — a shared canvas the agent can draw on over MCP.
- **Info** — what setup did behind this worktree, and the Shortcut story it came
  from, if there is one.
- Terminals, editors (Monaco) and browser tabs, opened as you need them.

Atelier gives each Coding Agent an MCP server over which it can act on its own
workstream — open tabs, read your review comments, start the stack, run a check,
draw on the whiteboard. Turn on **Agent messaging** (Settings → Coding Agent) and
agents in different workstreams can find each other and exchange messages too. A
command palette (⌘⇧P) reaches everything above.

## Install

Download the latest DMG from
[Releases](https://github.com/phaedryx/atelier/releases). Builds are ad-hoc
signed but **not notarized** — this project has no Apple Developer account — so
macOS refuses a downloaded copy on first launch until you clear quarantine:

```console
xattr -dr com.apple.quarantine /Applications/Atelier.app
```

There is no in-app updater and no release polling: upgrading means downloading a
newer DMG, or building one.

## Build from source

macOS 14+, Xcode 16+, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). One command does the first-time
setup — ghostty submodule, the Monaco bundle, prek hooks, `xcodegen generate` and
a debug build:

```console
./scripts/setup.sh
./scripts/dev.sh br       # thereafter: build and run
./scripts/dev.sh test     # run the test suite
```

The ghostty xcframework and resources are **not in git and nothing builds them
for you** — see
[docs/ghostty-xcframework-build.md](docs/ghostty-xcframework-build.md). Without
them `setup.sh` stops with a message naming what is missing.

`Atelier.xcodeproj` is generated from `project.yml` — edit the latter and run
`xcodegen generate`, never the former.

## Project layout

Atelier creates worktrees beside the repository when the project uses a bare-repo
container — a `.bare` directory with a `.git` file next to it — so a worktree for
`/repos/app` lands at `/repos/app/<name>`. Any other layout falls back to
`~/.atelier/worktrees/<project>/<name>`.

**Clone Repository sets this up for you.** The recipe below is for converting a
repository you already have.

```console
git clone --bare git@github.com:org/project.git .bare
echo "gitdir: ./.bare" > .git
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch --all --prune
```

Then park `HEAD` on a scratch branch so the default branch is free to be checked
out as its own worktree. `wt.default` is not just a convention — Atelier reads it
to learn which worktree holds the default branch.

```console
# fish
set def (git symbolic-ref --short HEAD)
git config wt.default $def
git branch root $def
git symbolic-ref HEAD refs/heads/root
git worktree add $def
```

```console
# bash
def=$(git symbolic-ref --short HEAD)
git config wt.default "$def"
git branch root "$def"
git symbolic-ref HEAD refs/heads/root
git worktree add "$def"
```

## Configuration

A project tells Atelier what to run through four files, all of them in the
**project directory** — the repository's home, which in the bare-repo layout is
the container holding `.bare` and every worktree as peers, not a worktree itself.
Nothing inside a worktree is read, so one copy serves every workstream, git never
sees it, and an agent confined to its worktree cannot change what runs.

| File | What it holds |
|------|---------------|
| `execution.process-compose.yaml` | the dev stack, in three namespaces |
| `initialization.yaml` | the steps run once, when a worktree is created |
| `verification.yaml` | the checks the Verification tab runs |
| `ports.yaml` | the port variables Atelier assigns per worktree |

The three namespaces in the execution file:

| Namespace | When it runs |
|-----------|--------------|
| `prepare` | Before every Start, to completion; a failure stops `execute` |
| `execute` | The long-lived stack, shown in the Execution tab's process table |
| `dispose` | Once, when a workstream is archived |

Atelier runs the execution file through
[process-compose](https://f1bonacc1.github.io/process-compose/), which is a
requirement rather than an option — there is no switch, and Start does nothing
without it. It is auto-detected from `/opt/homebrew/bin`, `/usr/local/bin` and
`~/.local/bin`, in that order, with no path setting; Settings → Environment →
**Detected Tools** reports what resolved. Verification is the exception: its
checks are plain commands, run without process-compose.

New Project and Clone Repository write commented templates of the execution and
verification files. **[docs/configuration.md](docs/configuration.md)** is the full
reference: a worked example, the port mechanism, and the three things about
process-compose that will bite you.

### Base branch

**Base branch** (Settings → General) chooses the branch new worktrees are cut
from: `main`, `master`, `trunk`, `develop`, or **Repository default**, which asks
git. It governs worktree creation only. The Changes tab's diff and the
ahead/behind counts still compare against the branch git guesses is the default,
so if you set this to something git does not consider the default, those two
numbers are measured against a different base than the one your branch was cut
from.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New workstream, or new project when none is selected |
| ⌘⇧N | New project |
| ⌘, | Settings |
| ⌘/ | Help |
| ⌘⇧C | Toggle sidebar |
| ⌘⇧P | Command palette |
| ⌘I | Info tab |
| ⌘↩ | Focus Coding Agent |
| ⌘1–9 | Switch to tab by position |
| ⌘⇧[ / ⌘⇧] | Cycle tabs |
| ⌘⌥← / ⌘⌥→ | Cycle tabs |
| ⌘T | New terminal tab |
| ⌘W | Close tab |
| ⌘[ / ⌘] | Cycle workstreams |
| ⌘↑ / ⌘↓ | Cycle projects |
| ⌘0 | Back to project |
| ⌘⇧R | Rename workstream |
| ⌘⇧W | Archive workstream |
| ⌘⇧↩ | Start / Rerun |
| ⌘P | Find file (editor) |
| ⌘S / ⌘⇧S | Save / Save As (editor) |
| ⌘L | Address bar (browser) |
| ⌘⌥B | Open in external browser |
| ⌘⌥T | Open in external terminal |
| ⇧drag | Select in a terminal, over a TUI that has grabbed the mouse |

⌘⌥← / ⌘⌥→ and ⌘⇧[ / ⌘⇧] do the same thing: the bracket chords are read off a
key monitor, and the menu's own Previous Tab / Next Tab items carry the arrow
pair because a menu item cannot be given a chord a monitor already swallows.

A full-screen TUI — process-compose's own, which Start runs for the `execute`
phase — reports mouse events to itself, so an ordinary drag never reaches the
terminal and selects nothing. Holding shift takes the mouse back for the
duration of the drag; the selection is copied on release, so there is no ⌘C to
follow it with. process-compose also has its own answer for the log pane alone,
**Ctrl-S**, which turns the pane into an editable buffer you select in and press
Enter to copy.

## Contributing

[Open an issue](https://github.com/phaedryx/atelier/issues/new/choose) for a bug
or a feature — for a feature, the use case rather than the solution.

For a pull request: branch off `main` with a **hyphenated** name (`feat-thing`,
`fix-thing` — a slashed one puts the worktree a directory deeper instead of
beside `main`), put any new user-facing string in
`Localization/en.lproj/Localizable.strings`, make `./scripts/dev.sh build` and
`./scripts/dev.sh test` pass, and open it against `main`. `CLAUDE.md` holds the
full set of conventions.

## License

MIT. See [LICENSE](LICENSE).
