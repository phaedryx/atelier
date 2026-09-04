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
    /// It does not pin the ordering; the menu here is populated by the test rather
    /// than by the population step, so both orderings pass it. That is
    /// `testWillOpenMenuRemovesItemsThePopulationStepAdded`'s job.
    func testWillOpenMenuRemovesOnlyTheOpenLinkInNewWindowItem() throws {
        let webView = BrowserWebView()
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open Link in New Window", identifier: "WKMenuItemIdentifierOpenLinkInNewWindow"))
        menu.addItem(menuItem(title: "Copy", identifier: "WKMenuItemIdentifierCopy"))
        menu.addItem(menuItem(title: "Reload", identifier: "WKMenuItemIdentifierReload"))

        try webView.willOpenMenu(menu, with: rightClick())

        XCTAssertEqual(
            menu.items.compactMap(\.identifier?.rawValue),
            ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierReload"],
            "only the new-window item goes"
        )
    }

    /// The bug that shipped here ran the removal *before* the menu was populated, so
    /// it filtered an empty menu and the item survived into the real context menu.
    /// Nothing caught it: on a `WKWebView` with no loaded page `super.willOpenMenu`
    /// contributes no items, so a test that populates the menu itself passes either
    /// way. `populateMenu` exists so the population step can be substituted for one
    /// that does add an item — which is what `super` does against a live page — and
    /// the ordering becomes observable without a UI test target.
    ///
    /// Scope, exactly: this pins the *order* of the two steps. It does not pin
    /// `populateMenu`'s body — the double replaces it, so deleting the `super` call
    /// in production leaves this green (verified by mutation). `didPopulate` proves
    /// the substituted step ran, not that production reaches `super`.
    func testWillOpenMenuRemovesItemsThePopulationStepAdded() throws {
        let webView = PopulatingBrowserWebView()
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Copy", identifier: "WKMenuItemIdentifierCopy"))

        try webView.willOpenMenu(menu, with: rightClick())

        XCTAssertTrue(webView.didPopulate, "precondition: the substituted population step ran")
        XCTAssertEqual(
            menu.items.compactMap(\.identifier?.rawValue),
            ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierReload"],
            "the removal has to run after the menu is populated, or it filters an empty menu"
        )
    }

    /// Stands in for a `WKWebView` with a live page under the cursor: the population
    /// step adds the items the removal is supposed to act on.
    private final class PopulatingBrowserWebView: BrowserWebView {
        private(set) var didPopulate = false

        override func populateMenu(_ menu: NSMenu, with _: NSEvent) {
            didPopulate = true
            let newWindow = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
            newWindow.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
            menu.addItem(newWindow)
            let reload = NSMenuItem(title: "Reload", action: nil, keyEquivalent: "")
            reload.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierReload")
            menu.addItem(reload)
        }
    }

    private func rightClick(file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), file: file, line: line)
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
