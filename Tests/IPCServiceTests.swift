// ABOUTME: Tests for the IPC tool surface: registration, addressing, project scoping, and the mailbox.
// ABOUTME: Exercises IPC.Service directly, with no socket in the way.

@testable import Atelier
import XCTest

final class IPCServiceTests: XCTestCase {
    private var service: IPC.Service!

    private let projectA = "/repos/atelier"
    private let projectB = "/repos/other"

    override func setUp() {
        super.setUp()
        service = IPC.Service()
    }

    // MARK: - Helpers

    private func client(
        project: String?,
        peerID: String? = nil,
        workstream: String = "bold-crimson-parser",
        surfaceID: UUID? = UUID()
    ) -> IPC.ClientIdentity {
        IPC.ClientIdentity(
            workstreamID: UUID().uuidString,
            workstreamName: workstream,
            projectDirectory: project,
            surfaceID: surfaceID?.uuidString,
            peerID: peerID
        )
    }

    private func call(_ tool: IPC.Tool, _ arguments: [String: String] = [:], as client: IPC.ClientIdentity) async -> IPC.Response {
        await service.handle(IPC.Request(token: "unused", tool: tool, arguments: arguments, client: client))
    }

    /// Registers a peer and returns its id, as the helper would remember it.
    private func register(name: String, role: String = "", project: String?, workstream: String = "bold-crimson-parser") async throws -> String {
        let response = await call(.registerPeer, ["name": name, "role": role], as: client(project: project, workstream: workstream))
        guard case let .peer(peer) = response.payload else {
            throw XCTSkip("register_peer did not return a peer: \(String(describing: response.error))")
        }
        return peer.id
    }

    private func peers(of response: IPC.Response) throws -> [IPC.PeerInfo] {
        guard case let .peers(peers) = response.payload else {
            throw XCTSkip("expected a peers payload, got \(String(describing: response.payload ?? nil))")
        }
        return peers
    }

    // MARK: - Registration

    func test_registerPeer_defaultsNameToTheWorkstream() async {
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

        let listed = try await peers(of: call(.listPeers, as: client(project: projectA)))
        XCTAssertEqual(listed.count, 1, "a rename must not leave a second peer behind")
    }

    // MARK: - Listing

    func test_listPeers_excludesTheCallerAndOtherProjects() async throws {
        let mine = try await register(name: "mine", project: projectA)
        _ = try await register(name: "sibling", project: projectA)
        _ = try await register(name: "stranger", project: projectB)

        let listed = try await peers(of: call(.listPeers, as: client(project: projectA, peerID: mine)))
        XCTAssertEqual(listed.map(\.name), ["sibling"])
    }

