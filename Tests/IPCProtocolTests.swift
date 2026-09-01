// ABOUTME: Tests the identity the atelier-mcp helper derives from its own environment.
// ABOUTME: That inheritance is the whole addressing scheme — no config interpolation, no headers.

@testable import Atelier
import XCTest

final class IPCProtocolTests: XCTestCase {
    func test_identity_comesFromTheInheritedEnvironment() {
        let surfaceID = UUID().uuidString
        let workstreamID = UUID().uuidString
        let identity = IPCClientIdentity.fromEnvironment([
            "ATELIER_WORKSTREAM_ID": workstreamID,
            "ATELIER_WORKSTREAM": "bold-crimson-parser",
            "ATELIER_PROJECT_DIR": "/repos/atelier",
            "ATELIER_SURFACE_ID": surfaceID,
        ], peerID: "some-peer")

        XCTAssertEqual(identity.workstreamID, workstreamID)
        XCTAssertEqual(identity.workstreamName, "bold-crimson-parser")
        XCTAssertEqual(identity.projectDirectory, "/repos/atelier")
        XCTAssertEqual(identity.surfaceID, surfaceID)
        XCTAssertEqual(identity.peerID, "some-peer")
    }

    func test_identity_outsideAWorkstream_isEmptyRatherThanWrong() {
        let identity = IPCClientIdentity.fromEnvironment([:])
        XCTAssertNil(identity.workstreamID)
        XCTAssertNil(identity.projectDirectory)
        XCTAssertNil(identity.surfaceID, "no surface id means pull-only, not a guessed pane")
        XCTAssertNil(identity.peerID)
    }

    func test_framing_splitsOnNewlinesAndKeepsThePartialLine() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8)
        let (lines, remainder) = IPCFraming.lines(from: buffer)
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"c\"")

        buffer = remainder
        buffer.append(Data(":3}\n".utf8))
        let (rest, tail) = IPCFraming.lines(from: buffer)
        XCTAssertEqual(rest.map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
        XCTAssertTrue(tail.isEmpty)
    }
}
