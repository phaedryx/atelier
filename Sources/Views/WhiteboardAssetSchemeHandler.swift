// ABOUTME: Serves one board's pasted images to its webview over a custom scheme.
// ABOUTME: Rooted at that board's assets/ directory, and never resolves outside it.

import Foundation
import WebKit

extension Whiteboard {
    /// Serves a single board's `assets/` directory to its webview.
    ///
    /// A separate type from `MonacoResourceSchemeHandler` on purpose, and the
    /// separation is not duplication for its own sake: that handler is rooted at
    /// the app *bundle*, a fixed directory for the life of the process, and its
    /// containment rule is hardened against a symlink planted inside it. This
    /// one is rooted at a *per-workstream cache directory* — a different base
    /// with a different lifetime, created and swept with the workstream.
    /// Pointing one handler at both would make it an object whose base changes
    /// underneath it, which is how the hardened rule eventually gets relaxed to
    /// accommodate the second caller.
    ///
    /// What *is* shared is the containment primitive, `isCanonicallyInside` —
    /// which is the part worth having exactly one of.
    final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
        static let scheme = "atelier-board-asset"

        private let baseURL: URL

        init(baseURL: URL) {
            self.baseURL = baseURL
        }

        func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }

            guard let fileURL = Self.resolve(requestPath: url.path, in: baseURL) else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": Self.mimeType(for: fileURL.pathExtension),
                    "Content-Length": "\(data.count)",
                    // The PNG export reads each asset back with `fetch` and
                    // re-inlines it as a data URL, because an asset-scheme image
                    // **taints the export canvas**: Excalidraw builds its
                    // `Image` with no `crossOrigin`, so the whole `exportToBlob`
                    // fails with `SecurityError` — not just the image. Measured
                    // against 0.18.1, and only reachable after a relaunch, since
                    // a freshly pasted image is already a `data:` URL. Without
                    // this header the `fetch` itself fails first (`TypeError:
                    // Load failed`), so both halves are needed and neither is
                    // sufficient alone.
                    //
                    // This widens what may *read* a response and nothing else.
                    // What may be served at all is `resolve`'s decision, and
                    // `isCanonicallyInside` is untouched — the origin being
                    // allowed here is the board's own page.
                    "Access-Control-Allow-Origin": "*",
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}

        /// The asset a request names, or nil if it does not resolve to one
        /// *inside* this board's assets directory.
        ///
        /// Containment goes through `isCanonicallyInside`, which resolves
        /// symlinks on both sides and requires a separator: a bare `hasPrefix`
        /// on the raw path is true for any sibling whose name merely *starts*
        /// with the base's, so `.../assets-evil/payload.png` would pass a guard
        /// meant to allow only `.../assets/...`. "Inside" is also strict — the
        /// directory itself is not a file to serve.
        ///
        /// Resolving is the half a lexical `.standardized` cannot do. It
        /// collapses `..` textually and never follows a link, so a symlink
        /// planted in `assets/` would keep every path component of the base —
        /// passing containment — while pointing anywhere on disk.
        ///
        /// The canonical URL is what gets returned, so the file that was checked
        /// is the file that gets read.
        ///
        /// Internal so the containment rule can be tested without a
        /// `WKURLSchemeTask`.
        static func resolve(requestPath: String, in baseURL: URL) -> URL? {
            var relative = requestPath
            if relative.hasPrefix("/") {
                relative.removeFirst()
            }
            guard !relative.isEmpty else { return nil }

            let candidate = baseURL.appendingPathComponent(relative)
            guard candidate.path.isCanonicallyInside(baseURL.path) else { return nil }

            let canonical = candidate.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return canonical
        }

        private static func mimeType(for ext: String) -> String {
            switch ext.lowercased() {
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "gif": "image/gif"
            case "svg": "image/svg+xml"
            case "webp": "image/webp"
            default: "application/octet-stream"
            }
        }
    }
}
