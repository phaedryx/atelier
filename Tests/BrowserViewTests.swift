// ABOUTME: Tests for browser web view caching in TerminalSurfaceCache.
// ABOUTME: Verifies cached WKWebView instances are reused across tab switches.

@testable import Atelier
import WebKit
import XCTest

@MainActor
final class BrowserViewTests: XCTestCase {
    func testWebViewCacheReturnsSameInstance() {
        let cache = TerminalSurfaceCache()
        let id = UUID()

        let first = cache.webView(for: id)
        let second = cache.webView(for: id)

        XCTAssertTrue(first === second, "Cache should return the same WKWebView instance")
    }

    func testWebViewCacheReturnsDifferentInstancesForDifferentIDs() {
        let cache = TerminalSurfaceCache()
        let id1 = UUID()
        let id2 = UUID()

        let view1 = cache.webView(for: id1)
        let view2 = cache.webView(for: id2)

        XCTAssertFalse(view1 === view2, "Different IDs should get different WKWebView instances")
    }

    func testRemoveWebViewClearsCache() {
        let cache = TerminalSurfaceCache()
        let id = UUID()

        let first = cache.webView(for: id)
        cache.removeWebView(for: id)
        let second = cache.webView(for: id)

        XCTAssertFalse(first === second, "After removal, a new WKWebView instance should be created")
    }

    /// The test above holds `first` for its whole body, so it proves the id was
    /// remapped and nothing about whether the cache let go — the leak it reads as
    /// covering. A weak reference is the only thing that can tell those apart.
    func testRemoveWebViewReleasesTheCachedInstance() {
        let cache = TerminalSurfaceCache()
        let id = UUID()

        weak var cached: WKWebView?
        autoreleasepool {
            cached = cache.webView(for: id)
        }
        XCTAssertNotNil(cached, "precondition: the cache is the one holding it")

        autoreleasepool {
            cache.removeWebView(for: id)
        }

        XCTAssertNil(cached, "removeWebView must drop the cache's own reference, not just unmap the id")
    }

    /// `coordinator is WKUIDelegate` proved only that the type declares the
    /// conformance: nothing assigned `uiDelegate` and nothing invoked anything through
    /// it. This drives the override instead, and pins two things that were unasserted
    /// — the identifier the removal matches on, and that it removes *only* that item.
    ///
    /// What it deliberately does not cover: the ordering bug that shipped here (the
    /// removal running ahead of `super.willOpenMenu`, which is what populates the menu
    /// from the responder chain). It cannot. The menu below is populated by the test,
    /// not by `super`, so on a `WKWebView` with no loaded page and a synthetic event
    /// `super` contributes nothing and both orderings pass — verified by reverting the
    /// fix and watching this test stay green. Observing the ordering needs a live page
    /// and a real right-click, which is a UI test, not this. The ordering is held by
    /// the comment at the call site.
    func testWillOpenMenuRemovesOnlyTheOpenLinkInNewWindowItem() throws {
        let webView = BrowserWebView()
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open Link in New Window", identifier: "WKMenuItemIdentifierOpenLinkInNewWindow"))
        menu.addItem(menuItem(title: "Copy", identifier: "WKMenuItemIdentifierCopy"))
        menu.addItem(menuItem(title: "Reload", identifier: "WKMenuItemIdentifierReload"))

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        webView.willOpenMenu(menu, with: event)

        XCTAssertEqual(
            menu.items.compactMap(\.identifier?.rawValue),
            ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierReload"],
            "only the new-window item goes, and it goes after super has populated the menu"
        )
    }

    private func menuItem(title: String, identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    func testCoordinatorConformsToWKUIDelegate() {
        let webView = WKWebView()
        let representable = WebViewRepresentable(
            webView: webView,
            isLoading: .constant(false),
            canGoBack: .constant(false),
            canGoForward: .constant(false),
            urlText: .constant(""),
            connectionError: .constant(false),
            pageTitle: .constant(nil)
        )
        let coordinator = representable.makeCoordinator()
        XCTAssertTrue(coordinator is WKUIDelegate, "Coordinator should conform to WKUIDelegate")
    }
}
