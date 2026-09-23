// ABOUTME: Containment for the board asset scheme, mirroring the Monaco handler's shape.
// ABOUTME: A request must never resolve outside the board's own assets directory.

@testable import Atelier
import XCTest

final class WhiteboardAssetSchemeHandlerTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func test_resolvesAFileThatIsReallyInside() throws {
        let file = base.appendingPathComponent("a.png")
        try Data([0x89]).write(to: file)
        XCTAssertEqual(
            Whiteboard.AssetSchemeHandler.resolve(requestPath: "/a.png", in: base)?.path,
            file.resolvingSymlinksInPath().path
        )
    }

    func test_refusesATraversalOutOfTheAssetsDirectory() {
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(
            requestPath: "/../../etc/passwd", in: base
        ))
    }

    func test_refusesASiblingWhoseNameMerelyStartsWithTheBase() throws {
        // A bare hasPrefix makes `<base>-evil` a child of `<base>`. The separator
        // is the whole of the containment rule.
        let evil = URL(fileURLWithPath: base.path + "-evil")
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evil) }
        try Data([0x00]).write(to: evil.appendingPathComponent("payload.png"))
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(
            requestPath: "/../\(evil.lastPathComponent)/payload.png", in: base
        ))
    }

    func test_refusesASymlinkPlantedInsideThatPointsOut() throws {
        // Resolving is the half a lexical `.standardized` cannot do: it collapses
        // `..` textually and never follows a link, so a symlink planted inside
        // the assets directory keeps every path component of the base — passing
        // containment — while pointing anywhere on disk.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.png")
        try Data([0x01]).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link.png"), withDestinationURL: secret
        )
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(requestPath: "/link.png", in: base))
    }

    func test_refusesTheAssetsDirectoryItself() {
        // "Inside" is strict — the base directory is not a file to serve.
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(requestPath: "/", in: base))
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(requestPath: "", in: base))
    }

    func test_refusesASubdirectory() throws {
        let sub = base.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(requestPath: "/nested", in: base))
    }

    func test_refusesAFileThatIsNotThere() {
        XCTAssertNil(Whiteboard.AssetSchemeHandler.resolve(requestPath: "/missing.png", in: base))
    }

    // MARK: - The media types, which are half of a table

    /// **The other half is `assetExtensions` in `editor/src/whiteboard.jsx`.**
    ///
    /// That table decides the extension a pasted image lands under in
    /// `assets/`; this one decides the `Content-Type` it is served back with.
    /// They were written independently and disagreed — the page writes `bmp`,
    /// `ico`, `avif` and `jfif`, and the handler knew none of them, so those
    /// four were served as `application/octet-stream` and re-inlined under the
    /// wrong type on the next mount.
    ///
    /// A scheme handler answers a network request, so there is no op for the
    /// vocabulary to ride on the way a `captionKey` does. It is hand-mirrored,
    /// and this is what makes the mirroring fail loudly: a change to either
    /// file without the other lands here. **Written out rather than derived**,
    /// for the reason `IPCToolRegistry`'s `advertisedOrder` is — a set derived
    /// from the thing it checks checks nothing.
    func test_theMediaTypesAreTheSameSetTheEditorBundleWrites() {
        XCTAssertEqual(
            Whiteboard.AssetSchemeHandler.mimeTypes,
            [
                "png": "image/png",
                "jpg": "image/jpeg",
                "jpeg": "image/jpeg",
                "gif": "image/gif",
                "svg": "image/svg+xml",
                "webp": "image/webp",
                "bmp": "image/bmp",
                "ico": "image/x-icon",
                "avif": "image/avif",
                "jfif": "image/jfif",
            ]
        )
    }

    /// The four the handler used to miss, named on their own: this is the
    /// regression, and the set assertion above would also fail for a harmless
    /// reordering of the others.
    func test_theExtensionsThePageAlsoWritesAreNotServedAsOctetStream() {
        for ext in ["bmp", "ico", "avif", "jfif"] {
            XCTAssertNotNil(Whiteboard.AssetSchemeHandler.mimeTypes[ext], ext)
        }
    }
}
