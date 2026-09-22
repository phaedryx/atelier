// ABOUTME: Pins that an agent's whiteboard write opens the Whiteboard tab only once the write has landed.
// ABOUTME: A refused write must leave the user's workspace exactly as it found it.

@testable import Atelier
import XCTest

/// These run a real `Whiteboard.Host` — an offscreen `WKWebView` holding the
/// built whiteboard bundle — which works here because `TEST_HOST` is
/// `Atelier.app`, so `Bundle.main` resolves `MonacoEditor`. Nothing about the
/// board needs libghostty. That is what makes the success path reachable from
/// XCTest at all; anything that is a claim about what the *page* does with what
/// it is handed still belongs in `Tests/Harnesses/whiteboard-harness.swift`.
@MainActor
final class WhiteboardWriteTabTests: XCTestCase {
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
        // No libghostty in a unit-test host — the same seam
        // WorkspaceActionsCloseTabTests opens. The board needs none of it.
        surfaceCache.terminalApp = { nil }
        WorkspaceActions.shared.projectList = list
        WorkspaceActions.shared.surfaceCache = surfaceCache
    }

    override func tearDown() {
        // The host is deliberately left standing. `removeWhiteboardHost` calls
        // `Host.teardown`, which closes the offscreen `NSWindow` the host also
        // holds strongly — and `WhiteboardHost.swift` never sets
        // `isReleasedWhenClosed`, so it keeps its default of true and the close
        // over-releases it: measured here, the process segfaults in the next
        // autorelease pool pop, after `teardown` has already returned. That is a
        // separate bug and not this file's to fix; what it costs here is one
        // parked offscreen webview per test, which the suite carries fine.
        Whiteboard.Store.sweep(for: workstreamID)
        WorkspaceActions.shared.projectList = nil
        WorkspaceActions.shared.surfaceCache = nil
        projectList = nil
        surfaceCache = nil
        workstreamID = nil
        super.tearDown()
    }

    private func tabs() throws -> [WorkspaceTab] {
        try WorkspaceActions.shared.context(workstreamID: workstreamID).model.tabs
    }

    func test_aRefusedWriteLeavesTheWorkspaceExactlyAsItFoundIt() async throws {
        let before = try tabs()
        XCTAssertFalse(before.contains(.whiteboard), "\(before)")

        // An unknown `kind` — a typo is the ordinary way to reach this. The
        // refusal comes from `Whiteboard.Write.addPlan`, which runs after the
        // host has been built and the live page read, so this is what pins that
        // building the host is not the same act as putting a pane in front of
        // the user.
        do {
            _ = try await WorkspaceActions.shared.whiteboardAdd(
                workstreamID: workstreamID,
                elementsJSON: #"[{"kind":"blob","text":"hi"}]"#
            )
            XCTFail("expected an unknown kind to be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("blob"), "\(error)")
        }

        XCTAssertEqual(try tabs(), before)
    }

    func test_aWriteThatLandsOpensTheBoardExactlyOnce() async throws {
        let start = try tabs()
        XCTAssertFalse(start.contains(.whiteboard), "\(start)")

        _ = try await WorkspaceActions.shared.whiteboardAdd(
            workstreamID: workstreamID,
            elementsJSON: #"[{"kind":"box","text":"one"}]"#
        )
        var open = try tabs()
        XCTAssertEqual(open.filter { $0 == .whiteboard }.count, 1, "\(open)")

        // `ensureSingleton` and not `activateSingleton`, and a singleton: a
        // second write must not stack a second board tab.
        _ = try await WorkspaceActions.shared.whiteboardAdd(
            workstreamID: workstreamID,
            elementsJSON: #"[{"kind":"box","text":"two"}]"#
        )
        open = try tabs()
        XCTAssertEqual(open.filter { $0 == .whiteboard }.count, 1, "\(open)")
    }

    func test_aRefusedWriteAfterTheBoardIsOpenLeavesItOpen() async throws {
        // The other direction of the same rule: the tab the user already has is
        // not closed by a refusal either — the write simply does nothing.
        //
        // A companion assertion, not an independent regression guard: it passes
        // on the old ordering too, because a board already open stays open
        // whichever act opened it. The test above is the one with teeth.
        _ = try await WorkspaceActions.shared.whiteboardAdd(
            workstreamID: workstreamID,
            elementsJSON: #"[{"kind":"box","text":"one"}]"#
        )
        let before = try tabs()
        XCTAssertTrue(before.contains(.whiteboard))

        do {
            _ = try await WorkspaceActions.shared.whiteboardUpdate(
                workstreamID: workstreamID,
                id: "nothing-on-this-board",
                at: nil,
                text: "x",
                color: nil
            )
            XCTFail("expected an unknown element to be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("nothing-on-this-board"), "\(error)")
        }

        XCTAssertEqual(try tabs(), before)
    }
}
