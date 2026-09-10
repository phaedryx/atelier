// ABOUTME: Tests for the sidebar status line's word and colour selection.
// ABOUTME: Covers the channel-down masking rule the liveness probe feeds.

@testable import Atelier
import SwiftUI
import XCTest

final class AgentStatusLabelTests: XCTestCase {
    private func label(
        _ state: Workstream.AgentStateTracker.AgentRunState,
        hasLiveSession: Bool = true,
        channelDown: Bool = false
    ) -> AgentStatusLabel? {
        AgentStatusLabel.resolve(
            agentState: state,
            hasLiveSession: hasLiveSession,
            channelDown: channelDown
        )
    }

    // MARK: - A verified channel

    /// The tier that used to say "Stalled" at 45 seconds. With the channel
    /// verified, silence is the agent's own and there is nothing to report.
    func test_working_readsAsWorking() {
        XCTAssertEqual(label(.working)?.key, "Working")
        XCTAssertEqual(label(.working)?.color, .blue)
    }

    func test_wedged_readsAsStalled() {
        XCTAssertEqual(label(.stalled)?.key, "Stalled")
        XCTAssertEqual(label(.stalled)?.color, .yellow)
    }

    func test_permissionPrompt_readsAsWaitingForApproval() {
        XCTAssertEqual(label(.needsAttention(.permission))?.key, "Waiting for approval")
        XCTAssertEqual(label(.needsAttention(.permission))?.color, .orange)
    }

    func test_finishedTurn_readsAsDone() {
        XCTAssertEqual(label(.needsAttention(.justFinished))?.key, "Done")
    }

    func test_idleWithALiveSession_readsAsIdle() {
        XCTAssertEqual(label(.idle)?.key, "Idle")
    }

    /// No session, no status line — the row is dormant, not quiet.
    func test_idleWithNoLiveSession_hasNoLine() {
        XCTAssertNil(label(.idle, hasLiveSession: false))
    }

    // MARK: - A channel that is not delivering

    func test_channelDown_replacesWorkingWithNoSignal() {
        XCTAssertEqual(label(.working, channelDown: true)?.key, "No Signal")
    }

    /// Grey, not yellow or orange: the fault is Atelier's own plumbing and
    /// nothing is being asked of the user, so it must not compete with the
    /// states that do want them.
    func test_noSignal_isNotColouredAsSomethingToActOn() {
        XCTAssertEqual(label(.working, channelDown: true)?.color, .secondary)
    }

    /// `.stalled` is the one claim a down channel most thoroughly undermines:
    /// it was only ever inferred from the absence of events.
    func test_channelDown_replacesStalledWithNoSignal() {
        XCTAssertEqual(label(.stalled, channelDown: true)?.key, "No Signal")
    }

    /// A permission prompt reached the app through the very channel now in
    /// doubt, and the agent is stopped until someone answers it. Masking the
    /// one state that needs the user would be the worst possible trade.
    func test_channelDown_doesNotMaskAPermissionPrompt() {
        XCTAssertEqual(label(.needsAttention(.permission), channelDown: true)?.key, "Waiting for approval")
    }

    /// `Done` and `Idle` are facts a delivered hook established. Losing the
    /// channel afterwards does not unmake them, and reporting No Signal over
    /// them would throw away information the app really has.
    func test_channelDown_doesNotMaskAFinishedTurn() {
        XCTAssertEqual(label(.needsAttention(.justFinished), channelDown: true)?.key, "Done")
    }

    func test_channelDown_doesNotMaskIdle() {
        XCTAssertEqual(label(.idle, channelDown: true)?.key, "Idle")
    }

    /// Nothing to be out of contact with.
    func test_channelDown_addsNoLineToADormantRow() {
        XCTAssertNil(label(.idle, hasLiveSession: false, channelDown: true))
    }
}
