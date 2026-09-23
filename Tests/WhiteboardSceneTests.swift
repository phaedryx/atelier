// ABOUTME: Pins parsing of a real Excalidraw scene into the digest's element model.
// ABOUTME: The fixture is captured from Excalidraw 0.18.1, not hand-written.

@testable import Atelier
import XCTest

final class WhiteboardSceneTests: XCTestCase {
    /// Captured from a real board: two labelled rectangles, an arrow bound to
    /// both and carrying its own label, a floating text, a freehand stroke and
    /// an image.
    ///
    /// The shape that matters, and that a hand-written fixture would have got
    /// wrong: a container's label is a **separate** text element carrying
    /// `containerId`, sitting *after* its container in file order. Nine raw
    /// elements are six the user would count.
    static let fixture = """
    {"type":"excalidraw","version":2,"source":"local","elements":[
    {"id":"rectA","type":"rectangle","x":120,"y":80,"width":240,"height":90,
     "isDeleted":false,"boundElements":[{"type":"text","id":"labelA"},{"type":"arrow","id":"arrowA"}]},
    {"id":"rectB","type":"rectangle","x":480,"y":80,"width":240,"height":90,
     "isDeleted":false,"boundElements":[{"type":"text","id":"labelB"},{"type":"arrow","id":"arrowA"}]},
    {"id":"arrowA","type":"arrow","x":360,"y":125,"width":120,"height":0,"isDeleted":false,
     "startBinding":{"elementId":"rectA","focus":0,"gap":1},
     "endBinding":{"elementId":"rectB","focus":0,"gap":1},
     "boundElements":[{"type":"text","id":"labelArrow"}]},
    {"id":"loose","type":"text","x":200,"y":240,"width":137,"height":25,
     "text":"why is this sync?","containerId":null,"isDeleted":false},
    {"id":"labelA","type":"text","x":189,"y":112,"width":101,"height":25,
     "text":"Auth service","containerId":"rectA","isDeleted":false},
    {"id":"labelB","type":"text","x":553,"y":112,"width":93,"height":25,
     "text":"Token store","containerId":"rectB","isDeleted":false},
    {"id":"labelArrow","type":"text","x":396,"y":112,"width":47,"height":25,
     "text":"issues","containerId":"arrowA","isDeleted":false},
    {"id":"freeA","type":"freedraw","x":100,"y":400,"width":280,"height":160,
     "isDeleted":false,"points":[[0,0],[40,20],[120,90],[280,160]]},
    {"id":"imgA","type":"image","x":60,"y":620,"width":200,"height":200,
     "fileId":"spikeasset0001","isDeleted":false}
    ],"appState":{},"files":{}}
    """

    private func loaded(_ json: String) throws -> Whiteboard.Scene {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse(json) else {
            throw XCTSkip("expected a loaded scene")
        }
        return scene
    }

    func test_aContainersLabelIsFoldedIntoIt_ratherThanListedTwice() throws {
        let scene = try loaded(Self.fixture)
        XCTAssertEqual(scene.elements.count, 6)
        XCTAssertEqual(scene.elements.map(\.id), ["rectA", "rectB", "arrowA", "loose", "freeA", "imgA"])

        let rectA = try XCTUnwrap(scene.elements.first { $0.id == "rectA" })
        XCTAssertEqual(rectA.kind, .box)
        XCTAssertEqual(rectA.text, "Auth service")
    }

    func test_anArrowCarriesItsEndpointsAndItsOwnLabel() throws {
        let scene = try loaded(Self.fixture)
        let arrow = try XCTUnwrap(scene.elements.first { $0.id == "arrowA" })
        XCTAssertEqual(arrow.kind, .arrow)
        XCTAssertEqual(arrow.from, "rectA")
        XCTAssertEqual(arrow.to, "rectB")
        XCTAssertEqual(arrow.text, "issues")
    }

