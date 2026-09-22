# Worktree setup

A new Atelier worktree is not usable until four things have happened: the ghostty
submodule is checked out, the two build artifacts that are not in git are
symlinked into it, the Monaco bundle is present, and the project has been built
once so SourceKit can resolve symbols across files.

`scripts/setup.sh` is the only copy of that work. It takes **no environment
variables** — it resolves the repository's home from git itself, so it is correct
in the README's bare-repo layout and in a plain clone — and it takes a subcommand:

```bash
./scripts/setup.sh            # all four, in order
./scripts/setup.sh ghostty    # submodule checkout, the two symlinks, and a check
./scripts/setup.sh editor     # copy the Monaco bundle from the default checkout
./scripts/setup.sh hooks      # prek
./scripts/setup.sh build      # xcodegen, dev.sh build, buildServer.json
```

**`editor` and `hooks` cannot fail the run**, and they are written to make that
true rather than merely likely: each catches its own failure and returns 0.
Neither is load-bearing. The Monaco copy is only a shortcut past a rebuild that
needs bun and takes minutes — `dev.sh build` runs `scripts/build-editor.sh` itself
when the bundle is missing — and a machine without `uv` is not a reason to leave
the worktree unbuilt. Because steps halt on the first failure, a step that
reported one here would stop a machine with no seed bundle from ever reaching
`build`. The copy is also staged and moved into place rather than written
directly, so a copy that breaks halfway cannot leave a partial bundle whose
`index.html` suppresses the rebuild that is supposed to be the fallback.

**`ghostty` can and does fail the run**, and it is the one step where that is
the point. `ln -sfn` succeeds whether or not its target exists, so linking is no
evidence that anything was built: the step used to print a green ✓ over a
dangling symlink, and the real failure arrived two steps later as `dev.sh
build`'s `Ghostty resources not found at ghostty/zig-out/share/` — which names
neither the xcframework nor the submodule, and which this document already calls
the misleading error the script exists to stop. So the step now probes the
*resolved* artifacts (`-d` follows a symlink, so a dangling link fails exactly as
an absent one does) and, when they are not there, exits non-zero with a message
naming what is missing and pointing at `docs/ghostty-xcframework-build.md`.

That halts `editor`, `hooks` and `build` behind it, and that is the intended
trade rather than a cost being overlooked. **The run was already going to fail** —
`build` cannot succeed without those artifacts — so the change is *where* the
failure is reported and *what it says*, not whether one happens. What halting
actually skips is a Monaco copy that `dev.sh build` regenerates by itself and a
`prek install`, both of which the paragraph above calls not load-bearing, and both
of which are one **Rerun** away once the artifacts exist.

`build` is last because it is the slowest and the likeliest to fail, so a failure
there still leaves a worktree that links and runs.

## Nothing runs it for you unless the project says so

**There is no automatic hook.** A `.hooks/worktree-create.sh` used to be described
here and in `AGENTS.md` as running on worktree creation; it was inherited from
Factory Floor, nothing in Atelier ever invoked it, and it has been removed rather
than left to send readers to wait for setup that never came. The mechanism that
did run setup — a `worktree` process in a `bootstrap` namespace — went when the
`bootstrap` namespace did.

**It was removed rather than repaired, and the difference matters.** The obvious
repair looks cheap: the script hard-fails on `WORKTREE_DIR` and
`CLAUDE_PROJECT_DIR`, an initialization step is handed `ATELIER_WORKTREE_DIR` and
`ATELIER_PROJECT_DIR`, so map the two and call it. That makes it worse. The
script's whole body is wrapped in `[ -d "$CLAUDE_PROJECT_DIR/ghostty" ]`, and in
the bare-repo layout the project directory is the container — which holds no
`ghostty`, because every checkout does. So the mapped script passes both guards,
skips everything, and **exits 0**: a green Setup row on the Info tab above a
worktree that still does not build. Today's failure at least says
`error: Ghostty resources not found`. Do not reintroduce the mapping.

The replacement is **`initialization.yaml`**, and it works only once this project
has one. Without it, a new worktree has an empty `ghostty/`, no
`Resources/MonacoEditor`, and `./scripts/dev.sh test` fails with
`error: Ghostty resources not found at ghostty/zig-out/share/` while a build gives
three xcodegen "missing source directory" errors that name nothing about the
submodule.

## The file, and where it goes

`initialization.yaml` lives in the **project directory** and nowhere else — the
`.bare` container, not a checkout inside it — because a file there sits outside
every worktree and so cannot have arrived with the repository. That is what lets
its commands run unattended with no approval gate, and it is the same rule
`verification.yaml` and `execution.process-compose.yaml` follow. It is therefore
**not in this repository and cannot be**, and it has to be placed by hand:

```yaml
# ABOUTME: Atelier's own worktree setup — what a new workstream needs before it builds.
# ABOUTME: Each step is a subcommand of scripts/setup.sh in the new worktree.
#
# Steps run sequentially, in file order, and halt on the first failure. Each gets
# its own ProcessRunner.Timeout.install deadline (1800s).
#
# Uncommented on purpose, unlike the template Atelier seeds for a new project.
# The template is commented out because an uncommented step would execute behind
# every new worktree of a project that never asked for one; here that is exactly
# what is wanted, and every command is a subcommand of a script in the worktree
# being set up.

ghostty:
  command: ./scripts/setup.sh ghostty

editor:
  command: ./scripts/setup.sh editor

hooks:
  command: ./scripts/setup.sh hooks

build:
  command: ./scripts/setup.sh build
```

Four steps rather than one `./scripts/setup.sh`, because the Info tab's Setup row
names the running step and its position, and because each step then gets its own
deadline instead of four phases sharing one. Progress reads
`Running “ghostty” (1 of 4)`, and a failure names the step that failed and quotes
the tail of its output.

No `shell:` key on any step: each command invokes a script with its own shebang,
so it means the same thing under any shell.

## The dead `process-compose.yaml` beside it

A project directory set up before this may still hold a `process-compose.yaml`
carrying a `worktree` process in a `bootstrap` namespace. That file is what used
to do this work, and it is inert twice over: the `bootstrap` namespace was removed
from `ProcessCompose.Phase`, and the bare filename was dropped from
`ProcessCompose.Config.locate`, which now reads `execution.process-compose.yaml`
and nothing else. Knowing only one of the two is a trap — renaming the file is not
sufficient to revive setup, and it is not harmless either.

**Leave it alone.** It also declares `prepare`, `execute` and `dispose`, so
renaming it to `execution.process-compose.yaml` would make three namespaces live at
once, on a config nobody has reviewed against the current app. Whether to adopt,
prune or delete it is a separate decision from worktree setup, and adding
`initialization.yaml` beside it does not force one: the two files are read by
different code and neither shadows the other.

## What still needs the manual path

**Adoption.** A worktree registered through Atelier's Adopt button deliberately
does not run initialization — adoption registers a worktree, it does not build
one, and running a project's setup commands unprompted in a tree that may hold
work in progress is a side effect nobody asked for. The Info tab shows
`Nothing reported this session.` with **Rerun** enabled beside it, so the steps
are one press away; `./scripts/setup.sh` from the worktree does the same thing.

**A worktree made outside Atelier.** A bare `git worktree add` runs nothing. Run
`./scripts/setup.sh` in it.

See `docs/ghostty-xcframework-build.md` for what the two symlinks point at and why
the artifacts are built once rather than per worktree.
