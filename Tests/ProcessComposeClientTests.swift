// ABOUTME: Tests for decoding process-compose API responses.
// ABOUTME: The transport is exercised separately against a real binary.

@testable import Atelier
import XCTest

final class ProcessComposeClientTests: XCTestCase {
    /// Captured verbatim from a running process-compose, trimmed to the fields
    /// Atelier reads. Unknown fields must not break decoding — the API adds them.
    private let sample = """
    {"data":[
      {"name":"worker","namespace":"execute","status":"Running","system_time":"3s",
       "age":3991085375,"is_ready":"-","has_ready_probe":false,"restarts":0,
       "exit_code":0,"pid":27659,"is_elevated":false,"mem":2113536,"cpu":0,
       "is_running":true},
      {"name":"web","namespace":"execute","status":"Completed","is_ready":"y",
       "has_ready_probe":true,"restarts":2,"exit_code":1,"pid":0,"is_running":false}
    ]}
    """.data(using: .utf8)!

    func testDecodesProcesses() throws {
        let processes = try ProcessComposeClient.decodeProcesses(sample)

        XCTAssertEqual(processes.count, 2)
        let worker = try XCTUnwrap(processes.first { $0.name == "worker" })
        XCTAssertEqual(worker.namespace, "execute")
        XCTAssertEqual(worker.status, "Running")
        XCTAssertEqual(worker.pid, 27659)
        XCTAssertTrue(worker.isRunning)
        XCTAssertFalse(worker.hasReadyProbe)
    }

    func testDecodesReadinessAndExitCode() throws {
        let processes = try ProcessComposeClient.decodeProcesses(sample)

        let web = try XCTUnwrap(processes.first { $0.name == "web" })
        XCTAssertTrue(web.hasReadyProbe)
        XCTAssertEqual(web.isReady, "y")
        XCTAssertEqual(web.restarts, 2)
        XCTAssertEqual(web.exitCode, 1)
        XCTAssertFalse(web.isRunning)
    }

    func testUnknownFieldsAreIgnored() throws {
        let withExtra = """
        {"data":[{"name":"a","namespace":"execute","status":"Running","is_ready":"-",
        "has_ready_probe":false,"restarts":0,"exit_code":0,"pid":1,"is_running":true,
        "some_future_field":{"nested":true}}]}
        """.data(using: .utf8)!

        XCTAssertEqual(try ProcessComposeClient.decodeProcesses(withExtra).count, 1)
    }

    func testEmptyDataDecodesToNoProcesses() throws {
        XCTAssertTrue(try ProcessComposeClient.decodeProcesses(XCTUnwrap(#"{"data":[]}"#.data(using: .utf8))).isEmpty)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try ProcessComposeClient.decodeProcesses(Data("not json".utf8)))
    }
}
