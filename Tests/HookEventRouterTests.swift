// ABOUTME: Tests for HookEventRouter's path normalization and dispatch.
// ABOUTME: A project reached through a symlink must route to the same handler as its real path.

@testable import Atelier
import XCTest

final class HookEventRouterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testNormalizesTrailingComponentsAndRelativeSegments() {
        XCTAssertEqual(
            HookEventRouter.normalizePath("/tmp/project/../project/./"),
            HookEventRouter.normalizePath("/tmp/project")
        )
    }

    /// `Workstream.AgentStateTracker.normalize` resolves symlinks on exactly the
    /// same hook-payload paths, and says in its doc comment that it has to. The
    /// router did not, so a project opened through a symlink matched no handler
    /// and every one of its events was dropped.
    func testResolvesSymlinksSoBothSpellingsOfAPathAgree() throws {
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            HookEventRouter.normalizePath(link.path),
            HookEventRouter.normalizePath(real.path)
        )
    }

    func testRoutesAnEventArrivingBySymlinkToTheHandlerRegisteredForTheRealPath() throws {
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let router = HookEventRouter.shared
        defer { router.unregister(projectDir: real.path) }

        var received = 0
        router.register(projectDir: real.path) { _ in received += 1 }
        router.route(projectDir: link.path, event: .status(agentId: "main", status: "idleNotification"))

        XCTAssertEqual(received, 1)
    }
}
