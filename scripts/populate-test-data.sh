#!/usr/bin/env bash
# ABOUTME: Populates UserDefaults with test projects for scrollbar testing.
# ABOUTME: Creates 30 fake projects pointing at /tmp directories.

set -e

# Create temp directories
for i in $(seq 1 30); do
  mkdir -p "/tmp/atelier-test-project-$i"
done

# Build JSON array of projects
PROJECTS="["
for i in $(seq 1 30); do
  ID=$(uuidgen)
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ $i -gt 1 ] && PROJECTS="$PROJECTS,"
  PROJECTS="$PROJECTS{\"id\":\"$ID\",\"name\":\"test-project-$i\",\"directory\":\"/tmp/atelier-test-project-$i\",\"workstreams\":[],\"lastAccessedAt\":\"$NOW\"}"
done
PROJECTS="$PROJECTS]"

# Write to UserDefaults
defaults write com.atelier.app atelier.projects -data "$(echo "$PROJECTS" | python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.read().encode())')"

echo "Added 30 test projects. Restart atelier to see them."
echo "To remove: defaults delete com.atelier.app atelier.projects"