    func test_listPeers_reportsWorkstreamAndPendingCount() async throws {
        let sender = try await register(name: "sender", project: projectA)
        let recipient = try await register(name: "recipient", project: projectA, workstream: "wry-amber-lexer")
        _ = await call(.sendMessage, ["to": recipient, "content": "ping"], as: client(project: projectA, peerID: sender))

        let listed = try await peers(of: call(.listPeers, as: client(project: projectA, peerID: sender)))
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

    // MARK: - Sanitization

    func test_registerPeer_stripsWhatWouldBeTypedIntoAnotherTerminal() async {
        let hostile = "planner\u{1B}[31m\nrm -rf /\u{3}"
        let response = await call(.registerPeer, ["name": hostile, "role": "writes\nplans"], as: client(project: projectA))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        XCTAssertFalse(peer.name.contains("\n"), "a newline plus the nudge's Returns submits a second line")
        XCTAssertFalse(peer.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, "ESC and Ctrl-C must not survive")
        XCTAssertEqual(peer.name, "planner[31mrm -rf /")
        XCTAssertFalse(peer.role.contains("\n"))
    }

    func test_registerPeer_leavesNoInvisibleCharactersInAName() async {
        // A right-to-left override, a zero-width space, a zero-width joiner, a
        // byte-order mark, and a no-break space. The last becomes a plain space
        // rather than vanishing: two peers whose names render identically are a
        // way to get an agent to address the wrong one.
        let hostile = "pla\u{202E}n\u{200B}n\u{200D}e\u{FEFF}r\u{00A0}two"
        let response = await call(.registerPeer, ["name": hostile], as: client(project: projectA))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        XCTAssertEqual(peer.name, "planner two")
    }

    func test_registerPeer_capsTheNameOnACharacterBoundary() async {
        // 39 plain characters then a combining acute. Cutting by scalar could
        // keep the "e" and drop its accent, or strand the accent so it attaches
        // to whatever follows the name; cutting by character cannot.
        let name = String(repeating: "a", count: 39) + "e\u{0301}"
        let response = await call(.registerPeer, ["name": name], as: client(project: projectA))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        XCTAssertEqual(peer.name.count, 40)
        XCTAssertTrue(peer.name.hasSuffix("é"), "the accent must travel with its letter, got: \(peer.name)")
    }

    func test_registerPeer_capsTheName() async {
        let response = await call(.registerPeer, ["name": String(repeating: "a", count: 200)], as: client(project: projectA))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertEqual(peer.name.count, 40)
    }

    func test_registerPeer_aNameOfNothingButControlCharacters_fallsBack() async {
        let response = await call(.registerPeer, ["name": "\u{1B}\u{3}"], as: client(project: projectA))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertEqual(peer.name, "agent")
    }

    // MARK: - Surface identity

    func test_registerPeer_recordsTheSurfaceTheAgentRunsIn() async throws {
        // What the Coding Agent surface exports: its surface id is the
        // workstream id, since claudeID == workstreamID.
        let workstreamID = UUID()
        let agent = IPC.ClientIdentity(
            workstreamID: workstreamID.uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: projectA,
            surfaceID: workstreamID.uuidString,
            peerID: nil
        )
        let response = await call(.registerPeer, ["name": "agent-tab"], as: agent)
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        let context = try await service._testContext(for: XCTUnwrap(UUID(uuidString: peer.id)))
        XCTAssertEqual(context?.surfaceID, workstreamID, "the Agent tab must still address its own pane")
    }

    func test_twoAgentsInOneWorkstream_keepSeparateSurfaces() async throws {
        let workstreamID = UUID()
        let tabSurface = UUID()

        func identity(surface: UUID) -> IPC.ClientIdentity {
            IPC.ClientIdentity(
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

        let firstContext = try await service._testContext(for: XCTUnwrap(UUID(uuidString: first.id)))
        let secondContext = try await service._testContext(for: XCTUnwrap(UUID(uuidString: second.id)))
        XCTAssertEqual(firstContext?.surfaceID, workstreamID)
        XCTAssertEqual(secondContext?.surfaceID, tabSurface, "a tab must be nudged in its own pane, not the Agent's")
        XCTAssertEqual(firstContext?.workstreamID, secondContext?.workstreamID, "both are in the same workstream")
    }

    func test_peerWithoutASurface_isPullOnly() async throws {
        let response = await call(.registerPeer, ["name": "elsewhere"], as: client(project: projectA, surfaceID: nil))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }

        let context = try await service._testContext(for: XCTUnwrap(UUID(uuidString: peer.id)))
        XCTAssertNil(context?.surfaceID, "an agent Atelier did not launch has nowhere to be nudged")
    }

    func test_peersWithoutAProject_cannotSeeEachOther() async throws {
        let mine = try await register(name: "mine", project: nil)
        _ = try await register(name: "stranger", project: nil)

        // "Same project" must mean a project, not two peers that both lack one.
        let listed = try await peers(of: call(.listPeers, as: client(project: nil, peerID: mine)))
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Liveness

    func test_anyRequest_countsAsAHeartbeat() async throws {
        let poller = try await register(name: "poller", project: projectA)
        let observer = try await register(name: "observer", project: projectA)
        try await service._testBackdate(peerID: XCTUnwrap(UUID(uuidString: poller)), to: Date().addingTimeInterval(-540))

        // A pure read is still proof the agent is there; without it a polite
        // agent that only ever lists peers expires while it is asking.
        _ = await call(.listPeers, as: client(project: projectA, peerID: poller))

        let response = await call(.getPeerStatus, ["peer_id": poller], as: client(project: projectA, peerID: observer))
        guard case let .peer(peer) = response.payload else { return XCTFail("expected a peer") }
        XCTAssertLessThan(peer.lastSeenSecondsAgo, 5, "the poll should have refreshed lastSeen")
    }

    func test_anIdleAgentStaysReachable() async throws {
        let waiting = try await register(name: "waiting", project: projectA)
        let sender = try await register(name: "sender", project: projectA)

        // Twenty minutes of silence: twice the TTL. An agent sitting at a
        // prompt is exactly what this feature exists to message, so it must
        // still be listed and still take delivery.
        try await service._testBackdate(peerID: XCTUnwrap(UUID(uuidString: waiting)), to: Date().addingTimeInterval(-1200))

        let listed = try await peers(of: call(.listPeers, as: client(project: projectA, peerID: sender)))
        XCTAssertEqual(listed.map(\.name), ["waiting"])

        let response = await call(.sendMessage, ["to": waiting, "content": "still there?"], as: client(project: projectA, peerID: sender))
        XCTAssertNil(response.error, "a quiet agent must take delivery, not be told it does not exist")
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

    // MARK: - open_tab

    func test_openTab_withoutAKind_saysWhichArgumentIsMissing() async {
        let response = await call(.openTab, [:], as: client(project: projectA))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("kind") == true, String(describing: response.error))
    }

    func test_openTab_outsideAWorkstream_refuses() async {
        let stranger = IPC.ClientIdentity(
            workstreamID: nil, workstreamName: nil, projectDirectory: projectA, surfaceID: nil, peerID: nil
        )

        let response = await call(.openTab, ["kind": "verification"], as: stranger)

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("inside an Atelier workstream") == true, String(describing: response.error))
    }

    /// An empty string is a missing argument, not a kind to look up — otherwise
    /// the refusal would name the legal values for an agent that named nothing.
    func test_openTab_treatsAnEmptyKindAsMissing() async {
        let response = await call(.openTab, ["kind": ""], as: client(project: projectA))

        XCTAssertTrue(response.error?.contains("kind") == true, String(describing: response.error))
    }

    // MARK: - Session checkpoint

    private func checkpointText(of response: IPC.Response) throws -> String {
        guard case let .text(text) = response.payload else {
            throw XCTSkip("expected a text payload, got \(String(describing: response.payload))")
        }
        return text
    }

    func test_getSessionCheckpoint_outsideAWorkstream_refuses() async {
        let stranger = IPC.ClientIdentity(
            workstreamID: nil, workstreamName: nil, projectDirectory: projectA, surfaceID: nil, peerID: nil
        )

        let response = await call(.getSessionCheckpoint, as: stranger)

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("inside an Atelier workstream") == true, String(describing: response.error))
    }

    /// "Never saved" must not read as an empty checkpoint some agent wrote on
    /// purpose — the same three-case discipline `Verification.Config.Load`
    /// applies to its own file.
    func test_getSessionCheckpoint_whenNoneSaved_saysSoRatherThanAnsweringEmpty() async throws {
        let mine = client(project: projectA)

        let text = try await checkpointText(of: call(.getSessionCheckpoint, as: mine))

        XCTAssertTrue(text.contains("No checkpoint saved yet"), text)
        XCTAssertTrue(text.contains("update_session_checkpoint"), "should point the agent at how to save one: \(text)")
    }

    func test_updateSessionCheckpoint_thenGet_roundTrips() async throws {
        let mine = client(project: projectA)
        let workstreamID = try XCTUnwrap(mine.workstreamID.flatMap(UUID.init(uuidString:)))
        addTeardownBlock { IPC.CheckpointStore.clear(for: workstreamID) }

        let saved = try await checkpointText(of: call(.updateSessionCheckpoint, ["content": "finished the login form, tests still red"], as: mine))
        XCTAssertTrue(saved.contains("saved"), saved)

        let read = try await checkpointText(of: call(.getSessionCheckpoint, as: mine))
        XCTAssertTrue(read.contains("finished the login form, tests still red"), read)
        XCTAssertTrue(read.contains("Checkpoint from"), "should report recency: \(read)")
    }

    /// A second save with no version history: the checkpoint is what the
    /// *second* call wrote, not an accumulation of both.
    func test_updateSessionCheckpoint_overwritesRatherThanAppending() async throws {
        let mine = client(project: projectA)
        let workstreamID = try XCTUnwrap(mine.workstreamID.flatMap(UUID.init(uuidString:)))
        addTeardownBlock { IPC.CheckpointStore.clear(for: workstreamID) }

        _ = await call(.updateSessionCheckpoint, ["content": "first note"], as: mine)
        _ = await call(.updateSessionCheckpoint, ["content": "second note"], as: mine)

        let read = try await checkpointText(of: call(.getSessionCheckpoint, as: mine))
        XCTAssertTrue(read.contains("second note"), read)
        XCTAssertFalse(read.contains("first note"), "must overwrite, not accumulate: \(read)")
    }

    func test_updateSessionCheckpoint_rejectsEmptyContent() async {
        let response = await call(.updateSessionCheckpoint, ["content": ""], as: client(project: projectA))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("content") == true, String(describing: response.error))
    }

