// ABOUTME: Tests that the callbacks ChangesView installs on MonacoDiffBridge do not capture the view.
// ABOUTME: ChangesView is a struct holding `let bridge`, so a captured self is a cycle through the bridge.

@testable import Atelier
import SwiftUI
import XCTest

@MainActor
final class ChangesViewBridgeHandlerTests: XCTestCase {
    private func makeView(
        bridge: MonacoDiffBridge,
        annotations: ChangeAnnotationStore = ChangeAnnotationStore()
    ) -> ChangesView {
        ChangesView(
            workstreamID: UUID(),
            workingDirectory: NSTemporaryDirectory(),
            projectDirectory: NSTemporaryDirectory(),
            bridge: bridge,
            annotations: annotations
        )
    }

    /// `onLoadFile` and `onCommentEvent` are stored properties of the bridge, and the
    /// view that fills them is a struct carrying `let bridge`. A closure touching
    /// `self` — a `@State` write, an `@ObservedObject` read, an instance method call —
    /// therefore captures that reference straight back into the bridge's own storage.
    /// Nothing ever clears the slots, so such a cycle is permanent, and unlike
    /// `pendingOps` it needs no failure to reach: the ordinary load path installs it.
    func testInstalledHandlersDoNotRetainTheBridge() {
        weak var weakBridge: MonacoDiffBridge?

        autoreleasepool {
            let bridge = MonacoDiffBridge()
            makeView(bridge: bridge).installBridgeHandlers()
            weakBridge = bridge
        }

        XCTAssertNil(weakBridge, "Handlers installed on the bridge must not capture the view that installed them")
    }

    /// The same rule for the one installed per load rather than per appearance. The
    /// binding stands in for the view's own `@State`: what is pinned is that the
    /// installer stores a closure over the flag's storage and not over the view.
    func testContentReadyHandlerDoesNotRetainTheBridge() {
        weak var weakBridge: MonacoDiffBridge?
        var flag = true

        autoreleasepool {
            let bridge = MonacoDiffBridge()
            makeView(bridge: bridge).clearWhenContentReady(
                Binding(get: { flag }, set: { flag = $0 })
            )
            weakBridge = bridge
        }

        XCTAssertNil(weakBridge, "The content-ready handler must not capture the view that installed it")
    }

    /// Breaking the cycle must not break the feature: the handler still routes a
    /// comment into the store once the view that installed it is gone. It reaches the
    /// store and the bridge through its own captures rather than through `self`.
    func testCommentHandlerStillRoutesAfterTheViewIsGone() {
        let bridge = MonacoDiffBridge()
        let annotations = ChangeAnnotationStore()

        autoreleasepool {
            makeView(bridge: bridge, annotations: annotations).installBridgeHandlers()
        }

        bridge.onCommentEvent?(
            .added(
                filePath: "a.swift",
                side: .new,
                line: 3,
                endLine: nil,
                lineText: "let x = 1",
                text: "needs a name"
            )
        )

        XCTAssertEqual(
            annotations.comments(mode: .branch).map(\.text),
            ["needs a name"],
            "The handler must still reach the store it captured"
        )
    }
}
