// ABOUTME: Tests that a surface id resolves to the workstream that owns it.
// ABOUTME: `.terminalActivity`'s two receivers key by workstream id, so an unresolved surface moves nothing.

@testable import Atelier
import XCTest

@MainActor
final class TerminalActivityOwnerTests: XCTestCase {
    private let workstreamID = UUID(uuidString: "3D1C7A90-55E2-4F1B-9A44-0C2E6B8D1A33")!

    private func cacheWithModel() -> (TerminalSurfaceCache, WorkspaceModel) {
        let cache = TerminalSurfaceCache()
        let model = cache.workspaceModel(
            for: workstreamID,
            seed: startupWorkspaceTabState(savedTab: nil)
        )
        return (cache, model)
    }

    /// The bug this closes: a terminal tab's surface id is derived from its
    /// workstream's, so posting it moved nothing in Recent order and refreshed
    /// no worktree state — an hour's work in a terminal tab was invisible.
    func testATerminalTabResolvesToItsWorkstream() {
        let (cache, model) = cacheWithModel()
        let surfaceID = model.addTerminal()
        XCTAssertNotEqual(surfaceID, workstreamID)
        XCTAssertEqual(cache.workstreamID(owningSurface: surfaceID), workstreamID)
    }

    /// The Coding Agent's surface id *is* the workstream id, which is why that
    /// one tab worked before this existed. It has to keep working.
    func testTheAgentSurfaceResolvesToItself() {
        let (cache, _) = cacheWithModel()
        XCTAssertEqual(cache.workstreamID(owningSurface: workstreamID), workstreamID)
    }

    func testASurfaceNothingClaimsResolvesToNothing() {
        let (cache, _) = cacheWithModel()
        XCTAssertNil(cache.workstreamID(owningSurface: UUID()))
    }

    /// A browser tab has a surface id of the same shape and no terminal behind
    /// it, so it must not be mistaken for one.
    func testABrowserTabIsNotATerminal() {
        let (cache, model) = cacheWithModel()
        let browserID = model.addBrowser()
        XCTAssertNil(cache.workstreamID(owningSurface: browserID))
    }
}
