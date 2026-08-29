// ABOUTME: Tests the policy that decides whether a message may interrupt an agent's terminal.
// ABOUTME: The injection itself needs a live Ghostty surface and is not covered here.

@testable import Atelier
import XCTest

@MainActor
final class AgentNudgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func shouldNudge(
        state: WorkstreamAgentStateTracker.AgentRunState,
        hasSurface: Bool = true,
        nudgeEnabled: Bool = true,
        lastNudge: Date? = nil
    ) -> Bool {
        AgentNudge.shouldNudge(
            state: state,
            hasSurface: hasSurface,
            nudgeEnabled: nudgeEnabled,
            lastNudge: lastNudge,
            now: now
        )
    }

    func test_nudges_whenTheTurnHasEnded() {
        XCTAssertTrue(shouldNudge(state: .idle))
        XCTAssertTrue(shouldNudge(state: .needsAttention(.justFinished)), "the tracker reports this for an unselected workstream that just finished")
    }

    func test_staysQuiet_whileTheAgentIsMidTurn() {
        XCTAssertFalse(shouldNudge(state: .working))
        XCTAssertFalse(shouldNudge(state: .stalled), "a stalled run has not ended its turn")
        XCTAssertFalse(shouldNudge(state: .needsAttention(.permission)), "typing at a permission prompt would answer it")
    }

    func test_staysQuiet_whenTheSettingIsOff() {
        XCTAssertFalse(shouldNudge(state: .idle, nudgeEnabled: false))
    }

    func test_staysQuiet_forASessionAtelierDidNotLaunch() {
        XCTAssertFalse(shouldNudge(state: .idle, hasSurface: false), "with no surface id there is nowhere to type")
    }

    func test_coalesces_aBurstOfMessages() {
        XCTAssertFalse(shouldNudge(state: .idle, lastNudge: now.addingTimeInterval(-1)))
        XCTAssertTrue(shouldNudge(state: .idle, lastNudge: now.addingTimeInterval(-AgentNudge.cooldown - 1)))
    }

    // MARK: - Attribution

    private let workstreamID = UUID()

    func test_perSurfaceEvidence_alwaysWins() {
        let other = UUID()
        XCTAssertEqual(
            AgentNudge.resolveState(surfaceState: .working, workstreamState: .idle, surfaceID: other, workstreamID: workstreamID),
            .working,
            "a busy pane must not be interrupted because the workstream looks idle"
        )
    }

    func test_noEvidenceAnywhere_isNotIdle() {
        // state(for:) defaults to .idle so a sidebar row can draw something.
        // Acting on that default would treat "hooks never arrived" as "the turn
        // ended", which is why resolveState takes the reported state instead.
        XCTAssertNil(
            AgentNudge.resolveState(surfaceState: nil, workstreamState: nil, surfaceID: workstreamID, workstreamID: workstreamID),
            "an Agent tab that has never reported must not be nudged"
        )
    }

    func test_theAgentTab_fallsBackToTheWorkstreamSignal() {
        // claudeID == workstreamID, so the workstream signal is a statement
        // about that pane rather than a guess about it.
        XCTAssertEqual(
            AgentNudge.resolveState(surfaceState: nil, workstreamState: .idle, surfaceID: workstreamID, workstreamID: workstreamID),
            .idle
        )
    }

    func test_anyOtherSurface_withoutEvidence_isNotNudged() {
        XCTAssertNil(
            AgentNudge.resolveState(surfaceState: nil, workstreamState: .idle, surfaceID: UUID(), workstreamID: workstreamID),
            "the workstream signal says nothing about a pane that has never reported"
        )
    }

    func test_nudge_withoutASurfaceCache_recordsNothing() {
        AgentNudge.shared._testReset()
        let surface = UUID()
        AgentNudge.shared.nudge(surfaceID: surface, workstreamID: surface, senderName: "planner", waiting: 1)
        XCTAssertNil(AgentNudge.shared._testLastNudge(for: surface), "a nudge with nowhere to go must not consume the cooldown")
    }

    func test_releasingAPeer_clearsTheSurfaceItOccupied() async {
        let tracker = WorkstreamAgentStateTracker.shared
        tracker.resetForTesting()
        defer { tracker.resetForTesting() }

        let surface = UUID()
        let workstream = UUID()
        tracker.workstreamLookup = { _ in workstream }
        var finished = AgentEvent.idle(agentId: "main")
        finished.surfaceID = surface.uuidString
        tracker.handle(projectDir: "/tmp/atelier-nudge-test", event: finished)
        XCTAssertEqual(tracker.state(forSurface: surface), .idle)

        let service = IPCService()
        let peer = await service._testRegister(
            name: "departing",
            role: "",
            context: IPCService.PeerContext(
                workstreamID: workstream.uuidString,
                workstreamName: "bold-crimson-parser",
                projectDirectory: "/repos/atelier",
                surfaceID: surface
            )
        )
        await service.release(peerID: peer.id)

        XCTAssertNil(tracker.state(forSurface: surface), "a retired peer's surface must stop reporting a finished turn")
    }
}
