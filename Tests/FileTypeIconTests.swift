// ABOUTME: Tests for the file-tree icon lookup in FileTypeIcon and its generated tables.
// ABOUTME: Covers name/extension precedence, folder state, and that every asset the tables name exists.

import AppKit
@testable import Atelier
import XCTest

final class FileTypeIconTests: XCTestCase {
    // MARK: Files

    func testExactFileNameBeatsExtension() {
        // "cargo.toml" is keyed by name; ".toml" alone maps elsewhere.
        XCTAssertEqual(FileTypeIcon.icon(for: "Cargo.toml").assetName, "cargo")
        XCTAssertNotEqual(
            FileTypeIcon.icon(for: "settings.toml").assetName,
            "cargo",
            "A plain .toml should not borrow the Cargo icon"
        )
    }

    func testLookupIsCaseInsensitive() {
        // A few vscicons keys ship capitalised (CLAUDE.md, Cargo.toml, Rakefile),
        // so matching folds case on both sides.
        XCTAssertEqual(
            FileTypeIcon.icon(for: "cargo.toml").assetName,
            FileTypeIcon.icon(for: "CARGO.TOML").assetName
        )
        XCTAssertEqual(
            FileTypeIcon.icon(for: "readme.md").assetName,
            FileTypeIcon.icon(for: "README.md").assetName
        )
    }

    /// vscicons keys framework conventions as compound extensions — "service.ts",
    /// "spec.ts", "d.ts" — so `user.service.ts` is meant to read as a service
    /// rather than as plain TypeScript. Walking dots left to right tries the
    /// longest suffix first, which is what makes the specific key win.
    func testCompoundExtensionBeatsItsBareSuffix() {
        XCTAssertEqual(FileTypeIcon.icon(for: "user.service.ts").assetName, "angular-service")
        XCTAssertEqual(FileTypeIcon.icon(for: "user.spec.ts").assetName, "testts")
        XCTAssertEqual(FileTypeIcon.icon(for: "index.d.ts").assetName, "typescriptdef")
        XCTAssertEqual(FileTypeIcon.icon(for: "user.ts").assetName, "typescript")
    }

    /// The other half of the rule: a dotted name whose inner segments match no
    /// key must fall through to the bare extension rather than matching something
    /// adjacent. A too-eager walk would reach for a neighbouring icon here.
    func testDottedNameWithNoCompoundKeyFallsThroughToTheBareExtension() {
        for fileName in ["user.model.ts", "order.mapper.ts", "cart.total.ts"] {
            XCTAssertEqual(
                FileTypeIcon.icon(for: fileName).assetName,
                "typescript",
                "Expected \(fileName) to fall through to the TypeScript icon"
            )
        }
    }

    /// Tool configs are keyed by their whole name, which must beat both the
    /// compound-extension walk and the bare extension.
    func testToolConfigNamesWinOverTheExtensionWalk() {
        XCTAssertEqual(FileTypeIcon.icon(for: "vite.config.ts").assetName, "vite")
        XCTAssertEqual(FileTypeIcon.icon(for: "next.config.ts").assetName, "next")
    }

    /// The dot-prefixed extension keys (".travis.yml") are only reachable if the
    /// walk tries each dot *with* itself before stripping it.
    func testDotPrefixedExtensionKeyIsReachable() {
        XCTAssertEqual(FileTypeIcon.icon(for: ".travis.yml").assetName, "travis")
    }

    /// Guards the assertions above: an unknown extension must not resolve to
    /// something specific, or the matches elsewhere prove nothing.
    func testUnknownExtensionFallsBackToTheGenericFile() {
        XCTAssertEqual(
            FileTypeIcon.icon(for: "Inter.woatelier").assetName,
            FileIconCatalog.defaultFile
        )
        XCTAssertEqual(FileTypeIcon.icon(for: "noextension").assetName, FileIconCatalog.defaultFile)
    }

    /// A project-wide rename of "ff" to "atelier" once ate the middle of `woff2`,
    /// leaving `"woatelier"` in the font case and sending every web font to the
    /// generic icon. The table is generated now, but a mangled table is still a
    /// silent failure, so the guard stays.
    func testEveryFontExtensionGetsTheFontIcon() {
        for ext in ["ttf", "otf", "woff", "woff2"] {
            XCTAssertEqual(
                FileTypeIcon.icon(for: "Inter.\(ext)").assetName,
                "font",
                "Expected .\(ext) to map to the font icon"
            )
        }
    }

    func testCommonSourceExtensionsResolve() {
        let expected = [
            "main.swift": "swift",
            "index.ts": "typescript",
            "app.rb": "ruby",
            "main.go": "go",
            "lib.rs": "rust",
            "setup.py": "python",
            "Dockerfile": "docker",
        ]
        for (fileName, asset) in expected {
            XCTAssertEqual(
                FileTypeIcon.icon(for: fileName).assetName,
                asset,
                "Expected \(fileName) to map to \(asset)"
            )
        }
    }

    // MARK: Folders

    func testKnownFolderResolvesAndTracksExpansion() {
        let collapsed = FileTypeIcon.folderIcon(for: "src", isExpanded: false)
        let expanded = FileTypeIcon.folderIcon(for: "src", isExpanded: true)
        XCTAssertEqual(collapsed.assetName, "folder_src")
        XCTAssertEqual(expanded.assetName, "folder_src_open")
    }

    func testUnknownFolderFallsBackAndStillTracksExpansion() {
        XCTAssertEqual(
            FileTypeIcon.folderIcon(for: "zzz-not-a-real-folder", isExpanded: false).assetName,
            FileIconCatalog.defaultFolder
        )
        XCTAssertEqual(
            FileTypeIcon.folderIcon(for: "zzz-not-a-real-folder", isExpanded: true).assetName,
            FileIconCatalog.defaultFolderExpanded
        )
    }

    // MARK: Catalog integrity

    /// The tables and the asset catalog are generated from one source, so a
    /// missing asset means the two have drifted — which shows up as a blank row
    /// in the tree rather than an error.
    func testEveryAssetTheCatalogNamesExists() {
        var names = Set([
            FileIconCatalog.defaultFile,
            FileIconCatalog.defaultFolder,
            FileIconCatalog.defaultFolderExpanded,
        ])
        for table in [
            FileIconCatalog.fileNames,
            FileIconCatalog.fileExtensions,
            FileIconCatalog.folderNames,
            FileIconCatalog.folderNamesExpanded,
        ] {
            names.formUnion(table.values)
        }

        XCTAssertGreaterThan(names.count, 700, "Expected the full vscicons set to be generated")

        // NSImage(named:) resolves against the main bundle — the app, since these
        // tests are hosted in it — which is the same path SwiftUI's Image(_:)
        // takes in the tree.
        let missing = names.filter { NSImage(named: "FileIcons/\($0)") == nil }
        XCTAssertTrue(missing.isEmpty, "Assets named by the catalog but absent: \(missing.sorted())")
    }

    func testCatalogKeysAreAllLowercased() {
        for table in [
            FileIconCatalog.fileNames,
            FileIconCatalog.fileExtensions,
            FileIconCatalog.folderNames,
            FileIconCatalog.folderNamesExpanded,
        ] {
            let mixed = table.keys.filter { $0 != $0.lowercased() }
            XCTAssertTrue(mixed.isEmpty, "Keys must be folded to lowercase: \(mixed.sorted())")
        }
    }
}
