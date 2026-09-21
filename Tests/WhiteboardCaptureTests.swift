// ABOUTME: The pure halves of screen capture — naming a file and sizing it for the board.
// ABOUTME: The spawn itself is interactive and is not exercised here.

import AppKit
@testable import Atelier
import XCTest

final class WhiteboardCaptureTests: XCTestCase {
    private typealias Capture = Whiteboard.Capture

    /// A real PNG of a given pixel size.
    private func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - fileID

    func test_fileIDIsTheLowercaseHexSHA1OfTheBytes() {
        // Excalidraw's own `fileId` convention, so a captured image and a pasted
        // one are named by one rule — and `assets/<stem>` equals the element's
        // fileId either way, which is what the manifest and the digest both join
        // on.
        XCTAssertEqual(
            Capture.fileID(for: Data("hello".utf8)),
            "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"
        )
    }

    func test_aFileIDIsAlwaysUsableAsAFileName() {
        // `Store.writeAsset` REFUSES a name it would have had to rewrite, so an
        // id that is not a safe component loses the capture outright.
        XCTAssertTrue(Whiteboard.Store.isSafeComponent(Capture.fileID(for: Data("anything".utf8))))
    }

    func test_theSameBytesGetTheSameName() throws {
        let bytes = try png(width: 4, height: 4)
        XCTAssertEqual(Capture.fileID(for: bytes), Capture.fileID(for: bytes))
    }

    // MARK: - onBoardSize

    func test_aSmallCaptureKeepsItsOwnSize() throws {
        let size = try XCTUnwrap(Capture.onBoardSize(of: png(width: 320, height: 200)))
        XCTAssertEqual(size.width, 320, accuracy: 0.5)
        XCTAssertEqual(size.height, 200, accuracy: 0.5)
    }

    func test_aRetinaCaptureIsScaledDownByItsLongEdge() throws {
        // A 3200px-wide capture placed at its pixel size dwarfs every box on the
        // board, and the user has to zoom out to find their own diagram.
        let size = try XCTUnwrap(Capture.onBoardSize(of: png(width: 3200, height: 800)))
        XCTAssertEqual(size.width, Capture.maxOnBoardEdge, accuracy: 0.5)
        XCTAssertEqual(size.height, Capture.maxOnBoardEdge / 4, accuracy: 0.5)
    }

    func test_aTallCaptureIsScaledByItsHeight() throws {
        let size = try XCTUnwrap(Capture.onBoardSize(of: png(width: 400, height: 2000)))
        XCTAssertEqual(size.height, Capture.maxOnBoardEdge, accuracy: 0.5)
        XCTAssertEqual(size.width, Capture.maxOnBoardEdge / 5, accuracy: 0.5)
    }

    func test_theAspectRatioIsKept() throws {
        let size = try XCTUnwrap(Capture.onBoardSize(of: png(width: 1600, height: 900)))
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.01)
    }

    func test_somethingThatIsNotAnImageHasNoSize() {
        // Answered with nil rather than a guessed default: placing a zero-sized
        // or arbitrarily-sized element would put something on the board that
        // the digest describes and the picture does not show.
        XCTAssertNil(Capture.onBoardSize(of: Data("not a png".utf8)))
    }
}
