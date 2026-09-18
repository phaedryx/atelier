#!/usr/bin/env bash
# ABOUTME: Regenerates the file-tree icon assets and lookup tables from the Material Icon Theme extension.
# ABOUTME: Downloads a pinned .vsix, writes its imagesets, and emits Sources/Models/FileIconCatalog.swift.
set -euo pipefail

# Material Icon Theme (MIT, https://github.com/material-extensions/vscode-material-icon-theme)
# publishes a .vsix carrying both the SVGs and `dist/material-icons.json` — the
# canonical name/extension mapping. Reading that artifact avoids parsing the
# extension's TypeScript sources, which are inputs to its own build rather than
# the mapping itself.
THEME_VERSION="5.38.1"
THEME_SHA256="fa7515831a2d68b1f78bd02de40f96260bfe74efb03a238c2bde70265e04b696"
VSIX_URL="https://open-vsx.org/api/PKief/material-icon-theme/${THEME_VERSION}/file/PKief.material-icon-theme-${THEME_VERSION}.vsix"
THEME_MANIFEST="dist/material-icons.json"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ICONSET_DIR="$PROJECT_DIR/Resources/Assets.xcassets/FileIcons"
CATALOG_SWIFT="$PROJECT_DIR/Sources/Models/FileIconCatalog.swift"
LICENSE_OUT="$PROJECT_DIR/Resources/material-icon-theme-LICENSE.txt"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Downloading Material Icon Theme ${THEME_VERSION}"
curl -sSfL "$VSIX_URL" -o "$WORK_DIR/theme.vsix"

ACTUAL_SHA="$(shasum -a 256 "$WORK_DIR/theme.vsix" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA" != "$THEME_SHA256" ]; then
    echo "error: checksum mismatch for Material Icon Theme ${THEME_VERSION}" >&2
    echo "  expected $THEME_SHA256" >&2
    echo "  actual   $ACTUAL_SHA" >&2
    exit 1
fi

unzip -q "$WORK_DIR/theme.vsix" -d "$WORK_DIR/vsix"
EXTENSION_DIR="$WORK_DIR/vsix/extension"

echo "==> Generating imagesets and catalog"
ICONSET_DIR="$ICONSET_DIR" \
CATALOG_SWIFT="$CATALOG_SWIFT" \
EXTENSION_DIR="$EXTENSION_DIR" \
THEME_MANIFEST="$THEME_MANIFEST" \
THEME_VERSION="$THEME_VERSION" \
python3 "$SCRIPT_DIR/generate-file-icons.py"

# The upstream notice ships with CRLF line endings; normalise it so the
# repo's hooks do not rewrite it after every regenerate.
tr -d "\r" < "$EXTENSION_DIR/LICENSE.txt" > "$LICENSE_OUT"

echo "==> Done"
echo "    imagesets: $(find "$ICONSET_DIR" -name '*.imageset' | wc -l | tr -d ' ')"
echo "    catalog:   ${CATALOG_SWIFT#"$PROJECT_DIR"/}"
echo "    license:   ${LICENSE_OUT#"$PROJECT_DIR"/}"
