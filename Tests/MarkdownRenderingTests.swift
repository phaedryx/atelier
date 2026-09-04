// ABOUTME: Pins cmark-gfm's safe mode for the markdown a repository or Shortcut story supplies.
// ABOUTME: Raw HTML and javascript:/data: links must not reach the WKWebView that renders it.

@testable import Atelier
import XCTest

final class MarkdownRenderingTests: XCTestCase {
    /// `MarkdownView`'s header says it strips raw HTML, and cmark-gfm's safe mode
    /// — the default since 0.29, enabled unless `CMARK_OPT_UNSAFE` is passed —
    /// is what makes that true. The markdown rendered here is a Shortcut story
    /// description, so it is remote text: this pins the option rather than
    /// trusting the comment.
    func testRawHTMLBlocksDoNotSurvive() {
        let html = renderMarkdownToHTML("<iframe src=\"https://example.com\"></iframe>")
        XCTAssertFalse(html.lowercased().contains("<iframe"))
    }

    func testInlineHTMLDoesNotSurvive() {
        let html = renderMarkdownToHTML("Hello <img src=x onerror=alert(1)> there")
        XCTAssertFalse(html.lowercased().contains("<img"))
        XCTAssertFalse(html.lowercased().contains("onerror"))
    }

    func testJavascriptLinksAreStripped() {
        let html = renderMarkdownToHTML("[click](javascript:alert(1))")
        XCTAssertFalse(html.lowercased().contains("javascript:"))
    }

    func testOrdinaryMarkdownStillRenders() {
        let html = renderMarkdownToHTML("# Title\n\n- one\n- two\n")
        XCTAssertTrue(html.contains("<h1>"))
        XCTAssertTrue(html.contains("<li>"))
    }

    func testTablesStillRenderThroughTheGFMExtension() {
        let html = renderMarkdownToHTML("| a | b |\n| - | - |\n| 1 | 2 |\n")
        XCTAssertTrue(html.contains("<table>"))
    }
}
