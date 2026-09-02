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

    func testBodyThrowsWhenNoHeaderBodySeparator() {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2".utf8)

        XCTAssertThrowsError(try ProcessComposeClient.body(of: response)) { error in
            XCTAssertEqual(error as? ProcessComposeClient.ClientError, .malformedResponse)
        }
    }

    func testBodyThrowsOnUnparseableStatusLine() {
        let response = Data("not a status line\r\n\r\n{}".utf8)

        XCTAssertThrowsError(try ProcessComposeClient.body(of: response)) { error in
            XCTAssertEqual(error as? ProcessComposeClient.ClientError, .malformedResponse)
        }
    }

    func testBodyThrowsHTTPErrorOnNon2xxStatus() {
        let response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)

        XCTAssertThrowsError(try ProcessComposeClient.body(of: response)) { error in
            XCTAssertEqual(error as? ProcessComposeClient.ClientError, .http(404))
        }
    }

    func testBodyReturnsBodyOn200() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"data\":[]}\n".utf8)

        let body = try ProcessComposeClient.body(of: response)

        XCTAssertEqual(body, Data("{\"data\":[]}\n".utf8))
    }

    func testBodyReturnsEmptyBodyOn200WithNoContent() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)

        let body = try ProcessComposeClient.body(of: response)

        XCTAssertTrue(body.isEmpty)
    }

    // MARK: - Chunked transfer encoding

    /// One process record, close enough in size to a real one that the count
    /// below reproduces the real threshold.
    private func record(_ name: String) -> String {
        """
        {"name":"\(name)","namespace":"execute","status":"Running","system_time":"2s",\
        "age":2646373791,"is_ready":"-","has_ready_probe":false,"restarts":0,\
        "exit_code":0,"pid":3655,"is_elevated":false,"password_provided":false,\
        "mem":2080768,"cpu":0,"is_running":true,\
        "process_start_time":"2026-09-02T06:02:54.383581-06:00",\
        "process_ready_time":"2026-09-02T06:02:54.383581-06:00"}
        """
    }

    private func chunkedResponse(_ payload: String, chunkSize: Int = 4096) -> Data {
        var response = Data("""
        HTTP/1.1 200 OK\r
        Content-Type: application/json; charset=utf-8\r
        Connection: close\r
        Transfer-Encoding: chunked\r
        \r

        """.utf8)
        let bytes = Array(payload.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let slice = Array(bytes[offset ..< end])
            response.append(Data(String(format: "%x\r\n", slice.count).utf8))
            response.append(contentsOf: slice)
            response.append(Data("\r\n".utf8))
            offset = end
        }
        response.append(Data("0\r\n\r\n".utf8))
        return response
    }

    /// The regression test for the bug every prior review round missed.
    ///
    /// Six processes is where Go's ~2 KB buffer gives up on `Content-Length`
    /// and switches to chunked, so this is an ordinary stack. The old
    /// `body(of:)` returned the framing bytes verbatim and this decode threw
    /// `.malformedResponse`.
    func testAChunkedSixProcessListingDecodes() throws {
        let payload = "{\"data\":[" + (0 ..< 6).map { record("svc\($0)") }.joined(separator: ",") + "]}"
        XCTAssertGreaterThan(payload.utf8.count, 2048, "must exceed Go's buffer or it would not chunk")

        let body = try ProcessComposeClient.body(of: chunkedResponse(payload))
        let processes = try ProcessComposeClient.decodeProcesses(body)

        XCTAssertEqual(processes.count, 6)
        XCTAssertEqual(processes.map(\.name).sorted(), (0 ..< 6).map { "svc\($0)" }.sorted())
    }

    /// A payload split across many chunks, which is what a real server does
    /// once the body outgrows one write.
    func testABodySpanningManyChunksIsReassembledInOrder() throws {
        let payload = "{\"data\":[" + (0 ..< 20).map { record("svc\($0)") }.joined(separator: ",") + "]}"

        let body = try ProcessComposeClient.body(of: chunkedResponse(payload, chunkSize: 64))
        let processes = try ProcessComposeClient.decodeProcesses(body)

        XCTAssertEqual(processes.count, 20)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), payload)
    }

    func testAnIdentityBodyIsReturnedUnchanged() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{\"data\":[]}".utf8)

        let body = try ProcessComposeClient.body(of: response)

        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{\"data\":[]}")
    }

    func testAChunkSizeExtensionIsIgnored() throws {
        var response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        response.append(Data("5;name=value\r\nhello\r\n0\r\n\r\n".utf8))

        let body = try ProcessComposeClient.body(of: response)

        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
    }

    func testChunkedIsDetectedInAHeaderValueList() throws {
        var response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8)
        response.append(Data("2\r\nhi\r\n0\r\n\r\n".utf8))

        XCTAssertEqual(try String(decoding: ProcessComposeClient.body(of: response), as: UTF8.self), "hi")
    }

    func testAChunkSizeLargerThanThePayloadIsMalformed() {
        var response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        response.append(Data("ff\r\nshort\r\n0\r\n\r\n".utf8))

        XCTAssertThrowsError(try ProcessComposeClient.body(of: response)) { error in
            XCTAssertEqual(error as? ProcessComposeClient.ClientError, .malformedResponse)
        }
    }

    func testANonHexChunkSizeIsMalformed() {
        var response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        response.append(Data("zz\r\npayload\r\n0\r\n\r\n".utf8))

        XCTAssertThrowsError(try ProcessComposeClient.body(of: response)) { error in
            XCTAssertEqual(error as? ProcessComposeClient.ClientError, .malformedResponse)
        }
    }

    /// `isChunked` must not fire on a header that merely mentions the word,
    /// or every identity response would be run through the de-chunker.
    func testIsChunkedIgnoresUnrelatedHeaders() {
        XCTAssertFalse(ProcessComposeClient.isChunked("HTTP/1.1 200 OK\r\nX-Note: chunked is off"))
        XCTAssertFalse(ProcessComposeClient.isChunked("HTTP/1.1 200 OK\r\nContent-Length: 3"))
        XCTAssertTrue(ProcessComposeClient.isChunked("HTTP/1.1 200 OK\r\ntransfer-encoding:  CHUNKED "))
    }
}
