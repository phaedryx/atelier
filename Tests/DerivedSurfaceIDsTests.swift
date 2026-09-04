// ABOUTME: Tests that archiving a workstream enumerates every surface id it ever created.
// ABOUTME: The per-kind counters are monotonic and persisted, so a fixed 0..99 sweep loses them.

@testable import Atelier
import XCTest

@MainActor
final class DerivedSurfaceIDsTests: XCTestCase {
    private let workstreamID = UUID(uuidString: "6E8C9E4A-1F2B-4C3D-9E5A-7B8C9D0E1F20")!

    private func ids(
        terminals: Int = 0,
        browsers: Int = 0,
        editors: Int = 0,
        runGeneration: Int = 0
    ) -> Set<UUID> {
        TerminalSurfaceCache.derivedSurfaceIDs(
            for: workstreamID,
            terminalCount: terminals,
            browserCount: browsers,
            editorCount: editors,
            runGeneration: runGeneration
        )
    }

    /// `WorkspaceModel`'s counters are monotonic and ride in `WorkspaceTabSnapshot`,
    /// so a workstream that has opened 101 terminal tabs over its lifetime holds a
    /// live surface at `terminal-101`. The old sweep hardcoded `0 ... 99` and could
    /// not reach it: archiving left a ghostty surface and its shell running for the
    /// rest of the process.
    func testReachesATerminalPastTheOldHardcodedHundred() {
        let leaked = derivedUUID(from: workstreamID, salt: "terminal-101")
        XCTAssertTrue(ids(terminals: 101).contains(leaked))
    }

    func testReachesABrowserAndAnEditorPastTheOldHardcodedHundred() {
        XCTAssertTrue(ids(browsers: 140).contains(derivedUUID(from: workstreamID, salt: "browser-140")))
        XCTAssertTrue(ids(editors: 140).contains(derivedUUID(from: workstreamID, salt: "editor-140")))
    }

    func testCoversEveryGenerationUpToTheCurrentRun() {
        let swept = ids(runGeneration: 3)
        for generation in 0 ... 3 {
            XCTAssertTrue(
                swept.contains(derivedUUID(from: workstreamID, salt: "env-run-\(generation)")),
                "env-run-\(generation) must be swept"
            )
        }
    }

    func testCoversEveryCountUpToTheCurrentOne() {
        let swept = ids(terminals: 2, browsers: 2, editors: 2)
        for index in 0 ... 2 {
            for prefix in ["terminal", "browser", "editor"] {
                XCTAssertTrue(swept.contains(derivedUUID(from: workstreamID, salt: "\(prefix)-\(index)")))
            }
        }
    }

    /// Nothing derives an `env-setup-N` id; the prefix outlived the feature and
    /// only ever cost 100 hashes per archive.
    func testDoesNotSweepTheEnvSetupPrefixNothingCreates() {
        let swept = ids(terminals: 5, browsers: 5, editors: 5, runGeneration: 5)
        for index in 0 ... 5 {
            XCTAssertFalse(swept.contains(derivedUUID(from: workstreamID, salt: "env-setup-\(index)")))
        }
    }

    /// The bound is what was created, not a fixed ceiling: a fresh workstream
    /// sweeps a handful of ids rather than five hundred.
    func testAFreshWorkstreamSweepsOnlyTheZeroGeneration() {
        XCTAssertEqual(ids().count, 4)
    }
}
