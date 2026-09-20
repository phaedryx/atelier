// ABOUTME: Owns one workstream's whiteboard webview and the offscreen window it parks in.
// ABOUTME: Cache-owned, never view-owned — the board must survive navigating away.

import AppKit
import Foundation
import OSLog
import WebKit

private let logger = Logger(subsystem: AppConstants.appID, category: "whiteboard")

extension Whiteboard {
    /// One workstream's whiteboard: the `WKWebView`, and the offscreen window it
    /// lives in whenever no tab is showing it.
    ///
    /// **Owned by `TerminalSurfaceCache`, never by a view.** `ContentView` keys
    /// `TerminalContainerView` `.id(workstreamID)`, so the view is destroyed on
    /// navigation — and a board the user drew on before switching workstreams
    /// has to still be there when they come back, with anything still saving
    /// still saving. This codebase has shipped that exact bug twice
    /// (`runGeneration` as view `@State`, then `browserStartPending`), and
    /// `ProcessCompose.RunSession` exists because of it. Retention like this is
    /// already precedented: the cache holds `[UUID: WKWebView]` for browser tabs.
    ///
    /// **The offscreen window does much less than it looks like it does, and the
    /// difference is load-bearing.** A window parked off every screen is
    /// `NSWindowOcclusionState`-occluded, and the one thing an occluded window
    /// loses is `requestAnimationFrame`. That was measured rather than reasoned
    /// about, along with the other half: `setTimeout`, `MessageChannel`,
    /// `document.fonts.ready`, `canvas.toBlob`, `OffscreenCanvas`,
    /// `img.decode()` and `createImageBitmap` all keep working there. So the
    /// board goes on saving with no tab open because Excalidraw's save and
    /// export paths never await a frame — **not** because this window grants it
    /// a render surface, which is the intuitive reading and is wrong.
    ///
    /// The consequence to keep: **nothing on the save or export path may await
    /// rAF.** A rAF-driven debounce is a very ordinary thing to reach for, and
    /// it would fail only when the tab is closed, with no error, no timeout and
    /// a promise that simply never settles.
    ///
    /// Two details that look like tidying and are not:
    ///
    /// - **`.borderless`.** AppKit's `constrainFrameRect` drags a *titled*
    ///   window back onto the screen, so a titled "offscreen" window is not
    ///   offscreen at all — it is sitting in the corner of the user's display.
    /// - **Never `orderFront`.** A window that is never ordered in behaves
    ///   identically for this purpose (verified), so there is no reason to put
    ///   one into the window list for the user to trip over.
    @MainActor
    final class Host {
        private(set) var webView: WKWebView!
        private let offscreenWindow: NSWindow
        private let bridge: Bridge

        /// Far outside any plausible screen arrangement.
        private static let parkingSpot = NSPoint(x: -20000, y: -20000)
        /// The size the page lays out at while parked. Any reasonable canvas
        /// size does; the tab resizes it on attach.
        private static let parkedSize = NSSize(width: 1200, height: 800)