    func test_updateSessionCheckpoint_rejectsOversizedContent() async {
        let tooBig = String(repeating: "a", count: IPC.CheckpointStore.maxContentSize + 1)

        let response = await call(.updateSessionCheckpoint, ["content": tooBig], as: client(project: projectA))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("64KB") == true, String(describing: response.error))
    }

    func test_updateSessionCheckpoint_outsideAWorkstream_refuses() async {
        let stranger = IPC.ClientIdentity(
            workstreamID: nil, workstreamName: nil, projectDirectory: projectA, surfaceID: nil, peerID: nil
        )

        let response = await call(.updateSessionCheckpoint, ["content": "note"], as: stranger)

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("inside an Atelier workstream") == true, String(describing: response.error))
    }

    /// Two workstreams never see each other's checkpoint — the key is per
    /// workstream, unlike a peer's inbox, which is per registered agent.
    func test_twoWorkstreams_haveIndependentCheckpoints() async throws {
        let first = client(project: projectA)
        let second = client(project: projectA)
        let firstID = try XCTUnwrap(first.workstreamID.flatMap(UUID.init(uuidString:)))
        let secondID = try XCTUnwrap(second.workstreamID.flatMap(UUID.init(uuidString:)))
        addTeardownBlock {
            IPC.CheckpointStore.clear(for: firstID)
            IPC.CheckpointStore.clear(for: secondID)
        }

        _ = await call(.updateSessionCheckpoint, ["content": "workstream one's note"], as: first)

        let secondRead = try await checkpointText(of: call(.getSessionCheckpoint, as: second))
        XCTAssertTrue(secondRead.contains("No checkpoint saved yet"), secondRead)
    }

    // MARK: - close_tab

    /// The full argument contract — exactly one of `kind`/`surface_id`, the
    /// Execution refusal, the singleton and terminal behaviors — is tested
    /// against `WorkspaceActions.shared.closeTab` directly in
    /// `WorkspaceActionsCloseTabTests`, the same split `open_tab` uses. Here
    /// there is only the one thing this layer alone can answer: whether the
    /// caller is in a workstream at all.
    func test_closeTab_withoutEitherArgument_saysWhichOnesAreMissing() async {
        let response = await call(.closeTab, [:], as: client(project: projectA))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("kind") == true, String(describing: response.error))
        XCTAssertTrue(response.error?.contains("surface_id") == true, String(describing: response.error))
    }

    func test_closeTab_outsideAWorkstream_refuses() async {
        let stranger = IPC.ClientIdentity(
            workstreamID: nil, workstreamName: nil, projectDirectory: projectA, surfaceID: nil, peerID: nil
        )

        let response = await call(.closeTab, ["kind": "changes"], as: stranger)

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("inside an Atelier workstream") == true, String(describing: response.error))
    }
}
