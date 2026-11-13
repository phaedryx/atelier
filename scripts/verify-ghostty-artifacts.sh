#!/usr/bin/env bash
# ABOUTME: Checks the ghostty build artifacts the app needs, reading names from the xcframework.
# ABOUTME: Used by ci.yml, test-ghostty.yml and release.yml right after the zig build.
#
# The library's file name and slice directory are read from the xcframework's
# Info.plist, never assumed. Since ghostty v1.4.0 the two xcframework targets
# disagree on both: `native` writes `macos-arm64/libghostty-internal.a`,
# `universal` writes `macos-arm64_x86_64/ghostty-internal.a`. A check that names
# either one passes for one target and fails for the other — or, worse, the old
# check only tested that directories existed, so a slice without the library
# passed here and failed ten minutes later at link.
#
# Prints the slice's library path on success; exits non-zero naming each
# missing artifact otherwise.
set -euo pipefail

root="${1:-ghostty}"
xcf="$root/macos/GhosttyKit.xcframework"
plist="$xcf/Info.plist"
fail=0

if [ ! -f "$plist" ]; then
    echo "error: no $plist" >&2
    fail=1
else
    # The macOS entry; the xcframework carries no other platform today, but
    # match it rather than take index 0 on trust.
    count=$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$plist" | grep -c 'LibraryIdentifier')
    lib=""
    for i in $(seq 0 $((count - 1))); do
        platform=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:SupportedPlatform" "$plist")
        if [ "$platform" = "macos" ]; then
            id=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:LibraryIdentifier" "$plist")
            name=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:LibraryPath" "$plist")
            lib="$xcf/$id/$name"
            break
        fi
    done
    if [ -z "$lib" ]; then
        echo "error: $plist lists no macos library" >&2
        fail=1
    elif [ ! -f "$lib" ]; then
        echo "error: $plist names $lib, which does not exist" >&2
        ls -la "$(dirname "$lib")" >&2 || true
        fail=1
    fi
fi

for dir in terminfo ghostty; do
    if [ ! -d "$root/zig-out/share/$dir" ]; then
        echo "error: no $root/zig-out/share/$dir" >&2
        fail=1
    fi
done

[ "$fail" -eq 0 ] || exit 1
lipo -info "$lib" >&2
echo "$lib"
