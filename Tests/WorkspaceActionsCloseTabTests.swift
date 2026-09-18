// ABOUTME: Tests for close_tab's behavior — singleton and terminal closing, permanent-tab refusal, replay idempotence.
// ABOUTME: Wires a live surfaceCache+projectList into WorkspaceActions.shared, the way IPCVerificationBridgeTests does for projectList alone.

@testable import Atelier
import XCTest

@MainActor
final class WorkspaceActionsCloseTabTests: XCTestCase {
    private var projectList: ProjectList!
    private var surfaceCache: TerminalSurfaceCache!
    private var workstreamID: UUID!

    override func setUp() {
        super.setUp()
        let id = UUID()
        workstreamID = id
        let list = ProjectList()
        list.items = [Project(
            name: "app",
            directory: "/repos/app",
            workstreams: [Workstream(name: "wry-amber-lexer", worktreePath: "/repos/app/wry-amber-lexer", id: id)]
        )]
        projectList = list
        surfaceCache = TerminalSurfaceCache()
        // No libghostty in a unit-test host, and a run starts a surface.
        surfaceCache.terminalApp = { nil }
        WorkspaceActions.shared.projectList = list
        WorkspaceActions.shared.surfaceCache = surfaceCache
    }

    override func tearDown() {
        WorkspaceActions.shared.projectList = nil
        WorkspaceActions.shared.surfaceCache = nil
        projectList = nil
        surfaceCache = nil
        workstreamID = nil
        super.tearDown()
    }

    private func model() throws -> WorkspaceModel {
        try WorkspaceActions.shared.context(workstreamID: workstreamID).model
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: - Argument shape

    func testNeitherKindNorSurfaceIDIsRefused() {
        XCTAssertThrowsError(
            try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: nil, surfaceID: nil)
        ) { error in
            let text = self.message(error)
            XCTAssertTrue(text.contains("kind") && text.contains("surface_id"), text)
        }
    }

