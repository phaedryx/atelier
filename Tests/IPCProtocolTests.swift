// ABOUTME: Tests the identity the atelier-mcp helper derives from its own environment.
// ABOUTME: That inheritance is the whole addressing scheme — no config interpolation, no headers.

@testable import Atelier
import XCTest

final class IPCProtocolTests: XCTestCase {
    func test_identity_comesFromTheInheritedEnvironment() {
        let surfaceID = UUID().uuidString
        let workstreamID = UUID().uuidString
        let identity = IPC.ClientIdentity.fromEnvironment([
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
        let identity = IPC.ClientIdentity.fromEnvironment([:])
        XCTAssertNil(identity.workstreamID)
        XCTAssertNil(identity.projectDirectory)
        XCTAssertNil(identity.surfaceID, "no surface id means pull-only, not a guessed pane")
        XCTAssertNil(identity.peerID)
    }

    func test_framing_splitsOnNewlinesAndKeepsThePartialLine() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8)
        let (lines, remainder) = IPC.Framing.lines(from: buffer)
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"c\"")

        buffer = remainder
        buffer.append(Data(":3}\n".utf8))
        let (rest, tail) = IPC.Framing.lines(from: buffer)
        XCTAssertEqual(rest.map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
        XCTAssertTrue(tail.isEmpty)
    }

    // MARK: - Reply deadlines

    /// The bug this table exists to close: one 15-second socket timeout for
    /// every tool, over a comment claiming every handler was sub-millisecond.
    /// `create_workstream` does not answer until `git worktree add` has, so the
    /// helper gave up while the app was still working and called that a dead
    /// app.
    func test_createWorkstream_outlastsTheWorkItWaitsOn() {
        XCTAssertGreaterThan(
            IPC.Tool.createWorkstream.replyDeadline,
            ProcessRunner.Timeout.userCommand,
            "createWorktree runs git worktree add under userCommand; a shorter deadline here gives up first"
        )
        XCTAssertGreaterThan(
            IPC.Tool.createWorkstream.replyDeadline,
            ProcessRunner.Timeout.userCommand + ProcessRunner.Timeout.network,
            "it fetches the base branch before the worktree add, and both are on the same round trip"
        )
    }

    /// Nothing got a *shorter* wait than the single value it replaced. The point
    /// of the split was to stop cutting slow handlers off, not to tighten fast
    /// ones.
    func test_noTool_waitsLessThanTheOldSingleTimeout() {
        for tool in IPC.Tool.allCases {
            XCTAssertGreaterThanOrEqual(tool.replyDeadline, 15, "\(tool.rawValue) waits less than the 15s it used to")
        }
    }

    // MARK: - Replay policy

    /// A replay is a second execution. These are the tools that cannot afford
    /// one — and the list is idempotence, not `surface`: `receive_messages` is
    /// messaging and drains an inbox, `open_editor` is a workspace action and
    /// puts the same file on screen twice.
    func test_toolsThatChangeSomething_areNotReplayed() {
        for tool in [IPC.Tool.createWorkstream, .openAgentTab, .startVerification, .sendMessage, .broadcast, .receiveMessages] {
            XCTAssertFalse(tool.isSafeToReplay, "\(tool.rawValue) does something different the second time")
        }
    }

    /// Every workspace *read* stays replayable, so the helper's recovery from a
    /// restarted app is not lost along with the duplicates.
    func test_readsAndRenames_stayReplayable() {
        for tool in [IPC.Tool.listPeers, .getPeerStatus, .listTabs, .readReviewComments, .checkVerification, .openEditor, .requestAttention] {
            XCTAssertTrue(tool.isSafeToReplay, "\(tool.rawValue) changes nothing by running twice")
        }
        XCTAssertTrue(
            IPC.Tool.registerPeer.isSafeToReplay,
            "the reconnect path replays register_peer by hand to recover the session's identity"
        )
    }
}
