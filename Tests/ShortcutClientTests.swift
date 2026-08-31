// ABOUTME: Tests ShortcutClient's request construction and response handling.
// ABOUTME: Uses a stubbed URLProtocol so no request leaves the machine.

@testable import Atelier
import XCTest

/// Intercepts every request made through a session configured with it, so tests can
/// assert on the outgoing request and choose the response.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        handler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ShortcutClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func client(token: String? = "test-token") -> ShortcutClient {
        let stored: String? = token
        return ShortcutClient(session: session, token: { stored })
    }

    private func respond(_ status: Int, _ body: String) {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
    }

    private let storyBody = """
    {
      "id": 17411,
      "name": "A story",
      "description": "body",
      "app_url": "https://app.shortcut.com/sixfifty/story/17411",
      "formatted_vcs_branch_name": "tadthorley/sc-17411/a-story",
      "workflow_state_id": 500000030
    }
    """

    func testStoryRequestHitsTheStoriesEndpoint() async throws {
        respond(200, storyBody)
        _ = try await client().story(id: 17411)
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.absoluteString,
            "https://api.app.shortcut.com/api/v3/stories/17411"
        )
    }

    func testStoryRequestSendsTokenHeader() async throws {
        respond(200, storyBody)
        _ = try await client(token: "secret-abc").story(id: 17411)
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Shortcut-Token"),
            "secret-abc"
        )
    }

    func testStoryDecodesSuccessfulResponse() async throws {
        respond(200, storyBody)
        let story = try await client().story(id: 17411)
        XCTAssertEqual(story.id, 17411)
        XCTAssertEqual(story.branchName, "tadthorley/sc-17411/a-story")
    }

    func testMissingTokenFailsWithoutMakingARequest() async {
        respond(200, storyBody)
        await assertThrows(.noToken) { _ = try await self.client(token: nil).story(id: 17411) }
        XCTAssertNil(StubURLProtocol.lastRequest, "must not call the API with no token")
    }

    func testUnauthorizedResponseMapsToUnauthorized() async {
        respond(401, "{}")
        await assertThrows(.unauthorized) { _ = try await self.client().story(id: 17411) }
    }

    func testNotFoundResponseMapsToNotFound() async {
        respond(404, "{}")
        await assertThrows(.notFound) { _ = try await self.client().story(id: 99999) }
    }

    func testMalformedBodyMapsToDecodingError() async {
        respond(200, "{\"unexpected\": true}")
        await assertThrows(.decoding) { _ = try await self.client().story(id: 17411) }
    }

    func testCurrentMemberHitsTheMemberEndpoint() async throws {
        respond(200, """
        {"name": "Tad Thorley", "mention_name": "tadthorley", "workspace2": {"name": "Sixfifty"}}
        """)
        let member = try await client().currentMember()
        XCTAssertEqual(member.workspaceName, "Sixfifty")
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.absoluteString,
            "https://api.app.shortcut.com/api/v3/member"
        )
    }

    func testWorkflowsHitsTheWorkflowsEndpoint() async throws {
        respond(200, """
        [{"id": 1, "name": "Engineering", "states": [{"id": 5, "name": "In Progress", "type": "started"}]}]
        """)
        let workflows = try await client().workflows()
        XCTAssertEqual(workflows.stateName(for: 5), "In Progress")
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.absoluteString,
            "https://api.app.shortcut.com/api/v3/workflows"
        )
    }

    private func assertThrows(
        _ expected: ShortcutError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) but the call succeeded", file: file, line: line)
        } catch let error as ShortcutError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected) but got \(error)", file: file, line: line)
        }
    }
}
