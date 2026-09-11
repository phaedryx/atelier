#!/usr/bin/env bash
# ABOUTME: Writes a version into project.yml's Info.plist properties.
# ABOUTME: Usage: ./scripts/set-version.sh <version>   e.g. ./scripts/set-version.sh 0.2.0

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

# A release passes a bare `0.2.0`; a local build passes what `git describe`
# produced, e.g. `0.2.1-76-gbe4598a`. Both are accepted, and they are written to
# *different* keys: CFBundleVersion must be period-separated integers, so it
# only ever gets the `X.Y.Z` core, while CFBundleShortVersionString — the string
# the app displays — carries the suffix that says which commit this is.
if [[ ! "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: '$VERSION' is not a version (e.g. 0.2.0 or 0.2.1-76-gbe4598a)" >&2
  exit 1
fi
CORE="${BASH_REMATCH[1]}"

# The git tag is the source of truth for the shipped version, so this rewrites
# project.yml at build time rather than the version being committed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed -i.bak -E \
  -e "s|^([[:space:]]*CFBundleVersion:[[:space:]]*).*|\1\"${CORE}\"|" \
  -e "s|^([[:space:]]*CFBundleShortVersionString:[[:space:]]*).*|\1\"${VERSION}\"|" \
  "$ROOT/project.yml"
rm -f "$ROOT/project.yml.bak"

grep -E 'CFBundleVersion|CFBundleShortVersionString' "$ROOT/project.yml"
