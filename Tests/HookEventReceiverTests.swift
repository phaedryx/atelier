// ABOUTME: Tests that hook events reach the app carrying the surface they came from.
// ABOUTME: Drives the real HTTP listener, since the envelope parsing is what's under test.

@testable import Atelier
import Darwin
import XCTest

final class HookEventReceiverTests: XCTestCase {
    private var receiver: HookEventReceiver { HookEventReceiver.shared }

    override func tearDown() {
        receiver.onEvent = nil
        super.tearDown()
    }

    /// POSTs one hook envelope over a raw socket — the same shape `atelier-hook`
    /// sends with curl — and returns the events the receiver produced.
    private func post(_ envelope: [String: Any], timeout: TimeInterval = 10) throws -> [AgentEvent] {
        receiver.start()

        // Ask the listener for its port rather than reading hook-port: the file
        // may still hold the number a previous run of the app wrote.
        let deadline = Date().addingTimeInterval(timeout)
        var port: UInt16?
        while Date() < deadline, port == nil {
            port = receiver.boundPort
            if port == nil { usleep(20_000) }
        }
        let resolved = try XCTUnwrap(port, "hook receiver did not bind a port")

        var received: [AgentEvent] = []
        let delivered = expectation(description: "hook event routed")
        delivered.assertForOverFulfill = false
        receiver.onEvent = { _, event in
            received.append(event)
            delivered.fulfill()
        }

        let body = try JSONSerialization.data(withJSONObject: envelope)
        let head = "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        var request = Data(head.utf8)
        request.append(body)

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
        _ = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, request.count, 0) }

        wait(for: [delivered], timeout: timeout)
        return received
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
}
