#!/usr/bin/env python3
# ABOUTME: Turns an unpacked vscicons extension into Xcode imagesets plus a Swift lookup table.
# ABOUTME: Driven by generate-file-icons.sh, which owns the download, checksum, and version pin.
"""Emit Assets.xcassets/FileIcons/ and Sources/Models/FileIconCatalog.swift.

`icons.json` maps names and extensions to *icon definition ids* (`_f_swift`),
which in turn point at SVG paths. Those ids are an implementation detail of the
extension, so they are resolved here and the Swift table maps straight to asset
names.
"""

import json
import os
import shutil
import sys
from pathlib import Path

ICONSET_DIR = Path(os.environ["ICONSET_DIR"])
CATALOG_SWIFT = Path(os.environ["CATALOG_SWIFT"])
EXTENSION_DIR = Path(os.environ["EXTENSION_DIR"])
VSCICONS_VERSION = os.environ["VSCICONS_VERSION"]
FOLDER_BODY_FROM = os.environ["FOLDER_BODY_FROM"]
FOLDER_BODY_TO = os.environ["FOLDER_BODY_TO"]

theme = json.loads((EXTENSION_DIR / "icons.json").read_text())
definitions = theme["iconDefinitions"]


def asset_name(definition_id):
    """Resolve an icon definition id to the SVG basename used as the asset name."""
    definition = definitions.get(definition_id)
    if definition is None:
        return None
    return Path(definition["iconPath"]).stem


dropped = []


def resolve(table):
    """Lowercase keys and resolve values, dropping entries with no definition."""
    resolved = {}
    for key, definition_id in sorted(table.items()):
        name = asset_name(definition_id)
        if name is None:
            # A mapping entry pointing at a definition the theme no longer
            # declares. Silently dropping it would make an icon disappear on a
            # version bump with nothing to notice, so it is reported below.
            dropped.append(f"{key} -> {definition_id}")
            continue
        # A handful of keys ship capitalised (CLAUDE.md, Cargo.toml, Rakefile).
        # Matching is case-insensitive, so fold them here and let the first
        # spelling win — the duplicates in this set all agree on their icon.
        resolved.setdefault(key.lower(), name)
    return resolved


file_names = resolve(theme["fileNames"])
file_extensions = resolve(theme["fileExtensions"])
folder_names = resolve(theme["folderNames"])
folder_names_expanded = resolve(theme["folderNamesExpanded"])

defaults = {
    "file": asset_name(theme["file"]),
    "folder": asset_name(theme["folder"]),
    "folderExpanded": asset_name(theme["folderExpanded"]),
}
missing_defaults = [key for key, value in defaults.items() if value is None]
if missing_defaults:
    sys.exit(f"error: theme has no definition for default(s): {missing_defaults}")

# Only ship icons something can actually reach, so the asset catalog and the
# lookup tables cannot drift apart.
referenced = set(defaults.values())
for table in (file_names, file_extensions, folder_names, folder_names_expanded):
    referenced.update(table.values())

# ---------------------------------------------------------------- imagesets

if ICONSET_DIR.exists():
    shutil.rmtree(ICONSET_DIR)
ICONSET_DIR.mkdir(parents=True)

# `provides-namespace` keeps these 776 names in a "FileIcons/" prefix so they
# cannot collide with the app's own assets (github, shortcut, AppIcon).
(ICONSET_DIR / "Contents.json").write_text(
    json.dumps(
        {
            "info": {"author": "xcode", "version": 1},
            "properties": {"provides-namespace": True},
        },
        indent=2,
    )
    + "\n"
)

recoloured = 0
for name in sorted(referenced):
    source = EXTENSION_DIR / "icons" / f"{name}.svg"
    if not source.exists():
        sys.exit(f"error: {name} is referenced by the theme but has no SVG")

    svg = source.read_text()
    if FOLDER_BODY_FROM.lstrip("#") in svg:
        svg = svg.replace(FOLDER_BODY_FROM.lstrip("#"), FOLDER_BODY_TO.lstrip("#"))
        recoloured += 1

    # Most of the upstream SVGs have no trailing newline, which the repo's
    # end-of-file-fixer hook would rewrite on every commit after a regenerate.
    if not svg.endswith("\n"):
        svg += "\n"

    imageset = ICONSET_DIR / f"{name}.imageset"
    imageset.mkdir()
    (imageset / f"{name}.svg").write_text(svg)
    (imageset / "Contents.json").write_text(
        json.dumps(
            {
                "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                # Vector data is preserved so a single SVG serves every size, and
                # no rendering intent is set — the call site chooses .original or
                # .template per colour scheme.
                "properties": {"preserves-vector-representation": True},
            },
            indent=2,
        )
        + "\n"
    )

# ------------------------------------------------------------------- swift


def swift_dictionary(name, table):
    lines = [f"    static let {name}: [String: String] = ["]
    for key, value in sorted(table.items()):
        escaped = key.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'        "{escaped}": "{value}",')
    lines.append("    ]")
    return "\n".join(lines)


body = "\n\n".join(
    [
        swift_dictionary("fileNames", file_names),
        swift_dictionary("fileExtensions", file_extensions),
        swift_dictionary("folderNames", folder_names),
        swift_dictionary("folderNamesExpanded", folder_names_expanded),
    ]
)

CATALOG_SWIFT.write_text(
    f"""// ABOUTME: Generated file-tree icon tables from the vscicons extension — do not edit by hand.
// ABOUTME: Regenerate with scripts/generate-file-icons.sh; see FileTypeIcon for the lookup rules.

/// Name and extension tables lifted from vscicons {VSCICONS_VERSION} (MIT).
///
/// Keys are lowercased; values are asset names inside the `FileIcons` namespace
/// of `Resources/Assets.xcassets`. `FileTypeIcon` owns the matching rules.
enum FileIconCatalog {{
    static let version = "{VSCICONS_VERSION}"

    static let defaultFile = "{defaults["file"]}"
    static let defaultFolder = "{defaults["folder"]}"
    static let defaultFolderExpanded = "{defaults["folderExpanded"]}"

{body}
}}
"""
)

if dropped:
    print(f"    warning: {len(dropped)} mapping entries name an undeclared definition")
    for entry in dropped[:10]:
        print(f"      {entry}")

print(f"    {len(referenced)} imagesets ({recoloured} folder bodies recoloured)")
print(
    f"    {len(file_names)} file names, {len(file_extensions)} extensions, "
    f"{len(folder_names)} folders, {len(folder_names_expanded)} expanded folders"
)
