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

    func test_writeAsset_cannotEscapeViaACraftedFileID() {
        // The id is the page's, so it is checked rather than trusted: an id
        // carrying `../` would otherwise write outside the board entirely.
        // Refused rather than rewritten — see the round-trip tests below.
        XCTAssertThrowsError(
            try Whiteboard.Store.writeAsset(
                Data([0x00]), id: "../../evil", ext: "png", for: workstreamID
            )
        )
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

    // MARK: - The asset name IS the file id

    /// `Host` lists `assets/` into a manifest and the page rebuilds `files[id]`
    /// from each name's stem, so the stem has to equal the `fileId` on the image
    /// element. A real Excalidraw file id is a SHA-1 digest as lowercase hex.
    func test_aRealExcalidrawFileIDRoundTripsUnchanged() throws {
        let fileID = "9f3c1b7e2a4d5c6f8091a2b3c4d5e6f708192a3b"
        let url = try Whiteboard.Store.writeAsset(
            Data([0x89]), id: fileID, ext: "png", for: workstreamID
        )
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, fileID)

        // And it is what the directory listing hands the page.
        let names = try FileManager.default.contentsOfDirectory(
            atPath: Whiteboard.Store.assetsDirectory(for: workstreamID).path
        )
        XCTAssertEqual(names, ["\(fileID).png"])
    }

    /// Refused, never rewritten. A silently sanitized name stops matching the
    /// element's `fileId` and the image comes back missing with nothing logged —
    /// the same silent shape as the two persistence bugs this feature already
    /// had. Losing the image loudly is strictly better.
    func test_anIDThatWouldNotRoundTripIsRefusedRatherThanRewritten() {
        for unsafe in ["../../evil", "has space", "dot.dot", "", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(
                try Whiteboard.Store.writeAsset(Data([0x00]), id: unsafe, ext: "png", for: workstreamID),
                "\(unsafe) cannot round-trip and must be refused"
            )
        }
        XCTAssertThrowsError(
            try Whiteboard.Store.writeAsset(Data([0x00]), id: "ok", ext: "p/g", for: workstreamID)
        )
    }

    func test_nothingIsWrittenForARefusedName() {
        try? Whiteboard.Store.writeAsset(Data([0x00]), id: "../escape", ext: "png", for: workstreamID)
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: Whiteboard.Store.assetsDirectory(for: workstreamID).path
        )
        XCTAssertTrue(contents?.isEmpty ?? true)
    }
}
