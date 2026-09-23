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
        private let workstreamID: UUID
        /// Whether a capture overlay is already up.
        ///
        /// `screencapture -i` takes over the screen, so a second press while one
        /// is waiting would stack two overlays over each other. Cleared in a
        /// `defer`, so a capture, an Escape and a refusal for want of Screen
        /// Recording permission all release it — a flag that only a success
        /// cleared would disable the button for the rest of the session.
        private(set) var isCapturing = false

        /// Far outside any plausible screen arrangement.
        private static let parkingSpot = NSPoint(x: -20000, y: -20000)
        /// The size the page lays out at while parked. Any reasonable canvas
        /// size does; the tab resizes it on attach.
        private static let parkedSize = NSSize(width: 1200, height: 800)

        init(workstreamID: UUID) {
            self.workstreamID = workstreamID
            offscreenWindow = NSWindow(
                contentRect: NSRect(origin: Self.parkingSpot, size: Self.parkedSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            offscreenWindow.isExcludedFromWindowsMenu = true
            // **`close()` must not release this window, because ARC owns it.**
            //
            // `NSWindow.isReleasedWhenClosed` defaults to true, and it is a
            // contract from the days before ARC: the window releases *itself*
            // on close, on the assumption that nothing else holds a strong
            // reference. `offscreenWindow` is a strong `let` on this class, so
            // it is held twice and released twice — `teardown` returns
            // normally and the process segfaults in the next autorelease pool
            // pop, which is what made this look like a crash somewhere else
            // entirely. Both archive paths reach `teardown` through
            // `removeWhiteboardHost`, so archiving or purging a workstream
            // whose board had ever been opened was enough.
            offscreenWindow.isReleasedWhenClosed = false

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
        /// is the headroom wanted here: the refusal on the other side of it is
        /// `.notReady`, so paying it wrongly costs an agent a round trip rather
        /// than its first write of the session — nothing has been sent when it
        /// fires, and the message says so. That is the reason to keep the
        /// number where it is rather than a reason to trim it: a retry is only
        /// cheap for an agent that has one to spend, and the cold-mount case
        /// this exists for is the first write. It still has to stay under the
        /// tools' own 15s reply deadline, so there is not room to simply raise
        /// it if it ever proves tight; the bundle is what would need to shrink.
        private static let readyTimeout: TimeInterval = 10

        enum WriteFailure: LocalizedError, Equatable {
            /// The page could not be reached or could not answer, **before any
            /// operation was posted to it**. Safe to retry, and the message
            /// says so.
            ///
            /// This is the one the whole session's first write is most likely
            /// to meet: a cold board has to load the bundle and mount React,
            /// and `readyTimeout` is what bounds that. It used to share a case
            /// with `outcomeUnknown` and therefore shared its sentence, so an
            /// agent whose first call hit a slow cold page was told it might
            /// already have drawn something and must not retry — forbidding the
            /// one action that would have worked, over a board it had not
            /// touched.
            case notReady(String)
            /// An operation was posted and the page's answer never arrived, so
            /// whether it landed is unknown. **Forbids a retry**, which is the
            /// distinction this case exists to keep: the two are told apart by
            /// whether `__whiteboardApply` has been called, not by how the
            /// failure looked.
            case outcomeUnknown(String)
            case refused(String)
            case unknownElements([String])

            /// What failed, with nothing about what to do about it.
            ///
            /// **`errorDescription` is written for one audience and this is
            /// for the other.** Every sentence that type adds on top of this
            /// one is addressed to an agent that just made an IPC call — a
            /// retry it may or may not make, and `read_whiteboard` to find out
            /// what landed. `captureToBoard` has no such caller: the user
            /// pressed a button, it answers by doing nothing, and its failures
            /// go to a log. Telling whoever is reading Console that their call
            /// is safe to retry names a call that does not exist and an action
            /// they cannot take.
            ///
            /// So the two are not two copies: the half both audiences need —
            /// which read failed, or what the page said — is written here once
            /// and `errorDescription` appends its advice to it. A wording fix
            /// to the failure itself cannot land in one and miss the other.
            var diagnostic: String {
                switch self {
                case let .notReady(what):
                    "The whiteboard page was not ready: \(what)."
                case let .outcomeUnknown(what):
                    "The whiteboard page stopped answering while applying the write: \(what)."
                case let .refused(reason):
                    "The whiteboard page refused the write: \(reason)"
                case let .unknownElements(ids):
                    "No element on this board has the id "
                        + ids.map { "\"\($0)\"" }.joined(separator: ", ") + "."
                }
            }

            var errorDescription: String? {
                switch self {
                case .notReady:
                    // Invites the retry that `outcomeUnknown` forbids. Nothing
                    // was posted to the page, so there is nothing a second
                    // attempt could duplicate — and saying otherwise costs the
                    // caller a write it could have had.
                    diagnostic + " Nothing was sent to the board, so this call is safe to retry."
                case .outcomeUnknown:
                    // Forbids a retry rather than inviting one, the rule
                    // `create_workstream`'s timeout message states: the page may
                    // have applied the write before it stopped answering, and a
                    // caller cannot tell a genuine failure from one its own
                    // retry caused.
                    diagnostic + " Do not retry this call — it may have been applied anyway, and "
                        + "repeating it could duplicate what it drew. Call read_whiteboard to see "
                        + "what is on the board."
                case .refused:
                    diagnostic
                case .unknownElements:
                    diagnostic + " Call read_whiteboard for the current ids."
                }
            }

            /// The diagnostic half of any error a write path can throw.
            ///
            /// `liveState` and `apply` can also surface a `WKWebView` error
            /// that never passed through this type, so a log site cannot simply
            /// downcast and would otherwise have to choose between losing those
            /// or carrying the agent's copy for the ones it has.
            static func diagnostic(for error: Error) -> String {
                (error as? WriteFailure)?.diagnostic ?? error.localizedDescription
            }
        }

        /// Blocks until the page reports itself mounted, or gives up.
        ///
        /// **Both callers reach this before they have posted anything**, so it
        /// is `.notReady` for `apply(_:)` exactly as it is for `liveState()`:
        /// a board that never mounted is a board `__whiteboardApply` was never
        /// called on. The op having been *built* is not the op having been
        /// *sent*, and it is the send that decides which sentence an agent is
        /// owed.
        private func waitUntilReady() async throws {
            let deadline = Date().addingTimeInterval(Self.readyTimeout)
            while Date() < deadline {
                if await (try? callJS("return JSON.stringify(!!window.whiteboardReady)")) == "true" {
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            throw WriteFailure.notReady("it did not finish loading in time")
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
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw WriteFailure.notReady("it did not answer with its state") }
            return try Self.decodeLiveState(raw)
        }

        /// The page's four fields, or nothing.
        ///
        /// Split out from `liveState` so it is reachable with no webview — the
        /// shape `Bridge.handle` already has in this file, and for the same
        /// reason: the decode is where the mistakes live and a `WKWebView` buys
        /// none of its coverage.
        ///
        /// **A field this cannot read is a protocol error, not a value to
        /// guess.** `window.__whiteboardState` answers either `null` or one
        /// object literal carrying all four keys, so a dictionary holding a
        /// subset of them is not a page in a degraded state — it is a page that
        /// does not exist, and there is nothing partial to make the best of.
        /// `.notReady` is what the rest of this guard chain already says about
        /// one of those.
        ///
        /// **`imageIDs` used to fail open to every id, and that is no longer
        /// available.** The reasoning was sound while the set was read in one
        /// direction: a caption belongs on an image, and reading an absent
        /// field as "no images" would have refused every legitimate caption
        /// with `captionNeedsImage`, a refusal naming the wrong cause. Falling
        /// back to every id deferred the question to the page, which refuses an
        /// id it cannot find. `Write.updatePlan` now reads the same set in the
        /// **opposite** direction too — `textNeedsCanvasText`, which refuses
        /// `text` *on* an image — so there is no longer a lenient value: every
        /// id makes the page's own answer unreachable for `text`, and no id
        /// makes it unreachable for `caption`. Whichever way it fell it would
        /// refuse a whole arm of the tool while naming the wrong cause, so
        /// neither is a defensible guess and the field is now required.
        ///
        /// The layout is required on the same footing rather than keeping its
        /// per-field default. Guessing coordinates is the harm
        /// `captureToBoard`'s placement comment describes — an element dropped
        /// on top of the user's diagram, which reads perfectly well in the
        /// digest and ruins the picture — so a half-read layout must not be
        /// silently completed either.
        static func decodeLiveState(_ raw: [String: Any]) throws -> Write.Live {
            guard let ids = raw["ids"] as? [String],
                  let imageIDs = raw["imageIDs"] as? [String],
                  let originX = (raw["originX"] as? NSNumber)?.doubleValue,
                  let nextY = (raw["nextY"] as? NSNumber)?.doubleValue
            else { throw WriteFailure.notReady("it answered with an incomplete state") }
            return Write.Live(
                ids: Set(ids),
                imageIDs: Set(imageIDs),
                layout: Write.Layout(originX: originX, nextY: nextY)
            )
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

            // **Past this call the outcome is no longer knowable from here**,
            // which is the whole of the difference between the two readiness
            // failures above and this one. `__whiteboardApply` applies and
            // saves; a webview that throws on the way back may have thrown
            // before it ran, during it, or after it had already saved. So the
            // raw `WKError` that used to propagate — an agent-facing string
            // nobody wrote, saying nothing about whether the board changed —
            // becomes the one refusal that forbids a retry.
            let json: String?
            do {
                json = try await callJS(
                    "return JSON.stringify(await window.__whiteboardApply(JSON.parse(op)))",
                    ["op": payload]
                )
            } catch {
                throw WriteFailure.outcomeUnknown(error.localizedDescription)
            }

            guard let json,
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

        // MARK: - Screen capture

        /// Captures a screen region and puts it on this board.
        ///
        /// The whole flow, in one place rather than assembled in the view: the
        /// view holds nothing a second caller could not reach, and the board's
        /// life belongs here anyway. Answers false when there was nothing to
        /// place — the user cancelled, the capture could not be written, or the
        /// page could not say where the board ends — which the button reports
        /// by doing nothing.
        ///
        /// **Placed below everything already on the board**, from the same
        /// `Layout` an unpositioned agent element uses. A capture dropped at a
        /// fixed origin lands on top of whatever the user has drawn, and that is
        /// invisible in the digest — the coordinates read perfectly well — while
        /// ruining the picture, which is the half of the read path that exists
        /// to corroborate the other.
        ///
        /// **So a page that cannot answer refuses the placement rather than
        /// falling back to that fixed origin.** This read used to be a `try?`
        /// onto `Layout.fallback`, which is `(100, 100)` — so the one failure
        /// the paragraph above exists to prevent was the one thing that failure
        /// did, and silently, with nothing logged. It now logs and returns
        /// false like the two failures before it.
        @discardableResult
        func captureToBoard() async -> Bool {
            guard !isCapturing else { return false }
            isCapturing = true
            defer { isCapturing = false }

            guard let png = await Capture.run() else { return false }
            guard let size = Capture.onBoardSize(of: png) else {
                logger.error("Captured bytes were not a readable image")
                return false
            }

            // The file's name IS the fileId — `Store.writeAsset` refuses any id
            // it would have had to rewrite, and a SHA-1 hex string can never be
            // one of those.
            //
            // **Written before it is placed, and deliberately not cleaned up if
            // the placement then fails.** The bytes have to be on disk before
            // the page can fetch them over the asset scheme, so this order is
            // forced; what is a choice is leaving the file behind. Deleting it
            // would be the more dangerous half: the name is content-addressed,
            // so an identical capture taken earlier is the *same* file, and an
            // element already on the board may be pointing at it — a tidy-up
            // would blank that image out. An orphan costs a file in a cache
            // directory that is swept with the workstream, and the next capture
            // of the same region reuses it rather than writing a second.
            let fileID = Capture.fileID(for: png)
            do {
                try Store.writeAsset(png, id: fileID, ext: "png", for: workstreamID)
            } catch {
                logger.error("Could not write the capture: \(error.localizedDescription, privacy: .public)")
                return false
            }

            // The board's extent, and nothing to fall back on if it cannot be
            // read — see the placement paragraph above. The already-written
            // asset is deliberately left behind on this path too, on the
            // reasoning the `writeAsset` comment gives: the name is
            // content-addressed, so the next capture of the same region reuses
            // this file rather than writing a second one.
            let layout: Write.Layout
            do {
                layout = try await liveState().layout
            } catch {
                logger.error("Could not read where to place the capture: \(WriteFailure.diagnostic(for: error), privacy: .public)")
                return false
            }
            do {
                _ = try await apply([
                    "kind": "image",
                    // `mintID`'s own comment reads the `atl-` prefix as "an
                    // agent put this here", which is not true of a capture: the
                    // user pressed the button, and this element deliberately
                    // carries no `atelierAuthor` so the digest does not claim
                    // otherwise. Here the prefix means only "minted by
                    // Atelier". Reused rather than given its own spelling, so
                    // the board keeps one id shape instead of growing a second
                    // for a single caller.
                    "id": Write.mintID(),
                    "fileId": fileID,
                    "name": "\(fileID).png",
                    "mimeType": "image/png",
                    "x": layout.originX,
                    "y": layout.nextY,
                    "width": size.width,
                    "height": size.height,
                ])
            } catch {
                logger.error("Could not place the capture: \(WriteFailure.diagnostic(for: error), privacy: .public)")
                return false
            }
            return true
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
