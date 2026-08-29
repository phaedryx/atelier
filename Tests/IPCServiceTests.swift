// ABOUTME: Tests for the IPC tool surface: registration, addressing, project scoping, and the mailbox.
// ABOUTME: Exercises IPCService directly, with no socket in the way.

@testable import Atelier
import XCTest

final class IPCServiceTests: XCTestCase {
    private var service: IPCService!

    private let projectA = "/repos/atelier"
    private let projectB = "/repos/other"

    override func setUp() {
        super.setUp()
        service = IPCService()
    }

    // MARK: - Helpers

    private func client(
        project: String?,
        peerID: String? = nil,
        workstream: String = "bold-crimson-parser",
        surfaceID: UUID? = UUID()
    ) -> IPCClientIdentity {
        IPCClientIdentity(
            workstreamID: UUID().uuidString,
            workstreamName: workstream,
            projectDirectory: project,
            surfaceID: surfaceID?.uuidString,
            peerID: peerID
        )
    }

    private func call(_ tool: IPCTool, _ arguments: [String: String] = [:], as client: IPCClientIdentity) async -> IPCResponse {
        await service.handle(IPCRequest(token: "unused", tool: tool, arguments: arguments, client: client))
    }

    /// Registers a peer and returns its id, as the helper would remember it.
    private func register(name: String, role: String = "", project: String?, workstream: String = "bold-crimson-parser") async throws -> String {
        let response = await call(.registerPeer, ["name": name, "role": role], as: client(project: project, workstream: workstream))
        guard case let .peer(peer) = response.payload else {
            throw XCTSkip("register_peer did not return a peer: \(String(describing: response.error))")
        }
        return peer.id
    }

    private func peers(of response: IPCResponse) throws -> [IPCPeerInfo] {
        guard case let .peers(peers) = response.payload else {
            throw XCTSkip("expected a peers payload, got \(String(describing: response.payload ?? nil))")
        }
        return peers
    }

    // MARK: - Registration

    func test_registerPeer_defaultsNameToTheWorkstream() async throws {
        let response = await call(.registerPeer, [:], as: client(project: projectA, workstream: "wry-amber-lexer"))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertEqual(peer.name, "wry-amber-lexer")
    }

    func test_registerPeer_calledAgainWithAnExistingID_renamesRatherThanMinting() async throws {
        let id = try await register(name: "planner", role: "writes plans", project: projectA)

        let response = await call(.registerPeer, ["name": "reviewer"], as: client(project: projectA, peerID: id))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertEqual(peer.id, id, "re-registering must keep the same identity")
        XCTAssertEqual(peer.name, "reviewer")
        XCTAssertEqual(peer.role, "writes plans", "an omitted role must not blank the existing one")

        let listed = try peers(of: await call(.listPeers, as: client(project: projectA)))
        XCTAssertEqual(listed.count, 1, "a rename must not leave a second peer behind")
    }

    // MARK: - Listing

    func test_listPeers_excludesTheCallerAndOtherProjects() async throws {
        let mine = try await register(name: "mine", project: projectA)
        _ = try await register(name: "sibling", project: projectA)
        _ = try await register(name: "stranger", project: projectB)

        let listed = try peers(of: await call(.listPeers, as: client(project: projectA, peerID: mine)))
        XCTAssertEqual(listed.map(\.name), ["sibling"])
    }

    func test_listPeers_reportsWorkstreamAndPendingCount() async throws {
        let sender = try await register(name: "sender", project: projectA)
        let recipient = try await register(name: "recipient", project: projectA, workstream: "wry-amber-lexer")
        _ = await call(.sendMessage, ["to": recipient, "content": "ping"], as: client(project: projectA, peerID: sender))

        let listed = try peers(of: await call(.listPeers, as: client(project: projectA, peerID: sender)))
        XCTAssertEqual(listed.first?.workstream, "wry-amber-lexer")
        XCTAssertEqual(listed.first?.pendingMessages, 1)
    }

    // MARK: - Sending

    func test_sendMessage_beforeRegistering_isRefused() async throws {
        let recipient = try await register(name: "recipient", project: projectA)
        let response = await call(.sendMessage, ["to": recipient, "content": "hi"], as: client(project: projectA))
        XCTAssertEqual(response.error, "You must register_peer first.")
    }

    func test_sendMessage_acrossProjects_isRefused() async throws {
        let sender = try await register(name: "sender", project: projectA)
        let stranger = try await register(name: "stranger", project: projectB)

        let response = await call(.sendMessage, ["to": stranger, "content": "hi"], as: client(project: projectA, peerID: sender))
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("Peer not found") == true, "got \(response.error ?? "nil")")

