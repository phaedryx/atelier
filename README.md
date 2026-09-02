# Atelier

A macOS app for running several AI coding agents side by side, one per git
worktree. Each **workstream** is a branch, a worktree, and a terminal running the
Coding Agent, plus tabs for its diff, its dev server, and an editor. Terminals
are GPU-rendered through [libghostty](https://github.com/ghostty-org/ghostty).

A personal fork of [Factory Floor](https://github.com/alltuner/factoryfloor) and
[Vibefloor](https://github.com/AndresGonzalez5/vibefloor).

## Install

Download the DMG from [Releases](https://github.com/phaedryx/atelier/releases).

Builds are ad-hoc signed and **not notarized** — this project has no Apple
Developer account. macOS quarantines the downloaded DMG, so open the app once via
right-click → Open, or clear the attribute:

```console
xattr -d com.apple.quarantine /Applications/Atelier.app
```

A locally built app is unaffected. See [docs/distribution.md](docs/distribution.md).

## Build from source

Requirements and commands are in [CONTRIBUTING.md](CONTRIBUTING.md). The short
version:

```console
git submodule update --init
xcodegen generate
./scripts/dev.sh br
```

## Project layout

Atelier creates worktrees beside the repository when the project uses a bare-repo
container — a `.bare` directory with a `.git` file next to it — so a worktree for
`/repos/app` lands at `/repos/app/<name>`. Any other layout falls back to
`~/.atelier/worktrees/<project>/<name>`.

To set a repository up that way:

```console
git clone --bare git@github.com:org/project.git .bare
echo "gitdir: ./.bare" > .git
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch --all --prune
```

Then park `HEAD` on a scratch branch so the default branch is free to be checked
out as its own worktree:

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

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘I | Info tab |
| ⌘↩ | Focus Coding Agent |
| ⌘1–9 | Switch to tab by position |
| ⌘⇧[ / ⌘⇧] | Cycle tabs |
| ⌘W | Close tab |
| ⌘[ / ⌘] | Cycle workstreams |
| ⌘↑ / ⌘↓ | Cycle projects |
| ⌘0 | Back to project |
| ⌘⇧R | Rename workstream |
| ⌘⇧W | Archive workstream |
| ⌘⇧↩ | Start / Rerun |
| ⌘⇧C | Toggle sidebar |
| ⌘⇧P | Command palette |
| ⌘P | Find file (editor) |
| ⌘S / ⌘⇧S | Save / Save As (editor) |
| ⌘L | Address bar (browser) |
| ⌘⌥B | Open in external browser |
| ⌘⌥T | Open in external terminal |
| ⌘/ | Help |

## Configuration

Turn on **Enable process-compose** in Settings first — it is off by default, and
nothing below runs until it is on, including the Environment tab's Start button.

Per-project commands live in a `process-compose.yaml` — in the worktree, or in
the project directory beside it — read by
[process-compose](https://f1bonacc1.github.io/process-compose/). Atelier drives
four namespaces in it:

| Namespace | When it runs |
|-----------|--------------|
| `bootstrap` | Once, in the background, when a workstream is created |
| `prepare` | Before every Start, to completion; a failure stops `execute` |
| `execute` | The long-lived stack, shown in the Environment tab's process table |
| `dispose` | Once, when a workstream is archived |

```yaml
processes:
  install:
    namespace: bootstrap
    command: npm ci
  migrate:
    namespace: prepare
    command: npm run db:migrate
  web:
    namespace: execute
    command: npm run dev -- --port $$WEB_PORT
  cleanup:
    namespace: dispose
    command: docker compose down -v
```

Write `$$VAR`, not `$VAR`, for a variable the shell should expand: process-compose
runs each `command` through envsubst first, and that eats `${VAR}` **and** bare
`$VAR`. A backslash does not escape it.

`bootstrap` and `dispose` run unattended, so a config that came with the
repository has to be approved first, and has to be approved again whenever it
changes. A config you placed in the project directory by hand is never asked
about — approval is gated by *where the file is*, not what is in it. `execute` is
never gated: it is a deliberate press on a command the Environment tab is already
showing.

Keeping the config in the project directory means one file for every worktree,
and in the bare-repo layout git never sees it. A config in the worktree wins when
both exist.

A `ports.yaml` in the **project directory** declares the port variables Atelier
supplies, so several workstreams can run the same stack at once without
colliding:

```yaml
ports:
  WEB_PORT: { assigned: true, browser: true }
  API_PORT: { assigned: true }
  OAUTH_PORT: { fixed: 4000 }
```

An `assigned` port gets its own number per worktree; a `fixed` one is that number
everywhere, for values registered off the machine such as an OAuth redirect URI.
At most one port may set `browser: true` — that is the one the embedded browser
opens. Every name is exported to every terminal surface, not just the run pane.

If a project has no `process-compose.yaml`, worktrees are still created and the
Environment tab says there is nothing to run; a per-workstream command typed into
Customize is the escape hatch.

## License

MIT. See [LICENSE](LICENSE).
