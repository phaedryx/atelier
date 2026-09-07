#!/usr/bin/env bash
# ABOUTME: Claude Code worktree-create hook for Atelier.
# ABOUTME: Initializes ghostty submodule, symlinks build artifacts, and runs a build so SourceKit resolves symbols.
set -euo pipefail

: "${WORKTREE_DIR:?WORKTREE_DIR must be set}"
: "${CLAUDE_PROJECT_DIR:?CLAUDE_PROJECT_DIR must be set}"

# Ghostty submodule + build artifacts (built with zig, not in git)
if [ -d "$CLAUDE_PROJECT_DIR/ghostty" ]; then
    # Ensure submodule is checked out (may already be done by the global hook)
    if [ ! -e "$WORKTREE_DIR/ghostty/include" ]; then
        git -C "$WORKTREE_DIR" -c protocol.file.allow=always submodule update --init --reference "$CLAUDE_PROJECT_DIR/ghostty" ghostty
    fi
    # Symlink build artifacts (zig-out, xcframework) that aren't in git.
    # They live in `.shared/` beside the bare repo — see
    # docs/ghostty-xcframework-build.md. Link there directly rather than at the
    # main checkout's own links into it, so a worktree survives main being
    # removed. Fall back to the main checkout in a layout with no `.shared/`.
    SHARED_DIR="$(dirname "$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir)")/.shared"
    if [ -d "$SHARED_DIR" ]; then
        XCFRAMEWORK="$SHARED_DIR/GhosttyKit.xcframework"
        ZIG_OUT="$SHARED_DIR/zig-out"
    else
        XCFRAMEWORK="$CLAUDE_PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
        ZIG_OUT="$CLAUDE_PROJECT_DIR/ghostty/zig-out"
    fi
    ln -sfn "$XCFRAMEWORK" "$WORKTREE_DIR/ghostty/macos/GhosttyKit.xcframework"
    ln -sfn "$ZIG_OUT" "$WORKTREE_DIR/ghostty/zig-out"
fi

# Build so SourceKit can resolve symbols across files in the worktree.
# dev.sh runs xcodegen + xcodebuild with the shared SPM cache.
# After the build, generate buildServer.json so SourceKit-LSP can use the
# Xcode build index for cross-file type resolution.
# Runs in background to avoid blocking worktree creation.
cd "$WORKTREE_DIR"
nohup bash -c './scripts/dev.sh build && command -v xcode-build-server >/dev/null && xcode-build-server config -project Atelier.xcodeproj -scheme Atelier --build_root build/debug/derived' >/dev/null 2>&1 &