    func testBothKindAndSurfaceIDIsRefusedAsAmbiguous() {
        XCTAssertThrowsError(
            try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "changes", surfaceID: UUID().uuidString)
        ) { error in
            XCTAssertTrue(self.message(error).contains("only one"), self.message(error))
        }
    }

    /// An empty string is a missing argument, not a value to look up —
    /// otherwise `["kind": ""]` would be read as naming a real (empty) kind.
    func testEmptyStringArgumentsAreTreatedAsAbsent() {
        XCTAssertThrowsError(
            try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "", surfaceID: "")
        ) { error in
            let text = self.message(error)
            XCTAssertTrue(text.contains("kind") && text.contains("surface_id"), text)
        }
    }

    // MARK: - Closing a singleton by kind

    func testClosingAnOpenSingletonRemovesItAndReportsItWasOpen() throws {
        _ = try WorkspaceActions.shared.openTab(workstreamID: workstreamID, kind: "changes")
        XCTAssertTrue(try model().tabs.contains(.changes))

        let result = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "changes", surfaceID: nil)

        XCTAssertEqual(result.kind, "changes")
        XCTAssertTrue(result.wasOpen)
        XCTAssertFalse(try model().tabs.contains(.changes))
    }

    func testClosingAnAlreadyClosedSingletonIsANoOpSuccess() throws {
        let result = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "verification", surfaceID: nil)

        XCTAssertEqual(result.kind, "verification")
        XCTAssertFalse(result.wasOpen)
    }

    func testClosingTheSameSingletonTwiceIsIdempotent() throws {
        _ = try WorkspaceActions.shared.openTab(workstreamID: workstreamID, kind: "changes")

        let first = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "changes", surfaceID: nil)
        let second = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "changes", surfaceID: nil)

        XCTAssertTrue(first.wasOpen)
        XCTAssertFalse(second.wasOpen)
    }

    /// Going through `model.removeTab` is what guarantees this rather than a
    /// hand-rolled removal — the same claim `WorkspaceModelTests` already
    /// pins at the model layer; this is the wiring check that `closeTab`
    /// actually goes through it.
    func testClosingTheActiveSingletonReassignsSelection() throws {
        let m = try model()
        m.activateSingleton(.changes)
        XCTAssertEqual(m.activeTab, .changes)

        _ = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "changes", surfaceID: nil)

        XCTAssertNotEqual(m.activeTab, .changes)
    }

    /// Execution used to be refused by name, because stopping the run meant
    /// reaching view-local `@State` this singleton could not see. It closes now:
    /// `ProcessCompose.RunSession` owns the run, the surface cache owns the
    /// session, and this calls the same `stopIfTabOwnsRun` the user's ⌘W does.
    func testExecutionClosesAndStopsTheRun() throws {
        _ = try WorkspaceActions.shared.openTab(workstreamID: workstreamID, kind: "execution")
        let session = surfaceCache.runSession(for: workstreamID)
        session.start(ProcessCompose.RunSession.StartContext(
            command: "just dev",
            workingDirectory: "/repo",
            environment: [:],
            launcherPath: nil,
            tmux: nil,
            shell: "/bin/zsh"
        ))
        XCTAssertTrue(session.runStarted)

        let result = try WorkspaceActions.shared.closeTab(
            workstreamID: workstreamID, kind: "execution", surfaceID: nil
        )

        XCTAssertEqual(result.kind, "execution")
        XCTAssertTrue(result.wasOpen)
        XCTAssertFalse(try model().tabs.contains(.execution))
        XCTAssertFalse(session.runStarted, "closing the run's owning tab must stop it")
    }

    /// Closing a tab that was already closed is success, not a refusal — and it
    /// must not stop a run, because the tab it would be stopping for was not
    /// there to own it.
    func testClosingAnUnopenedExecutionTabDoesNotStopTheRun() throws {
        let session = surfaceCache.runSession(for: workstreamID)
        session.start(ProcessCompose.RunSession.StartContext(
            command: "just dev",
            workingDirectory: "/repo",
            environment: [:],
            launcherPath: nil,
            tmux: nil,
            shell: "/bin/zsh"
        ))

        let result = try WorkspaceActions.shared.closeTab(
            workstreamID: workstreamID, kind: "execution", surfaceID: nil
        )

        XCTAssertFalse(result.wasOpen)
        XCTAssertTrue(session.runStarted)
    }

    /// The unknown-kind message lists every singleton an agent may close, and
    /// execution is one of them now.
    func testAnUnknownKindNamesTheClosableOnes() {
        XCTAssertThrowsError(
            try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: "logs", surfaceID: nil)
        ) { error in
            let text = self.message(error)
            XCTAssertTrue(text.contains("changes"), text)
            XCTAssertTrue(text.contains("execution"), text)
            XCTAssertTrue(text.contains("verification"), text)
        }
    }

    func testPermanentAndInstancedKindsAreNotClosableByName() {
        for kind in ["info", "agent", "terminal", "browser", "editor"] {
            XCTAssertThrowsError(
                try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: kind, surfaceID: nil),
                "\(kind) must not be closeable by kind"
            )
        }
    }

    // MARK: - Closing a terminal by surface id

    func testClosingAnOpenTerminalRemovesTheTabAndTheSurface() throws {
        let m = try model()
        let terminalID = m.addTerminal()
        XCTAssertTrue(m.tabs.contains(.terminal(terminalID)))

        let result = try WorkspaceActions.shared.closeTab(
            workstreamID: workstreamID, kind: nil, surfaceID: terminalID.uuidString
        )

        XCTAssertEqual(result.kind, "terminal")
        XCTAssertTrue(result.wasOpen)
        XCTAssertFalse(m.tabs.contains(.terminal(terminalID)))
    }

    /// The behavioural half of `isSafeToReplay`: closing the same terminal
    /// twice must not error the second time, because a replay lands after
    /// Atelier already acted on the first copy.
    func testClosingTheSameTerminalTwiceIsIdempotent() throws {
        let m = try model()
        let terminalID = m.addTerminal()

        let first = try WorkspaceActions.shared.closeTab(
            workstreamID: workstreamID, kind: nil, surfaceID: terminalID.uuidString
        )
        let second = try WorkspaceActions.shared.closeTab(
            workstreamID: workstreamID, kind: nil, surfaceID: terminalID.uuidString
        )

        XCTAssertTrue(first.wasOpen)
        XCTAssertEqual(first.kind, "terminal")
        XCTAssertFalse(second.wasOpen)
        XCTAssertNil(second.kind, "nothing owns that id any more, so no kind should be claimed")
    }

    func testASurfaceIDNothingOwnsIsANoOpRatherThanAnError() throws {
        let result = try WorkspaceActions.shared.closeTab(
            workstreamID: workstreamID, kind: nil, surfaceID: UUID().uuidString
        )

        XCTAssertFalse(result.wasOpen)
        XCTAssertNil(result.kind)
    }

    func testAMalformedSurfaceIDIsRejected() {
        XCTAssertThrowsError(
            try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: nil, surfaceID: "not-a-uuid")
        ) { error in
            XCTAssertTrue(self.message(error).contains("surface_id"), self.message(error))
        }
    }

    /// The Agent tab's surface id *is* the workstream id — the identity
    /// `AgentNudge` and `PeerInfo.surfaceID` already rely on. An agent
    /// passing its own main session's surface id must be refused, not
    /// treated as "nothing to close" — those are different facts.
    func testClosingTheAgentTabBySurfaceIDIsRefused() throws {
        XCTAssertThrowsError(
            try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: nil, surfaceID: workstreamID.uuidString)
        ) { error in
            XCTAssertTrue(self.message(error).contains("Agent tab"), self.message(error))
        }
        XCTAssertTrue(try model().tabs.contains(.agent), "refusing must not close it as a side effect")
    }

    func testClosingTheActiveTerminalReassignsSelection() throws {
        let m = try model()
        let terminalID = m.addTerminal()
        XCTAssertEqual(m.activeTab, .terminal(terminalID))

        _ = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: nil, surfaceID: terminalID.uuidString)

        XCTAssertNotEqual(m.activeTab, .terminal(terminalID))
    }

    /// One of two terminals closes without disturbing the other — addressing
    /// by surface id, not by kind, is the whole reason this path exists.
    func testClosingOneTerminalLeavesOthersUntouched() throws {
        let m = try model()
        let first = m.addTerminal()
        let second = m.addTerminal()

        _ = try WorkspaceActions.shared.closeTab(workstreamID: workstreamID, kind: nil, surfaceID: first.uuidString)

        XCTAssertFalse(m.tabs.contains(.terminal(first)))
        XCTAssertTrue(m.tabs.contains(.terminal(second)))
    }
}
