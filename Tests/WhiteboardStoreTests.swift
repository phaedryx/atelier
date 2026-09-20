// ABOUTME: Pins where a board lives on disk, and that the sweep removes it.
// ABOUTME: Pure file IO — no WebKit, no libghostty.

@testable import Atelier
import XCTest

final class WhiteboardStoreTests: XCTestCase {
    private let workstreamID = UUID()

    override func tearDown() {
        Whiteboard.Store.sweep(for: workstreamID)
        super.tearDown()
    }

    func test_directory_isUnderTheCacheDirectory_keyedByWorkstream() {
        let dir = Whiteboard.Store.directory(for: workstreamID)
        // Deliberately not the worktree: a board file there would show up in
        // `git status` and in the Changes tab, which is noise on every diff the
        // user reads. See tad/why-nots/whiteboard-file-in-the-worktree.md.
        XCTAssertTrue(dir.path.hasPrefix(AppConstants.cacheDirectory.path))
        XCTAssertTrue(dir.path.contains("whiteboard"))
        XCTAssertTrue(dir.path.contains(workstreamID.uuidString.lowercased()))
    }

    func test_loadScene_isNilForABoardNobodyHasDrawnOn() {
        // An empty board is the first state every workstream is in. It must read
        // as empty, never as an error — the two send a reader to completely
        // different places.
        XCTAssertNil(Whiteboard.Store.loadScene(for: workstreamID))
    }

    func test_saveScene_thenLoadScene_roundTrips() throws {
        let json = #"{"type":"excalidraw","elements":[]}"#
        try Whiteboard.Store.saveScene(json, for: workstreamID)
        XCTAssertEqual(Whiteboard.Store.loadScene(for: workstreamID), json)
    }

    func test_saveScene_createsTheDirectoryItNeeds() throws {
        try Whiteboard.Store.saveScene("{}", for: workstreamID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Whiteboard.Store.sceneURL(for: workstreamID).path
        ))
    }

    func test_writeAsset_landsInsideTheAssetsDirectory() throws {
        let url = try Whiteboard.Store.writeAsset(
            Data([0x89, 0x50]), id: "abc", ext: "png", for: workstreamID
        )
        XCTAssertTrue(url.path.isCanonicallyInside(
            Whiteboard.Store.assetsDirectory(for: workstreamID).path
        ))
    }

    func test_writeAsset_cannotEscapeViaACraftedFileID() throws {
        // The id is the page's, so it is sanitized rather than trusted: an id
        // carrying `../` would otherwise write outside the board entirely.
        let url = try Whiteboard.Store.writeAsset(
            Data([0x00]), id: "../../evil", ext: "png", for: workstreamID
        )
        XCTAssertTrue(url.path.isCanonicallyInside(
            Whiteboard.Store.assetsDirectory(for: workstreamID).path
        ))
    }

    func test_sweep_removesTheWholeBoardDirectory() throws {
        try Whiteboard.Store.saveScene("{}", for: workstreamID)
        _ = try Whiteboard.Store.writeAsset(Data([0x00]), id: "abc", ext: "png", for: workstreamID)
        Whiteboard.Store.sweep(for: workstreamID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Whiteboard.Store.directory(for: workstreamID).path
        ))
    }

    func test_sweep_isASafeNoOpForABoardThatNeverExisted() {
        // Both archive paths call this unconditionally, and a workstream nobody
        // opened the board on is the common case rather than an edge case.
        Whiteboard.Store.sweep(for: UUID())
    }
}
