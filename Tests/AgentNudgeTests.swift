// ABOUTME: Tests the policy that decides whether a message may interrupt an agent's terminal.
// ABOUTME: The injection itself needs a live Ghostty surface and is not covered here.

@testable import Atelier
import XCTest

@MainActor
final class AgentNudgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func shouldNudge(
        state: Workstream.AgentStateTracker.AgentRunState,
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

    func test_onlyPerSurfaceEvidenceCounts() {
        // The workstream signal used to stand in for the Coding Agent tab. It is
        // contaminated by any other session in the same worktree, so a pane with
        // nothing reported about it is now simply not interrupted.
        XCTAssertNil(AgentNudge.resolveState(surfaceState: nil))
        XCTAssertEqual(AgentNudge.resolveState(surfaceState: .idle), .idle)
        XCTAssertEqual(AgentNudge.resolveState(surfaceState: .working), .working)
    }

    func test_nudge_withoutASurfaceCache_recordsNothing() {
        AgentNudge.shared._testReset()
        let surface = UUID()
        AgentNudge.shared.nudge(surfaceID: surface, senderName: "planner", waiting: 1)
        XCTAssertNil(AgentNudge.shared._testLastNudge(for: surface), "a nudge with nowhere to go must not consume the cooldown")
    }

    func test_releasingAPeer_clearsTheSurfaceItOccupied() async {
        let tracker = Workstream.AgentStateTracker.shared
        tracker.resetForTesting()
        defer { tracker.resetForTesting() }

        let surface = UUID()
        let workstream = UUID()
        tracker.workstreamLookup = { _ in workstream }
        var finished = AgentEvent.idle(agentId: "main")
        finished.surfaceID = surface.uuidString
        tracker.handle(projectDir: "/tmp/atelier-nudge-test", event: finished)
        XCTAssertEqual(tracker.state(forSurface: surface), .idle)

        let service = IPC.Service()
        let peer = await service._testRegister(
            name: "departing",
            role: "",
            context: IPC.Service.PeerContext(
                workstreamID: workstream.uuidString,
                workstreamName: "bold-crimson-parser",
                projectDirectory: "/repos/atelier",
                surfaceID: surface
            )
        )
        await service.release(peerID: peer.id)

        XCTAssertNil(tracker.state(forSurface: surface), "a retired peer's surface must stop reporting a finished turn")
    }

    /// `releaseAll` is the shutdown path for the same teardown `release(peerID:)` does
    /// one peer at a time. It used to drop the store and the contexts and leave every
    /// surface behind in the tracker, still reporting its dead agent's last state.
    func test_releasingEveryPeer_clearsEverySurfaceTheyOccupied() async {
        let tracker = Workstream.AgentStateTracker.shared
        tracker.resetForTesting()
        defer { tracker.resetForTesting() }

        let workstream = UUID()
        tracker.workstreamLookup = { _ in workstream }

        let service = IPC.Service()
        var surfaces: [UUID] = []
        for name in ["first", "second"] {
            let surface = UUID()
            surfaces.append(surface)

            var finished = AgentEvent.idle(agentId: "main")
            finished.surfaceID = surface.uuidString
            tracker.handle(projectDir: "/tmp/atelier-nudge-test", event: finished)
            XCTAssertEqual(tracker.state(forSurface: surface), .idle)

            _ = await service._testRegister(
                name: name,
                role: "",
                context: IPC.Service.PeerContext(
                    workstreamID: workstream.uuidString,
                    workstreamName: "bold-crimson-parser",
                    projectDirectory: "/repos/atelier",
                    surfaceID: surface
                )
            )
        }

        await service.releaseAll()

        for surface in surfaces {
            XCTAssertNil(
                tracker.state(forSurface: surface),
                "shutdown must not leave a dead agent's surface reporting a state"
            )
        }
    }
}
