// ABOUTME: End-to-end check that the Monaco bundle actually loads through the scheme handler.
// ABOUTME: A rejected asset fails silently as a blank pane, so unit-testing `resolve` is not enough.

@testable import Atelier
import WebKit
import XCTest

/// Drives a real `WKWebView` through the real `MonacoResourceSchemeHandler`
/// against the real bundle.
///
/// The containment rule and the MIME table both got stricter, and both fail
/// *silently*: a rejected request becomes `didFailWithError`, WebKit refuses a
/// script or font with the wrong type without a visible error, and the editor
/// pane simply renders blank. Nothing short of loading the page catches that —
/// `resolve` returning the right URL for a path says nothing about whether
/// WebKit accepted what came back.
@MainActor
final class MonacoAssetPipelineTests: XCTestCase {
    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        let finished = XCTestExpectation(description: "diff.html finished loading")
        var failure: Error?

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            finished.fulfill()
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            failure = error
            finished.fulfill()
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            failure = error
            finished.fulfill()
        }
    }

    func testTheDiffPageLoadsAndItsScriptsRunThroughTheSchemeHandler() async throws {
        let base = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("MonacoEditor")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: base.appendingPathComponent("diff.html").path),
            "MonacoEditor bundle is built by scripts/build-editor.sh"
        )

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MonacoResourceSchemeHandler(baseURL: base),
            forURLScheme: "atelier-resource"
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let delegate = LoadDelegate()
        webView.navigationDelegate = delegate

        let url = try XCTUnwrap(URL(string: "atelier-resource://monaco/diff.html"))
        webView.load(URLRequest(url: url))
        await fulfillment(of: [delegate.finished], timeout: 30)
        XCTAssertNil(delegate.failure, "diff.html failed to load")

        // `window.diffAPI` is assigned at the end of diff.js, which the page pulls
        // through this handler along with everything diff.js itself imports —
        // Monaco included. If any module in that chain were rejected on
        // containment or refused on MIME type, it never appears, which is exactly
        // what a blank pane looks like.
        //
        // Polled rather than read at `didFinish`: that fires once the document is
        // parsed, while the module graph is still loading. `readyState` is
        // `interactive` at that point by design.
        var hasAPI = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !hasAPI {
            hasAPI = try await (webView.evaluateJavaScript(
                "typeof window.diffAPI === 'object' && typeof window.diffAPI.setFiles === 'function'"
            ) as? Bool) ?? false
            if !hasAPI {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        XCTAssertTrue(hasAPI, "diff.js did not finish executing — an asset was refused")

        let state = try await webView.evaluateJavaScript("document.readyState") as? String
        XCTAssertEqual(state, "complete")
    }
}
