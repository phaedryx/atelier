#!/usr/bin/env bash
# ABOUTME: Development convenience script for Atelier.
# ABOUTME: Usage: ./scripts/dev.sh [build|run|test|clean]

set -e

PROJECT="Atelier.xcodeproj"
SCHEME="Atelier"
TEST_SCHEME="Atelier"
APP_NAME="Atelier"
BUILD_DIR="build/debug/derived"
APP_PATH="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
SPM_CACHE="$HOME/Library/Caches/atelier/spm"
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
GHOSTTY_RESOURCES="ghostty/zig-out/share"
MONACO_OUTPUT="Resources/MonacoEditor/index.html"

ensure_ghostty_resources() {
  if [ ! -d "$GHOSTTY_RESOURCES/terminfo" ] || [ ! -d "$GHOSTTY_RESOURCES/ghostty" ]; then
    echo "error: Ghostty resources not found at $GHOSTTY_RESOURCES/"
    echo "       Build the xcframework first: cd ghostty && zig build"
    exit 1
  fi
}

# The version a local Release build reports. `--match` keeps the answer on
# release tags only, so a stray tag cannot become the version; `--dirty` marks a
# build made over uncommitted changes, which is otherwise indistinguishable from
# the commit it was built on. With no matching tag in the history at all
# `describe` fails, and the sha alone is not a version set-version.sh accepts.
#
# `--first-parent` makes the count "PRs merged since the tag" rather than
# "commits reachable since the tag". Without it every commit that arrived inside
# a merged PR branch is counted too, so three days and 27 merges past v0.2.1 read
# as `0.2.1-95` — a number that looks like months of history and tells a reader
# nothing they can act on. The `-g<sha>` suffix is what identifies the build; the
# count is only meant to say roughly how far past the tag it is.
release_version() {
  local described
  described="$(git describe --tags --first-parent --match 'v[0-9]*.[0-9]*.[0-9]*' --dirty 2>/dev/null || true)"
  if [ -n "$described" ]; then
    echo "${described#v}"
  else
    echo "0.0.0-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi
}

ensure_monaco_editor() {
  if [ ! -f "$MONACO_OUTPUT" ]; then
    echo "info: Monaco editor not built, running scripts/build-editor.sh..."
    bash scripts/build-editor.sh
  fi
}

