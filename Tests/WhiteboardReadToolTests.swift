// ABOUTME: Pins read_whiteboard's registry facts and the answer it gives per board state.
// ABOUTME: Its description is the discovery mechanism — there is no fourth system prompt.

@testable import Atelier
import XCTest

final class WhiteboardReadToolTests: XCTestCase {
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
    {"id":"n","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false}]}
    """

    // MARK: - Registry facts

    func test_itIsAWorkspaceReadOnTheFifteenSecondTier() {
        let spec = IPC.Tool.readWhiteboard.spec
        // No new Surface case: this acts on the caller's own workstream, which
        // is `.workspaceRead`'s stated charter. The trust argument is inherited
        // rather than rewritten.
        XCTAssertEqual(spec.surface, .workspaceRead)
        // File IO and no main-actor hop, the same tier as the other reads.
        XCTAssertEqual(spec.replyDeadline, IPC.ToolSpec.Deadline.immediate)
    }

    func test_itIsReplayable_becauseItChangesNothing() {
        XCTAssertTrue(IPC.Tool.readWhiteboard.isSafeToReplay)
    }

    func test_itsDescriptionTellsTheAgentToOpenThePNG() {
        // Load-bearing rather than nice prose. There is deliberately no fourth
        // system prompt, so this description is the only place an agent is told
        // that the picture exists and that it has to open it to see freehand and
        // images. An agent that reads only the digest concludes the board is
        // five boxes.
        let description = IPC.Tool.readWhiteboard.spec.description.lowercased()
        XCTAssertTrue(description.contains("board.png"))
        XCTAssertTrue(description.contains("read"))
        XCTAssertTrue(description.contains("freehand"))
    }

    func test_itsDescriptionPointsAtOpenTabForTheUsersEyes() {
        // The board starts closed, and reading it does not open it. An agent
        // that wants the user to look has to be told how.
        let description = IPC.Tool.readWhiteboard.spec.description
        XCTAssertTrue(description.contains("open_tab"), description)
    }

    func test_noFourthSystemPromptWasAdded() {
        // This tool is exactly where one would have been added, so the list is
        // pinned here. Assembled with every gate open, the prompt is the same
        // three it has always been and says nothing about a whiteboard.
        let prompt = Workstream.AgentCommand.systemPrompt(
            allowOutsideWorktree: false,
            autoRenameBranch: true,
            worktreePath: "/tmp/wt",
            workstreamName: "ws",
            mcpConfigWritten: true
        )
        let assembled = try? XCTUnwrap(prompt)
        XCTAssertEqual(assembled?.components(separatedBy: "\n\n").isEmpty, false)
        XCTAssertEqual(assembled?.lowercased().contains("whiteboard"), false)
        XCTAssertEqual(assembled?.lowercased().contains("board.png"), false)
    }

    // MARK: - The answer, per board state

    func test_anEmptyBoardIsAnswered_notRefused() {
        // Every workstream starts here. An empty board and a broken board must
        // never render as the same sentence.
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        XCTAssertTrue(text.lowercased().contains("empty"), text)
        XCTAssertFalse(text.lowercased().contains("could not be read"), text)
    }

    func test_aBrokenBoardIsAnswered_withADifferentSentence() throws {
        try Whiteboard.Store.saveScene("{not json", for: workstreamID)
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        XCTAssertTrue(text.lowercased().contains("could not be read"), text)
        XCTAssertFalse(text.lowercased().contains("nothing has been drawn"), text)
    }

    func test_theAnswerCarriesTheAbsolutePathToThePNGAndItsSize() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        try Whiteboard.Store.writeRender(png: Data([0x89]), width: 640, height: 480, for: workstreamID)
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        let path = Whiteboard.Store.pngURL(for: workstreamID).path
        // Absolute, because the agent's cwd is its worktree and the board lives
        // in the cache directory — a relative path is unresolvable from there.
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(text.contains(path), text)
        XCTAssertTrue(text.contains("640×480"), text)
    }

    func test_aFailedRenderIsReportedAsStale_notPassedOffAsFresh() throws {
        try Whiteboard.Store.saveScene(Self.scene, for: workstreamID)
        try Whiteboard.Store.writeRender(png: Data([0x89]), width: 640, height: 480, for: workstreamID)
        Whiteboard.Store.invalidateRender(for: workstreamID)
        let text = Whiteboard.Store.digestText(for: workstreamID, now: Date())
        XCTAssertTrue(text.lowercased().contains("earlier version"), text)
        XCTAssertTrue(text.lowercased().contains("digest below is current"), text)
    }
}
