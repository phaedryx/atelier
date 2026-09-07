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
        super.tearDown()
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
    private func sendEnvelope(_ envelope: [String: Any], timeout: TimeInterval) throws -> Int32 {
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
        let head = "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
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
}
