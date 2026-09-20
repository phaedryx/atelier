// ABOUTME: Pins the save/render arms of the page's message handler.
// ABOUTME: Above all that a render is only ever accepted for the scene it came from.

@testable import Atelier
import XCTest

@MainActor
final class WhiteboardBridgeTests: XCTestCase {
    private var workstreamID = UUID()
    private var bridge: Whiteboard.Bridge!

    override func setUp() {
        super.setUp()
        workstreamID = UUID()
        bridge = Whiteboard.Bridge(workstreamID: workstreamID)
    }

    override func tearDown() {
        Whiteboard.Store.sweep(for: workstreamID)
        bridge = nil
        super.tearDown()
    }

    private static let scene = """
    {"type":"excalidraw","elements":[
    {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false,"text":"hi"}]}
    """

    private static let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()

    private func save(rev: String, scene: String = scene) {
        bridge.handle(["action": "save", "rev": rev, "scene": scene])
    }

    private func render(rev: String, width: String = "800", height: String = "600") {
        bridge.handle([
            "action": "render", "rev": rev, "ok": "true",
            "width": width, "height": height, "data": Self.png,
        ])
    }

    private var state: Whiteboard.Digest.Render {
        Whiteboard.Store.renderState(for: workstreamID)
    }

    // MARK: - The save arm

    func test_aSaveWritesTheSceneAndTheDigest() throws {
        save(rev: "1")
        XCTAssertEqual(Whiteboard.Store.loadScene(for: workstreamID), Self.scene)
        let digest = try String(
            contentsOf: Whiteboard.Store.digestURL(for: workstreamID),
            encoding: .utf8
        )
        XCTAssertTrue(digest.contains("box"), digest)
    }

    func test_aSaveMakesAnExistingRenderStale() {
        save(rev: "1")
        render(rev: "1")
        XCTAssertEqual(state, .current(
            width: 800, height: 600,
            path: Whiteboard.Store.pngURL(for: workstreamID).path
        ))

        save(rev: "2")
        XCTAssertEqual(state, .stale(path: Whiteboard.Store.pngURL(for: workstreamID).path))
    }

    // MARK: - The render arm

    func test_aRenderForTheCurrentSaveIsAccepted() {
        save(rev: "1")
        render(rev: "1", width: "1360", height: "1520")
        XCTAssertEqual(state, .current(
            width: 1360, height: 1520,
            path: Whiteboard.Store.pngURL(for: workstreamID).path
        ))
    }

    func test_aRenderForAnOlderSaveIsDropped() {
        // The ordering bug this guard exists for: exports are not ordered
        // against each other, so a big board's export can finish *after* the
        // save that follows it. Accepting it would stamp a picture of the older
        // board as matching the newer scene — the one thing the stamp exists to
        // prevent, and silent when it happens.
        save(rev: "1")
        save(rev: "2")
        render(rev: "1")
        XCTAssertEqual(state, .none, "a render for a superseded scene must not be written at all")
    }

    func test_aFailedRenderLeavesTheOldPictureAndDoesNotMarkItCurrent() {
        save(rev: "1")
        render(rev: "1")
        save(rev: "2")
        bridge.handle(["action": "render", "rev": "2", "ok": "false", "reason": "SecurityError"])
        // Kept, because a picture of the board a moment ago is still worth
        // looking at — but reported as stale, never as fresh.
        XCTAssertEqual(state, .stale(path: Whiteboard.Store.pngURL(for: workstreamID).path))
    }

    func test_aRenderMissingItsDimensionsIsRefusedRatherThanGuessed() {
        save(rev: "1")
        bridge.handle(["action": "render", "rev": "1", "ok": "true", "data": Self.png])
        XCTAssertEqual(state, .none)
    }

    func test_aRenderBeforeAnySaveIsDropped() {
        // There is no scene for it to have come from, so there is nothing it
        // could honestly be stamped against.
        render(rev: "1")
        XCTAssertEqual(state, .none)
    }

    // MARK: - Malformed bodies

    func test_aBodyWithNoActionIsIgnored() {
        bridge.handle(["scene": Self.scene])
        bridge.handle("not a dictionary")
        XCTAssertNil(Whiteboard.Store.loadScene(for: workstreamID))
    }

    func test_anUnknownActionIsIgnored() {
        bridge.handle(["action": "whatIsThis"])
        XCTAssertNil(Whiteboard.Store.loadScene(for: workstreamID))
    }
}