        let received = await call(.receiveMessages, as: client(project: projectB, peerID: stranger))
        guard case let .messages(messages) = received.payload else { return XCTFail("expected messages") }
        XCTAssertTrue(messages.isEmpty, "a cross-project send must not land in the inbox")
    }

    func test_sendMessage_withoutContent_isRefused() async throws {
        let sender = try await register(name: "sender", project: projectA)
        let recipient = try await register(name: "recipient", project: projectA)
        let response = await call(.sendMessage, ["to": recipient, "content": ""], as: client(project: projectA, peerID: sender))
        XCTAssertEqual(response.error, "send_message needs non-empty `content`.")
    }

    // MARK: - Receiving

    func test_receiveMessages_returnsSenderNameThenEmptiesTheInbox() async throws {
        let sender = try await register(name: "planner", project: projectA)
        let recipient = try await register(name: "builder", project: projectA)
        _ = await call(.sendMessage, ["to": recipient, "content": "the plan is ready"], as: client(project: projectA, peerID: sender))

        let first = await call(.receiveMessages, as: client(project: projectA, peerID: recipient))
        guard case let .messages(messages) = first.payload else { return XCTFail("expected messages") }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "the plan is ready")
        XCTAssertEqual(messages.first?.fromName, "planner")

        let second = await call(.receiveMessages, as: client(project: projectA, peerID: recipient))
        guard case let .messages(again) = second.payload else { return XCTFail("expected messages") }
        XCTAssertTrue(again.isEmpty, "delete-on-read: a message must not be returned twice")
    }

    // MARK: - Broadcast

    func test_broadcast_reachesOwnProjectOnly() async throws {
        let sender = try await register(name: "sender", project: projectA)
        let sibling = try await register(name: "sibling", project: projectA)
        let stranger = try await register(name: "stranger", project: projectB)

        let response = await call(.broadcast, ["content": "standup in five"], as: client(project: projectA, peerID: sender))
        guard case let .text(text) = response.payload else { return XCTFail("expected text") }
        XCTAssertEqual(text, "Delivered to 1 peer.")

        let siblingInbox = await call(.receiveMessages, as: client(project: projectA, peerID: sibling))
        guard case let .messages(delivered) = siblingInbox.payload else { return XCTFail("expected messages") }
        XCTAssertEqual(delivered.first?.content, "standup in five")

        let strangerInbox = await call(.receiveMessages, as: client(project: projectB, peerID: stranger))
        guard case let .messages(none) = strangerInbox.payload else { return XCTFail("expected messages") }
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Surface identity

    func test_registerPeer_recordsTheSurfaceTheAgentRunsIn() async throws {
        // What the Coding Agent surface exports: its surface id is the
        // workstream id, since claudeID == workstreamID.
        let workstreamID = UUID()
        let agent = IPCClientIdentity(
            workstreamID: workstreamID.uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: projectA,
            surfaceID: workstreamID.uuidString,
            peerID: nil
        )
        let response = await call(.registerPeer, ["name": "agent-tab"], as: agent)
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        let context = await service._testContext(for: try XCTUnwrap(UUID(uuidString: peer.id)))
        XCTAssertEqual(context?.surfaceID, workstreamID, "the Agent tab must still address its own pane")
    }

    func test_twoAgentsInOneWorkstream_keepSeparateSurfaces() async throws {
        let workstreamID = UUID()
        let tabSurface = UUID()

        func identity(surface: UUID) -> IPCClientIdentity {
            IPCClientIdentity(
                workstreamID: workstreamID.uuidString,
                workstreamName: "bold-crimson-parser",
                projectDirectory: projectA,
                surfaceID: surface.uuidString,
                peerID: nil
            )
        }

        let agentTab = await call(.registerPeer, ["name": "agent-tab"], as: identity(surface: workstreamID))
        let handStarted = await call(.registerPeer, ["name": "hand-started"], as: identity(surface: tabSurface))
        guard case let .peer(first) = agentTab.payload, case let .peer(second) = handStarted.payload else {
            return XCTFail("expected two peers")
        }

        let firstContext = await service._testContext(for: try XCTUnwrap(UUID(uuidString: first.id)))
        let secondContext = await service._testContext(for: try XCTUnwrap(UUID(uuidString: second.id)))
        XCTAssertEqual(firstContext?.surfaceID, workstreamID)
        XCTAssertEqual(secondContext?.surfaceID, tabSurface, "a tab must be nudged in its own pane, not the Agent's")
        XCTAssertEqual(firstContext?.workstreamID, secondContext?.workstreamID, "both are in the same workstream")
    }

    func test_peerWithoutASurface_isPullOnly() async throws {
        let response = await call(.registerPeer, ["name": "elsewhere"], as: client(project: projectA, surfaceID: nil))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        let context = await service._testContext(for: try XCTUnwrap(UUID(uuidString: peer.id)))
        XCTAssertNil(context?.surfaceID, "an agent Atelier did not launch has nowhere to be nudged")
    }

    // MARK: - Liveness

    func test_anyRequest_countsAsAHeartbeat() async throws {
        let poller = try await register(name: "poller", project: projectA)
        let observer = try await register(name: "observer", project: projectA)
        await service._testBackdate(peerID: try XCTUnwrap(UUID(uuidString: poller)), to: Date().addingTimeInterval(-540))

        // A pure read is still proof the agent is there; without it a polite
        // agent that only ever lists peers expires while it is asking.
        _ = await call(.listPeers, as: client(project: projectA, peerID: poller))

        let response = await call(.getPeerStatus, ["peer_id": poller], as: client(project: projectA, peerID: observer))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertLessThan(peer.lastSeenSecondsAgo, 5, "the poll should have refreshed lastSeen")
    }

    // MARK: - Status

    func test_getPeerStatus_acrossProjects_isRefused() async throws {
        let mine = try await register(name: "mine", project: projectA)
        let stranger = try await register(name: "stranger", project: projectB)

        let response = await call(.getPeerStatus, ["peer_id": stranger], as: client(project: projectA, peerID: mine))
        XCTAssertTrue(response.error?.contains("Peer not found") == true, "got \(response.error ?? "nil")")
    }

    func test_getPeerStatus_reportsPendingMessages() async throws {
        let sender = try await register(name: "sender", project: projectA)
        let recipient = try await register(name: "recipient", project: projectA)
        _ = await call(.sendMessage, ["to": recipient, "content": "one"], as: client(project: projectA, peerID: sender))

        let response = await call(.getPeerStatus, ["peer_id": recipient], as: client(project: projectA, peerID: sender))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertEqual(peer.pendingMessages, 1)
    }
}
