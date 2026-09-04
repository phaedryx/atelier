// ABOUTME: Tests for the Monaco asset server's path containment and MIME mapping.
// ABOUTME: A sibling directory must not be reachable, and .woff2 must be served as a real font type.

@testable import Atelier
import XCTest

final class MonacoResourceSchemeHandlerTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Apps/Atelier.app/Contents/Resources/MonacoEditor")

    // MARK: - Containment

    func testResolvesAFileInsideTheBundle() {
        let resolved = MonacoResourceSchemeHandler.resolve(requestPath: "/vs/loader.js", in: base)
        XCTAssertEqual(resolved?.path, "/Apps/Atelier.app/Contents/Resources/MonacoEditor/vs/loader.js")
    }

    func testRejectsATraversalOutOfTheBundle() {
        XCTAssertNil(MonacoResourceSchemeHandler.resolve(requestPath: "/../../../etc/passwd", in: base))
    }

    /// `hasPrefix` on the bare base path is true for any sibling whose name
    /// merely *starts* with it, so `MonacoEditor-evil/` passed containment.
    func testRejectsASiblingDirectoryThatSharesThePrefix() {
        XCTAssertNil(
            MonacoResourceSchemeHandler.resolve(requestPath: "/../MonacoEditor-evil/payload.js", in: base)
        )
    }

    func testTheBaseDirectoryItselfIsNotAFileToServe() {
        XCTAssertNil(MonacoResourceSchemeHandler.resolve(requestPath: "/", in: base))
    }

    // MARK: - MIME types

    /// `"woatelier"` — collateral from a project-wide rename of "ff" to "atelier"
    /// that ate the middle of `woff2`. WebKit rejects `font/woatelier`, so the
    /// editor's fonts never loaded.
    func testWoff2IsServedAsARealFontType() {
        XCTAssertEqual(MonacoResourceSchemeHandler.mimeType(for: "woff2"), "font/woff2")
    }

    func testNoMimeTypeStillCarriesTheManglingArtifact() {
        for ext in ["html", "js", "mjs", "css", "json", "wasm", "ttf", "woff", "woff2", "svg", "png"] {
            let type = MonacoResourceSchemeHandler.mimeType(for: ext)
            XCTAssertFalse(type.contains("atelier"), "\(ext) maps to \(type)")
            XCTAssertNotEqual(type, "application/octet-stream", "\(ext) should have a real type")
        }
    }

    func testUnknownExtensionsFallBackToOctetStream() {
        XCTAssertEqual(MonacoResourceSchemeHandler.mimeType(for: "xyz"), "application/octet-stream")
    }

    func testExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(MonacoResourceSchemeHandler.mimeType(for: "WOFF2"), "font/woff2")
    }
}