    func test_aFloatingTextSurvivesAsItsOwnElement() throws {
        let scene = try loaded(Self.fixture)
        let text = try XCTUnwrap(scene.elements.first { $0.id == "loose" })
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.text, "why is this sync?")
    }

    func test_aStrokeCarriesItsPointCountAndNothingAboutItsShape() throws {
        let scene = try loaded(Self.fixture)
        let stroke = try XCTUnwrap(scene.elements.first { $0.id == "freeA" })
        XCTAssertEqual(stroke.kind, .stroke)
        XCTAssertEqual(stroke.pointCount, 4)
        XCTAssertNil(stroke.text, "a stroke is opaque; nothing may claim to know what it says")
    }

    func test_anImageCarriesItsFileIDVerbatim() throws {
        let scene = try loaded(Self.fixture)
        let image = try XCTUnwrap(scene.elements.first { $0.id == "imgA" })
        XCTAssertEqual(image.kind, .image)
        // The file's NAME is this id — `writeAsset` refused any id it would have
        // had to rewrite — so there is no mapping table and no normalisation.
        XCTAssertEqual(image.fileID, "spikeasset0001")
        XCTAssertNil(image.text, "an image is opaque; only a caption may speak for it")
    }

    func test_deletedElementsAreNotInTheScene() throws {
        let json = """
        {"type":"excalidraw","elements":[
        {"id":"gone","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":true},
        {"id":"here","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false}
        ]}
        """
        let scene = try loaded(json)
        XCTAssertEqual(scene.elements.map(\.id), ["here"])
    }

    func test_customDataCarriesTheAuthorAndTheCaption() throws {
        // PR 3 writes the author marker and PR 4 the transcription; the keys are
        // fixed here, in the reader, so both have one spelling to write to.
        let json = """
        {"type":"excalidraw","elements":[
        {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "customData":{"\(Whiteboard.Element.authorKey)":"\(Whiteboard.Element.agentAuthorValue)"}},
        {"id":"i","type":"image","x":0,"y":0,"width":10,"height":10,"isDeleted":false,
         "fileId":"abc","customData":{"\(Whiteboard.Element.captionKey)":"Settings pane, red row"}}
        ]}
        """
        let scene = try loaded(json)
        XCTAssertTrue(try XCTUnwrap(scene.elements.first { $0.id == "n" }).isAgentAuthored)
        XCTAssertFalse(try XCTUnwrap(scene.elements.first { $0.id == "i" }).isAgentAuthored)
        XCTAssertEqual(
            try XCTUnwrap(scene.elements.first { $0.id == "i" }).caption,
            "Settings pane, red row"
        )
    }

    func test_anUnknownTypeKeepsItsOwnName_ratherThanBeingCalledABox() throws {
        let json = """
        {"type":"excalidraw","elements":[
        {"id":"f","type":"frame","x":0,"y":0,"width":10,"height":10,"isDeleted":false}
        ]}
        """
        let scene = try loaded(json)
        let element = try XCTUnwrap(scene.elements.first)
        XCTAssertEqual(element.kind, .other)
        XCTAssertEqual(element.rawType, "frame")
    }

    // MARK: - The three load cases

    func test_aSceneWithNoElements_isEmptyRatherThanLoaded() {
        guard case .empty = Whiteboard.SceneLoad.parse("""
        {"type":"excalidraw","elements":[],"appState":{}}
        """) else {
            return XCTFail("a board nobody has drawn on is empty, not loaded")
        }
    }

    func test_aSceneThatWillNotParse_isUnreadableRatherThanEmpty() {
        // The distinction `Verification.Config.Load` draws, and it exists because
        // "declares nothing" and "could not be read" send a reader to completely
        // different places.
        guard case let .unreadable(reason) = Whiteboard.SceneLoad.parse("{not json") else {
            return XCTFail("a broken scene must never render as an empty one")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func test_aSceneWhoseElementsKeyIsNotAList_isUnreadable() {
        guard case .unreadable = Whiteboard.SceneLoad.parse("""
        {"type":"excalidraw","elements":"nope"}
        """) else {
            return XCTFail("a malformed elements key is a broken file, not an empty board")
        }
    }

    func test_anAbsentSceneFile_isEmpty() {
        // Every workstream's first state. Reading it as a failure would send the
        // user looking for a problem that is not there.
        guard case .empty = Whiteboard.SceneLoad.load(for: UUID()) else {
            return XCTFail("a board that was never opened is empty")
        }
    }

    // MARK: - the note kind

    func test_aRectangleCarryingTheNoteMarker_parsesAsANote() {
        // The design's vocabulary is box / note / text / arrow and Excalidraw
        // has no `note`. Without this half a note round-trips as a box and the
        // vocabulary silently has three kinds instead of four.
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[{"id":"n1","type":"rectangle","x":10,"y":20,"width":200,"height":80,
          "customData":{"atelierKind":"note","atelierAuthor":"agent"}}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertEqual(scene.elements.first?.kind, .note)
        XCTAssertEqual(scene.elements.first?.isAgentAuthored, true)
    }

    func test_aRectangleWithoutTheMarker_isStillABox() {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[{"id":"b1","type":"rectangle","x":0,"y":0,"width":10,"height":10}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertEqual(scene.elements.first?.kind, .box)
    }

    func test_theNoteMarkerOnANonRectangle_isIgnored() {
        // The marker says how a RECTANGLE was authored. It is not a way to
        // relabel any element as something else.
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[{"id":"e1","type":"ellipse","x":0,"y":0,"width":10,"height":10,
          "customData":{"atelierKind":"note"}}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertEqual(scene.elements.first?.kind, .ellipse)
    }

    func test_aNoteKeepsItsBoundLabel() {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[
          {"id":"n1","type":"rectangle","x":0,"y":0,"width":200,"height":80,
           "customData":{"atelierKind":"note"}},
          {"id":"t1","type":"text","containerId":"n1","text":"check the TTL"}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertEqual(scene.elements.count, 1)
        XCTAssertEqual(scene.elements.first?.kind, .note)
        XCTAssertEqual(scene.elements.first?.text, "check the TTL")
    }

    /// **A label whose container is gone is still on the canvas.**
    ///
    /// The fold is an optimisation over a `containerId`, which is a claim
    /// about another element rather than a guarantee — a scene edited outside
    /// Atelier, an older file, or a delete that took a container without its
    /// label all leave one behind. Skipped unconditionally it vanished from
    /// the digest while Excalidraw went on drawing it, which is the digest
    /// reporting less than the picture holds.
    func test_aLabelWhoseContainerIsGoneIsReportedRatherThanFoldedIntoNothing() {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[
          {"id":"n1","type":"rectangle","x":0,"y":0,"width":200,"height":80},
          {"id":"t1","type":"text","containerId":"gone","text":"orphaned words"}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertEqual(scene.elements.count, 2)
        let orphan = scene.elements.first { $0.id == "t1" }
        XCTAssertEqual(orphan?.kind, .text)
        XCTAssertEqual(orphan?.text, "orphaned words")
    }

    /// **A frame carries its words in `name`.**
    ///
    /// Excalidraw labels a frame that way and nothing else, and a mermaid class
    /// diagram with a `namespace` block draws one per namespace. Read through
    /// `text` alone the digest printed a bare `frame` with its dimensions and
    /// nothing saying which namespace it was — an element on the canvas
    /// carrying a word the digest could not see.
    func test_aFrameIsNamedByItsNameRatherThanRenderedWordless() {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[
          {"id":"f1","type":"frame","name":"Auth","x":0,"y":0,"width":400,"height":300}]}
        """) else { return XCTFail("expected a loaded scene") }
        let frame = try? XCTUnwrap(scene.elements.first)
        XCTAssertEqual(frame?.text, "Auth")
        // Still `.other`, which names itself from `rawType`. Adding a `frame`
        // case would be a claim about how its children relate to it, and
        // nothing here reads that.
        XCTAssertEqual(frame?.kind, .other)
        XCTAssertEqual(frame?.rawType, "frame")
    }

    /// `name` is honoured for a frame and nowhere else — the same rule the note
    /// promotion follows, for the same reason: a board must not be able to
    /// rename its own shapes out from under the reader.
    func test_aNameOnSomethingThatIsNotAFrameIsIgnored() {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[
          {"id":"r1","type":"rectangle","name":"not a label","x":0,"y":0,
           "width":10,"height":10}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertNil(scene.elements.first?.text)
    }

    /// A container that is present but *deleted* is gone for this purpose too:
    /// `parse` filters `isDeleted` before anything else, so the label has no
    /// container to be folded into and must be reported.
    func test_aLabelWhoseContainerIsDeletedIsReportedToo() {
        guard case let .loaded(scene) = Whiteboard.SceneLoad.parse("""
        {"elements":[
          {"id":"n1","type":"rectangle","x":0,"y":0,"width":200,"height":80,
           "isDeleted":true},
          {"id":"t1","type":"text","containerId":"n1","text":"orphaned words"}]}
        """) else { return XCTFail("expected a loaded scene") }
        XCTAssertEqual(scene.elements.map(\.id), ["t1"])
        XCTAssertEqual(scene.elements.first?.text, "orphaned words")
    }
}
