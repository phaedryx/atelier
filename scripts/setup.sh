#!/usr/bin/env bash
# ABOUTME: Workstream setup for Atelier development.
# ABOUTME: Initializes ghostty submodule, symlinks build artifacts, and runs a debug build.
set -euo pipefail

# The repository's home, the way .hooks/worktree-create.sh resolves it. In the
# README's bare-repo layout the common dir is `<container>/.bare`, so this is
# the container holding every worktree — the directory `.shared/` sits beside.
# `git worktree list | head -1` named `.bare` itself there, which holds no
# ghostty and no .shared, so everything below was silently skipped.
# Assigned in two steps so a failing `git` aborts under `set -e`: `dirname` of
# nothing is `.`, and the exit status of the outer capture would be dirname's.
GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
REPO_ROOT=$(dirname "$GIT_COMMON_DIR")
WORKTREE_ROOT=$(git rev-parse --show-toplevel)

# Ghostty submodule (headers + xcframework)
if [ ! -e ghostty/include ]; then
    # `--reference` borrows objects from a ghostty already checked out
    # elsewhere, so the ~90MB submodule is not re-fetched per worktree. It is an
    # optimization and never a requirement, and the candidates are deliberately
    # only the two *durable* ones: without `--dissociate` the alternates file is
    # a hard dependency on whatever it names, so referencing a feature worktree
    # would corrupt this one when that worktree is purged. The main checkout of
    # a plain clone is `$REPO_ROOT/ghostty`; in the bare-repo layout a worktree
    # is spelled like its branch, so the default branch's checkout is
    # `$REPO_ROOT/<default-branch>/ghostty`. Neither present just means a full
    # clone, which is slower and not wrong — unlike pointing `--reference` at
    # this checkout's own empty `ghostty/`, which is what a plain clone did.
    DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    DEFAULT_BRANCH=${DEFAULT_BRANCH#origin/}
    REFERENCE=""
    for candidate in "$REPO_ROOT/ghostty" "$REPO_ROOT/${DEFAULT_BRANCH:-.}/ghostty"; do
        if [ "$candidate" != "$WORKTREE_ROOT/ghostty" ] && [ -e "$candidate/include" ]; then
            REFERENCE="$candidate"
            break
        fi
    done

    if [ -n "$REFERENCE" ]; then
        git -c protocol.file.allow=always submodule update --init --reference "$REFERENCE" ghostty
    else
        git -c protocol.file.allow=always submodule update --init ghostty
    fi
    echo "✓ Initialized ghostty submodule"
fi

# The build artifacts are not in git and are not built per worktree. In the
# bare-repo layout they live in `.shared/` beside the bare repo; in a plain
# clone's worktree they sit in the main checkout's own ghostty. A plain clone
# itself is its own root and builds them in place, so it links nothing.
# See docs/ghostty-xcframework-build.md.
#
# Relinked on every run, outside the init guard above, the way
# .hooks/worktree-create.sh does it: `git submodule update --init` is listed as
# a prerequisite in CONTRIBUTING.md, so a contributor who follows it arrives
# here with `ghostty/include` present and no links at all. Gating these on the
# init would skip them in silence and fail the build with
# `ld: library 'ghostty' not found` — the same shape as the bug this replaced.
if [ -d "$REPO_ROOT/.shared" ]; then
    ln -sfn "$REPO_ROOT/.shared/GhosttyKit.xcframework" ghostty/macos/GhosttyKit.xcframework
    ln -sfn "$REPO_ROOT/.shared/zig-out" ghostty/zig-out
elif [ "$REPO_ROOT" != "$WORKTREE_ROOT" ] && [ -d "$REPO_ROOT/ghostty" ]; then
    ln -sfn "$REPO_ROOT/ghostty/macos/GhosttyKit.xcframework" ghostty/macos/GhosttyKit.xcframework
    ln -sfn "$REPO_ROOT/ghostty/zig-out" ghostty/zig-out
fi

# Pre-commit hooks
if [ -f prek.toml ] && command -v uv >/dev/null 2>&1; then
    if git -C . config --get core.hooksPath >/dev/null 2>&1; then
        git config --local --unset-all core.hooksPath 2>/dev/null || true
    fi
    uv tool run prek install 2>/dev/null && echo "✓ prek hooks installed" || true
fi

# Generate Xcode project and build
xcodegen generate && echo "✓ Xcode project generated"
./scripts/dev.sh build && echo "✓ Build succeeded"
