// ABOUTME: Tests for the file-tree icon table in FileTypeIcon.
// ABOUTME: Covers the font extensions, which a project-wide rename silently corrupted.

@testable import Atelier
import XCTest

final class FileTypeIconTests: XCTestCase {
    /// A project-wide rename of "ff" to "atelier" ate the middle of `woff2`, leaving
    /// `"woatelier"` in the font case. `.woff2` is the common web-font extension, so
    /// every one of them fell through to the generic `doc` icon.
    func testWoff2GetsTheFontIcon() {
        XCTAssertEqual(FileTypeIcon.icon(for: "Inter.woff2").symbolName, "textformat")
    }

    func testEveryFontExtensionGetsTheFontIcon() {
        for ext in ["ttf", "otf", "woff", "woff2"] {
            XCTAssertEqual(
                FileTypeIcon.icon(for: "Inter.\(ext)").symbolName,
                "textformat",
                "Expected .\(ext) to map to the font icon"
            )
        }
    }

    /// Guards the assertion above: the font cases are meaningful only because an
    /// unknown extension does *not* return "textformat".
    func testAnUnknownExtensionFallsBackToTheGenericIcon() {
        XCTAssertEqual(FileTypeIcon.icon(for: "Inter.woatelier").symbolName, "doc")
    }
}
