// ABOUTME: Resolves file and folder names to vscicons assets for the file tree.
// ABOUTME: Holds the matching rules only; the lookup tables live in the generated FileIconCatalog.

import SwiftUI

/// The icon for one file-tree row.
///
/// Icons carry their own brand colours, which read well on the dark sidebar but
/// fight the light one, so the tree draws them as template images in light mode
/// — see `FileTreeView`. That works because each icon is a silhouette: tinting
/// uses the alpha channel, so the glyph survives even where the artwork is a
/// filled tile with knocked-out detail.
struct FileTypeIcon: Equatable {
    /// Asset name within the `FileIcons` namespace.
    let assetName: String

    /// The name to hand `Image(_:)`, including the catalog namespace.
    var resourceName: String {
        "FileIcons/\(assetName)"
    }

    static func icon(for fileName: String) -> FileTypeIcon {
        let name = fileName.lowercased()

        if let asset = FileIconCatalog.fileNames[name] {
            return FileTypeIcon(assetName: asset)
        }

        // Extensions are keyed both bare ("ts") and compound ("component.ts",
        // ".travis.yml"). Walking the dots left to right tries the most
        // specific suffix first; each dot is tried with and without itself so
        // the dot-prefixed keys stay reachable.
        var searchStart = name.startIndex
        while let dot = name[searchStart...].firstIndex(of: ".") {
            let afterDot = name.index(after: dot)
            for candidate in [String(name[dot...]), String(name[afterDot...])] {
                if let asset = FileIconCatalog.fileExtensions[candidate] {
                    return FileTypeIcon(assetName: asset)
                }
            }
            if afterDot == name.endIndex {
                break
            }
            searchStart = afterDot
        }

        return FileTypeIcon(assetName: FileIconCatalog.defaultFile)
    }

    static func folderIcon(for folderName: String, isExpanded: Bool) -> FileTypeIcon {
        let name = folderName.lowercased()
        let table = isExpanded ? FileIconCatalog.folderNamesExpanded : FileIconCatalog.folderNames
        if let asset = table[name] {
            return FileTypeIcon(assetName: asset)
        }
        let fallback = isExpanded
            ? FileIconCatalog.defaultFolderExpanded
            : FileIconCatalog.defaultFolder
        return FileTypeIcon(assetName: fallback)
    }
}
