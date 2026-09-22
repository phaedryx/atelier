#!/usr/bin/env bash
# ABOUTME: Workstream setup for Atelier development — ghostty, Monaco, prek, build.
# ABOUTME: Subcommands ghostty|editor|hooks|build run one phase; no argument runs all four in order.
set -euo pipefail

# This script is the *only* copy of what a new worktree needs. It is what
# CONTRIBUTING.md tells a human to run and what the project's
# `initialization.yaml` runs behind a new workstream, one subcommand per step —
# see docs/worktree-setup.md. The subcommands exist so those steps are named and
# bounded individually on the Info tab, not so the logic can live in two places:
# an `initialization.yaml` that inlined these commands would be a second copy
# that no test reads and that would not follow a change made here.
#
# It deliberately takes **no environment variables**. It resolves everything it
# needs from git, so it is correct wherever it is run from and there is nothing
# for a caller to map or get wrong.

# The repository's home. In the README's bare-repo layout the common dir is
# `<container>/.bare`, so this is the container holding every worktree — the
# directory `.shared/` sits beside. `git worktree list | head -1` named `.bare`
# itself there, which holds no ghostty and no .shared, so everything below was
# silently skipped.
# Assigned in two steps so a failing `git` aborts under `set -e`: `dirname` of
# nothing is `.`, and the exit status of the outer capture would be dirname's.
GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
REPO_ROOT=$(dirname "$GIT_COMMON_DIR")
WORKTREE_ROOT=$(git rev-parse --show-toplevel)

