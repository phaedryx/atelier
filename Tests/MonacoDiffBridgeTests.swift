// ABOUTME: Tests for MonacoDiffBridge's ownership of its coordinator and its queued operations.
// ABOUTME: Pins that neither edge retains the bridge, so the diff WebView can die with its workstream.

@testable import Atelier
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

    /// The whole graph, rooted at the bridge: a real WebView, its content controller
    /// holding the coordinator, and operations queued while diff.js has not reported
    /// ready. That last one is its own cycle — `pendingOps` is a stored property, so a
    /// queued closure capturing `self` strongly is only ever broken by `markReady`'s
    /// flush, which never runs when the Monaco bundle fails to load. Under XCTest it
    /// never runs, which is exactly the state this pins.
    func testBridgeDeallocatesWithAWebViewAndQueuedOperations() {
        weak var weakBridge: MonacoDiffBridge?

        autoreleasepool {
            let bridge = MonacoDiffBridge()
            _ = bridge.ensureWebView()
            bridge.setFiles([["filePath": "queued-while-not-ready"]])
            bridge.relayout()
            weakBridge = bridge
        }

        XCTAssertNil(weakBridge, "Bridge must not be retained by its coordinator or its queued operations")
    }
}
