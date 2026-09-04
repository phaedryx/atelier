// ABOUTME: Manages the app's launch-at-login registration via SMAppService.
// ABOUTME: Provides a simple enable/disable interface backed by the system login item service.

import OSLog
import ServiceManagement

enum LaunchAtLogin {
    private static let logger = Logger(subsystem: AppConstants.appID, category: "LaunchAtLogin")

    /// What the system says about our login item.
    ///
    /// The three cases matter separately to the UI. On macOS 13+ `register()` routinely
    /// lands in `.requiresApproval` — the registration is recorded, but the user has to
    /// approve it in System Settings ▸ General ▸ Login Items before it takes effect.
    /// Collapsing that into "off" makes the toggle flip back with nothing said, and the
    /// user has no way to learn that the fix is one switch away in another app.
    enum Status: Equatable {
        /// Registered and active.
        case enabled
        /// Registered, but waiting on the user to approve it in System Settings.
        case requiresApproval
        /// Not registered — including `.notFound`, which is the state before a first
        /// registration and the state after a successful unregister.
        case disabled
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    /// True only when the login item is actually active. `.requiresApproval` is not
    /// "on" — the app will not launch until the user approves it — so anything that
    /// only needs a yes/no can keep reading this.
    static var isEnabled: Bool {
        status == .enabled
    }

    /// The outcome of a toggle, so the caller can tell the three apart.
    enum Result: Equatable {
        /// The change took effect.
        case success
        /// Registered, but the user must approve it in System Settings ▸ Login Items.
        case requiresApproval
        /// SMAppService threw. The toggle did not change.
        case failed(String)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // Registering does not mean enabled: re-read the service rather than
                // assuming, since approval is the common outcome on macOS 13+.
                if status == .requiresApproval {
                    logger.info("Registered launch at login; awaiting user approval in System Settings")
                    return .requiresApproval
                }
                logger.info("Registered launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered launch at login")
            }
            return .success
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") launch at login: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    /// Opens System Settings at the Login Items pane, so a `.requiresApproval` result
    /// can hand the user somewhere to go rather than just telling them something is wrong.
    static var loginItemsSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }
}
