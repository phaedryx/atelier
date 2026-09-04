// ABOUTME: Renders markdown to HTML using cmark-gfm and displays it in a WKWebView.
// ABOUTME: Strips raw HTML from markdown for safe rendering.

import cmark_gfm
import cmark_gfm_extensions
import SwiftUI
import WebKit

struct MarkdownContentView: NSViewRepresentable {
    let markdown: String
    /// Called with the rendered document height once it has laid out. Only set by
    /// `SelfSizingMarkdownView`; the full-pane use fills its container and does not care.
    var onContentHeight: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(false, forKey: "javaScriptCanOpenWindowsAutomatically")
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Assigned before the guard: reporting a height re-renders the parent, which lands
        // back here with the markdown unchanged, and the callback must survive that.
        context.coordinator.onContentHeight = onContentHeight
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.lastMarkdown = markdown
        let html = renderMarkdownToHTML(markdown)
        let page = wrapInHTMLPage(html)
        webView.loadHTMLString(page, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastMarkdown: String?
        var onContentHeight: ((CGFloat) -> Void)?

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            measureContentHeight(webView)
            // `didFinish` can land before layout settles, and a first read that comes back
            // short would stick: unchanged markdown never triggers another load, so nothing
            // would measure again. One delayed re-read is what actually catches that.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak webView] in
                guard let self, let webView else { return }
                measureContentHeight(webView)
            }
        }

        private func measureContentHeight(_ webView: WKWebView) {
            guard let onContentHeight else { return }
            // `allowsContentJavaScript` gates scripts inside the loaded document, not
            // host-side evaluation. If that ever stops holding, the result is nil and the
            // caller keeps its fallback height rather than collapsing to nothing.
            let script = "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            webView.evaluateJavaScript(script) { value, _ in
                guard let number = value as? NSNumber, number.doubleValue > 0 else { return }
                onContentHeight(CGFloat(number.doubleValue))
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                // Only open absolute HTTP(S) links in the external browser.
                // Ignore anchor links, relative paths, and other schemes.
                if url.scheme == "https" || url.scheme == "http" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// A markdown pane that sizes itself to its content, for embedding inside a `Form` section.
///
/// `MarkdownContentView` wraps a `WKWebView`, which has no intrinsic content size. In the
/// full-height docs pane that is fine because it fills whatever it is given, but dropped into
/// a Form row it would collapse to nothing. This measures the rendered document instead, and
/// caps the result so a long story description cannot push the rest of the tab off-screen.
struct SelfSizingMarkdownView: View {
    let markdown: String
    var maxHeight: CGFloat = 320

    @State private var contentHeight: CGFloat?

    var body: some View {
        MarkdownContentView(markdown: markdown) { contentHeight = $0 }
            .frame(height: min(contentHeight ?? maxHeight, maxHeight))
    }
}

// MARK: - cmark-gfm rendering

/// Markdown → HTML, in cmark-gfm's **safe** mode.
///
/// Safe is the default since cmark-gfm 0.29 — raw HTML blocks and inline HTML
/// become a placeholder comment, and `javascript:`/`vbscript:`/`file:`/`data:`
/// links become empty strings — and this passes `CMARK_OPT_DEFAULT`, so the
/// header's "strips raw HTML" is true. Do not add `CMARK_OPT_UNSAFE`: the
/// markdown rendered here is a Shortcut story description, i.e. remote text, and
/// `allowsContentJavaScript = false` would still leave `<iframe>`/`<object>`
/// parsing inside the WKWebView. `Tests/MarkdownRenderingTests.swift` pins it.
func renderMarkdownToHTML(_ markdown: String) -> String {
    cmark_gfm_core_extensions_ensure_registered()

    guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return escapeHTML(markdown) }
    defer { cmark_parser_free(parser) }

    for name in ["table", "autolink", "strikethrough", "tasklist"] {
        if let ext = cmark_find_syntax_extension(name) {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
    }

    cmark_parser_feed(parser, markdown, markdown.utf8.count)

    guard let doc = cmark_parser_finish(parser) else { return escapeHTML(markdown) }
    defer { cmark_node_free(doc) }

    let options = CMARK_OPT_DEFAULT
    let extensions = cmark_parser_get_syntax_extensions(parser)
    guard let cString = cmark_render_html(doc, options, extensions) else { return escapeHTML(markdown) }
    defer { free(cString) }

    return String(cString: cString)
}

private func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - HTML template with GitHub-style CSS

private func wrapInHTMLPage(_ bodyHTML: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root {
        color-scheme: light dark;
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        font-size: 14px;
        line-height: 1.6;
        color: light-dark(#1f2328, #e6edf3);
        background: transparent;
        max-width: 860px;
        margin: 0 auto;
        padding: 16px 32px;
        word-wrap: break-word;
    }
    h1, h2, h3, h4, h5, h6 {
        font-weight: 600;
        line-height: 1.25;
        margin-top: 24px;
        margin-bottom: 16px;
    }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid light-dark(#d1d9e0, #30363d); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid light-dark(#d1d9e0, #30363d); }
    h3 { font-size: 1.25em; }
    p, ul, ol, blockquote, table, pre { margin-bottom: 16px; }
    a { color: light-dark(#0969da, #4493f8); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
        font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        font-size: 85%;
        padding: 0.2em 0.4em;
        background: light-dark(rgba(175,184,193,0.2), rgba(110,118,129,0.4));
        border-radius: 6px;
    }
    pre {
        padding: 16px;
        overflow: auto;
        background: light-dark(#f6f8fa, #161b22);
        border-radius: 6px;
        line-height: 1.45;
    }
    pre code {
        padding: 0;
        background: transparent;
        font-size: 85%;
    }
    blockquote {
        padding: 0 1em;
        color: light-dark(#636c76, #8b949e);
        border-left: 0.25em solid light-dark(#d1d9e0, #30363d);
        margin-left: 0;
    }
    table {
        border-collapse: collapse;
        width: 100%;
    }
    th, td {
        padding: 6px 13px;
        border: 1px solid light-dark(#d1d9e0, #30363d);
    }
    th { font-weight: 600; background: light-dark(#f6f8fa, #161b22); }
    tr:nth-child(2n) { background: light-dark(#f6f8fa, #161b2200); }
    img { max-width: 100%; height: auto; }
    hr {
        height: 0.25em;
        padding: 0;
        margin: 24px 0;
        background: light-dark(#d1d9e0, #30363d);
        border: 0;
    }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: 0.25em; }
    /* Task list checkboxes */
    li input[type="checkbox"] { margin-right: 0.5em; }
    /* Badge images (inline) */
    p img[src*="shields.io"], p img[src*="badge"] {
        display: inline;
        vertical-align: middle;
        margin: 2px 4px;
    }
    /* Centered paragraphs */
    p[align="center"], h1[align="center"] { text-align: center; }
    </style>
    </head>
    <body>
    \(bodyHTML)
    </body>
    </html>
    """
}
