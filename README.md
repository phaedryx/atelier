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

Atelier runs a project's commands through
[process-compose](https://f1bonacc1.github.io/process-compose/), so it needs
that binary on the machine. It is a requirement rather than an option: there is
no switch to turn it on, and nothing below works without it, including the
Execution tab's Start button. Settings → Environment lists it under **Detected
Tools** beside `git` and `claude`, with a path field for an install the usual
locations do not cover.

The Verification tab is the exception: its checks are plain commands, declared in
their own file and run without process-compose. See **Verification** below.

### What Atelier reads

| File | Where Atelier looks | What it holds |
|------|---------------------|---------------|
| `execution.process-compose.yaml` | the project directory only | the commands, in three namespaces |
| `initialization.yaml` | the project directory only | the steps run once, when a worktree is created |
| `verification.yaml` | the project directory only | the checks the Verification tab runs |
| `ports.yml` (or `ports.yaml`) | the project directory only | the port variables Atelier supplies |

**"The project directory" is the repository's home — in the bare-repo layout the
container that holds `.bare`, the default checkout and every worktree as peers,
not the default checkout inside it.** That is the whole point: the file sits
outside every worktree, so one copy serves all of them instead of each growing
its own that drifts, and git cannot see it, so no ignore rule is needed. For an
ordinary clone the repository's home *is* the checkout, and the file goes at its
root like anything else.

`execution.process-compose.yaml` is
[process-compose](https://f1bonacc1.github.io/process-compose/)'s own format; the
rest are Atelier's. **A new project starts with a commented template of the
execution and verification files**, written by New Project and Clone Repository.
Adding a directory you already have leaves it alone.

**One name, one place.** The lookup is `execution.process-compose.yaml` in the
project directory, then `execution.process-compose.yml`, and that is the whole
of it — nothing inside a worktree is read. That is a trust decision rather than a
convenience: a file outside every work tree cannot have arrived with a clone, so
Atelier never has to ask you to approve the commands it runs unattended at
archive. It also means an agent confined to its worktree cannot edit what runs
there. It is the same rule `initialization.yaml` and `verification.yaml` follow.

The `execution.` prefix is what makes a single name safe to demand. A repository
may run process-compose for its own reasons, and a generic `process-compose.yaml`
is indistinguishable from Atelier's — so no generic name is read at all.

> **Upgrading.** This replaced a four-tier search over
> `atelier.process-compose.y*ml` and `process-compose.y*ml`, in the worktree and
> then the project directory. None of those names are read any more. Rename your
> config to `execution.process-compose.yaml` and move it to the project directory;
> until you do, the Execution tab says there is nothing to start and names the
> file to create.

Wherever the config lives, process-compose runs with the *worktree* as cwd, so a
relative `working_dir` resolves inside it.

The file is named with `-f`, which turns process-compose's own discovery off: the
file Atelier shows you is the file it runs. That also means `compose.yaml` is
never loaded, whatever process-compose would do on its own, and that an
`execution.process-compose.override.yml` sitting beside the config is not merged
into it. Name the file the same way when you run the stack yourself:

```console
process-compose up -f ../execution.process-compose.yaml    # from inside a worktree
```

### Namespaces

| Namespace | When it runs |
|-----------|--------------|
| `prepare` | Before every Start, to completion; a failure stops `execute` |
| `execute` | The long-lived stack, shown in the Execution tab's process table |
| `dispose` | Once, when a workstream is archived |

### A worked example

A pnpm monorepo with a Rails API: `apps/api` (Rails + Sidekiq), a bff that serves
the SPA and proxies the API, Vite, and an html-to-json service. Everything the
services need to be told is either seeded from a file or supplied as a port.

Worktree setup is the other file — see **Initialization** below for what this
project's `initialization.yaml` holds. Everything from here on is
`execution.process-compose.yaml`:

```yaml
version: "0.5"

processes:

  # Before every Start. Fails once with an actionable message rather than
  # letting five services each produce their own confusing error — a bff with
  # no .env dies during module load with "Cannot read properties of undefined
  # (reading 'split')", which says nothing about env files.
  preflight:
    namespace: prepare
    command: |
      set -e
      test -f .env || { echo "missing .env — initialization did not seed"; exit 1; }
      test -f apps/api/.env || { echo "missing apps/api/.env"; exit 1; }
      redis-cli -u "$${REDIS_URL:-redis://localhost:6379}" ping >/dev/null 2>&1 \
        || { echo "redis is not answering — brew services start redis"; exit 1; }
      pg_isready -q || { echo "postgres is not answering"; exit 1; }
      # Every ${NAME:-default} below is a fallback for running this stack
      # without Atelier. Under Atelier the names ports.yml declares are always
      # set, so a fallback that fires means ports.yml misspelled or forgot one —
      # which would otherwise be invisible, and would land every worktree on the
      # same repo default. ATELIER_WORKTREE_DIR is set everywhere Atelier runs
      # a project's command and in no plain shell, so it tells the two apart.
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

  # Off by default; start it by hand from the process-compose TUI when you need
  # it, rather than editing this file, which every worktree shares.
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
`execution.process-compose.yaml` reads them, and they have to match it exactly.

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
`ATELIER_WORKTREE_DIR` because it is set everywhere Atelier runs a project's
command and in no plain shell. Keep the defaults; make them prove they were unnecessary.

An `assigned` port gets its own number per worktree; a `fixed: 4000` one is that
number everywhere, for values registered off the machine such as an OAuth
redirect URI. At most one port may set `browser: true` — that is the one the
embedded browser opens, and here it is the bff, because the bff is what serves
the app. Pointing it at Vite gets you the dev server without the API. Every
declared name is exported to every terminal surface, to all three namespaces, to
every initialization step and to every verification check, alongside
`ATELIER_PROJECT_DIR`, `ATELIER_WORKTREE_DIR` and the rest of the `ATELIER_*`
set — so one worktree has one environment, whatever is running in it.

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
and a Ruby matching `apps/api/.ruby-version`. `initialization.yaml` installs the
project's own dependencies; it does not install the toolchain or start the
daemons.
`prepare` is the right place to check for those — a stack that fails on a
missing daemon should say so once, before five processes each fail differently.

`process-compose` itself has to be findable, and it is **auto-detected with no
override**. Atelier does not search `PATH`: it looks at `/opt/homebrew/bin`,
`/usr/local/bin` and `~/.local/bin`, in that order, and takes the first
executable it finds. There is no setting — the `process-compose` row under
Settings → Environment → **Detected Tools** reports what resolved, its refresh
button re-probes, and the onboarding screen lists it as a prerequisite beside
`git` and `claude`.

The consequence is worth stating plainly: an install by way of `go install`, nix,
mise or asdf lands outside those three directories, and there is no path field to
point at it. Such a binary is simply not found, and the fix is to put one where
Atelier looks — a symlink into `~/.local/bin` does it.

### When there is no config

`dispose` runs with its output captured rather than shown in a terminal, and
nothing asks you to approve it. That is what the project-directory-only lookup
buys: the file was placed there by hand, outside every work tree, so it cannot
have arrived with a clone. Atelier used to search the worktree too, and a config
found there had to be approved before `dispose` would run it; the tiers and the
approval went together. Rule of thumb — if a file can arrive with a clone,
Atelier will not run it unattended, and the way it enforces that is by not
looking there. `initialization.yaml` and `verification.yaml` follow the same
rule, so all three files sit in the same place for the same reason.

If a project has no `execution.process-compose.yaml` in its project directory,
worktrees are still created and the Execution tab says there is nothing to run
and names the file to add; a per-workstream command typed into Customize is the
escape hatch. When Start cannot run for some other reason — process-compose is
not on disk where Atelier looks, or the config declares no `execute` processes —
the tab says which, and the Info tab reports what initialization did or did not
do. That last one is a refusal rather than a dead button on purpose:
`process-compose up -n execute` against a namespace nothing declares neither
fails nor exits, so starting it would give you an empty TUI and no explanation.

### Initialization

What a new worktree needs before anyone works in it — dependencies installed, env
files seeded, a database prepared — is declared in an **`initialization.yaml`** in
the project directory, beside `.bare` and the worktrees rather than inside one:

```yaml
seed:
  command: |
    rsync -rlpt --omit-dir-times --copy-links --ignore-existing \
      "$ATELIER_PROJECT_DIR/seed/" .
deps:
  command: pnpm install && pnpm build
gems:
  shell: fish
  command: cd apps/api && mise exec -- bundle install
```

A name, a command, and optionally the shell to run it in (`$SHELL` by default) —
the same schema `verification.yaml` uses. It runs once, in the background, the
moment a workstream's worktree exists, so the Coding Agent is usable while setup
is still going.

**Steps run in the order the file declares them, and the first failure stops the
rest.** That is the difference from verification's checks, which are independent
and run at once: setup steps normally depend on each other, and running the rest
after a failure works against a half-built worktree and buries the error that
mattered. Each step gets the worktree as its working directory and the same
`ATELIER_*` and `ports.yaml` variables every other Atelier-launched command does.
A single `$VAR` is right here — this file is Atelier's, not process-compose's, so
there is no envsubst pass to double the `$` for.

Like `verification.yaml`, the file is deliberately **not** read from the worktree.
It sits outside git, so one set of steps serves every worktree, nothing asks you
to approve it, and an agent working inside a worktree cannot rewrite what runs
when the next one is made.

The Info tab's **Setup** row is where this reports — running, succeeded, or which
step failed and what it said — and its Rerun button runs the whole file again
against the worktree you are in. There is no other UI: initialization is
something that happens to a worktree, not a pane you work in.

> **Moving from the `bootstrap` namespace.** Setup used to be a `bootstrap`
> namespace in the process-compose config. That namespace is no longer run. Move
> each of its processes into `initialization.yaml` as a step, in the order its
> `depends_on` edges implied, and drop the `$$` doubling. A project whose
> `execution.process-compose.yaml` still declares `bootstrap` and that has no
> `initialization.yaml` is told so on the Info row rather than quietly getting no
> setup at all. (A project still on one of the *old* config names is not told —
> that file is not read at all any more, which the Execution tab says outright.)

### Verification

Checks live in a **`verification.yaml`** in the project directory — beside
`.bare` and the worktrees, not inside one:

```yaml
rubocop:
  shell: fish
  command: bundle exec rubocop
rspec:
  command: bundle exec rspec
```

A name, a command, and optionally the shell to run it in (`$SHELL` by default).
Each check runs as a login shell command with the worktree as its working
directory, and gets the same `ATELIER_*` and `ports.yaml` variables every other
Atelier-launched command does. Rows appear in the order the file declares them.

The file is deliberately **not** read from the worktree. It sits outside git, so
one set of checks serves every worktree, nothing asks you to approve it, and an
agent working inside a worktree cannot edit the checks that decide whether its
own work passes.

Each check gets a row with its own run button, and its own terminal:

```
▸  ◯ rspec ▶                                        stale   12.4s
```

Press ▶ and expand the triangle to watch it run — a real terminal, so colour and
progress output look exactly as they do when you run the command yourself. Checks
are independent: start as many as you like at once, and stop any one of them
without touching the others. `stale` means the worktree has changed since that
result was produced.

**A check's output lives in its terminal and nowhere else.** It is not written to
a file and does not survive quitting Atelier or re-running the check — a verdict
and a duration are what persist. Agents that start checks over MCP get verdicts
too, never output.

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

## License

MIT. See [LICENSE](LICENSE).
