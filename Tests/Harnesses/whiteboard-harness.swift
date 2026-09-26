#!/usr/bin/env swift
// ABOUTME: Drives the real whiteboard bundle in a real offscreen WKWebView and checks the files it writes.
// ABOUTME: Manually run — see Tests/Harnesses/README.md. Not part of ./scripts/dev.sh test.

// Every assertion in here reads an ARTIFACT ON DISK — board.excalidraw, assets/,
// board.png — and never the value a JavaScript call handed back. Nine silent bugs
// have shipped in this feature so far and every one of them SUCCEEDED: the call
// returned fine, the write really happened, and the board's picture and its digest
// disagreed afterwards. A harness that trusts a return value cannot see any of
// them.

import AppKit
import CryptoKit
import WebKit

// MARK: - Reporting

var failures: [String] = []
var checksRun = 0

func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    checksRun += 1
    if passed {
        print("  ok   \(name)")
    } else {
        let why = detail()
        print("  FAIL \(name)\(why.isEmpty ? "" : " — \(why)")")
        failures.append(name)
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

// MARK: - Run-loop pumping

//
// A script has no app event loop, so everything here is synchronous-with-pumping
// rather than async/await. That is deliberate: `await` in a script needs the main
// thread free to resume the continuation, and the main thread is the one waiting.

func pump(_ seconds: TimeInterval = 0.02) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(seconds))
}

@discardableResult
func waitUntil(timeout: TimeInterval = 20, _ ready: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if ready() {
            return true
        }
        pump()
    }
    return ready()
}

// MARK: - The board's files

//
// A minimal stand-in for `Whiteboard.Store`: the harness cannot link the app
// target, so it writes the same four artifacts to the same names. Anything this
// gets wrong shows up as a check that cannot find its file, not as a false pass.

final class BoardFiles {
    let directory: URL
    var sceneWrites = 0
    var renderWrites = 0
    /// How many times the page has POSTED an asset's bytes.
    ///
    /// The one thing in here that is not a file, and section 7 says why: the
    /// bug it exists for re-posts bytes that are identical, so the file on disk
    /// is correct after every one of them and cannot see it.
    ///
    /// **Cumulative for the whole run, across every host this file builds.**
    /// Section 7 therefore compares against a baseline it takes for itself
    /// rather than against zero — an absolute count would make a section added
    /// above it fail *this* check, reporting the re-upload bug as back when
    /// what really happened is that something else posted an asset.
    var assetWrites = 0
    var lastRenderFailure: String?

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whiteboard-harness-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(
            at: assets, withIntermediateDirectories: true
        )
    }

    var scene: URL {
        directory.appendingPathComponent("board.excalidraw")
    }

    var png: URL {
        directory.appendingPathComponent("board.png")
    }

    var stamp: URL {
        directory.appendingPathComponent("board.png.json")
    }

    var assets: URL {
        directory.appendingPathComponent("assets")
    }

    func sceneText() -> String {
        (try? String(contentsOf: scene, encoding: .utf8)) ?? ""
    }

    /// The live elements of the scene ON DISK, keyed by id.
    func elements() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: scene),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["elements"] as? [[String: Any]]
        else { return [:] }
        var out: [String: [String: Any]] = [:]
        for element in list where (element["isDeleted"] as? Bool) != true {
            if let id = element["id"] as? String {
                out[id] = element
            }
        }
        return out
    }

    func assetNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Scheme handlers

//
// The app's two live in the Atelier target, which a script cannot link, so these
// are minimal copies. They are NOT the thing under test — containment is pinned by
// WhiteboardAssetSchemeHandlerTests in XCTest, where it belongs. These exist only
// to get the real bundle and the real assets in front of the real page.

