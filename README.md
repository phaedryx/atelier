# Atelier

A macOS app for running several AI coding agents side by side, one per git
worktree. Each **workstream** is a branch, a worktree, and a terminal running the
Coding Agent, plus tabs for its diff, its dev server, and an editor. Terminals
are GPU-rendered through [libghostty](https://github.com/ghostty-org/ghostty).

This is a personal fork of [Factory Floor](https://github.com/alltuner/factoryfloor) and
[Vibefloor](https://github.com/AndresGonzalez5/vibefloor).

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

## Configuration

Turn on **Enable process-compose** in Settings first — it is off by default, and
nothing below runs until it is on, including the Environment tab's Start button.

### What Atelier reads

| File | Where Atelier looks | What it holds |
|------|---------------------|---------------|
| `process-compose.yaml` | the worktree, then the project directory | the commands, in four namespaces |
| `process-compose.override.yml` | the worktree | per-worktree additions to a project-directory config |
| `ports.yml` (or `ports.yaml`) | the project directory only | the port variables Atelier supplies |

The first two are [process-compose](https://f1bonacc1.github.io/process-compose/)'s
own format; `ports.yml` is Atelier's. Keeping them in the project directory —
beside `.bare` and the worktrees — means one copy serves every worktree instead
of each growing its own that drifts, and in the bare-repo layout git cannot see
them, so no ignore rule is needed. A `process-compose.yaml` in the worktree wins
when both exist, because a worktree carrying its own is saying something
deliberate — and in that case the override is not consulted, since a worktree
config already *is* the per-worktree file.
Either way process-compose runs with the *worktree* as cwd, so a relative
`working_dir` resolves inside it.

Every file is named with `-f`, which turns process-compose's own discovery off:
the files Atelier shows you are the files it runs. That also means `compose.yaml`
is never loaded, whatever process-compose would do on its own. Name the file the
same way when you run the stack yourself:

```console
process-compose up -f ../process-compose.yaml    # from inside a worktree
```

### Namespaces

| Namespace | When it runs |
|-----------|--------------|
| `bootstrap` | Once, in the background, when a workstream is created |
| `prepare` | Before every Start, to completion; a failure stops `execute` |
| `execute` | The long-lived stack, shown in the Environment tab's process table |
| `dispose` | Once, when a workstream is archived |

### A worked example

A pnpm monorepo with a Rails API: `apps/api` (Rails + Sidekiq), a bff that serves
the SPA and proxies the API, Vite, and an html-to-json service. Everything the
services need to be told is either seeded from a file or supplied as a port.

```yaml
version: "0.5"

processes:

  # Once, at worktree creation. `seed/` sits in the project directory and holds
  # the .env files the services need — real secrets, so it stays out of git and
  # out of every worktree. ATELIER_PROJECT_DIR is how the phase finds it.
  #
  # --ignore-existing means anything already in the worktree wins, so a re-run
  # never clobbers a local edit; --copy-links turns a seeded symlink into a real
  # file. Populate `seed/` once, by hand or with whatever the repo uses to fetch
  # env files, and every worktree from then on gets them for free.
  #
  # Dependency installs live here too: this phase already runs once, in the
  # background, at exactly the moment a fresh worktree has none, and Atelier
  # gives it a 30-minute budget for exactly that reason.
  seed:
    namespace: bootstrap
    command: |
      set -e
      rsync -rlpt --omit-dir-times --copy-links --ignore-existing \
        "$$ATELIER_PROJECT_DIR/seed/" .
      pnpm install
      pnpm build
      (cd apps/api && mise exec -- bundle install)
    availability:
      restart: "no"

  # Before every Start. Fails once with an actionable message rather than
  # letting five services each produce their own confusing error — a bff with
  # no .env dies during module load with "Cannot read properties of undefined
  # (reading 'split')", which says nothing about env files.
  preflight:
    namespace: prepare
    command: |
      set -e
      test -f .env || { echo "missing .env — bootstrap did not seed"; exit 1; }
      test -f apps/api/.env || { echo "missing apps/api/.env"; exit 1; }
      redis-cli -u "$${REDIS_URL:-redis://localhost:6379}" ping >/dev/null 2>&1 \
        || { echo "redis is not answering — brew services start redis"; exit 1; }
      pg_isready -q || { echo "postgres is not answering"; exit 1; }
      # Every ${NAME:-default} below is a fallback for running this stack
      # without Atelier. Under Atelier the names ports.yml declares are always
      # set, so a fallback that fires means ports.yml misspelled or forgot one —
      # which would otherwise be invisible, and would land every worktree on the
      # same repo default. ATELIER_WORKTREE_DIR is set in all four namespaces
      # under Atelier and in no plain shell, so it is what tells the two apart.
      # Add a line here for each port ports.yml gains, or the new one is exactly
      # the case this guard was written to catch.
      if [ -n "$${ATELIER_WORKTREE_DIR:-}" ]; then
        : "$${BFF_PORT:?not declared in ports.yml}"
        : "$${RAILS_PORT:?not declared in ports.yml}"
        : "$${HTML_TO_JSON_PORT:?not declared in ports.yml}"
        : "$${VITE_PORT:?not declared in ports.yml}"
      fi
    availability:
      restart: "no"

  # This is the app: it serves the SPA and proxies the API. Not Vite.
  #
  # `${NAME:-default}` throughout: Atelier sets every name ports.yml declares,
  # and the default is only reached when nothing did — see preflight above.
  bff:
    namespace: execute
    command: pnpm dev:bff
    environment:
      - "PORT=${BFF_PORT:-3006}"
      - "PROXY_API_URL=http://localhost:${RAILS_PORT:-3005}"
      - "PUBLIC_FRONTEND_URL=http://localhost:${BFF_PORT:-3006}"
      - "PUBLIC_WEBSOCKET_URL=ws://localhost:${RAILS_PORT:-3005}"
    readiness_probe:
      http_get:
        host: 127.0.0.1
        port: ${BFF_PORT:-3006}
        path: /
      initial_delay_seconds: 10
      period_seconds: 3
      failure_threshold: 20

  api:
    namespace: execute
    command: mise exec -- bundle exec rails server
    working_dir: apps/api
    environment:
      - "PORT=${RAILS_PORT:-3005}"
      - "HTML_TO_JSON_URL=http://localhost:${HTML_TO_JSON_PORT:-3012}"

  sidekiq:
    namespace: execute
    command: mise exec -- bundle exec sidekiq
    working_dir: apps/api
    depends_on:
      api:
        condition: process_started

  # Vite. Not the app — the bff serves the SPA and proxies to it.
  frontend:
    namespace: execute
    command: pnpm dev:frontend
    environment:
      - "VITE_PORT=${VITE_PORT:-5173}"

  # POST-only. A browser GET / returns 500; that log line is expected.
  html-to-json:
    namespace: execute
    command: pnpm dev:html-to-json
    environment:
      - "HTML_TO_JSON_PORT=${HTML_TO_JSON_PORT:-3012}"

  # Off by default. Turn it on in a process-compose.override.yaml rather than
  # editing this file, which every worktree shares.
  merge-worker:
    namespace: execute
    command: pnpm dev:merge-worker
    disabled: true
```

### Ports

A `ports.yml` in the **project directory** declares the port variables Atelier
supplies, so several workstreams can run this stack at once without colliding:

```yaml
ports:
  BFF_PORT: { assigned: true, browser: true }
  RAILS_PORT: { assigned: true }
  HTML_TO_JSON_PORT: { assigned: true }
  VITE_PORT: { assigned: true }
```

The names are yours, not Atelier's — they mean something only because
`process-compose.yaml` reads them, and they have to match it exactly.

**Why the `:-3006` defaults are there.** `ports.yml` carries no number for an
`assigned` port — Atelier picks that per worktree — so every reference in the
config is written `${NAME:-<default>}`, and the default covers the case where
nothing set the variable at all — running the stack by hand, with no Atelier in
the picture. Once the ports come out of the repo's own env files and
live only here, that fallback is the last remaining record of the stack's
conventional layout, which is a reason to keep it rather than inline the numbers
or drop them.

What it cannot do is tell "no Atelier" from "declared it wrong". A name
`ports.yml` misspells — or never declares — still yields a running stack, on the
repo default, in every worktree at once: exactly the collision the mechanism
exists to prevent, arrived at silently. So `preflight` asserts the fallbacks go
*unused* whenever Atelier is running the stack, branching on
`ATELIER_WORKTREE_DIR` because it is set in all four namespaces under Atelier and
in no plain shell. Keep the defaults; make them prove they were unnecessary.

An `assigned` port gets its own number per worktree; a `fixed: 4000` one is that
number everywhere, for values registered off the machine such as an OAuth
redirect URI. At most one port may set `browser: true` — that is the one the
embedded browser opens, and here it is the bff, because the bff is what serves
the app. Pointing it at Vite gets you the dev server without the API. Every
declared name is exported to every terminal surface and to all four namespaces,
alongside `ATELIER_PROJECT_DIR`, `ATELIER_WORKTREE_DIR` and the rest of the
`ATELIER_*` set, so `bootstrap` and `dispose` see the same environment `prepare`
and `execute` do.

### Three things that will bite you

**Write `$$VAR` for a variable the shell should expand.** process-compose runs
each `command` through envsubst at load time, and that eats `${VAR}` **and** bare
`$VAR`; a backslash does not escape it. An un-doubled shell variable is replaced
with the empty string before the shell ever runs — which is why the `preflight`
check above reads `$${REDIS_URL:-…}`. Single `$` is right in `environment:` and
`readiness_probe` — those are substituted before the config is run, which is
where the assigned port numbers come from.

**Map ports per process, not globally.** The bff and Rails both read a bare
`PORT`, from two different `.env` files — one global `PORT` cannot be both. A
per-process `environment:` block also outranks process-compose's own dotenv
injection, which would otherwise let the seeded `.env` put the repo's default
ports back over the assigned ones.

**`mise exec --` is load-bearing, not decoration.** A version manager that picks
Ruby from `.ruby-version` through a shell hook resolves it at the *shell's* cwd,
and process-compose spawns children with the PATH it inherited — so
`working_dir: apps/api` re-resolves nothing and the children get whatever Ruby
the launching directory selected. That surfaces as `Bundler::RubyVersionMismatch`,
which reads like a missing install rather than a PATH problem. `mise exec`
resolves per invocation, from `working_dir`.

### Prerequisites this particular stack assumes

Postgres and Redis answering on localhost, `pnpm` and a Node matching `.nvmrc`,
and a Ruby matching `apps/api/.ruby-version`. `bootstrap` installs the project's
own dependencies; it does not install the toolchain or start the daemons.
`prepare` is the right place to check for those — a stack that fails on a
missing daemon should say so once, before five processes each fail differently.

`process-compose` itself has to be findable. Atelier does not search `PATH`: it
looks at `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`, in that order,
and otherwise uses the path set in Settings verbatim — a configured path that is
wrong fails rather than falling back to a search, because silently running a
different binary than the one you named is worse. Installs by way of `go
install`, nix, mise or asdf land outside those three, so point the setting at the
binary — not the directory holding it.

### Approval, and when there is no config

`bootstrap` and `dispose` run unattended, so a config that came with the
repository has to be approved first, and again whenever it changes. A config you
placed in the project directory by hand is never asked about — approval is gated
by *where the file is*, not what is in it. `execute` is never gated because it is
*attended*: you press Start, the stack's output lands in a terminal surface in
front of you, and Stop is right there. The Environment tab shows which files are
in play, not the command Start runs.

If a project has no `process-compose.yaml`, worktrees are still created and the
Environment tab says there is nothing to run; a per-workstream command typed into
Customize is the escape hatch. When Start cannot run for some other reason — the
integration is switched off, or process-compose is not on disk where Atelier
looks — the tab says which, and the Info tab reports what background setup did or
did not do.

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

## License

MIT. See [LICENSE](LICENSE).
