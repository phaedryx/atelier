#!/usr/bin/env bash
# ABOUTME: Writes a version into project.yml's Info.plist properties.
# ABOUTME: Usage: ./scripts/set-version.sh <version>   e.g. ./scripts/set-version.sh 0.2.0

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Error: '$VERSION' is not a semver version (e.g. 0.2.0)" >&2; exit 1 ;;
esac

# The git tag is the source of truth for the shipped version, so this rewrites
# project.yml at build time rather than the version being committed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed -i.bak -E \
  -e "s|^([[:space:]]*CFBundleVersion:[[:space:]]*).*|\1\"${VERSION}\"|" \
  -e "s|^([[:space:]]*CFBundleShortVersionString:[[:space:]]*).*|\1\"${VERSION}\"|" \
  "$ROOT/project.yml"
rm -f "$ROOT/project.yml.bak"

grep -E 'CFBundleVersion|CFBundleShortVersionString' "$ROOT/project.yml"
