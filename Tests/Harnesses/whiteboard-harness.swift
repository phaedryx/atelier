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
print("\n\(checksRun - failures.count)/\(checksRun) checks passed")
if failures.isEmpty {
    print("PASS")
    exit(0)
}

print("FAILED: \(failures.joined(separator: ", "))")
exit(1)