        init(workstreamID: UUID) {
            offscreenWindow = NSWindow(
                contentRect: NSRect(origin: Self.parkingSpot, size: Self.parkedSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            offscreenWindow.isExcludedFromWindowsMenu = true

            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(
                AssetSchemeHandler(baseURL: Store.assetsDirectory(for: workstreamID)),
                forURLScheme: AssetSchemeHandler.scheme
            )
            // The same bundle scheme the editor uses, and for the same reason
            // stated there: `loadFileURL` breaks `fetch()`, because WebKit's
            // fetch supports only http/https/blob/data.
            if let bundleURL = Bundle.main.url(forResource: "MonacoEditor", withExtension: nil) {
                config.setURLSchemeHandler(
                    MonacoResourceSchemeHandler(baseURL: bundleURL),
                    forURLScheme: "atelier-resource"
                )
            }

            bridge = Bridge(workstreamID: workstreamID)
            config.userContentController.add(bridge, name: Bridge.name)

            if let script = Self.initialSceneScript(for: workstreamID) {
                config.userContentController.addUserScript(script)
            }
            config.userContentController.addUserScript(Self.assetManifestScript(for: workstreamID))

            let wv = WKWebView(
                frame: NSRect(origin: .zero, size: Self.parkedSize),
                configuration: config
            )
            #if DEBUG
                wv.isInspectable = true
            #endif
            webView = wv
            park()

            if let url = URL(string: "atelier-resource://monaco/whiteboard.html") {
                wv.load(URLRequest(url: url))
            }
        }

        /// Hands the saved scene to the page before it mounts.
        ///
        /// **Base64, never interpolated.** A scene is arbitrary user text —
        /// every label the user typed on the board — and dropping it into a
        /// JavaScript source string is the two-nested-languages bug
        /// `AppleScriptRunner` exists to stop: a quote in a shape's label would
        /// close the literal, and the rest would either fail to parse or
        /// execute. Encoding sidesteps the quoting question rather than trying
        /// to win it.
        ///
        /// Returns nil for a board nobody has drawn on, which is the ordinary
        /// first state — the page then mounts empty.
        private static func initialSceneScript(for workstreamID: UUID) -> WKUserScript? {
            guard let saved = Store.loadScene(for: workstreamID),
                  let encoded = saved.data(using: .utf8)?.base64EncodedString()
            else { return nil }
            return WKUserScript(
                source: """
                window.__whiteboardInitialScene = new TextDecoder().decode(
                    Uint8Array.from(atob('\(encoded)'), function (c) { return c.charCodeAt(0); })
                );
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        }

        /// Tells the page which images this board has, and where to fetch them.
        ///
        /// The page is handed **URLs on the asset scheme, not data URLs**, and
        /// that is what `AssetSchemeHandler` is for. Inlining would mean
        /// base64-ing every pasted screenshot into a document-start user script
        /// — a 10 MB image becomes 13 MB of JavaScript source parsed before the
        /// page runs — and it would put the bytes straight back into the scene
        /// file the externalisation exists to keep them out of.
        ///
        /// Always injected, even when there are no assets: the page needs the
        /// base URL to build any image it is handed, and an absent global would
        /// make "no images yet" indistinguishable from "the manifest failed".
        private static func assetManifestScript(for workstreamID: UUID) -> WKUserScript {
            let dir = Store.assetsDirectory(for: workstreamID)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            // Only file names cross, and `writeAsset` refused any that were not
            // already safe, so each name's stem is byte-identical to the
            // `fileId` on its image element — which is what the page relies on.
            //
            // The two interpolations below are the deliberate exceptions to the
            // never-interpolate-into-JS rule `initialSceneScript` states: the
            // scheme is a compile-time constant, and the payload is
            // `JSONSerialization` output, which is already valid JS literal
            // syntax. Anything carrying user text still goes through base64.
            let payload = (try? JSONSerialization.data(withJSONObject: names.filter { !$0.hasPrefix(".") }))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return WKUserScript(
                source: """
                window.__whiteboardAssetBase = '\(AssetSchemeHandler.scheme)://board/';
                window.__whiteboardAssets = \(payload);
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        }

        /// Moves the webview into a visible container. Called by the tab when it
        /// appears, and idempotent so a re-render is free.
        func attach(to container: NSView) {
            guard webView.superview !== container else { return }
            webView.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(webView)
            webView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        /// Hands the webview back to the offscreen window, but only if it is
        /// still in `container`.
        ///
        /// Deliberately **not** a teardown: the page keeps running, which is the
        /// whole point of the offscreen window and the reason an agent will be
        /// able to write to a board whose tab is closed.
        ///
        /// The condition is what makes this safe to call from a view's teardown.
        /// SwiftUI does not order dismantling an outgoing view against creating
        /// the incoming one, so an unconditional park could take the webview
        /// back out of a container that had already claimed it — leaving the tab
        /// showing nothing.
        func detachIfAttached(to container: NSView) {
            guard webView.superview === container else { return }
            park()
        }

        private func park() {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.frame = NSRect(origin: .zero, size: Self.parkedSize)
            offscreenWindow.contentView?.addSubview(webView)
            // Re-asserted on every park: AppKit may have moved the window, and a
            // window that drifted back onto the screen is one the user can see.
            offscreenWindow.setFrameOrigin(Self.parkingSpot)
        }

        // MARK: - The agent write path

        /// How long to wait for the page to mount before giving up on a write.
        ///
        /// A board whose tab has never been opened in this launch has no page
        /// yet: the host is created on demand and has to load the bundle, mount
        /// React and initialize Excalidraw. That is the ordinary first write
        /// rather than an edge case, and it is why this exists at all.
        ///
        /// **Measured cold**, offscreen with no tab ever attached: 0.20s from
        /// `load` to `whiteboardReady`. Ten seconds is fifty times that, which
        /// is the headroom wanted here — the refusal on the other side of it
        /// forbids a retry, so paying it wrongly costs an agent its first write
        /// of the session with no way back. It still has to stay under the
        /// tools' own 15s reply deadline, so there is not room to simply raise
        /// it if it ever proves tight; the bundle is what would need to shrink.
        private static let readyTimeout: TimeInterval = 10

        enum WriteFailure: LocalizedError, Equatable {
            case notReady
            case refused(String)
            case unknownElements([String])

            var errorDescription: String? {
                switch self {
                case .notReady:
                    // Forbids a retry rather than inviting one, the rule
                    // `create_workstream`'s timeout message states: the page may
                    // have applied the write after the deadline, and a caller
                    // cannot tell a genuine failure from one its own retry
                    // caused.
                    "The whiteboard page did not respond in time. Do not retry this call — it may "
                        + "have been applied after the deadline, and repeating it could duplicate "
                        + "what it drew. Call read_whiteboard to see what is on the board."
                case let .refused(reason):
                    "The whiteboard page refused the write: \(reason)"
                case let .unknownElements(ids):
                    "No element on this board has the id "
                        + ids.map { "\"\($0)\"" }.joined(separator: ", ")
                        + ". Call read_whiteboard for the current ids."
                }
            }
        }

        /// Blocks until the page reports itself mounted, or gives up.
        private func waitUntilReady() async throws {
            let deadline = Date().addingTimeInterval(Self.readyTimeout)
            while Date() < deadline {
                if await (try? callJS("return JSON.stringify(!!window.whiteboardReady)")) == "true" {
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            throw WriteFailure.notReady
        }

        /// What is on the board right now, from the page rather than from disk.
        ///
        /// `board.excalidraw` lags the page by the save debounce, so an agent
        /// that adds a box and then updates it would be refused for naming an id
        /// that is plainly on the board. The layout rides along because
        /// `Whiteboard.Write` cannot compute it and because both are answers to
        /// the same instant.
        func liveState() async throws -> Write.Live {
            try await waitUntilReady()
            guard let json = try await callJS("return JSON.stringify(window.__whiteboardState())"),
                  let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = raw["ids"] as? [String]
            else { throw WriteFailure.notReady }
            let layout = Write.Layout(
                originX: (raw["originX"] as? NSNumber)?.doubleValue ?? Write.Layout.fallback.originX,
                nextY: (raw["nextY"] as? NSNumber)?.doubleValue ?? Write.Layout.fallback.nextY
            )
            return Write.Live(ids: Set(ids), layout: layout)
        }

        /// Posts one operation into the page and answers with the ids it moved.
        ///
        /// The page applies it and saves through the same debounced `save()` a
        /// user edit takes — one save path, which is what keeps exactly one
        /// place regenerating the digest and re-rendering the PNG.
        func apply(_ op: [String: Any]) async throws -> [String] {
            try await waitUntilReady()
            guard let payload = (try? JSONSerialization.data(withJSONObject: op))
                .flatMap({ String(data: $0, encoding: .utf8) })
            else { throw WriteFailure.refused("the operation could not be encoded") }

            guard let json = try await callJS(
                "return JSON.stringify(await window.__whiteboardApply(JSON.parse(op)))",
                ["op": payload]
            ),
                let data = json.data(using: .utf8),
                let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw WriteFailure.refused("it returned nothing") }

            if let unknown = result["unknown"] as? [String], !unknown.isEmpty {
                throw WriteFailure.unknownElements(unknown)
            }
            guard result["ok"] as? Bool == true else {
                throw WriteFailure.refused(result["reason"] as? String ?? "no reason given")
            }
            // The ids that really landed, not the ids that were asked for.
            return result["ids"] as? [String] ?? []
        }

        /// **`callAsyncJavaScript`, never `evaluateJavaScript`.**
        ///
        /// `evaluateJavaScript` does not await a returned promise — it hands
        /// back the promise object itself, so an async page function would
        /// report success the instant it was called, before anything had been
        /// applied. With the tab closed there would be nothing to notice it by.
        /// This one awaits it.
        ///
        /// **Everything crosses as a JSON string, in both directions.** The
        /// argument is marshalled by `callAsyncJavaScript` rather than
        /// interpolated, so the two-nested-languages problem
        /// `initialSceneScript` solves with base64 does not arise; encoding it
        /// as one string on top of that keeps the boundary `Sendable` and keeps
        /// the reply out of `NSNumber`-versus-`Double` guesswork, which is a
        /// real hazard here because every coordinate an agent sends may be
        /// integral.
        private func callJS(
            _ source: String,
            _ arguments: [String: String] = [:]
        ) async throws -> String? {
            try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) {
                    switch $0 {
                    case let .success(value): continuation.resume(returning: value as? String)
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
            }
        }

        /// Ends this board's life. Called from both archive paths.
        ///
        /// The message handler goes first: it holds the bridge, which holds the
        /// workstream id, and a save arriving after the board's directory has
        /// been swept would recreate it.
        func teardown() {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: Bridge.name)
            webView.stopLoading()
            webView.removeFromSuperview()
            offscreenWindow.contentView?.subviews.forEach { $0.removeFromSuperview() }
            offscreenWindow.close()
        }
    }

    /// Receives the page's saves.
    ///
    /// The web app is the sole writer of the scene; this persists what it is
    /// handed and never edits one. Every field is validated before use because
    /// the body crosses a JavaScript boundary and arrives as `Any`.
    @MainActor
    final class Bridge: NSObject, WKScriptMessageHandler {
        static let name = "atelierWhiteboard"

        private let workstreamID: UUID

        /// The revision of the most recently saved scene.
        ///
        /// A render is accepted only for *this* revision. Exports are not
        /// ordered against each other — a big board's export can outlast the
        /// save that follows it — so without this a slow render would land on
        /// top of a newer scene and be stamped as matching it, which is the one
        /// thing the stamp exists to prevent. The page guards on it too; this is
        /// the copy that matters, because it is the one holding the file.
        private var latestRevision: String?

        init(workstreamID: UUID) {
            self.workstreamID = workstreamID
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            handle(message.body)
        }

        /// The half of the handler a test can reach.
        ///
        /// Split out because `WKScriptMessage` has no init a test can call, and
        /// the `render` arm below is not the pass-through the `save` arm is: it
        /// decides which renders to accept by revision, which is the rule that
        /// stops a slow export being stamped as matching a scene it never came
        /// from. A rule with no test is one the next change quietly drops.
        ///
        /// Every field is checked rather than trusted — the body crosses a
        /// JavaScript boundary and arrives as `Any`.
        func handle(_ rawBody: Any) {
            guard let body = rawBody as? [String: Any],
                  let action = body["action"] as? String
            else {
                logger.error("Whiteboard message with no action")
                return
            }

            switch action {
            case "save":
                guard let json = body["scene"] as? String else { return }
                do {
                    try Store.saveScene(json, for: workstreamID)
                    latestRevision = body["rev"] as? String
                    // The picture on disk is now of an earlier board. It stays —
                    // a moment-old picture is still worth looking at — but
                    // nothing may read it as current until its render arrives.
                    Store.invalidateRender(for: workstreamID)
                    Store.refreshDigest(for: workstreamID)
                } catch {
                    logger.error("Could not save board: \(error.localizedDescription, privacy: .public)")
                }
            case "render":
                guard let rev = body["rev"] as? String, rev == latestRevision else { return }
                guard body["ok"] as? String == "true" else {
                    // Left stale on purpose: the digest reports that in words,
                    // which is the specified behaviour. Logged because the cause
                    // is otherwise invisible — on disk, a render that failed and
                    // a render that simply never arrived look identical.
                    let reason = body["reason"] as? String ?? "no reason given"
                    logger.error("Board render failed: \(reason, privacy: .public)")
                    return
                }
                guard let base64 = body["data"] as? String,
                      let data = Data(base64Encoded: base64),
                      let width = (body["width"] as? String).flatMap(Int.init),
                      let height = (body["height"] as? String).flatMap(Int.init)
                else { return }
                do {
                    try Store.writeRender(png: data, width: width, height: height, for: workstreamID)
                    // Again, because the render line is part of the digest and
                    // this is the arm that makes it true.
                    Store.refreshDigest(for: workstreamID)
                } catch {
                    logger.error("Could not save board render: \(error.localizedDescription, privacy: .public)")
                }
            case "saveAsset":
                guard let id = body["id"] as? String,
                      let ext = body["ext"] as? String,
                      let base64 = body["data"] as? String,
                      let data = Data(base64Encoded: base64)
                else { return }
                do {
                    try Store.writeAsset(data, id: id, ext: ext, for: workstreamID)
                } catch {
                    logger.error("Could not save board asset: \(error.localizedDescription, privacy: .public)")
                }
            default:
                logger.error("Unknown whiteboard action \(action, privacy: .public)")
            }
        }
    }
}
