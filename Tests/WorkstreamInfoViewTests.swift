// ABOUTME: Tests for the Info tab's bootstrap row — what each setup state says, and when Rerun is live.
// ABOUTME: Both used to be one optional tuple that rendered nothing for the two most common states.

@testable import Atelier
import XCTest

final class WorkstreamInfoViewTests: XCTestCase {
    // MARK: - Every state says something

    /// The row carries Rerun, so a state that renders nothing takes the button
    /// with it. These two returned nil while the row was only a report.
    func testTheStatesThatUsedToBeSilentNowSpeak() {
        XCTAssertFalse(bootstrapRow(for: .idle).detail.isEmpty)
        XCTAssertFalse(bootstrapRow(for: .completed).detail.isEmpty)
    }

    /// `.idle` is the resting state, not a transient: `AsyncSetupService.states`
    /// is in memory, so every workstream reports it after a relaunch. Its copy
    /// must not claim a bootstrap ran, and must not claim one never did —
    /// neither is knowable from here.
    func testIdleSpeaksOnlyForTheSessionAndNotForTheWorktree() {
        XCTAssertEqual(bootstrapRow(for: .idle).detail, "Nothing reported this session.")
    }

    /// A note's whole content is the reason nothing ran, so it is the detail
    /// rather than a prefix to it.
    func testANoteIsShownVerbatim() {
        let note = "process-compose was not found, so no bootstrap ran."
        XCTAssertEqual(bootstrapRow(for: .completedWithNote(note)).detail, note)
    }

    func testAFailureIsShownVerbatimAndTinted() {
        let row = bootstrapRow(for: .failed("Bootstrap failed: exit 1"))
        XCTAssertEqual(row.detail, "Bootstrap failed: exit 1")
        XCTAssertEqual(row.tint, .orange)
    }

    func testProgressShowsTheStep() {
        XCTAssertEqual(bootstrapRow(for: .inProgress(step: "Running bootstrap", progress: 0.5)).detail, "Running bootstrap")
    }

    // MARK: - When Rerun is live

    /// The actor already ignores a second bootstrap for a workstream that has
    /// one in flight — both would share `<id>-bootstrap.sock`. Disabling is how
    /// that refusal reads as unavailable rather than as a dead press.
    func testRerunIsRefusedOnlyWhileABootstrapIsInFlight() {
        XCTAssertFalse(canRerunBootstrap(.inProgress(step: "Running bootstrap", progress: 0.5)))
    }

    /// Including after a note. "The integration is turned off, so no bootstrap
    /// ran" is a thing the user can go and fix, and the press is how they find
    /// out whether they did — refusing it would trade the explanation for
    /// silence.
    func testRerunIsAvailableFromEveryRestingState() {
        XCTAssertTrue(canRerunBootstrap(.idle))
        XCTAssertTrue(canRerunBootstrap(.completed))
        XCTAssertTrue(canRerunBootstrap(.completedWithNote("The process-compose integration is turned off, so no bootstrap ran.")))
        XCTAssertTrue(canRerunBootstrap(.failed("Bootstrap failed: exit 1")))
    }
}
