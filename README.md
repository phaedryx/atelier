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

Per-project commands live in `.atelier.json` at the repository root:

```json
{ "setup": "cmd", "run": "cmd", "teardown": "cmd", "seed": "config/secrets" }
```

These come from the repository, so Atelier asks for approval before running any
of them, and asks again whenever they change. `seed` names a directory whose
contents are copied into each new worktree — that is how uncommitted `.env` files
reach a workstream. It defaults to `seed-files` (projects using the older
`.atelier-seed` keep working).

If a `process-compose.yaml` is found — in the worktree, or in the project
directory beside it — the Environment tab offers to start the stack with
[process-compose](https://f1bonacc1.github.io/process-compose/) instead of a
`package.json` dev script, and a picker switches between them. Keeping it in the
project directory means one file for every worktree, and in the bare-repo layout
git never sees it. That
tab also defines environment variables for the project — a literal value, or a
port Atelier picks per worktree so several workstreams can run the same stack at
once without colliding.

## License

MIT. See [LICENSE](LICENSE).