final class BundleScheme: NSObject, WKURLSchemeHandler {
    let base: URL
    init(base: URL) {
        self.base = base
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file = base.appendingPathComponent(String(url.path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = [
            "html": "text/html", "js": "text/javascript", "mjs": "text/javascript",
            "css": "text/css", "json": "application/json", "woff2": "font/woff2",
            "woff": "font/woff", "ttf": "font/ttf", "png": "image/png",
            "svg": "image/svg+xml", "wasm": "application/wasm",
        ]
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: [
                "Content-Type": types[file.pathExtension.lowercased()] ?? "application/octet-stream",
                "Content-Length": "\(data.count)",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}

final class AssetScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "atelier-board-asset"
    let base: URL
    init(base: URL) {
        self.base = base
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file = base.appendingPathComponent(String(url.path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: [
                "Content-Type": file.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg",
                "Content-Length": "\(data.count)",
                // Without this the export's re-inlining fetch fails first. The
                // app's handler sends it for the same reason; see PR 2.
                "Access-Control-Allow-Origin": "*",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}

// MARK: - The host

//
// The same shape `Whiteboard.Host` builds: a `.borderless` window parked far off
// every screen and never ordered front. A *titled* window would be dragged back
// onto the display by AppKit's `constrainFrameRect`, which is the whole reason the
// app spells it this way.

final class HarnessHost: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private let window: NSWindow
    private let files: BoardFiles

    init(files: BoardFiles, bundle: URL) {
        self.files = files
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false
        )

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleScheme(base: bundle), forURLScheme: "atelier-resource")
        config.setURLSchemeHandler(AssetScheme(base: files.assets), forURLScheme: AssetScheme.scheme)

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config
        )
        super.init()
        config.userContentController.add(self, name: "atelierWhiteboard")

        // Seeded exactly the way the app seeds it: base64, never interpolated. A
        // scene carries every label the user typed, and a quote in one would close
        // the JavaScript literal.
        if let saved = try? String(contentsOf: files.scene, encoding: .utf8),
           let encoded = saved.data(using: .utf8)?.base64EncodedString()
        {
            config.userContentController.addUserScript(WKUserScript(
                source: """
                window.__whiteboardInitialScene = new TextDecoder().decode(
                    Uint8Array.from(atob('\(encoded)'), function (c) { return c.charCodeAt(0); })
                );
                """,
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        let names = files.assetNames()
        let manifest = (try? JSONSerialization.data(withJSONObject: names))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        config.userContentController.addUserScript(WKUserScript(
            source: """
            window.__whiteboardAssetBase = '\(AssetScheme.scheme)://board/';
            window.__whiteboardAssets = \(manifest);
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))

        window.contentView?.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "atelier-resource://monaco/whiteboard.html")!))
    }

    /// Mirrors `Whiteboard.Bridge.handle` — including the revision rule, because a
    /// render accepted against the wrong revision is one of the states this whole
    /// design exists to prevent.
    private var latestRevision: String?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "save":
            guard let json = body["scene"] as? String else { return }
            try? json.write(to: files.scene, atomically: true, encoding: .utf8)
            latestRevision = body["rev"] as? String
            try? FileManager.default.removeItem(at: files.stamp)
            files.sceneWrites += 1
        case "render":
            guard let rev = body["rev"] as? String, rev == latestRevision else { return }
            guard body["ok"] as? String == "true" else {
                files.lastRenderFailure = body["reason"] as? String ?? "no reason given"
                return
            }
            guard let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64),
                  let width = (body["width"] as? String).flatMap(Int.init),
                  let height = (body["height"] as? String).flatMap(Int.init) else { return }
            try? data.write(to: files.png, options: .atomic)
            let stamp = try! JSONSerialization.data(withJSONObject: ["width": width, "height": height])
            try? stamp.write(to: files.stamp, options: .atomic)
            files.renderWrites += 1
            files.lastRenderFailure = nil
        case "saveAsset":
            guard let id = body["id"] as? String,
                  let ext = body["ext"] as? String,
                  let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            try? data.write(to: files.assets.appendingPathComponent("\(id).\(ext)"), options: .atomic)
            files.assetWrites += 1
        default:
            break
        }
    }

    // MARK: Driving the page

    /// `callAsyncJavaScript`, never `evaluateJavaScript` — the latter hands back
    /// the promise object rather than awaiting it, so an async apply would report
    /// success before applying anything.
    @discardableResult
    func callJS(_ source: String, _ arguments: [String: String] = [:]) -> String? {
        var done = false
        var out: String?
        webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) {
            switch $0 {
            case let .success(value): out = value as? String
            case let .failure(error): out = "JS ERROR: \(error.localizedDescription)"
            }
            done = true
        }
        waitUntil { done }
        return out
    }

    func waitUntilReady() -> Bool {
        waitUntil(timeout: 30) {
            callJS("return JSON.stringify(!!window.whiteboardReady)") == "true"
        }
    }

    /// Posts one op and waits for the save it triggers to reach disk. Returns the
    /// page's answer, which is only ever used to see a refusal — never as evidence
    /// that anything was written.
    func apply(_ op: [String: Any]) -> [String: Any] {
        let before = files.sceneWrites
        let payload = String(
            data: try! JSONSerialization.data(withJSONObject: op), encoding: .utf8
        )!
        let answer = callJS(
            "return JSON.stringify(await window.__whiteboardApply(JSON.parse(op)))",
            ["op": payload]
        )
        waitUntil(timeout: 10) { self.files.sceneWrites > before }
        guard let answer, let data = answer.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["ok": false, "reason": answer ?? "no answer"] }
        return parsed
    }

    /// Waits for the export that follows a save. It is deliberately not awaited by
    /// the save itself, so it lands afterwards or not at all.
    func waitForRender() {
        let before = files.renderWrites
        waitUntil(timeout: 25) {
            self.files.renderWrites > before || self.files.lastRenderFailure != nil
        }
    }

    func teardown() {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "atelierWhiteboard")
        webView.stopLoading()
        webView.removeFromSuperview()
        window.close()
    }
}

// MARK: - Skeleton helpers

func box(_ id: String, _ label: String, x: Double, y: Double, extra: [String: Any] = [:]) -> [String: Any] {
    var out: [String: Any] = [
        "id": id, "type": "rectangle", "x": x, "y": y, "width": 220, "height": 90,
        "label": ["text": label],
        "customData": ["atelierAuthor": "agent"],
    ]
    for (key, value) in extra {
        out[key] = value
    }
    return out
}

func arrow(_ id: String, from: String, to: String) -> [String: Any] {
    [
        "id": id, "type": "arrow", "x": 0, "y": 0,
        "start": ["id": from], "end": ["id": to],
        "customData": ["atelierAuthor": "agent"],
    ]
}

func binding(_ element: [String: Any]?, _ key: String) -> String? {
    (element?[key] as? [String: Any])?["elementId"] as? String
}

func number(_ raw: Any?) -> Double {
    (raw as? NSNumber)?.doubleValue ?? .nan
}

// MARK: - Run

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

/// The built bundle, looked for relative to the script and then to the working
/// directory — so it runs from the repository root either way.
let bundleDir: URL = {
    let fromScript = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent() // Harnesses
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("Resources/MonacoEditor")
    let fromCWD = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/MonacoEditor")
    for candidate in [fromScript, fromCWD]
        where FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("whiteboard.html").path
        )
    {
        return candidate.standardizedFileURL
    }
    print("""
    Could not find the built whiteboard bundle.
    Looked in:
      \(fromScript.path)
      \(fromCWD.path)
    Run ./scripts/build-editor.sh from the repository root first.
    """)
    exit(2)
}()

print("Whiteboard harness — bundle at \(bundleDir.path)")

let files = BoardFiles()
defer { files.cleanUp() }
var host = HarnessHost(files: files, bundle: bundleDir)

// ---------------------------------------------------------------------------
section("0. The harness can see the real page")
// A harness that reports clean because it silently failed to load the bundle is
// worse than no harness at all, so this is check zero and everything else is
// abandoned if it fails.

let ready = host.waitUntilReady()
check("the bundle loads and Excalidraw mounts offscreen", ready)
guard ready else {
    print("\nThe page never reported ready. Nothing below would mean anything.")
    exit(1)
}

// ---------------------------------------------------------------------------
section("1. PR 3's binding invariants (all already fixed — these prove the harness)")

_ = host.apply([
    "kind": "add",
    "elements": [
        box("h-a", "Auth service", x: 100, y: 100),
        box("h-b", "Token store", x: 600, y: 100),
    ],
])

// A separate call, so the arrow names boxes that are ALREADY on the board rather
// than ones beside it in the same batch. That is the case that shipped broken:
// convertToExcalidrawElements binds only within the array it is handed.
_ = host.apply(["kind": "add", "elements": [arrow("h-arrow", from: "h-a", to: "h-b")]])

var scene = files.elements()
check(
    "an arrow naming boxes already on the board binds to both",
    binding(scene["h-arrow"], "startBinding") == "h-a"
        && binding(scene["h-arrow"], "endBinding") == "h-b",
    "start=\(binding(scene["h-arrow"], "startBinding") ?? "nil") "
        + "end=\(binding(scene["h-arrow"], "endBinding") ?? "nil")"
)

// Bound but never moved: an arrow handed (0,0) stays at (0,0) with a stub segment,
// correctly bound and visibly pointing nowhere near the shapes it claims to join.
check(
    "that arrow's geometry reaches its endpoints, not (0,0)",
    number(scene["h-arrow"]?["x"]) > 200,
    "x=\(number(scene["h-arrow"]?["x"]))"
)

/// Excalidraw binds an arrow but never MOVES it, so a moved box leaves its arrow
/// behind — still bound, so the digest goes on reporting `h-a -> h-b` quite
/// correctly while the picture shows an arrow pointing at empty space.
let arrowBefore = (x: number(scene["h-arrow"]?["x"]), y: number(scene["h-arrow"]?["y"]))
_ = host.apply(["kind": "update", "id": "h-a", "x": 100, "y": 700])
scene = files.elements()
let arrowAfter = (x: number(scene["h-arrow"]?["x"]), y: number(scene["h-arrow"]?["y"]))
check(
    "moving a bound box drags its arrow with it",
    arrowAfter.x != arrowBefore.x || arrowAfter.y != arrowBefore.y,
    "before=(\(arrowBefore.x), \(arrowBefore.y)) after=(\(arrowAfter.x), \(arrowAfter.y))"
)
check(
    "the dragged arrow follows the box down the board",
    arrowAfter.y > arrowBefore.y + 100,
    "before y=\(arrowBefore.y) after y=\(arrowAfter.y)"
)

_ = host.apply(["kind": "delete", "ids": ["h-b"]])
scene = files.elements()
check(
    "deleting a box leaves no arrow bound to the dead id",
    binding(scene["h-arrow"], "endBinding") == nil,
    "endBinding=\(binding(scene["h-arrow"], "endBinding") ?? "nil")"
)
check(
    "and the arrow itself survives, unattached",
    scene["h-arrow"] != nil
)

// ---------------------------------------------------------------------------
section("2. customData survives a reload — the gate for captions")
// savedScene() runs restore(JSON.parse(...)) on every mount. PR 3 established that
// customData round-trips at CREATION time; nothing has established it survives
// restore. If it does not, a caption is written, renders in the digest at once,
// and is gone after relaunch — the PR 1 bug shape applied to customData.

_ = host.apply([
    "kind": "add",
    "elements": [
        box("h-note", "check the TTL", x: 100, y: 1000, extra: [
            "customData": [
                "atelierAuthor": "agent",
                "atelierKind": "note",
                "atelierCaption": "a caption planted before any reload",
            ],
        ]),
    ],
])

func customData(_ id: String) -> [String: Any] {
    files.elements()[id]?["customData"] as? [String: Any] ?? [:]
}

check(
    "all three customData keys reach board.excalidraw",
    customData("h-note")["atelierAuthor"] as? String == "agent"
        && customData("h-note")["atelierKind"] as? String == "note"
        && customData("h-note")["atelierCaption"] as? String == "a caption planted before any reload",
    "\(customData("h-note"))"
)

// Tear the page down and build a fresh host from the scene on disk — a relaunch,
// which is the only thing that exercises `restore`.
host.teardown()
pump(0.5)
host = HarnessHost(files: files, bundle: bundleDir)
guard host.waitUntilReady() else {
    check("the reloaded page mounts", false, "never became ready")
    print("\nCould not reload the board; the customData round-trip is unproven.")
    exit(1)
}

check("the reloaded page mounts from the saved scene", true)

// One more save, so what is on disk is what the RELOADED page believes — not the
// file the first page left behind.
_ = host.apply(["kind": "update", "id": "h-note", "x": 140, "y": 1000])

check(
    "atelierCaption survives restore on reload",
    customData("h-note")["atelierCaption"] as? String == "a caption planted before any reload",
    "\(customData("h-note"))"
)
check(
    "atelierKind survives restore on reload (a note stays a note)",
    customData("h-note")["atelierKind"] as? String == "note",
    "\(customData("h-note"))"
)
check(
    "atelierAuthor survives restore on reload",
    customData("h-note")["atelierAuthor"] as? String == "agent",
    "\(customData("h-note"))"
)

// ---------------------------------------------------------------------------
section("3. The board still renders offscreen")
// Not a formality: the export is the half of the read path that corroborates the
// digest, and it has failed outright before — invisibly, because a stale render
// and one that never arrived look identical on disk.

host.waitForRender()
check(
    "exportToBlob completes in an occluded window",
    files.renderWrites > 0,
    files.lastRenderFailure ?? "no render arrived"
)
check(
    "board.png and its stamp are on disk",
    FileManager.default.fileExists(atPath: files.png.path)
        && FileManager.default.fileExists(atPath: files.stamp.path)
)

// ---------------------------------------------------------------------------
section("4. The capture arm — an image placed on the board")
// A capture is a MUTATION ARM, so it owes the two standing questions an answer,
// and it is checked here rather than asserted in a PR body.

/// A real PNG, standing in for what `screencapture -i` hands back. The harness
/// cannot raise a capture overlay, so this is the half after it: the bytes exist,
/// and everything from naming them onwards is the code under test.
let capturedPNG: Data = {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 320, height: 200).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}()

/// Named the way `Whiteboard.Capture.fileID` names it — SHA-1 hex, Excalidraw's
/// own fileId convention — and written where `Store.writeAsset` would put it.
let capturedID = Insecure.SHA1.hash(data: capturedPNG)
    .map { String(format: "%02x", $0) }.joined()
try! capturedPNG.write(
    to: files.assets.appendingPathComponent("\(capturedID).png"), options: .atomic
)

/// Where the board ends right now, which is where a capture must land.
let extentBefore: Double = {
    let answer = host.callJS("return JSON.stringify(window.__whiteboardState())")
    guard let data = answer?.data(using: .utf8),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .nan }
    return number(state["nextY"])
}()

let placed = host.apply([
    "kind": "image", "id": "h-shot", "fileId": capturedID,
    "name": "\(capturedID).png", "mimeType": "image/png",
    "x": 100, "y": extentBefore, "width": 320, "height": 200,
])
check(
    "the page accepts an image op",
    placed["ok"] as? Bool == true,
    "\(placed)"
)

scene = files.elements()
check(
    "the image element reaches board.excalidraw",
    scene["h-shot"]?["type"] as? String == "image",
    "type=\(scene["h-shot"]?["type"] as? String ?? "nil")"
)
check(
    "its fileId is the assets/ filename's stem",
    scene["h-shot"]?["fileId"] as? String == capturedID,
    "fileId=\(scene["h-shot"]?["fileId"] as? String ?? "nil") stem=\(capturedID)"
)
check(
    "assets/ holds that file",
    files.assetNames().contains("\(capturedID).png"),
    "\(files.assetNames())"
)

// Rule 5, and the bug PR 1 shipped: serializeAsJSON inlines every referenced
// file as base64 unless it is handed an empty files map.
check(
    "board.excalidraw carries no image bytes",
    !files.sceneText().contains("data:image"),
    "the scene file contains a data: URL"
)

check(
    "the capture landed below what was already on the board",
    number(scene["h-shot"]?["y"]) >= extentBefore - 1,
    "y=\(number(scene["h-shot"]?["y"])) extent=\(extentBefore)"
)

// The standing rule, both halves. A capture moves nothing and removes nothing,
// so the answer to each should be "nothing changed" — which is worth checking
// rather than assuming, since the add arm reaches every element to merge
// boundElements.
check(
    "placing an image leaves the surviving arrow's binding alone",
    binding(scene["h-arrow"], "startBinding") == "h-a",
    "start=\(binding(scene["h-arrow"], "startBinding") ?? "nil")"
)
check(
    "placing an image leaves nothing bound to a dead id",
    scene.values.allSatisfy { element in
        guard element["type"] as? String == "arrow" else { return true }
        for key in ["startBinding", "endBinding"] {
            if let target = binding(element, key), scene[target] == nil {
                return false
            }
        }
        return true
    }
)

// The half that CANNOT be inherited from PR 2. A captured image is an
// asset-scheme URL from the moment it lands, unlike a pasted one, so it taints
// the export canvas in its own session rather than after a relaunch — and the
// whole export fails with SecurityError, not just the image.
host.waitForRender()
check(
    "the PNG export still succeeds with an asset-scheme image on the board",
    files.lastRenderFailure == nil,
    files.lastRenderFailure ?? ""
)

// ---------------------------------------------------------------------------
section("5. The caption arm")

/// The key travels WITH the value, the way `Write.updatePlan` sends it — the
/// page spells no customData key. The literal here is the harness playing
/// Swift's part; `WhiteboardWriteTests` is what pins it to `Element.captionKey`.
let captioned = host.apply([
    "kind": "update", "id": "h-shot",
    "caption": "Settings pane, Environment tab, process-compose row red",
    "captionKey": "atelierCaption",
])
check("the page accepts a caption", captioned["ok"] as? Bool == true, "\(captioned)")
check(
    "the caption reaches board.excalidraw",
    customData("h-shot")["atelierCaption"] as? String
        == "Settings pane, Environment tab, process-compose row red",
    "\(customData("h-shot"))"
)

// The merge, and the reason it is a merge. A note carries atelierKind in the
// same dictionary, so an assignment here would demote it to a box in the digest
// — silently, and only visible on a read.
_ = host.apply(["kind": "update", "id": "h-note", "caption": "", "captionKey": "atelierCaption"])
check(
    "a caption write on a note leaves atelierKind intact",
    customData("h-note")["atelierKind"] as? String == "note",
    "\(customData("h-note"))"
)
check(
    "and leaves atelierAuthor intact",
    customData("h-note")["atelierAuthor"] as? String == "agent",
    "\(customData("h-note"))"
)
check(
    "an empty caption removes the key rather than storing an empty string",
    customData("h-note")["atelierCaption"] == nil,
    "\(customData("h-note"))"
)

// The standing rule's first question, for the caption arm: a caption sent
// together with a move must still drag the arrows bound to what moved, rather
// than taking a path around the reflow.
//
// A fully bound arrow, drawn fresh, and pointing at the IMAGE — which is the
// real shape of this call, since `whiteboard_update` takes `at` and `caption`
// together and a caption only ever goes on an image. The arrow left over from
// section 1 is no use here: it lost its endBinding when h-b was deleted, and a
// half-bound arrow is never reflowed at all (`if (!from || !to) return el`), so
// it would report this arm broken whatever the arm did.
_ = host.apply([
    "kind": "add",
    "elements": [
        box("h-c", "the screenshot shows", x: 100, y: 1900),
        box("h-d", "the fix", x: 700, y: 1900),
        arrow("h-arrow2", from: "h-c", to: "h-d"),
    ],
])
scene = files.elements()
check(
    "a fresh arrow binds both ends",
    binding(scene["h-arrow2"], "startBinding") == "h-c"
        && binding(scene["h-arrow2"], "endBinding") == "h-d"
)

let arrowBeforeCaption = (
    x: number(scene["h-arrow2"]?["x"]), y: number(scene["h-arrow2"]?["y"])
)
_ = host.apply([
    "kind": "update", "id": "h-c", "x": 100, "y": 2600,
    "caption": "", "captionKey": "atelierCaption",
])
scene = files.elements()
check(
    "a caption sent with a move still reflows the arrows bound to what moved",
    // The element's presence is asserted first, deliberately: `number(nil)` is
    // NaN and `NaN != NaN` is TRUE, so a comparison alone reports a PASS for an
    // arrow that is not on the board at all. This check did exactly that once.
    scene["h-arrow2"] != nil
        && (number(scene["h-arrow2"]?["x"]) != arrowBeforeCaption.x
            || number(scene["h-arrow2"]?["y"]) != arrowBeforeCaption.y),
    scene["h-arrow2"] == nil
        ? "the arrow is not on the board"
        : "before=\(arrowBeforeCaption) "
        + "after=(\(number(scene["h-arrow2"]?["x"])), \(number(scene["h-arrow2"]?["y"])))"
)

_ = host.apply([
    "kind": "update", "id": "h-shot",
    "caption": "Settings pane, Environment tab, process-compose row red",
    "captionKey": "atelierCaption",
])
check(
    "the image still carries its caption after all of that",
    customData("h-shot")["atelierCaption"] as? String
        == "Settings pane, Environment tab, process-compose row red",
    "\(customData("h-shot"))"
)

check(
    "captioning removes nothing, so nothing is left bound to a dead id",
    scene.values.allSatisfy { element in
        guard element["type"] as? String == "arrow" else { return true }
        for key in ["startBinding", "endBinding"] {
            if let target = binding(element, key), scene[target] == nil {
                return false
            }
        }
        return true
    }
)

// And it survives a reload, the same way the planted keys did — this time
// through the real caption arm rather than a hand-built element.
host.teardown()
pump(0.5)
host = HarnessHost(files: files, bundle: bundleDir)
if host.waitUntilReady() {
    // One save from the RELOADED page, so what is on disk is what that page
    // believes rather than the file the previous one left behind.
    _ = host.apply(["kind": "update", "id": "h-shot", "x": 120, "y": 2000])
    check(
        "a real caption survives a reload",
        customData("h-shot")["atelierCaption"] as? String
            == "Settings pane, Environment tab, process-compose row red",
        "\(customData("h-shot"))"
    )
} else {
    check("the board reloads after a caption", false, "never became ready")
}

// ---------------------------------------------------------------------------
section("6. Known limitation, pinned so it cannot go quiet")
// An arrow CANNOT bind to an image: convertToExcalidrawElements throws
// `TypeError: undefined is not an object (evaluating 't.id')` for one, measured
// against 0.18.1. That is Excalidraw's own skeleton converter and it predates
// PR 4 — a board has been able to hold pasted images since PR 1 — but PR 4 is
// what makes images something an agent deliberately reaches for.
//
// What is pinned here is that it stays a REFUSAL. The refusal is honest: the
// board is left alone and the agent is told. The failure to guard against is it
// becoming a partial apply or a silent success, which is what would put an
// arrow on the board bound to nothing while the digest reported an endpoint.

let boardBefore = files.elements().count
let refused = host.apply([
    "kind": "add",
    "elements": [arrow("h-arrow-img", from: "h-c", to: "h-shot")],
])
check(
    "an arrow naming an image is refused rather than half-applied",
    refused["ok"] as? Bool != true,
    "\(refused)"
)
check(
    "and the refusal leaves the board exactly as it was",
    files.elements().count == boardBefore && files.elements()["h-arrow-img"] == nil,
    "before=\(boardBefore) after=\(files.elements().count)"
)

// ---------------------------------------------------------------------------
section("7. The update arm — a label follows its box, and `text` refuses where there is none")
// Both of these SUCCEEDED before this change, which is what makes them worth
// pinning: the call returned `ok`, and the board's picture and its digest
// disagreed afterwards.

/// The text element bound to a container, found by scanning.
///
/// Its id is minted by Excalidraw rather than supplied, so it cannot be looked
/// up by name the way every other element in this file is.
func labelOf(_ container: String) -> [String: Any]? {
    files.elements().values.first { $0["containerId"] as? String == container }
}

_ = host.apply([
    "kind": "add",
    "elements": [box("h-moved", "Session store", x: 200, y: 2000)],
])

// Presence FIRST, and the harness has been caught by exactly this before:
// number(nil) is NaN and NaN != NaN is true, so a "something changed"
// comparison passes against an element that is not on the board at all.
guard let labelBefore = labelOf("h-moved") else {
    check("the labelled box's label reaches the board", false, "no element carries containerId h-moved")
    print("\nWithout a label there is nothing to move; the rest of section 7 would be meaningless.")
    exit(1)
}

check("the labelled box's label reaches the board", true)

let offsetBefore = (
    x: number(labelBefore["x"]) - 200,
    y: number(labelBefore["y"]) - 2000
)

_ = host.apply(["kind": "update", "id": "h-moved", "x": 900, "y": 2600])

/// The container really moved — without this, a page that moved nothing at all
/// would satisfy the offset comparison below perfectly.
let movedBox = files.elements()["h-moved"]
check(
    "the moved box lands where it was sent",
    number(movedBox?["x"]) == 900 && number(movedBox?["y"]) == 2600,
    "(\(number(movedBox?["x"])), \(number(movedBox?["y"])))"
)

guard let labelAfter = labelOf("h-moved") else {
    check("the label survives the move", false, "no element carries containerId h-moved")
    print("\nThe label did not survive the move.")
    exit(1)
}

check("the label survives the move", true)

/// The offset is asserted rather than the position, because the offset is the
/// thing the fix preserves: Excalidraw insets an ellipse's label and constrains
/// a diamond's wrap width, so the label's place inside its container is
/// Excalidraw's own maths and not plain centring. Shifting by the delta keeps
/// whatever it decided; recomputing would have to reproduce it.
let offsetAfter = (
    x: number(labelAfter["x"]) - 900,
    y: number(labelAfter["y"]) - 2600
)
check(
    "moving a labelled box drags its label with it, at the same offset",
    abs(offsetAfter.x - offsetBefore.x) < 0.001 && abs(offsetAfter.y - offsetBefore.y) < 0.001,
    "before=(\(offsetBefore.x), \(offsetBefore.y)) after=(\(offsetAfter.x), \(offsetAfter.y)) "
        + "label now at (\(number(labelAfter["x"])), \(number(labelAfter["y"])))"
)

// A move and a retext in one call. The label is rewritten by id rather than by
// the object resolved before the move, so the shift must survive the text.
_ = host.apply(["kind": "update", "id": "h-moved", "x": 900, "y": 3200, "text": "Token cache"])
let labelBoth = labelOf("h-moved")
check(
    "a move and a retext in one call land both",
    labelBoth?["text"] as? String == "Token cache"
        && abs((number(labelBoth?["y"]) - 3200) - offsetBefore.y) < 0.001,
    "text=\(labelBoth?["text"] as? String ?? "nil") "
        + "offset y=\(number(labelBoth?["y"]) - 3200) expected \(offsetBefore.y)"
)

// A STANDALONE text element is the other branch of textTargetFor — it is its own
// words rather than a container's, so `text` writes to the element itself and
// there is no label to drag. Nothing else in this file retexts one: box() always
// attaches a label, and sections 4 and 5 work on images.

_ = host.apply([
    "kind": "add",
    "elements": [[
        "id": "h-standalone", "type": "text", "x": 200, "y": 3400,
        "text": "a free-floating note",
        "customData": ["atelierAuthor": "agent"],
    ]],
])
_ = host.apply(["kind": "update", "id": "h-standalone", "text": "rewritten in place"])
check(
    "`text` on a standalone text element rewrites the element itself",
    files.elements()["h-standalone"]?["text"] as? String == "rewritten in place"
        && files.elements()["h-standalone"]?["originalText"] as? String == "rewritten in place",
    "text=\(files.elements()["h-standalone"]?["text"] as? String ?? "nil") "
        + "originalText=\(files.elements()["h-standalone"]?["originalText"] as? String ?? "nil")"
)

// --- `text` on an element that has no label ---------------------------------
// textTargetFor returns null for any box, ellipse, diamond or arrow drawn
// without one, and the arm used to answer `ok` having changed nothing — the
// same silent success PR 4 closed for images, which Swift cannot close here
// because `Live` does not carry which elements have labels.

_ = host.apply([
    "kind": "add",
    "elements": [[
        "id": "h-bare", "type": "rectangle",
        "x": 200, "y": 3800, "width": 220, "height": 90,
        "customData": ["atelierAuthor": "agent"],
    ]],
])
check(
    "a bare rectangle reaches the board carrying no label",
    files.elements()["h-bare"] != nil && labelOf("h-bare") == nil,
    "label=\(String(describing: labelOf("h-bare")?["id"]))"
)

let bareRefused = host.apply(["kind": "update", "id": "h-bare", "text": "Cache"])
check(
    "`text` on an element with no label is refused rather than succeeding silently",
    bareRefused["ok"] as? Bool != true,
    "\(bareRefused)"
)
check(
    "and the refusal creates no label",
    labelOf("h-bare") == nil,
    "label=\(String(describing: labelOf("h-bare")?["id"]))"
)
check(
    "and leaves the element's boundElements alone",
    (files.elements()["h-bare"]?["boundElements"] as? [[String: Any]] ?? []).isEmpty,
    "\(String(describing: files.elements()["h-bare"]?["boundElements"]))"
)

/// Refused WHOLE. A call carrying both a move and text must land neither, or the
/// board ends in a state the answer does not describe — the rule the
/// arrow-naming-an-image refusal above already follows.
let bothRefused = host.apply(["kind": "update", "id": "h-bare", "x": 1500, "y": 4400, "text": "Cache"])
check(
    "a move sent with that text is refused with it, not applied on its own",
    bothRefused["ok"] as? Bool != true
        && number(files.elements()["h-bare"]?["x"]) == 200
        && number(files.elements()["h-bare"]?["y"]) == 3800,
    "\(bothRefused) position=(\(number(files.elements()["h-bare"]?["x"])), "
        + "\(number(files.elements()["h-bare"]?["y"])))"
)

// ---------------------------------------------------------------------------
section("8. A pasted image's bytes are posted once, not on every save")
// The board's save loop used to post the base64 of every image whose dataURL was
// still a `data:` one — every image pasted this session — on EVERY 800ms save,
// and Bridge rewrote each to disk. A board with several screenshots paid
// megabytes of bridge traffic per edit, for the life of the session.

host.teardown()
pump(0.5)

/// Bytes that are deliberately NOT the capture's, so this cannot pass on a file
/// that section 4 already put in assets/.
let pastedPNG: Data = {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 48).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}()

let pastedID = Insecure.SHA1.hash(data: pastedPNG)
    .map { String(format: "%02x", $0) }.joined()

/// A board whose scene file carries its image bytes INLINE, which is what
/// `api.getFiles()` holds for an image pasted this session.
///
/// It is the only way this harness can produce that state — a paste needs a real
/// paste event, while savedFiles() and the capture arm both hand Excalidraw an
/// asset-scheme URL — and it is faithful, because the loop under test
/// discriminates on exactly one thing: whether the dataURL has a comma in it. It
/// is also a real board rather than a contrivance. A scene written before
/// assets/ existed looks precisely like this, and rule 5's check in section 4 is
/// the assertion that Atelier never writes another one.
let inlinedScene: [String: Any] = [
    "type": "excalidraw",
    "version": 2,
    "source": "whiteboard-harness",
    "elements": [[
        "id": "h-pasted", "type": "image", "x": 40, "y": 40,
        "width": 320, "height": 200, "fileId": pastedID, "status": "saved",
        "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
        "roughness": 1, "opacity": 100, "groupIds": [], "frameId": NSNull(),
        "roundness": NSNull(), "boundElements": [], "link": NSNull(),
        "locked": false, "seed": 1, "version": 1, "versionNonce": 1,
        "updated": 1, "isDeleted": false, "scale": [1, 1],
    ]],
    "appState": ["viewBackgroundColor": "#ffffff"],
    "files": [pastedID: [
        "id": pastedID,
        "mimeType": "image/png",
        "dataURL": "data:image/png;base64," + pastedPNG.base64EncodedString(),
        "created": 1,
    ]],
]
try! JSONSerialization.data(withJSONObject: inlinedScene)
    .write(to: files.scene, options: .atomic)

/// What the counter stood at before this section — see `assetWrites`. Taken
/// after the seed is written and before the page that reads it exists, so
/// everything counted from here is this section's own.
let postsBeforeSection = files.assetWrites

host = HarnessHost(files: files, bundle: bundleDir)
if host.waitUntilReady() {
    // Driven by an op rather than waited for, so nothing here depends on
    // whether Excalidraw's own onChange happens to fire on mount.
    _ = host.apply(["kind": "update", "id": "h-pasted", "x": 80, "y": 40])

    check(
        "a pasted image's bytes reach assets/ on the first save",
        files.assetNames().contains("\(pastedID).png"),
        "\(files.assetNames())"
    )
    // Rule 5 again, on the way out: the bytes leave the scene file.
    check(
        "and leave board.excalidraw behind them",
        !files.sceneText().contains("data:image"),
        "the scene file still contains a data: URL"
    )

    // The finding itself, and the one check in this file whose instrument is a
    // POST COUNT rather than a file.
    //
    // That is not the return value the README forbids trusting: this is the
    // Swift end counting what the page really sent it, which is the same class
    // of evidence as reading the file. It has to be, because the re-posted
    // bytes are IDENTICAL — the name is a SHA-1 of them — so assets/ is
    // byte-for-byte correct after every redundant post, and no assertion about
    // a file can see this bug at all.
    let postsAfterFirstSave = files.assetWrites
    check(
        "the first save posted those bytes exactly once",
        postsAfterFirstSave - postsBeforeSection == 1,
        "\(postsAfterFirstSave - postsBeforeSection) posts"
    )

    _ = host.apply(["kind": "update", "id": "h-pasted", "x": 120, "y": 40])
    _ = host.apply(["kind": "update", "id": "h-pasted", "x": 160, "y": 40])
    check(
        "two further saves post no asset at all",
        files.assetWrites == postsAfterFirstSave,
        "\(files.assetWrites - postsAfterFirstSave) further posts"
    )
    check(
        "and the image is still in assets/ after them",
        files.assetNames().contains("\(pastedID).png"),
        "\(files.assetNames())"
    )

    // The standing pair, for a change that alters WHEN bytes are posted: it
    // moves no element and removes none, so the board must be exactly what the
    // three moves left. Checked rather than asserted, because the loop runs
    // inside the same save every op ends with.
    let finalScene = files.elements()
    check(
        "skipping a post changes nothing about the board itself",
        finalScene["h-pasted"] != nil
            && number(finalScene["h-pasted"]?["x"]) == 160
            && finalScene["h-pasted"]?["fileId"] as? String == pastedID,
        "\(finalScene["h-pasted"] ?? [:])"
    )
} else {
    check("the board reloads with an inlined image", false, "never became ready")
}

// ---------------------------------------------------------------------------
section("9. A pasted SVG lands under an extension Swift will write")
// `image/svg+xml` used to reach assets/ as the extension `svg+xml`, because
// save() derived one by taking the half of the MIME type after the slash.
// `Whiteboard.Store.isSafeComponent` refuses the `+`, so `writeAsset` threw
// `unsafeName` and only logged — while `writtenAssets` had already marked the id
// written, so no later save retried it. The board showed the image for the
// session and dropped it on the next relaunch.
//
// The name on disk is the whole of the bug, and it is why this section stops at
// the write half: `savedFiles()` splits on the LAST dot, so a file misnamed
// `<sha1>.svg+xml` would come back as the id `<sha1>` with a mimeType of
// `image/svg+xml` regardless — a reload check cannot tell the two apart, and
// this harness's own AssetScheme copy serves everything but PNG as JPEG, so it
// could not be trusted to either.

host.teardown()
pump(0.5)

/// Deliberately its own bytes, so this cannot pass on a file another section
/// already put in assets/ — the rule section 8 states for itself.
let pastedSVG = Data("""
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="48" viewBox="0 0 64 48">\
<rect width="64" height="48" fill="#4f46e5"/></svg>
""".utf8)

let svgID = Insecure.SHA1.hash(data: pastedSVG)
    .map { String(format: "%02x", $0) }.joined()

/// The same inlined-bytes fixture section 8 uses and for the same reason — a
/// real paste needs a real paste event — with the one value under test changed:
/// the file's mimeType. Excalidraw accepts `image/svg+xml` pastes, and the
/// mermaid work renders a diagram it cannot express as an asset of exactly this
/// type, so this is the ordinary case rather than an exotic one.
let svgScene: [String: Any] = [
    "type": "excalidraw",
    "version": 2,
    "source": "whiteboard-harness",
    "elements": [[
        "id": "h-svg", "type": "image", "x": 40, "y": 40,
        "width": 320, "height": 240, "fileId": svgID, "status": "saved",
        "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
        "roughness": 1, "opacity": 100, "groupIds": [], "frameId": NSNull(),
        "roundness": NSNull(), "boundElements": [], "link": NSNull(),
        "locked": false, "seed": 2, "version": 1, "versionNonce": 2,
        "updated": 1, "isDeleted": false, "scale": [1, 1],
    ]],
    "appState": ["viewBackgroundColor": "#ffffff"],
    "files": [svgID: [
        "id": svgID,
        "mimeType": "image/svg+xml",
        "dataURL": "data:image/svg+xml;base64," + pastedSVG.base64EncodedString(),
        "created": 1,
    ]],
]
try! JSONSerialization.data(withJSONObject: svgScene)
    .write(to: files.scene, options: .atomic)

host = HarnessHost(files: files, bundle: bundleDir)
if host.waitUntilReady() {
    // Driven by an op rather than waited for, the way section 8 drives its save.
    _ = host.apply(["kind": "update", "id": "h-svg", "x": 80, "y": 40])

    check(
        "a pasted SVG's bytes reach assets/ as <sha1>.svg",
        files.assetNames().contains("\(svgID).svg"),
        "\(files.assetNames())"
    )
    // The failing name, named — so a regression reports what it really wrote
    // rather than only that the file it wanted is missing.
    check(
        "and not under the MIME type's subtype, which Swift refuses to write",
        !files.assetNames().contains("\(svgID).svg+xml"),
        "the page posted the extension svg+xml"
    )
    // Rule 5, as every asset check restates it: the bytes leave the scene file.
    check(
        "and leave board.excalidraw behind them",
        !files.sceneText().contains("data:image"),
        "the scene file still contains a data: URL"
    )

    // The standing pair, for a change that alters only what an asset is NAMED:
    // it moves nothing and removes nothing, so the board must be exactly what
    // the one move left it.
    let svgSceneOnDisk = files.elements()
    check(
        "naming the asset changes nothing about the board itself",
        svgSceneOnDisk["h-svg"] != nil
            && number(svgSceneOnDisk["h-svg"]?["x"]) == 80
            && svgSceneOnDisk["h-svg"]?["fileId"] as? String == svgID,
        "\(svgSceneOnDisk["h-svg"] ?? [:])"
    )
} else {
    check("the board reloads with an inlined SVG", false, "never became ready")
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
section("10. The mermaid arm — expanded by Excalidraw's own converter, placed where asked")
// A mermaid definition is the one thing Swift hands the page WITHOUT having
// validated it: only `parseMermaidToExcalidraw` can say whether it parses, and
// only the page knows how big the result is. So every claim about this arm is a
// claim about the page, and every one is read off board.excalidraw and assets/.
//
// The op is spelled here exactly as `Whiteboard.Write.Mermaid.op` spells it —
// which, per the README, means this file cannot prove the two ends agree on
// those names; `WhiteboardWriteTests` pins the Swift side.

/// The op Swift sends, with the marker and the caption key travelling on it the
/// way `Write.Mermaid.op` sends them.
func mermaid(_ definition: String, x: Double, y: Double) -> [String: Any] {
    [
        "kind": "mermaid", "definition": definition, "x": x, "y": y,
        "customData": ["atelierAuthor": "agent"],
        "captionKey": "atelierCaption",
    ]
}

func fresh(since before: [String: [String: Any]]) -> [String: [String: Any]] {
    files.elements().filter { before[$0.key] == nil }
}

if host.waitUntilReady() {
    let flowchart = "graph LR; A[Auth] --> B[Token store]"

    // --- a flowchart, the ordinary case ------------------------------------
    let beforeFlowchart = files.elements()
    let answer = host.apply(mermaid(flowchart, x: 900, y: 900))
    let drawn = fresh(since: beforeFlowchart)
    let answeredIDs = (answer["ids"] as? [String]) ?? []

    // Two nodes, their two labels and the edge between them.
    check(
        "a flowchart lands on disk as its nodes, labels and edge",
        drawn.count == 5,
        "\(drawn.count) new elements: \(answer)"
    )
    check(
        "the answer's ids are all on the board",
        !answeredIDs.isEmpty && answeredIDs.allSatisfy { drawn[$0] != nil },
        "\(answeredIDs)"
    )
    check(
        "and name no bound label",
        answeredIDs.allSatisfy { drawn[$0]?["containerId"] == nil },
        "\(answeredIDs)"
    )
    let edges = drawn.values.filter { $0["type"] as? String == "arrow" }
    check(
        "the edge is bound at both ends to nodes the diagram drew",
        edges.count == 1
            && binding(edges.first, "startBinding").map { drawn[$0] != nil } == true
            && binding(edges.first, "endBinding").map { drawn[$0] != nil } == true,
        "start=\(binding(edges.first, "startBinding") ?? "nil") end=\(binding(edges.first, "endBinding") ?? "nil")"
    )
    let labels = drawn.values.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    check(
        "the node labels reach the board as the words in the definition",
        Set(labels).isSuperset(of: ["Auth", "Token store"]),
        "\(labels)"
    )
    // Placement is the page's job here — Swift cannot know the diagram's size —
    // and a diagram left at the converter's own origin lands on top of whatever
    // the user has at (0,0), which reads perfectly well in the digest.
    let minX = drawn.values.map { number($0["x"]) }.min() ?? .nan
    let minY = drawn.values.map { number($0["y"]) }.min() ?? .nan
    check(
        "the diagram's top-left is where it was asked to go",
        abs(minX - 900) < 1 && abs(minY - 900) < 1,
        "top-left=(\(minX), \(minY))"
    )
    // Every node and edge — not the bound labels, which the converter creates
    // fresh from `label` and which carry nothing on the add arm either; the
    // digest folds a label into its container and never reports it on its own.
    let authored = drawn.values.filter { $0["containerId"] == nil }
    check(
        "every node and edge it drew is marked agent-authored",
        !authored.isEmpty && authored.allSatisfy {
            (($0["customData"] as? [String: Any])?["atelierAuthor"] as? String) == "agent"
        },
        "\(authored.map { $0["customData"] ?? "nil" })"
    )

    // --- the same diagram twice --------------------------------------------
    // Mermaid names its nodes `A` and `B`; two diagrams that kept those ids
    // would collide on the board, and Excalidraw dedupes by id.
    let beforeSecond = files.elements()
    _ = host.apply(mermaid(flowchart, x: 900, y: 1400))
    let second = fresh(since: beforeSecond)
    check(
        "adding the same diagram again draws it again rather than colliding on mermaid's ids",
        second.count == drawn.count && Set(second.keys).isDisjoint(with: drawn.keys),
        "\(second.count) new elements, overlap \(Set(second.keys).intersection(drawn.keys))"
    )

    // --- a definition that does not parse ----------------------------------
    let sceneBefore = files.sceneText()
    let refused = host.apply(mermaid("this is not a diagram", x: 900, y: 1900))
    check(
        "a definition mermaid cannot parse is refused, and the refusal says why",
        refused["ok"] as? Bool != true && !((refused["reason"] as? String) ?? "").isEmpty,
        "\(refused)"
    )
    check(
        "and leaves the scene byte-identical",
        files.sceneText() == sceneBefore
    )

    // --- a diagram type the converter renders as an image ------------------
    // Flowcharts, sequence, class, ER and state diagrams become elements; every
    // other type comes back as an SVG rendered by mermaid itself, as an image
    // plus a file. That file has to survive the way a pasted image does, and it
    // carries no words on the canvas — so the definition is its caption.
    let pie = "pie title Pets\n    \"Dogs\" : 386\n    \"Cats\" : 85"
    let beforePie = files.elements()
    _ = host.apply(mermaid(pie, x: 900, y: 2000))
    let pieDrawn = fresh(since: beforePie)
    let image = pieDrawn.values.first { $0["type"] as? String == "image" }
    check(
        "a diagram type the converter cannot express lands as one image",
        image != nil && pieDrawn.count == 1,
        "\(pieDrawn.count) new elements: \(pieDrawn.values.map { $0["type"] ?? "?" })"
    )
    let fileID = image?["fileId"] as? String
    check(
        "its SVG reaches assets/ under the image's file id",
        fileID.map { files.assetNames().contains("\($0).svg") } == true,
        "fileId=\(fileID ?? "nil") assets=\(files.assetNames())"
    )
    check(
        "the image is captioned with the definition, so the digest is not blind to it",
        ((image?["customData"] as? [String: Any])?["atelierCaption"] as? String) == pie,
        "\(image?["customData"] ?? "nil")"
    )
    check(
        "and is placed where asked",
        abs(number(image?["x"]) - 900) < 1 && abs(number(image?["y"]) - 2000) < 1,
        "at=(\(number(image?["x"])), \(number(image?["y"])))"
    )
} else {
    check("the mermaid arm has a page to run in", false, "never became ready")
}

section("11. The save gate — a pan does not save, an edit does")
// Excalidraw fires onChange for APP STATE as well as elements: every pan, every
// zoom step, every selection. Each one used to arm a full save — a scene
// serialise, a PNG export that re-fetches and base64-encodes every asset, and a
// main-actor digest re-parse. `scheduleSave` now compares what a save would
// actually write (getSceneVersion plus the four appState keys serializeAsJSON
// persists) and declines when nothing did.
//
// **The gate's own counters are what make this non-vacuous.** "A pan posts no
// save" passes just as well if Excalidraw never fired onChange, so it would
// prove nothing and would go on passing with the gate deleted. `calls` rising
// while `armed` does not is the gate declining, which is the actual assertion.

host.teardown()
pump(0.5)

let gateScene: [String: Any] = [
    "type": "excalidraw",
    "elements": [[
        "id": "h-gate", "type": "rectangle", "x": 10, "y": 10,
        "width": 100, "height": 60, "version": 1, "versionNonce": 1,
        "isDeleted": false,
    ]],
    "appState": ["viewBackgroundColor": "#ffffff"],
]
try! JSONSerialization.data(withJSONObject: gateScene)
    .write(to: files.scene, options: .atomic)

host = HarnessHost(files: files, bundle: bundleDir)
if host.waitUntilReady() {
    /// `{calls, armed}` from the page.
    func gate() -> (calls: Int, armed: Int) {
        guard let raw = host.callJS("return window.__whiteboardDebug.gate()"),
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (-1, -1) }
        return (parsed["calls"] as? Int ?? -1, parsed["armed"] as? Int ?? -1)
    }

    // **A baseline save first, and the reason is the gate's own honest default.**
    // `savedSignature` starts null, so the FIRST onChange of a session always
    // arms a save whatever provoked it — the page cannot assume the file on disk
    // matches what it mounted, and one save to establish that is the safe answer.
    // Measuring a pan before any save had run therefore measured that baseline
    // rather than the gate. An agent write is the reliable way to produce one,
    // because Excalidraw's onChange does not necessarily fire on mount in an
    // occluded window — which is exactly what this harness exists to not assume.
    _ = host.apply(["kind": "update", "id": "h-gate", "x": 11, "y": 11])
    pump(1.2)

    // --- a pan -------------------------------------------------------------
    let beforePan = gate()
    let writesBeforePan = files.sceneWrites
    host.callJS("""
    const api = window.__whiteboardDebug.api()
    const st = api.getAppState()
    api.updateScene({ appState: { ...st, scrollX: (st.scrollX || 0) + 137,
                                  scrollY: (st.scrollY || 0) - 42, zoom: { value: 1.75 } } })
    return "done"
    """)
    // Past the 800ms debounce with margin, so a save that WAS armed has landed.
    pump(1.6)
    let afterPan = gate()

    check(
        "a pan reaches the gate at all — without this the next check is vacuous",
        afterPan.calls > beforePan.calls,
        "calls \(beforePan.calls) → \(afterPan.calls); onChange did not fire for an appState change"
    )
    check(
        "and the gate declines it rather than arming a save",
        afterPan.armed == beforePan.armed,
        "armed \(beforePan.armed) → \(afterPan.armed)"
    )
    // A companion assertion, NOT an independent guard — the shape
    // `WhiteboardWriteTabTests` already names for one of its three. Measured:
    // it passes with the gate deleted too, so it discriminates nothing on its
    // own. The `armed` check above is the one with teeth (verified by deleting
    // the gate: armed 1 → 2). This states the consequence the gate exists for,
    // which is worth saying out loud even where it cannot fail alone.
    check(
        "so nothing is written to board.excalidraw",
        files.sceneWrites == writesBeforePan,
        "\(files.sceneWrites - writesBeforePan) writes"
    )

    // --- an edit -----------------------------------------------------------
    // A new element, cloned from one already on the board so it is a real
    // Excalidraw element rather than a hand-written shape.
    let beforeEdit = gate()
    let writesBeforeEdit = files.sceneWrites
    host.callJS("""
    const api = window.__whiteboardDebug.api()
    const els = api.getSceneElements()
    const clone = { ...els[0], id: "h-gate-2", x: 500, y: 500,
                    version: (els[0].version || 1) + 1, versionNonce: 987654321 }
    api.updateScene({ elements: [...els, clone] })
    return "done"
    """)
    let saved = waitUntil(timeout: 10) { files.sceneWrites > writesBeforeEdit }
    let afterEdit = gate()

    check(
        "an edit arms a save",
        afterEdit.armed > beforeEdit.armed,
        "armed \(beforeEdit.armed) → \(afterEdit.armed)"
    )
    check(
        "and it reaches board.excalidraw",
        saved,
        "\(files.sceneWrites - writesBeforeEdit) writes"
    )
    check(
        "and the element it wrote is really there",
        files.elements()["h-gate-2"] != nil,
        "\(files.elements().keys.sorted())"
    )

    // --- an agent write costs exactly one save --------------------------------
    // `saveNow()` bypasses the gate on purpose: that path has just changed the
    // scene and must persist it whatever any comparison says. What the gate is
    // for here is the SECOND save — Excalidraw fires its own onChange for the
    // agent's updateScene, and before `save()` recorded the signature that
    // onChange armed a full redundant save (serialise, PNG export, digest
    // re-parse) 800ms after every single agent write.
    //
    // An identical `updateScene({elements: unchanged})` was tried here first and
    // is not a usable provocation: Excalidraw short-circuits it and fires no
    // onChange at all, so the check could only ever pass vacuously.
    let gateBeforeApply = gate()
    let writesBeforeApply = files.sceneWrites
    _ = host.apply(["kind": "update", "id": "h-gate", "x": 300, "y": 300])
    // Past the debounce, so a second save that WAS armed has had time to land.
    pump(1.6)
    let gateAfterApply = gate()

    check(
        "an agent write still saves, because saveNow bypasses the gate",
        files.sceneWrites > writesBeforeApply,
        "\(files.sceneWrites - writesBeforeApply) writes"
    )
    check(
        "and costs exactly one save, not a second armed by its own onChange",
        files.sceneWrites - writesBeforeApply == 1,
        "\(files.sceneWrites - writesBeforeApply) writes; "
            + "calls \(gateBeforeApply.calls) → \(gateAfterApply.calls), "
            + "armed \(gateBeforeApply.armed) → \(gateAfterApply.armed)"
    )
} else {
    check("the save gate has a page to run in", false, "never became ready")
}

// ---------------------------------------------------------------------------
section("12. Auto-sizing — the page measures, and every write answers with geometry")
// A box is no longer 220x90 whatever it says. Swift cannot measure text, so it
// asks the page, and the page asks the CONVERTER rather than measuring anything
// itself. Every claim below is about what Excalidraw really does with a label,
// which is exactly the kind of claim this file exists for and XCTest cannot make.

/// `__whiteboardMeasure`'s answer for one label, or nil.
func measured(_ text: String, boxed: Bool, maxWidth: Double = 400) -> (w: Double, h: Double)? {
    // `maxWidth` rides on the LABEL, not on the request: a caller that supplied
    // a width needs its own label wrapped at that width, and a batch can mix
    // supplied and auto widths. Sending it at the request level is how this
    // probe silently stopped exercising wrapping at all.
    let request: [String: Any] = [
        "labels": [["id": "m-probe", "text": text, "boxed": boxed, "maxWidth": maxWidth]],
    ]
    let payload = String(
        data: try! JSONSerialization.data(withJSONObject: request), encoding: .utf8
    )!
    guard let answer = host.callJS(
        "return JSON.stringify(await window.__whiteboardMeasure(JSON.parse(req)))",
        ["req": payload]
    ),
        let data = answer.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let sizes = parsed["sizes"] as? [String: Any],
        let size = sizes["m-probe"] as? [String: Any]
    else { return nil }
    return (number(size["width"]), number(size["height"]))
}

let shortLabel = measured("Auth", boxed: true)
let longLabel = measured("The authentication service that issues and rotates tokens", boxed: true)
check("the page answers with a measurement at all", shortLabel != nil)

if let shortLabel, let longLabel {
    // The whole premise of the change: a longer label measures WIDER. Under the
    // old fixed size both of these were 220 and the second one's text wrapped
    // inside the box and spilled out the bottom.
    check(
        "a longer label measures wider than a short one",
        longLabel.w > shortLabel.w,
        "short \(shortLabel.w), long \(longLabel.w)"
    )
    check(
        "and a label is never measured wider than maxWidth unless it cannot wrap",
        longLabel.w <= 400,
        "\(longLabel.w)"
    )
    check(
        "a label too wide to fit grows in HEIGHT instead, which is what wrapping means",
        longLabel.h > shortLabel.h,
        "short \(shortLabel.h), long \(longLabel.h)"
    )
}

// **The `\n` question, measured rather than asserted.**
//
// It was claimed that a box or note label collapses `\n` to a space while a
// bare `text` element honours it, and that nothing documents the difference.
// Reading Excalidraw's own `wrapText` says otherwise — it splits on "\n" first
// and wraps each line independently — but a claim about the page belongs here,
// not in a reading. It matters more under auto-sizing than it did under a fixed
// size: the measurement is taken from the label UNWRAPPED, so if the two halves
// disagree about a newline, every box holding one is sized for a rendering
// nobody sees.
let oneLine = measured("alpha beta", boxed: true)
let twoLines = measured("alpha\nbeta", boxed: true)
if let oneLine, let twoLines {
    check(
        "a newline in a box label is HONOURED, not collapsed — it measures taller",
        twoLines.h > oneLine.h,
        "one line \(twoLines.h) vs \(oneLine.h)"
    )
    check(
        "and narrower, because the two words are no longer side by side",
        twoLines.w < oneLine.w,
        "\(twoLines.w) vs \(oneLine.w)"
    )
}

// A bare text element is measured as itself: no container, and therefore no
// wrap and no padding. It must come out SMALLER than the same words in a box.
if let boxedSize = measured("alpha beta", boxed: true),
   let bareSize = measured("alpha beta", boxed: false)
{
    check(
        "a bare text element measures smaller than the same words in a container",
        bareSize.w < boxedSize.w && bareSize.h < boxedSize.h,
        "bare \(bareSize), boxed \(boxedSize)"
    )
}

/// **The round trip that the Swift half rests on.** Swift takes the measured
/// size and sends it back as the skeleton's own width and height. If handing a
/// measurement back caused Excalidraw to grow the container a second time, every
/// box would be drawn bigger than the size the answer reports — so this is the
/// check that the two ends agree.
let autoLabel = "The authentication service"
if let autoSize = measured(autoLabel, boxed: true) {
    _ = host.apply([
        "kind": "add",
        "elements": [
            box("m-sized", autoLabel, x: 2000, y: 2000, extra: [
                "width": autoSize.w, "height": autoSize.h,
            ]),
        ],
    ])
    let drawn = files.elements()["m-sized"]
    check(
        "a measured size handed back is the size the element really gets",
        number(drawn?["width"]) == autoSize.w && number(drawn?["height"]) == autoSize.h,
        "asked \(autoSize), got \(number(drawn?["width"]))x\(number(drawn?["height"]))"
    )
}

/// The geometry half of the answer. Swift's own placement is worthless if the
/// answer does not carry the result back: a caller that auto-sizes and is told
/// only the ids has traded a known-bad constant for an unknown one.
let geometryAnswer = host.apply([
    "kind": "add",
    "elements": [box("m-answer", "Rect", x: 3000, y: 3100)],
])
let answerRects = geometryAnswer["rects"] as? [String: Any]
let answerRect = answerRects?["m-answer"] as? [String: Any]
check(
    "an add answers with each element's own rectangle, keyed by id",
    number(answerRect?["x"]) == 3000 && number(answerRect?["y"]) == 3100,
    "\(String(describing: answerRect))"
)
check(
    "and that rectangle carries the size the element really has",
    number(answerRect?["width"]) == number(files.elements()["m-answer"]?["width"]),
    "answer \(number(answerRect?["width"]))"
)
let answerBoard = geometryAnswer["board"] as? [String: Any]
check(
    "and with the board's own extent, which retires the read_whiteboard round trip",
    number(answerBoard?["width"]) > 0 && number(answerBoard?["height"]) > 0,
    "\(String(describing: answerBoard))"
)
check(
    "and where the next unplaced element would go, below that extent",
    number(geometryAnswer["nextY"])
        > number(answerBoard?["y"]) + number(answerBoard?["height"]) - 0.001,
    "nextY \(number(geometryAnswer["nextY"]))"
)

// **Retexting has to resize, or the neighbouring tool undoes this feature.**
// A box sized to one word and then retexted to a sentence used to keep the size
// the old word earned, so its text spilled outside its own outline — the exact
// failure auto-sizing exists to fix, reached through whiteboard_update.
_ = host.apply([
    "kind": "add",
    "elements": [box("m-retext", "Hi", x: 4000, y: 4000, extra: ["width": 220, "height": 90])],
])
let beforeRetext = number(files.elements()["m-retext"]?["height"])
_ = host.apply([
    "kind": "update",
    "id": "m-retext",
    "text": "A much longer sentence than the one this box was drawn around, "
        + "long enough that it has to wrap onto several lines to fit at all.",
])
let afterRetext = files.elements()["m-retext"]
check(
    "retexting a box to something longer grows the box",
    number(afterRetext?["height"]) > beforeRetext,
    "\(beforeRetext) → \(number(afterRetext?["height"]))"
)
// Grow-only is Excalidraw's own semantics, not a policy invented here:
// redrawTextBoundingBox mutates a dimension only when the text exceeds it. It is
// what keeps a box the USER deliberately drew large from being shrunk by an
// agent's edit.
_ = host.apply(["kind": "update", "id": "m-retext", "text": "Hi"])
check(
    "and retexting it back to something short does NOT shrink it",
    number(files.elements()["m-retext"]?["height"]) >= number(afterRetext?["height"]),
    "\(number(files.elements()["m-retext"]?["height"]))"
)

// The label has to travel with the box it is inside. This is the same failure
// shiftLabel exists for, in the other direction: a container that grew while its
// label stayed put leaves the words sitting outside the outline that claims
// them, with the digest reporting the pair quite correctly.
if let retextLabel = labelOf("m-retext"), let retextBox = files.elements()["m-retext"] {
    let lx = number(retextLabel["x"])
    let ly = number(retextLabel["y"])
    check(
        "the label is still inside the box after it has been resized",
        lx >= number(retextBox["x"]) - 0.5
            && ly >= number(retextBox["y"]) - 0.5
            && lx + number(retextLabel["width"])
            <= number(retextBox["x"]) + number(retextBox["width"]) + 0.5,
        "label at \(lx),\(ly) in box at \(number(retextBox["x"])),\(number(retextBox["y"]))"
    )
}

// An arrow bound to a box that GREW has to be redrawn, for the same reason one
// bound to a box that MOVED has to be: edgePoints joins the two shapes' faces,
// and growing a box moves the face without moving the arrow. Still bound, so
// the digest goes on reporting the connection while the picture shows an arrow
// stopping short of the box or running inside it.
_ = host.apply([
    "kind": "add",
    "elements": [
        box("m-grow", "x", x: 5000, y: 5000, extra: ["width": 220, "height": 90]),
        box("m-fixed", "y", x: 5600, y: 5000),
    ],
])
_ = host.apply(["kind": "add", "elements": [arrow("m-edge", from: "m-grow", to: "m-fixed")]])
let growArrowBefore = (
    x: number(files.elements()["m-edge"]?["x"]),
    y: number(files.elements()["m-edge"]?["y"])
)
_ = host.apply([
    "kind": "update",
    "id": "m-grow",
    "text": "A label long enough that it has to wrap onto several lines inside this box",
])
let growArrowAfter = (
    x: number(files.elements()["m-edge"]?["x"]),
    y: number(files.elements()["m-edge"]?["y"])
)
// Both coordinates, not just `x`. Retexting is grow-only against the container's
// CURRENT width, so the label wraps at the width it already had and the box
// grows in HEIGHT — which moves the vertical centre `edgePoints` joins, not the
// right-hand face. Asserting on `x` alone passed for a box that was never
// reflowed at all, which is the failure this check exists to catch.
check(
    "an arrow bound to a box that GREW is redrawn to its new face",
    growArrowAfter != growArrowBefore,
    "arrow \(growArrowBefore) → \(growArrowAfter)"
)
check(
    "and it really did grow, or the check above would be vacuous",
    number(files.elements()["m-grow"]?["height"]) > 90,
    "height \(number(files.elements()["m-grow"]?["height"]))"
)

// **A labelled ARROW is not resized, and this is a real case rather than
// caution.** Write.skeletons sets a label for every kind, arrows included, so
// retexting a labelled arrow reaches the resize branch with an arrow as the
// container. An arrow's frame comes from its `points`, which a skeleton cannot
// carry — the conversion would rebuild it as a straight line — and
// computeContainerDimensionForBoundText has a separate `arrow` branch that grows
// by padding * 8. Excalidraw excludes arrows from this itself
// (`!isArrowElement(container)` in redrawTextBoundingBox), and so does the add
// arm, where `isBoxy` never sizes one.
_ = host.apply([
    "kind": "add",
    "elements": [
        box("m-l", "L", x: 6000, y: 6000),
        box("m-r", "R", x: 6600, y: 6000),
    ],
])
var labelledArrow = arrow("m-labelled", from: "m-l", to: "m-r")
labelledArrow["label"] = ["text": "calls"]
_ = host.apply(["kind": "add", "elements": [labelledArrow]])
let arrowFrameBefore = (
    w: number(files.elements()["m-labelled"]?["width"]),
    h: number(files.elements()["m-labelled"]?["height"])
)
_ = host.apply([
    "kind": "update",
    "id": "m-labelled",
    "text": "invokes over a very much longer edge label than the one it had",
])
check(
    "retexting a labelled arrow leaves its own frame alone",
    (
        w: number(files.elements()["m-labelled"]?["width"]),
        h: number(files.elements()["m-labelled"]?["height"])
    ) == arrowFrameBefore,
    "before \(arrowFrameBefore), after "
        + "\(number(files.elements()["m-labelled"]?["width"]))x"
        + "\(number(files.elements()["m-labelled"]?["height"]))"
)
check(
    "and the retext still landed on its label",
    (labelOf("m-labelled")?["text"] as? String)?.hasPrefix("invokes") == true,
    "\(String(describing: labelOf("m-labelled")?["text"]))"
)

// **A SUPPLIED size is honoured exactly** — the invariant a layout's column
// arithmetic rests on. Swift pins this on its own side; this pins that the page
// and Excalidraw do not quietly override it, which is the half Swift cannot see.
// 150 is below `boxSize.width` and the label is far too long for it, so both the
// floor and the grow-to-fit would show up here if either applied.
_ = host.apply([
    "kind": "add",
    "elements": [
        box("m-exact", "a label far too long to fit inside a hundred and fifty pixels",
            x: 7000, y: 7000, extra: ["width": 150, "height": 300]),
    ],
])
let exact = files.elements()["m-exact"]
check(
    "a supplied width and height reach the board untouched",
    number(exact?["width"]) == 150 && number(exact?["height"]) == 300,
    "\(number(exact?["width"]))x\(number(exact?["height"]))"
)

// A label measured against a SUPPLIED width, not against maxWidth. Measuring at
// the wrong width returns the height of a box nobody draws, and the one that is
// drawn is too short for the words in it.
if let atNarrow = measured("alpha beta gamma delta epsilon", boxed: true, maxWidth: 150),
   let atWide = measured("alpha beta gamma delta epsilon", boxed: true, maxWidth: 400)
{
    check(
        "a narrower maxWidth measures a taller box, because the label wraps more",
        atNarrow.h > atWide.h && atNarrow.w <= 150,
        "at 150: \(atNarrow), at 400: \(atWide)"
    )
}

// **`Live` carries every element's rectangle**, as validation input for a caller
// placing something relative to what is already there. The answer's geometry
// describes only the write that just happened, which is a whole call too late.
let liveJSON = host.callJS("return JSON.stringify(window.__whiteboardState())") ?? "null"
let liveRaw = (try? JSONSerialization.jsonObject(with: Data(liveJSON.utf8))) as? [String: Any]
let liveRects = liveRaw?["rects"] as? [String: Any]
let exactRect = liveRects?["m-exact"] as? [String: Any]
check(
    "the live state carries a named element's own rectangle",
    number(exactRect?["x"]) == 7000 && number(exactRect?["width"]) == 150,
    "\(String(describing: exactRect))"
)
// A SUBSET of `ids`, not an equal set: a non-finite coordinate is filtered out
// of `rects` and deliberately not out of `ids`, because membership of `ids` is
// what decides whether an element exists. Asserting equality would pin a
// stricter rule than the page promises.
check(
    "every rectangle it reports names an element it also reports",
    Set((liveRects ?? [:]).keys).isSubset(of: Set((liveRaw?["ids"] as? [String]) ?? [])),
    "\((liveRaw?["ids"] as? [String])?.count ?? -1) ids, \(liveRects?.count ?? -1) rects"
)

// **A board that cannot be measured answers NO ANSWER, never an empty board.**
// The empty answer carries `ids: []`, and reporting that for a board with
// elements on it would have whiteboard_update refuse a real id as unknown while
// the digest goes on listing it. This checks the ordinary half of that rule —
// that a non-empty scene never reports itself empty — because the other half is
// unreachable without a scene holding a non-finite coordinate, which Swift
// refuses to create.
let stateJSON = host.callJS("return JSON.stringify(window.__whiteboardState())") ?? "null"
let stateIDs = ((try? JSONSerialization.jsonObject(
    with: Data(stateJSON.utf8)
)) as? [String: Any])?["ids"] as? [String]
check(
    "a board with elements on it never reports itself as empty",
    !(stateIDs ?? []).isEmpty && !files.elements().isEmpty,
    "\(stateIDs?.count ?? -1) ids for \(files.elements().count) elements on disk"
)

// ---------------------------------------------------------------------------
print("\n\(checksRun - failures.count)/\(checksRun) checks passed")
if failures.isEmpty {
    print("PASS")
    exit(0)
}

print("FAILED: \(failures.joined(separator: ", "))")
exit(1)
