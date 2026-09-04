// ABOUTME: Tests for LaunchAtLogin's status reporting.
// ABOUTME: SMAppService is a live system service, so these cover the mapping, not registration.

@testable import Atelier
import XCTest

final class LaunchAtLoginTests: XCTestCase {
    /// `.requiresApproval` used to collapse into `false` alongside `.notFound`, which
    /// is why the toggle flipped back to off with nothing said: the registration had
    /// in fact been recorded and was waiting on System Settings.
    func testRequiresApprovalIsItsOwnStatusNotDisabled() {
        XCTAssertNotEqual(LaunchAtLogin.Status.requiresApproval, .disabled)
        XCTAssertNotEqual(LaunchAtLogin.Status.requiresApproval, .enabled)
    }

    /// `isEnabled` still means "actually on". `.requiresApproval` is not on — the app
    /// will not launch until it is approved — so callers wanting a yes/no keep it.
    func testIsEnabledIsTrueOnlyForEnabled() {
        XCTAssertEqual(LaunchAtLogin.isEnabled, LaunchAtLogin.status == .enabled)
    }

    /// The reads have to agree: a status of `.enabled` and an `isEnabled` of false
    /// would put the toggle and the notice in contradiction.
    func testStatusAndIsEnabledAgree() {
        switch LaunchAtLogin.status {
        case .enabled: XCTAssertTrue(LaunchAtLogin.isEnabled)
        case .requiresApproval, .disabled: XCTAssertFalse(LaunchAtLogin.isEnabled)
        }
    }

    /// The `.requiresApproval` notice offers a button, so it needs somewhere to send
    /// the user. A nil URL would render the notice without its only actionable part.
    func testThereIsAURLForTheLoginItemsSettingsPane() {
        XCTAssertNotNil(LaunchAtLogin.loginItemsSettingsURL)
    }

    func testAFailedResultCarriesTheReason() {
        XCTAssertEqual(LaunchAtLogin.Result.failed("boom"), .failed("boom"))
        XCTAssertNotEqual(LaunchAtLogin.Result.failed("boom"), .success)
        XCTAssertNotEqual(LaunchAtLogin.Result.requiresApproval, .success)
    }
}