case "${1:-build}" in
  build)
    ensure_ghostty_resources
    ensure_monaco_editor
    xcodegen generate
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$SPM_CACHE" \
      -skipPackagePluginValidation \
      CURRENT_PROJECT_VERSION="$BRANCH" build
    ;;
  run)
    shift 2>/dev/null || true
    pkill -xf ".*/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 0.5
    if [ -n "${1:-}" ]; then
      DIR=$(cd "$1" && pwd)
      open "$APP_PATH" --args "$DIR"
    else
      open "$APP_PATH"
    fi
    ;;
  full)
    shift 2>/dev/null || true
    echo "==> Building and running Atelier..."
    xcodegen generate
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$SPM_CACHE" \
      CURRENT_PROJECT_VERSION="$BRANCH" build
    pkill -xf ".*/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 0.5
    if [ -n "${1:-}" ]; then
      DIR=$(cd "$1" && pwd)
      open "$APP_PATH" --args "$DIR"
    else
      open "$APP_PATH"
    fi
    ;;
  br)
    shift 2>/dev/null || true
    ensure_ghostty_resources
    ensure_monaco_editor
    xcodegen generate
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$SPM_CACHE" \
      -skipPackagePluginValidation \
      CURRENT_PROJECT_VERSION="$BRANCH" build
    pkill -xf ".*/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 0.5
    if [ -n "${1:-}" ]; then
      DIR=$(cd "$1" && pwd)
      open "$APP_PATH" --args "$DIR"
    else
      open "$APP_PATH"
    fi
    ;;
  test)
    ensure_ghostty_resources
    ensure_monaco_editor
    xcodegen generate
    # Tee the log so we can assert tests actually ran. xcodebuild exits 0 and
    # prints "** TEST SUCCEEDED **" even when the scheme selects zero tests,
    # which once let a broken scheme pass CI for four PRs.
    TEST_LOG=$(mktemp)
    trap 'rm -f "$TEST_LOG"' EXIT
    set -o pipefail
    xcodebuild -project "$PROJECT" -scheme "$TEST_SCHEME" -configuration Debug \
      -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$SPM_CACHE" \
      -skipPackagePluginValidation test | tee "$TEST_LOG"
    executed=$(grep -oE 'Executed [0-9]+ test' "$TEST_LOG" | grep -oE '[0-9]+' | sort -rn | head -1)
    if [ -z "$executed" ] || [ "$executed" -eq 0 ]; then
      echo "error: the test run executed 0 tests. The scheme is not selecting the" >&2
      echo "       AtelierTests bundle -- check the 'schemes' block in project.yml." >&2
      exit 1
    fi
    echo "Executed $executed tests."
    ;;
  release)
    RELEASE_DIR="build/release-local/derived"
    # ARCHS=arm64 for the same reason release.yml pins it: a Release build
    # otherwise takes ARCHS_STANDARD (arm64 + x86_64), and libghostty.a is a
    # thin arm64 archive, so the x86_64 half fails to link on every ghostty_*
    # symbol -- and would ship for no one even if it linked.
    ensure_ghostty_resources
    ensure_monaco_editor
    # Stamp the version the same way the release workflow does, but derived from
    # git rather than from a tag that does not exist yet. A local Release build is
    # a build someone installs and then has to identify later, and the committed
    # placeholder makes every one of them claim 0.0.0-dev. `git describe` says
    # what it actually is -- `0.2.1-76-gbe4598a`, or `0.2.1-dirty` for a build
    # made over uncommitted changes -- and cannot be mistaken for a release.
    #
    # project.yml is restored from a copy rather than with `git checkout --`,
    # because this runs often enough that discarding an uncommitted edit to it
    # would be a real loss. The trap also covers set-version.sh rejecting the
    # version, which exits non-zero under `set -e` with the file half-written.
    VERSION="$(release_version)"
    PROJECT_YML_BACKUP="$(mktemp)"
    cp project.yml "$PROJECT_YML_BACKUP"
    trap 'cp "$PROJECT_YML_BACKUP" project.yml; rm -f "$PROJECT_YML_BACKUP"' EXIT
    echo "==> Stamping version $VERSION"
    ./scripts/set-version.sh "$VERSION" >/dev/null
    xcodegen generate
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
      -derivedDataPath "$RELEASE_DIR" -clonedSourcePackagesDirPath "$SPM_CACHE" \
      -skipPackagePluginValidation \
      ARCHS=arm64 \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGN_STYLE=Manual \
      ENABLE_HARDENED_RUNTIME=YES \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      CODE_SIGN_ENTITLEMENTS=Resources/atelier-local.entitlements \
      OTHER_CODE_SIGN_FLAGS="--options=runtime" \
      build
    APP_BUNDLE="$RELEASE_DIR/Build/Products/Release/Atelier.app"
    echo "==> Release build at: $APP_BUNDLE"
    if [ "${2:-}" = "--run" ]; then
      pkill -xf ".*/Contents/MacOS/Atelier" 2>/dev/null || true
      sleep 0.5
      open "$RELEASE_DIR/Build/Products/Release/Atelier.app"
    fi
    ;;
  clean)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug clean 2>/dev/null || true
    rm -rf build/debug build/release-local "$SPM_CACHE"
    ;;
  *)
    echo "Usage: ./scripts/dev.sh [command] [directory]"
    echo ""
    echo "  build    Build (debug)"
    echo "  run      Kill and relaunch (optionally with a directory)"
    echo "  br       Build and run"
    echo "  full     Build and run (same as br)"
    echo "  test     Run tests"
    echo "  release  Build Release matching CI (hardened runtime)"
    echo "  release --run  Build and run Release"
    echo "  clean    Clean build artifacts"
    ;;
esac