# The default branch's own checkout, which in the bare-repo layout is a worktree
# spelled like its branch (`<container>/main`). It is where the two things that
# are not in git but are expensive to make — the ghostty object store and the
# built Monaco bundle — can be borrowed from. Empty when there is no such
# checkout, and every use below treats that as "make it the slow way" rather
# than as an error.
#
# It always succeeds, printing nothing when there is no such checkout. Returning
# non-zero would abort the script under `set -e` at every call site below, since
# each one is a command substitution inside an assignment.
default_branch_checkout() {
    local branch checkout
    branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    branch=${branch#origin/}
    [ -n "$branch" ] || return 0
    checkout="$REPO_ROOT/$branch"
    if [ -d "$checkout" ] && [ "$checkout" != "$WORKTREE_ROOT" ]; then
        echo "$checkout"
    fi
    return 0
}

# The empty answer above must never be concatenated into a path: `"$(...)/x"`
# would probe the absolute `/x`, which is a different question that happens to
# answer "no" on this machine and is not something to depend on.
default_branch_path() {
    local base
    base="$(default_branch_checkout)"
    [ -n "$base" ] || return 0
    echo "$base/$1"
}

# ── ghostty ─────────────────────────────────────────────────────────────────
# The submodule's own checkout, then symlinks to the build artifacts. Without
# both, the build fails with `ld: library 'ghostty' not found` and the app
# refuses to start with `error: Ghostty resources not found at
# ghostty/zig-out/share/`.
setup_ghostty() {
    cd "$WORKTREE_ROOT"

    if [ ! -e ghostty/include ]; then
        # `--reference` borrows objects from a ghostty already checked out
        # elsewhere, so the ~90MB submodule is not re-fetched per worktree. It is
        # an optimization and never a requirement, and the candidates are
        # deliberately only the two *durable* ones: without `--dissociate` the
        # alternates file is a hard dependency on whatever it names, so
        # referencing a feature worktree would corrupt this one when that
        # worktree is purged. The main checkout of a plain clone is
        # `$REPO_ROOT/ghostty`; in the bare-repo layout it is the default
        # branch's own worktree. Neither present just means a full clone, which
        # is slower and not wrong — unlike pointing `--reference` at this
        # checkout's own empty `ghostty/`, which is what a plain clone did.
        local reference="" candidate
        for candidate in "$REPO_ROOT/ghostty" "$(default_branch_path ghostty)"; do
            if [ -n "$candidate" ] && [ "$candidate" != "$WORKTREE_ROOT/ghostty" ] &&
               [ -e "$candidate/include" ]; then
                reference="$candidate"
                break
            fi
        done

        if [ -n "$reference" ]; then
            git -c protocol.file.allow=always submodule update --init --reference "$reference" ghostty
        else
            git -c protocol.file.allow=always submodule update --init ghostty
        fi
        echo "✓ Initialized ghostty submodule"
    fi

    # The build artifacts are not in git and are not built per worktree. In the
    # bare-repo layout they live in `.shared/` beside the bare repo; in a plain
    # clone's worktree they sit in the main checkout's own ghostty. A plain clone
    # itself is its own root and builds them in place, so it links nothing.
    # Link at `.shared/` directly rather than at the default checkout's own links
    # into it, so this worktree survives that one being removed.
    # See docs/ghostty-xcframework-build.md.
    #
    # Relinked on every run, outside the init guard above: `git submodule update
    # --init` is listed as a prerequisite in CONTRIBUTING.md, so a contributor
    # who follows it arrives here with `ghostty/include` present and no links at
    # all. Gating these on the init would skip them in silence and fail the build
    # with `ld: library 'ghostty' not found` — the same shape as the bug this
    # replaced.
    if [ -d "$REPO_ROOT/.shared" ]; then
        ln -sfn "$REPO_ROOT/.shared/GhosttyKit.xcframework" ghostty/macos/GhosttyKit.xcframework
        ln -sfn "$REPO_ROOT/.shared/zig-out" ghostty/zig-out
        echo "✓ Linked ghostty build artifacts from .shared/"
    elif [ "$REPO_ROOT" != "$WORKTREE_ROOT" ] && [ -d "$REPO_ROOT/ghostty" ]; then
        ln -sfn "$REPO_ROOT/ghostty/macos/GhosttyKit.xcframework" ghostty/macos/GhosttyKit.xcframework
        ln -sfn "$REPO_ROOT/ghostty/zig-out" ghostty/zig-out
        echo "✓ Linked ghostty build artifacts from the main checkout"
    fi
}

# ── editor ──────────────────────────────────────────────────────────────────
# 26MB of vite output, gitignored, and a `bun install` away. Copy the default
# checkout's bundle instead of rebuilding it.
#
# **This step cannot fail the run, and that is the point of it being its own
# step.** It is purely a shortcut: `dev.sh build` runs `scripts/build-editor.sh`
# when the bundle is missing, so every way this can go wrong — nothing to copy
# from, or a copy that breaks halfway — has the same correct answer, which is to
# leave it to the build. Setup steps halt on the first failure, so if this
# reported one, a machine with no seed bundle would never reach `build` at all.
# Hence the `if ! cp ...` rather than a bare `cp`: under `set -e` a failing `cp`
# is not a value this function gets to inspect, it ends the script.
setup_editor() {
    cd "$WORKTREE_ROOT"

    if [ -f Resources/MonacoEditor/index.html ]; then
        return 0
    fi

    local seed
    seed="$(default_branch_path Resources/MonacoEditor)"
    if [ -z "$seed" ] || [ ! -f "$seed/index.html" ]; then
        echo "note: no Monaco bundle to copy — the build will run scripts/build-editor.sh (needs bun)"
        return 0
    fi

    # Staged, then moved into place. A `cp -R` straight onto the real path can
    # leave a partial bundle carrying an `index.html`, which is the one file
    # `dev.sh build` checks for — so a half-copy would suppress the rebuild that
    # is supposed to be the fallback, and the editor would load broken.
    #
    # `cp -R` rather than `rsync -a` on purpose: build-editor.sh decides by
    # mtime, and preserved times would look older than a freshly checked-out
    # `editor/` and trigger the rebuild this copy exists to skip.
    local staged="Resources/.MonacoEditor.staged.$$"
    rm -rf "$staged"
    mkdir -p "$staged"
    if ! cp -R "$seed/." "$staged/"; then
        rm -rf "$staged"
        echo "note: could not copy the Monaco bundle — the build will run scripts/build-editor.sh"
        return 0
    fi
    rm -rf Resources/MonacoEditor
    mv "$staged" Resources/MonacoEditor
    echo "✓ Copied the Monaco bundle from $seed"
}

# ── hooks ───────────────────────────────────────────────────────────────────
# Nothing installs prek: `uv tool run` fetches it per run. Never fatal — a
# missing uv is not a reason to leave the worktree unbuilt.
setup_hooks() {
    cd "$WORKTREE_ROOT"

    if [ ! -f prek.toml ]; then
        return 0
    fi
    if ! command -v uv >/dev/null 2>&1; then
        echo "note: uv is not installed — no prek hooks (brew install uv)"
        return 0
    fi
    if git config --get core.hooksPath >/dev/null 2>&1; then
        git config --local --unset-all core.hooksPath 2>/dev/null || true
    fi
    uv tool run prek install >/dev/null 2>&1 && echo "✓ prek hooks installed" || true
}

# ── build ───────────────────────────────────────────────────────────────────
# Build now, not at first Start: SourceKit resolves symbols across files from the
# build index, so an unbuilt worktree is one the editor and the Coding Agent both
# see wrong. Last of the four because it is the slowest and the likeliest to
# fail, so a failure here leaves a worktree that already links and runs.
setup_build() {
    cd "$WORKTREE_ROOT"

    # `dev.sh build` runs xcodegen itself, so this is a second run of it. Kept
    # deliberately: it is what reports "✓ Xcode project generated" and what
    # CONTRIBUTING.md says this script does, and it fails fast on a broken
    # `project.yml` instead of a minute into xcodebuild's startup. Pre-existing,
    # and not folded away here because that is a change to what the script
    # prints rather than to worktree setup.
    xcodegen generate && echo "✓ Xcode project generated"
    ./scripts/dev.sh build && echo "✓ Build succeeded"

    # buildServer.json points SourceKit-LSP at that index. Absolute paths, so it
    # is gitignored and per-worktree. Never fatal: the build above is the
    # expensive part and it has already succeeded, so a stale scheme here must
    # not report the whole step failed.
    if command -v xcode-build-server >/dev/null 2>&1; then
        xcode-build-server config -project Atelier.xcodeproj -scheme Atelier \
            --build_root build/debug/derived >/dev/null ||
            echo "note: xcode-build-server config failed — no buildServer.json"
    else
        echo "note: xcode-build-server not installed — no buildServer.json"
        echo "      brew install xcode-build-server"
    fi
}

case "${1:-all}" in
    ghostty) setup_ghostty ;;
    editor)  setup_editor ;;
    hooks)   setup_hooks ;;
    build)   setup_build ;;
    all)     setup_ghostty; setup_editor; setup_hooks; setup_build ;;
    *)
        echo "usage: ./scripts/setup.sh [ghostty|editor|hooks|build]" >&2
        echo "       no argument runs all four, in that order" >&2
        exit 2
        ;;
esac
