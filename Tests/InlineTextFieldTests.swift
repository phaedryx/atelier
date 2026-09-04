// ABOUTME: Tests for the inline rename field's click-monitor lifetime.
// ABOUTME: A rename committed before the deferred install must not leave a monitor behind.

@testable import Atelier
import XCTest

@MainActor
final class InlineTextFieldTests: XCTestCase {
    private func coordinator() -> InlineTextField.Coordinator {
        InlineTextField.Coordinator(onCommit: { _ in }, onCancel: {})
    }

    func testInstallsAMonitorWhileEditingIsStillOpen() {
        // The monitor this installs is torn down by the coordinator's `deinit`
        // when `sut` goes out of scope.
        let sut = coordinator()
        sut.installClickMonitor()

        XCTAssertTrue(sut.hasClickMonitor)
    }

    /// The monitor is installed on a 0.3s delay. Committing with Enter or Esc
    /// inside that window ran `finish`, whose `removeClickMonitor()` had nothing
    /// to remove — and the install then landed anyway, leaking one NSEvent
    /// monitor per rename for the life of the process.
    func testDoesNotInstallAMonitorAfterEditingHasFinished() {
        let sut = coordinator()
        sut.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))

        sut.installClickMonitor()

        XCTAssertFalse(sut.hasClickMonitor)
    }
}
