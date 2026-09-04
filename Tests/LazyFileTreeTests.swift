// ABOUTME: Tests for FileNode's lazy directory tree and the DirectoryWatcher behind it.
// ABOUTME: A directory that cannot be read must not be reported as an empty one.

@testable import Atelier
import XCTest

final class LazyFileTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lazy-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Put permissions back or the cleanup cannot descend.
        if let root {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appendingPathComponent("src").path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    // MARK: - Shallow build

    func testBuildsTheRootLevelWithDirectoriesUnloaded() throws {
        try write("src/a.swift")
        try write("README.md")

        let nodes = FileNode.buildShallowTree(rootPath: root.path)

        XCTAssertEqual(nodes.map(\.name), ["src", "README.md"])
        XCTAssertFalse(try XCTUnwrap(nodes.first).isLoaded, "Directories load lazily")
    }

    func testAnEmptyDirectoryLoadsAsAnEmptyChildList() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(FileNode.loadChildren(atRelativePath: "empty", rootPath: root.path).isEmpty)
    }

    // MARK: - Refresh

    func testRefreshKeepsLoadedChildrenAndPicksUpNewFiles() throws {
        try write("src/a.swift")

        var tree = FileNode.buildShallowTree(rootPath: root.path)
        tree = FileNode.insertChildren(
            FileNode.loadChildren(atRelativePath: "src", rootPath: root.path),
            atPath: "src",
            in: tree
        )
        try write("src/b.swift")

        let refreshed = FileNode.refreshLoadedNodes(in: tree, rootPath: root.path)
        let src = try XCTUnwrap(refreshed.first { $0.name == "src" })
        XCTAssertEqual(src.children?.map(\.name), ["a.swift", "b.swift"])
    }

    /// `buildShallowChildren` answered `[]` for both "this directory is empty"
    /// and "the read threw" — permission denied, or a path that blinked out from
    /// under a background refresh. `mergeNodes` mapped that onto the node, so one
    /// transient failure collapsed a subtree the user had expanded.
    func testAnUnreadableDirectoryKeepsItsPreviouslyLoadedChildren() throws {
        try write("src/a.swift")
        try write("src/b.swift")

        var tree = FileNode.buildShallowTree(rootPath: root.path)
        tree = FileNode.insertChildren(
            FileNode.loadChildren(atRelativePath: "src", rootPath: root.path),
            atPath: "src",
            in: tree
        )

        let src = root.appendingPathComponent("src")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: src.path) }

        let refreshed = FileNode.refreshLoadedNodes(in: tree, rootPath: root.path)
        let node = try XCTUnwrap(refreshed.first { $0.name == "src" })
        XCTAssertEqual(node.children?.map(\.name), ["a.swift", "b.swift"])
    }

    func testAnUnreadableRootLeavesTheTreeAlone() throws {
        try write("src/a.swift")
        let tree = FileNode.buildShallowTree(rootPath: root.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }

        XCTAssertEqual(
            FileNode.refreshLoadedNodes(in: tree, rootPath: root.path).map(\.name),
            tree.map(\.name)
        )
    }

    // MARK: - DirectoryWatcher

    func testWatcherReportsAChangeAndGoesQuietAfterStop() throws {
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        var afterStop: XCTestExpectation?
        let watcher = DirectoryWatcher(path: root.path) {
            if let afterStop {
                afterStop.fulfill()
            } else {
                fired.fulfill()
            }
        }

        try write("touched.txt")
        wait(for: [fired], timeout: 10)

        // A callback already queued on the main run loop when the watcher is
        // released is what used to reach freed memory; after stop() nothing may
        // arrive at all.
        let quiet = expectation(description: "no callback after stop")
        quiet.isInverted = true
        afterStop = quiet
        watcher.stop()
        try write("touched-again.txt")
        wait(for: [quiet], timeout: 3)
    }
}
