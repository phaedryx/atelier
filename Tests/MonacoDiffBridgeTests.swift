// ABOUTME: Tests for MonacoDiffBridge's ownership of its coordinator and its installed callbacks.
// ABOUTME: Pins that neither edge retains the bridge, so the diff WebView can die with its workstream.

@testable import Atelier
import SwiftUI
import XCTest

@MainActor
final class MonacoDiffBridgeTests: XCTestCase {
    /// The bridge owns the coordinator, and the WKUserContentController the coordinator
    /// is registered on is reachable from the bridge's own WebView. A strong back-reference
    /// is therefore a cycle: nothing would ever release the bridge or its ~17 MB WebView.
    func testCoordinatorDoesNotRetainItsBridge() {
        weak var weakBridge: MonacoDiffBridge?
        var coordinator: MonacoDiffBridge.Coordinator?

        autoreleasepool {
            let bridge = MonacoDiffBridge()
            weakBridge = bridge
            coordinator = MonacoDiffBridge.Coordinator(bridge: bridge)
        }

        XCTAssertNil(weakBridge, "Coordinator must hold its bridge weakly")
        XCTAssertNotNil(coordinator, "Coordinator has to outlive the bridge without crashing")
    }

    /// The callbacks `ChangesView` installs are stored *on the bridge*, so they
    /// outlive the view body. `ChangesView` is a struct holding `let bridge`, and a
    /// closure that reads `@State` or `@ObservedObject` captures a copy of the whole
    /// struct — bridge included. That closes the loop bridge → stored closure →
    /// ChangesView copy → bridge, permanently: `onContentReady` is reassigned on every
    /// load and every refresh, and nothing ever clears it.
    ///
    /// This runs the production installers rather than a lookalike, so the thing it
    /// pins is the real assignment site. Deliberately no `ensureWebView()`/`setFiles()`
    /// here: `MonacoDiffBridge.pendingOps` is a separate, still-open cycle, and a
    /// whole-graph test would fail on that one instead of this one.
    func testInstalledCallbacksDoNotRetainTheBridge() {
        weak var weakBridge: MonacoDiffBridge?
        let store = ChangeAnnotationStore()
        // Starts set, the way `isLoading` / `isRefreshing` do while a load is in flight.
        var isLoading = true
        let flag = Binding(get: { isLoading }, set: { isLoading = $0 })

        autoreleasepool {
            let bridge = MonacoDiffBridge()
            let view = ChangesView(
                workstreamID: UUID(),
                workingDirectory: NSTemporaryDirectory(),
                projectDirectory: NSTemporaryDirectory(),
                bridge: bridge,
                annotations: store
            )
            view.installContentReadyHandler(on: bridge, clearing: flag)
            view.installCommentHandler(on: bridge, store: store, mode: .branch)

            // Guard against a vacuous pass: a "fix" that installed nothing, or
            // installed a closure that does not do the job, must not go green here.
            XCTAssertNotNil(bridge.onContentReady, "The content-ready callback must actually be installed")
            XCTAssertNotNil(bridge.onCommentEvent, "The comment callback must actually be installed")
            bridge.onContentReady?()
            XCTAssertFalse(isLoading, "The content-ready callback must clear the flag it was handed")

            weakBridge = bridge
        }

        XCTAssertNil(weakBridge, "Bridge must not be retained by the callbacks ChangesView installs on it")
    }
}
