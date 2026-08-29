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

    func test_nudge_withoutASurfaceCache_isANoOp() {
        AgentNudge.shared._testReset()
        AgentNudge.shared.nudge(surfaceID: UUID(), workstreamID: UUID(), senderName: "planner", waiting: 1)
    }
}
