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

    // MARK: - Against the real bundle

    /// The tests above use a fabricated base. This one uses the bundle the app
    /// actually serves from, because the containment rule got *tighter* and its
    /// failure mode is silent: a rejected request becomes `didFailWithError`, and
    /// the editor pane just renders blank.
    func testEveryFileTheRealBundleShipsStillResolves() throws {
        let base = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("MonacoEditor")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: base.path),
            "MonacoEditor bundle is built by scripts/build-editor.sh"
        )

        let files = try FileManager.default
            .subpathsOfDirectory(atPath: base.path)
            .filter { !$0.hasSuffix(".DS_Store") }
            .filter { path in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: base.appendingPathComponent(path).path,
                    isDirectory: &isDirectory
                )
                return !isDirectory.boolValue
            }
        XCTAssertGreaterThan(files.count, 10, "Expected a populated Monaco bundle")

        for relativePath in files {
            let resolved = MonacoResourceSchemeHandler.resolve(requestPath: "/" + relativePath, in: base)
            XCTAssertNotNil(resolved, "\(relativePath) must still be servable")
            XCTAssertEqual(resolved?.path, base.appendingPathComponent(relativePath).path)
        }
    }

    /// The extensions WebKit is strict about — module scripts, stylesheets,
    /// fonts, wasm — must carry a real type when the bundle ships them. Data
    /// files Monaco `fetch()`es (`.txt`, `.tmlanguage`, `.code-snippets`) fall
    /// back to `application/octet-stream` and always have; `fetch` does not care,
    /// so this does not demand a type the handler never claimed to provide.
    func testTheEnforcedExtensionsTheRealBundleShipsCarryRealTypes() throws {
        let base = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("MonacoEditor")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: base.path))

        let enforced: [String: String] = [
            "js": "text/javascript",
            "mjs": "text/javascript",
            "css": "text/css",
            "wasm": "application/wasm",
            "ttf": "font/ttf",
            "woff": "font/woff",
            "woff2": "font/woff2",
        ]
        let shipped = try Set(
            FileManager.default.subpathsOfDirectory(atPath: base.path)
                .map { ($0 as NSString).pathExtension.lowercased() }
        )
        for (ext, expected) in enforced where shipped.contains(ext) {
            XCTAssertEqual(MonacoResourceSchemeHandler.mimeType(for: ext), expected)
        }
        XCTAssertFalse(shipped.isDisjoint(with: enforced.keys), "Expected a populated Monaco bundle")
    }
}
