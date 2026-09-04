// ABOUTME: Tests for MonacoDiffBridge's ownership of its WKScriptMessageHandler coordinator.
// ABOUTME: Pins that the coordinator does not retain the bridge, so the diff WebView can die.

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
}
