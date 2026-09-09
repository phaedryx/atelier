#!/usr/bin/env bash
# ABOUTME: Regenerates the file-tree icon assets and lookup tables from the vscicons extension.
# ABOUTME: Downloads a pinned .vsix, writes 776 imagesets, and emits Sources/Models/FileIconCatalog.swift.
set -euo pipefail

# vscicons (MIT, https://github.com/yusifaliyevpro/vscode-icons) publishes a
# .vsix carrying both the SVGs and `icons.json` — the canonical name/extension
# mapping. Reading that artifact avoids parsing the extension's TypeScript
# sources, which are inputs to its own build rather than the mapping itself.
VSCICONS_VERSION="1.2.10"
VSCICONS_SHA256="c20d620aaf782f438b48f3f1e9fb0294f337e41924181832e7b12d0ce726edfb"
VSIX_URL="https://open-vsx.org/api/yusifaliyevpro/vscicons/${VSCICONS_VERSION}/file/yusifaliyevpro.vscicons-${VSCICONS_VERSION}.vsix"

# Every folder icon draws its body in this one colour, a mid-dark warm grey that
# assumes VS Code's sidebar. On Atelier's dark sidebar it is nearly invisible, so
# the body is lightened on the way in. Light mode renders these as template
# images (alpha only), so the substitution is invisible there.
FOLDER_BODY_FROM="#45403d"
FOLDER_BODY_TO="#7c766f"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ICONSET_DIR="$PROJECT_DIR/Resources/Assets.xcassets/FileIcons"
CATALOG_SWIFT="$PROJECT_DIR/Sources/Models/FileIconCatalog.swift"
LICENSE_OUT="$PROJECT_DIR/Resources/vscicons-LICENSE.txt"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Downloading vscicons ${VSCICONS_VERSION}"
curl -sSfL "$VSIX_URL" -o "$WORK_DIR/vscicons.vsix"

ACTUAL_SHA="$(shasum -a 256 "$WORK_DIR/vscicons.vsix" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA" != "$VSCICONS_SHA256" ]; then
    echo "error: checksum mismatch for vscicons ${VSCICONS_VERSION}" >&2
    echo "  expected $VSCICONS_SHA256" >&2
    echo "  actual   $ACTUAL_SHA" >&2
    exit 1
fi

unzip -q "$WORK_DIR/vscicons.vsix" -d "$WORK_DIR/vsix"
EXTENSION_DIR="$WORK_DIR/vsix/extension"

echo "==> Generating imagesets and catalog"
ICONSET_DIR="$ICONSET_DIR" \
CATALOG_SWIFT="$CATALOG_SWIFT" \
EXTENSION_DIR="$EXTENSION_DIR" \
VSCICONS_VERSION="$VSCICONS_VERSION" \
FOLDER_BODY_FROM="$FOLDER_BODY_FROM" \
FOLDER_BODY_TO="$FOLDER_BODY_TO" \
python3 "$SCRIPT_DIR/generate-file-icons.py"

# The upstream notice ships with CRLF line endings; normalise it so the
# repo's hooks do not rewrite it after every regenerate.
tr -d "\r" < "$EXTENSION_DIR/LICENSE.txt" > "$LICENSE_OUT"

echo "==> Done"
echo "    imagesets: $(find "$ICONSET_DIR" -name '*.imageset' | wc -l | tr -d ' ')"
echo "    catalog:   ${CATALOG_SWIFT#"$PROJECT_DIR"/}"
echo "    license:   ${LICENSE_OUT#"$PROJECT_DIR"/}"
