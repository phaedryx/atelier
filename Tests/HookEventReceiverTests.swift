// ABOUTME: Tests that hook events reach the app carrying the surface they came from.
// ABOUTME: Drives the real HTTP listener, since the envelope parsing is what's under test.

@testable import Atelier
import Darwin
import XCTest

final class HookEventReceiverTests: XCTestCase {
    private var receiver: HookEventReceiver {
        HookEventReceiver.shared
    }

    override func tearDown() {
        receiver.onEvent = nil
        receiver.onPermissionRequest = nil
        receiver.onPing = nil
        receiver.onStatusLine = nil
        super.tearDown()
    }

    /// Blocks until the listener reports a port, or the deadline passes.
    private func waitForBoundPort(timeout: TimeInterval = 10) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        var port: UInt16?
        while Date() < deadline, port == nil {
            port = receiver.boundPort
            if port == nil {
                usleep(20_000)
            }
        }
        return port
    }

    // MARK: - Isolation from the machine

    /// This suite binds a *real* listener. `hook-port` is the single rendezvous
    /// every Claude Code session on the machine reads — `atelier-hook` is
    /// installed globally in `~/.claude/settings.json` and cannot know which
    /// process wrote the file — so a test process that publishes its port there
    /// is handed the live traffic of every running session.
    ///
    /// That is not hypothetical. It is what made the `isIgnored` cases fail at
    /// random: `agentToolStart`/`agentToolDone` from a real session, for the
    /// developer's own checkout, arrived inside an inverted expectation's window.
    /// Worse than the flake, the permission cases here install handlers that
    /// answer `.allow` and `.deny`, so a real permission prompt could be decided
    /// by a test — and `stop()` then deletes the app's port file on the way out.
    ///
    /// Nothing here needs the file; every helper reads `boundPort` directly.
    func test_aTestProcessDoesNotPublishItsPortToTheSharedFile() throws {
        let path = NSString(string: "~/Library/Caches/atelier/hook-port").expandingTildeInPath

        receiver.start()
        let port = try XCTUnwrap(waitForBoundPort(), "hook receiver did not bind a port")

        let published = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(
            published, String(port),
            "the suite advertised its own listener as the app's; live hook traffic will land in these tests"
        )
    }

    // MARK: - Permission requests

    /// POSTs to `/permission` and returns the response *body* — which for this
    /// one route is the decision document, so the reply is the thing under test
    /// rather than an acknowledgement of it.
    private func postPermission(
        toolName: String = "Bash",
        toolInput: [String: Any] = ["command": "ls"],
        readTimeout: TimeInterval = 10
    ) throws -> String {
        receiver.start()

        let deadline = Date().addingTimeInterval(10)
        var port: UInt16?
        while Date() < deadline, port == nil {
            port = receiver.boundPort
            if port == nil {
                usleep(20_000)
            }
        }
        let resolved = try XCTUnwrap(port, "hook receiver did not bind a port")

        let envelope: [String: Any] = [
            "event_input": [
                "hook_event_name": "PermissionRequest",
                "tool_name": toolName,
                "tool_input": toolInput,
            ],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ]
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        let head = "POST /permission HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
        var request = Data(head.utf8)
        request.append(payload)

        // Off the main thread, deliberately. `hold` hands the request to the app
        // with `DispatchQueue.main.async`, so a test that sat on the main thread
        // waiting for the reply would deadlock against the very handler it is
        // testing — and then read back an empty body, which is *also* a
        // legitimate answer, so the hang would show up as a wrong result rather
        // than as a hang. `wait(for:)` keeps the main runloop turning instead.
        var body = ""
        let received = expectation(description: "permission response")
        DispatchQueue.global().async {
            body = Self.exchange(port: resolved, request: request, readTimeout: readTimeout)
            received.fulfill()
        }
        wait(for: [received], timeout: readTimeout + 10)
        return body
    }

    /// Sends one request and reads the whole response, returning its body.
    private static func exchange(port: UInt16, request: Data, readTimeout: TimeInterval) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }

        // Without a receive timeout the read below never returns when the app
        // does not answer at all, which is one of the failures these tests exist
        // to report rather than hang on.
        var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return "" }
        let length = request.count
        _ = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, length, 0) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = Darwin.recv(fd, &buffer, buffer.count, 0)
            guard read > 0 else { break }
            response.append(contentsOf: buffer[0 ..< read])
        }

        let text = String(decoding: response, as: UTF8.self)
        guard let separator = text.range(of: "\r\n\r\n") else { return "" }
        return String(text[separator.upperBound...])
    }

    func test_permissionRequest_repliesWithTheDecisionTheAppGives() throws {
        receiver.onPermissionRequest = { _, _, respond in respond(.allow) }
        XCTAssertEqual(try postPermission(), HookEventReceiver.decisionBody(.allow))
    }

    func test_permissionRequest_repliesWithADenial() throws {
        receiver.onPermissionRequest = { _, _, respond in respond(.deny) }
        let body = try postPermission()
        XCTAssertTrue(body.contains("\"behavior\":\"deny\""))
    }

    /// Empty is not a degenerate case, it is the fallback: the hook script only
    /// echoes a body containing `hookSpecificOutput`, so nothing reaches Claude
    /// Code's stdin parser and it asks in the terminal as it always would.
    func test_permissionRequest_withNoDecision_repliesEmpty() throws {
        receiver.onPermissionRequest = { _, _, respond in respond(nil) }
        XCTAssertEqual(try postPermission(), "")
    }

    /// The state during launch: the app is up, the listener is bound, and
    /// nothing has installed a handler yet. Every Claude session on the machine
    /// reaches this path, so it has to answer rather than queue.
    func test_permissionRequest_withNoHandler_repliesEmptyRatherThanHanging() throws {
        receiver.onPermissionRequest = nil
        XCTAssertEqual(try postPermission(readTimeout: 5), "")
    }

    func test_permissionRequest_carriesTheToolAndItsInput() throws {
        var seen: PendingPermission?
        receiver.onPermissionRequest = { _, request, respond in
            seen = request
            respond(nil)
        }
        _ = try postPermission(toolName: "Bash", toolInput: ["command": "rm -rf build"])

        XCTAssertEqual(seen?.toolName, "Bash")
        XCTAssertEqual(seen?.detail, "rm -rf build", "the whole point is not having to grep a phrase for this")
    }

    func test_permissionRequest_alsoReportsThatSomethingIsWaiting() throws {
        var events: [AgentEvent] = []
        let reported = expectation(description: "status routed")
        reported.assertForOverFulfill = false
        receiver.onEvent = { _, event in
            events.append(event)
            reported.fulfill()
        }
        receiver.onPermissionRequest = { _, _, respond in respond(nil) }

        _ = try postPermission()
        wait(for: [reported], timeout: 10)

        // `contains` rather than an exact match: the receiver is a singleton and
        // routes on the main queue, so an event from a neighbouring case can
        // still be in flight. What is under test is that this one is produced.
        XCTAssertTrue(
            events.contains { $0.status == "permissionRequired" },
            "the row must light up even when nobody here can answer"
        )
    }

    /// The regression this pairs with: a held connection is taken out of
    /// `connections` precisely so the half-open reaper cannot cancel it. Left in,
    /// it was killed `connectionTimeout` into a hold that may run for 90 seconds,
    /// with the banner still on screen.
    func test_aHeldPermissionSurvivesTheReadDeadline() throws {
        let previous = HookEventReceiver.connectionTimeout
        HookEventReceiver.connectionTimeout = 0.3
        addTeardownBlock { HookEventReceiver.connectionTimeout = previous }

        receiver.onPermissionRequest = { _, _, respond in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { respond(.allow) }
        }

        XCTAssertEqual(try postPermission(), HookEventReceiver.decisionBody(.allow))
    }

    /// POSTs one hook envelope over a raw socket — the same shape `atelier-hook`
    /// sends with curl — and returns the events the receiver produced.
    private func post(_ envelope: [String: Any], timeout: TimeInterval = 10) throws -> [AgentEvent] {
        var received: [AgentEvent] = []
        let delivered = expectation(description: "hook event routed")
        delivered.assertForOverFulfill = false
        receiver.onEvent = { _, event in
            received.append(event)
            delivered.fulfill()
        }

        let fd = try sendEnvelope(envelope, timeout: timeout)
        defer { close(fd) }
        wait(for: [delivered], timeout: timeout)
        return received
    }

    /// POSTs an envelope the receiver is meant to *ignore*, and fails if anything
    /// comes out of it. An event the mapper drops has no arrival to wait for, so
    /// this waits out a window instead of one.
    private func postExpectingNothing(_ envelope: [String: Any]) throws {
        let quiet = expectation(description: "no hook event routed")
        quiet.isInverted = true
        receiver.onEvent = { _, _ in quiet.fulfill() }

        let fd = try sendEnvelope(envelope, timeout: 10)
        defer { close(fd) }
        wait(for: [quiet], timeout: 1)
    }

    /// Opens a socket to the listener and writes one envelope to it. Returns the
    /// descriptor so the caller can hold the connection open until it has
    /// finished waiting — closing it here would race the receiver's read.
    private func sendEnvelope(_ envelope: [String: Any], timeout: TimeInterval, target: String = "/hook") throws -> Int32 {
        receiver.start()

        // Ask the listener for its port rather than reading hook-port: the file
        // may still hold the number a previous run of the app wrote.
        let deadline = Date().addingTimeInterval(timeout)
        var port: UInt16?
        while Date() < deadline, port == nil {
            port = receiver.boundPort
            if port == nil {
                usleep(20_000)
            }
        }
        let resolved = try XCTUnwrap(port, "hook receiver did not bind a port")

        let body = try JSONSerialization.data(withJSONObject: envelope)
        let head = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        var request = Data(head.utf8)
        request.append(body)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = resolved.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "could not reach the hook receiver")
        _ = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, request.count, 0) }
        return fd
    }

    func test_surfaceID_isCarriedFromTheEnvelopeOntoEveryEvent() throws {
        let surfaceID = UUID().uuidString
        let events = try post([
            "event_input": ["hook_event_name": "Stop", "agent_id": "main"],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": surfaceID,
        ])

        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.surfaceID == surfaceID })
    }

    func test_missingSurfaceID_readsAsNil() throws {
        // What a Claude session started outside Atelier sends: the hook is
        // installed globally, and the variable simply isn't in its environment.
        let events = try post([
            "event_input": ["hook_event_name": "Stop", "agent_id": "main"],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])

        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.surfaceID == nil })
    }

    // MARK: - Session lifecycle

    private func sessionEnvelope(_ input: [String: Any]) -> [String: Any] {
        ["event_input": input, "project_dir": "/tmp/atelier-hook-test", "surface_id": ""]
    }

    func test_sessionStart_fromStartup_endsWhateverThePreviousSessionLeft() throws {
        let events = try post(sessionEnvelope(["hook_event_name": "SessionStart", "source": "startup"]))
        XCTAssertEqual(events.map(\.type), [.agentSessionStarted])
    }

    func test_sessionStart_fromClear_endsWhateverThePreviousSessionLeft() throws {
        let events = try post(sessionEnvelope(["hook_event_name": "SessionStart", "source": "clear"]))
        XCTAssertEqual(events.map(\.type), [.agentSessionStarted])
    }

    /// `resume` and `compact` continue a session that is already running.
    /// Compaction in particular fires mid-turn: treating it as a new session
    /// would wipe live subagents off the roster while they are still working.
    func test_sessionStart_fromResume_isIgnored() throws {
        try postExpectingNothing(sessionEnvelope(["hook_event_name": "SessionStart", "source": "resume"]))
    }

    func test_sessionStart_fromCompact_isIgnored() throws {
        try postExpectingNothing(sessionEnvelope(["hook_event_name": "SessionStart", "source": "compact"]))
    }

    func test_sessionStart_withNoSource_isIgnored() throws {
        // An unrecognised or absent source is not evidence of a new session, and
        // clearing a live roster is the more destructive way to be wrong.
        try postExpectingNothing(sessionEnvelope(["hook_event_name": "SessionStart"]))
    }

    func test_sessionEnd_reportsTheSessionOver() throws {
        let events = try post(sessionEnvelope(["hook_event_name": "SessionEnd", "reason": "exit"]))
        XCTAssertEqual(events.map(\.type), [.agentSessionEnded])
        XCTAssertEqual(events.first?.agentId, "main")
    }

    // MARK: - Compaction

    func test_preCompact_carriesAnActivity() throws {
        let events = try post(sessionEnvelope(["hook_event_name": "PreCompact", "trigger": "auto"]))
        XCTAssertEqual(events.map(\.status), ["compacting"])
        XCTAssertEqual(events.first?.activity, "Compacting context")
    }

    func test_postCompact_takesTheActivityAway() throws {
        let events = try post(sessionEnvelope(["hook_event_name": "PostCompact", "trigger": "auto"]))
        XCTAssertEqual(events.map(\.status), ["compacted"])
        XCTAssertNil(events.first?.activity)
    }

    func test_transcriptPathIsStampedOntoSessionAndCompactionEvents() throws {
        let events = try post([
            "event_input": [
                "hook_event_name": "PostCompact",
                "transcript_path": "/tmp/atelier-hook-test/session.jsonl",
            ],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])
        XCTAssertEqual(events.first?.transcriptPath, "/tmp/atelier-hook-test/session.jsonl")
    }

    // MARK: - Connection deadline

    /// A local client that opens a connection, sends half a header and goes
    /// quiet used to leave `receiveData` recursing forever with the connection
    /// pinned in `connections` for the life of the process.
    func test_aHalfOpenRequestIsClosedByTheReadDeadline() throws {
        let previous = HookEventReceiver.connectionTimeout
        HookEventReceiver.connectionTimeout = 0.5
        addTeardownBlock { HookEventReceiver.connectionTimeout = previous }

        receiver.start()
        let deadline = Date().addingTimeInterval(10)
        var port: UInt16?
        while Date() < deadline, port == nil {
            port = receiver.boundPort
            if port == nil {
                usleep(20_000)
            }
        }
        let resolved = try XCTUnwrap(port, "hook receiver did not bind a port")

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = resolved.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "could not reach the hook receiver")

        // Headers that never end, and a body that never arrives.
        let partial = Data("POST /hook HTTP/1.1\r\nContent-Length: 4096\r\n".utf8)
        _ = partial.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, partial.count, 0) }

        let closed = Date().addingTimeInterval(10)
        while Date() < closed, receiver.connectionCount > 0 {
            usleep(50_000)
        }
        XCTAssertEqual(receiver.connectionCount, 0, "the stalled connection was never reaped")
    }

    // MARK: - Tool brackets pair

    /// An MCP call is a tool call like any other, and often a slow one. Dropping
    /// its `PreToolUse` left it with no open bracket, so the stall sweep saw
    /// pure silence and had nothing to exempt — the reason a slow MCP tool read
    /// as a wedged agent.
    func test_mcpToolCall_opensABracket() throws {
        let events = try post([
            "event_input": [
                "hook_event_name": "PreToolUse",
                "tool_name": "mcp__scenius__read",
                "agent_id": "main",
            ],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])

        XCTAssertEqual(events.map(\.type), [.agentToolStart])
        XCTAssertEqual(events.first?.activity, "scenius/read")
    }

    /// The meta tools stay filtered — but on *both* sides. A `PostToolUse` the
    /// mapper let through for a `PreToolUse` it dropped closed a bracket that
    /// was never opened.
    func test_metaTool_isFilteredOnBothSidesOfTheBracket() throws {
        try postExpectingNothing([
            "event_input": ["hook_event_name": "PreToolUse", "tool_name": "Skill", "agent_id": "main"],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])
        try postExpectingNothing([
            "event_input": ["hook_event_name": "PostToolUse", "tool_name": "Skill", "agent_id": "main"],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])
    }

    /// An ordinary tool still closes its bracket.
    func test_ordinaryTool_closesItsBracket() throws {
        let events = try post([
            "event_input": ["hook_event_name": "PostToolUse", "tool_name": "Bash", "agent_id": "main"],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])

        XCTAssertEqual(events.map(\.type), [.agentToolDone])
    }

    // MARK: - Channel liveness ping

    /// `HookChannelProbe` posts this envelope through the real `atelier-hook`
    /// script and concludes the channel is up when its nonce comes back out
    /// here. Nothing else in the app can tell it the delivery path works.
    func test_ping_reportsItsNonce() throws {
        let nonce = UUID().uuidString
        var seen: String?
        let arrived = expectation(description: "ping nonce reported")
        receiver.onPing = { received in
            seen = received
            arrived.fulfill()
        }

        let fd = try sendEnvelope([
            "event_input": ["hook_event_name": "AtelierPing", "nonce": nonce],
            "project_dir": "",
            "surface_id": "",
        ], timeout: 10)
        defer { close(fd) }
        wait(for: [arrived], timeout: 10)

        XCTAssertEqual(seen, nonce)
    }

    /// The ping must not look like agent activity: an envelope that reset a
    /// workstream's stall clock would make the probe's own traffic the reason
    /// the channel looked healthy.
    func test_ping_producesNoAgentEvents() throws {
        receiver.onPing = { _ in }
        try postExpectingNothing([
            "event_input": ["hook_event_name": "AtelierPing", "nonce": UUID().uuidString],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ])
    }

    /// A ping with no nonce is not a ping. Reporting one would let a malformed
    /// envelope satisfy a probe that is waiting for a specific nonce.
    func test_ping_withoutANonceIsNotReported() throws {
        let quiet = expectation(description: "no nonce reported")
        quiet.isInverted = true
        receiver.onPing = { _ in quiet.fulfill() }

        let fd = try sendEnvelope([
            "event_input": ["hook_event_name": "AtelierPing"],
            "project_dir": "",
            "surface_id": "",
        ], timeout: 10)
        defer { close(fd) }
        wait(for: [quiet], timeout: 1)
    }

    // MARK: - The status line channel

    /// Posts one status line envelope and returns what `onStatusLine` was
    /// handed, or nil if nothing was delivered inside `timeout`.
    private func postStatusLine(
        _ envelope: [String: Any],
        timeout: TimeInterval = 10,
        expectDelivery: Bool = true
    ) throws -> (projectDir: String, surfaceID: String?, reading: StatusLine.Reading)? {
        var received: (projectDir: String, surfaceID: String?, reading: StatusLine.Reading)?
        let delivered = expectation(description: "status line delivered")
        delivered.assertForOverFulfill = false
        delivered.isInverted = !expectDelivery
        receiver.onStatusLine = { projectDir, surfaceID, reading in
            received = (projectDir, surfaceID, reading)
            delivered.fulfill()
        }

        let fd = try sendEnvelope(envelope, timeout: timeout, target: "/statusline")
        defer { close(fd) }
        wait(for: [delivered], timeout: expectDelivery ? timeout : 1)
        return received
    }

    func test_statusLinePayload_reachesTheAppWithItsFiguresAndSurface() throws {
        let surfaceID = UUID().uuidString
        let delivered = try XCTUnwrap(postStatusLine([
            "payload": [
                "workspace": ["project_dir": "/tmp/atelier-hook-test"],
                "context_window": ["total_input_tokens": 45127, "context_window_size": 1_000_000],
            ],
            "surface_id": surfaceID,
        ]))

        XCTAssertEqual(delivered.projectDir, "/tmp/atelier-hook-test")
        XCTAssertEqual(delivered.surfaceID, surfaceID)
        XCTAssertEqual(delivered.reading, StatusLine.Reading(usedTokens: 45127, limitTokens: 1_000_000))
    }

    /// The status line runs on every assistant message, and `context_window` is
    /// absent until the session's first API response. Nothing to report is an
    /// ordinary state on this route, not a fault.
    func test_statusLinePayload_withoutAContextWindowIsDropped() throws {
        let delivered = try postStatusLine([
            "payload": ["workspace": ["project_dir": "/tmp/atelier-hook-test"]],
            "surface_id": "",
        ], expectDelivery: false)

        XCTAssertNil(delivered)
    }

    /// The hook route's envelope has `project_dir` at the top level; this one
    /// carries the launch directory inside Claude Code's own payload. Posting a
    /// hook envelope here must not be read as a status line.
    func test_statusLineRoute_ignoresAHookEnvelope() throws {
        let delivered = try postStatusLine([
            "event_input": ["hook_event_name": "Stop", "agent_id": "main"],
            "project_dir": "/tmp/atelier-hook-test",
            "surface_id": "",
        ], expectDelivery: false)

        XCTAssertNil(delivered)
    }
}
