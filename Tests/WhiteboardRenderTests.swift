// ABOUTME: Pins how a render is marked current, stale, or absent.
// ABOUTME: A stamp present means the PNG and the scene came out of one save.

@testable import Atelier
import XCTest

final class WhiteboardRenderTests: XCTestCase {
    private var workstreamID = UUID()

    override func setUp() {
        super.setUp()
        workstreamID = UUID()
    }

    override func tearDown() {
        Whiteboard.Store.sweep(for: workstreamID)
        super.tearDown()
    }

    private static let scene = """
    {"type":"excalidraw","elements":[
    {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false,"text":"hi"}]}
    """

    private static let png = Data([0x89, 0x50, 0x4E, 0x47])

    func test_aBoardWithNoPNG_hasNoRender() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        XCTAssertEqual(Whiteboard.Store.renderState(for: workstreamID), .none)
    }

    func test_aRenderWrittenAfterItsSave_isCurrent() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        try Whiteboard.Store.writeRender(png: Self.png, width: 800, height: 600, for: workstreamID)
        XCTAssertEqual(
            Whiteboard.Store.renderState(for: workstreamID),
            .current(width: 800, height: 600, path: Whiteboard.Store.pngURL(for: workstreamID).path)
        )
    }

    func test_theNextSaveMakesTheExistingRenderStale_ratherThanDeletingIt() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        try Whiteboard.Store.writeRender(png: Self.png, width: 800, height: 600, for: workstreamID)
        // What `Bridge` does on every save, before the new export has finished:
        // the picture on disk is now of an earlier board.
        Whiteboard.Store.invalidateRender(for: workstreamID)
        XCTAssertEqual(
            Whiteboard.Store.renderState(for: workstreamID),
            .stale(path: Whiteboard.Store.pngURL(for: workstreamID).path)
        )
        // The PNG itself survives. A picture of the board a moment ago is nearly
        // always still worth looking at; what must not happen is it being read
        // as current, and the stamp is what decides that.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Whiteboard.Store.pngURL(for: workstreamID).path)
        )
    }

    func test_invalidatingWithNoRender_leavesNoRenderRatherThanAStaleOne() throws {
        // A board that has never been rendered must not report a stale picture
        // that does not exist for an agent to go and look at.
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        Whiteboard.Store.invalidateRender(for: workstreamID)
        XCTAssertEqual(Whiteboard.Store.renderState(for: workstreamID), .none)
    }

    func test_aRenderAfterAnInvalidationIsCurrentAgain() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        try Whiteboard.Store.writeRender(png: Self.png, width: 10, height: 10, for: workstreamID)
        Whiteboard.Store.invalidateRender(for: workstreamID)
        try Whiteboard.Store.writeRender(png: Self.png, width: 20, height: 20, for: workstreamID)
        XCTAssertEqual(
            Whiteboard.Store.renderState(for: workstreamID),
            .current(width: 20, height: 20, path: Whiteboard.Store.pngURL(for: workstreamID).path)
        )
    }

    func test_refreshingWritesBoardMarkdownBesideTheScene() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        Whiteboard.Store.refreshDigest(for: workstreamID)
        let written = try String(
            contentsOf: Whiteboard.Store.digestURL(for: workstreamID),
            encoding: .utf8
        )
        XCTAssertTrue(written.contains("box"), written)
        XCTAssertTrue(written.hasSuffix(Whiteboard.Digest.closingLine), written)
    }

    func test_theToolsTextIsGeneratedFresh_notReadBackFromBoardMarkdown() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        Whiteboard.Store.refreshDigest(for: workstreamID)
        // Overwrite board.md with a lie. The tool must not repeat it: the
        // relative age and the staleness verdict are both answers to "right
        // now", and a file cannot hold either.
        try "STALE COPY".write(
            to: Whiteboard.Store.digestURL(for: workstreamID),
            atomically: true,
            encoding: .utf8
        )
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        XCTAssertFalse(text.contains("STALE COPY"), text)
        XCTAssertTrue(text.contains("box"), text)
    }

    func test_theAgeIsReportedRelativeToTheScenesOwnTimestamp() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        let text = Whiteboard.Store.digestText(
            for: workstreamID,
            now: Date().addingTimeInterval(120)
        )
        XCTAssertTrue(text.contains("updated"), text)
        XCTAssertTrue(text.contains("2m"), text)
    }

    func test_aBoardNobodyHasOpened_readsAsEmptyRatherThanBroken() {
        // No directory at all. Every workstream starts here, and a missing file
        // is not a fault.
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        XCTAssertTrue(text.lowercased().contains("empty"), text)
        XCTAssertFalse(text.lowercased().contains("could not be read"), text)
    }

    func test_sweepTakesTheRenderAndTheDigestWithIt() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        try Whiteboard.Store.writeRender(png: Self.png, width: 1, height: 1, for: workstreamID)
        Whiteboard.Store.refreshDigest(for: workstreamID)
        Whiteboard.Store.sweep(for: workstreamID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: Whiteboard.Store.pngURL(for: workstreamID).path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: Whiteboard.Store.digestURL(for: workstreamID).path)
        )
        XCTAssertEqual(Whiteboard.Store.renderState(for: workstreamID), .none)
    }

    func test_assetPathsAreKeyedByTheFileIDTheSceneReferences() throws {
        try Whiteboard.Store.writeAsset(
            Data([0x89]), id: "abc123", ext: "png", for: workstreamID
        )
        let paths = Whiteboard.Store.assetPaths(for: workstreamID)
        // The stem IS the fileId — writeAsset refuses any id it would have had
        // to rewrite, so this is an equality, not a lookup table.
        XCTAssertEqual(paths["abc123"], Whiteboard.Store.assetsDirectory(for: workstreamID)
            .appendingPathComponent("abc123.png").path)
    }

    func test_anImageOnTheBoardIsPointedAtByItsRealPathOnDisk() throws {
        try Whiteboard.Store.writeAsset(
            Data([0x89]), id: "abc123", ext: "png", for: workstreamID
        )
        try Whiteboard.Store.saveScene("""
        {"type":"excalidraw","elements":[
        {"id":"i","type":"image","x":0,"y":0,"width":10,"height":10,
         "isDeleted":false,"fileId":"abc123"}]}
        """, for: workstreamID)
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        let expected = Whiteboard.Store.assetsDirectory(for: workstreamID)
            .appendingPathComponent("abc123.png").path
        XCTAssertTrue(text.contains(expected), text)
        // And it is genuinely openable, which is the whole claim.
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
    }
}
