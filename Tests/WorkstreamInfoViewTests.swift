// ABOUTME: Tests for the Info tab's bootstrap row — what each setup state says, and when Rerun is live.
// ABOUTME: Both used to be one optional tuple that rendered nothing for the two most common states.

@testable import Atelier
import XCTest

final class WorkstreamInfoViewTests: XCTestCase {
    // MARK: - Every state says something

    /// The row carries Rerun, so a state that renders nothing takes the button
    /// with it. These two returned nil while the row was only a report.
    func testTheStatesThatUsedToBeSilentNowSpeak() {
        XCTAssertFalse(initializationRow(for: .idle).detail.isEmpty)
        XCTAssertFalse(initializationRow(for: .completed).detail.isEmpty)
    }

    /// `.idle` is the resting state, not a transient: `Initialization.Runner.states`
    /// is in memory, so every workstream reports it after a relaunch. Its copy
    /// must not claim a bootstrap ran, and must not claim one never did —
    /// neither is knowable from here.
    func testIdleSpeaksOnlyForTheSessionAndNotForTheWorktree() {
        XCTAssertEqual(initializationRow(for: .idle).detail, "Nothing reported this session.")
    }

    /// A note's whole content is the reason nothing ran, so it is the detail
    /// rather than a prefix to it.
    func testANoteIsShownVerbatim() {
        let note = "This project has no initialization.yaml, so no setup ran."
        XCTAssertEqual(initializationRow(for: .completedWithNote(note)).detail, note)
    }

    func testAFailureIsShownVerbatimAndTinted() {
        let row = initializationRow(for: .failed("Initialization failed at “deps”: exit 1"))
        XCTAssertEqual(row.detail, "Initialization failed at “deps”: exit 1")
        XCTAssertEqual(row.tint, .orange)
    }

    func testProgressShowsTheStep() {
        XCTAssertEqual(initializationRow(for: .inProgress(step: "Running “deps” (1 of 2)", progress: 0.5)).detail, "Running “deps” (1 of 2)")
    }

    // MARK: - When Rerun is live

    /// The actor already ignores a second bootstrap for a workstream that has
    /// one in flight — both would share `<id>-bootstrap.sock`. Disabling is how
    /// that refusal reads as unavailable rather than as a dead press.
    func testRerunIsRefusedOnlyWhileABootstrapIsInFlight() {
        XCTAssertFalse(canRerunInitialization(.inProgress(step: "Running “deps” (1 of 2)", progress: 0.5)))
    }

    /// Including after a note. "process-compose was not found, so no bootstrap
    /// ran" is a thing the user can go and fix, and the press is how they find
    /// out whether they did — refusing it would trade the explanation for
    /// silence.
    func testRerunIsAvailableFromEveryRestingState() {
        XCTAssertTrue(canRerunInitialization(.idle))
        XCTAssertTrue(canRerunInitialization(.completed))
        XCTAssertTrue(canRerunInitialization(.completedWithNote("This project has no initialization.yaml, so no setup ran.")))
        XCTAssertTrue(canRerunInitialization(.failed("Initialization failed at “deps”: exit 1")))
    }
}
