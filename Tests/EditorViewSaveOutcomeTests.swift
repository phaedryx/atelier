// ABOUTME: Tests whether the switch-file alert may open the next file after a Save.
// ABOUTME: Save navigated unconditionally, so a failed write silently discarded the edits it was pressed to keep.

@testable import Atelier
import XCTest

/// Navigating replaces the Monaco model with the next file's contents from
/// disk, so the alert's Save button is the last thing standing between a write
/// that failed and the unsaved text going away. `mayNavigate(after:)` is that
/// decision, kept out of the view so it can be pinned here.
final class EditorViewSaveOutcomeTests: XCTestCase {
    func testASavedFileLetsTheAlertOpenTheNextOne() {
        XCTAssertTrue(EditorView.mayNavigate(after: .saved))
    }

    /// Nothing was written because nothing had changed, so there is nothing for
    /// the navigation to destroy.
    func testNothingToSaveLetsTheAlertOpenTheNextOne() {
        XCTAssertTrue(EditorView.mayNavigate(after: .nothingToSave))
    }

    /// The bug. A read-only file, a full disk, or a bridge that would not hand
    /// its text over all end here, and the edits are still in the model.
    func testAFailedSaveKeepsTheAlertOnTheCurrentFile() {
        XCTAssertFalse(EditorView.mayNavigate(after: .failed("Permission denied")))
    }
}
