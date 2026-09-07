// ABOUTME: Desktop notification for a workstream whose agent is blocked on a permission prompt.
// ABOUTME: Owns the suppression policy, the notification's identity, and the click payload.

import Foundation
import UserNotifications

/// Adds and withdraws user notifications. `UNUserNotificationCenter` conforms;
/// tests substitute a fake. Declared here rather than beside either caller
/// because both the terminal's bell notifications and this one deliver through
/// it.
protocol NotificationRequestAdding {
    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?
    )

    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationRequestAdding {}

extension Workstream {
    /// The banner that says an agent is waiting for approval.
    ///
    /// A blocked agent stops until someone answers it, and the sidebar dot that
    /// reports the block is only visible if Atelier is the app you are looking
    /// at — which, for a workstream running unattended, is exactly when it is
    /// not. This carries the same fact out to Notification Center, and carries
    /// the workstream's id back in when the banner is clicked.
    ///
    /// The permission state itself is `AgentStateTracker`'s; this type never
    /// derives it. It is handed the two edges (`.agentBlockedOnPermission` and
    /// `.agentPermissionResolved`) and decides only whether to show, and what
    /// the banner says.
    @MainActor
    final class PermissionNotifier {
        static let shared = PermissionNotifier()

        /// `@AppStorage` key for the Coding Agent setting. Defaults to on —
        /// every reader must pass `true` when the key is absent.
        nonisolated static let enabledKey = "atelier.notifyOnPermission"

        /// Carries the workstream id through `userInfo` and back on a click.
        nonisolated static let userInfoKey = "workstreamID"

        private let center: any NotificationRequestAdding

        init(center: any NotificationRequestAdding = UNUserNotificationCenter.current()) {
            self.center = center
        }

        // MARK: - Policy

        /// Whether a block on `workstreamID` is worth a banner.
        ///
        /// Suppressed in exactly one case: the workstream is selected *and*
        /// Atelier is frontmost, so the prompt is already on screen in front of
        /// the user. Either half alone is not enough — a selected workstream in
        /// a backgrounded app is the main case this feature exists for, and a
        /// frontmost app showing some *other* workstream's pane says nothing
        /// about this one.
        static func shouldNotify(
            enabled: Bool,
            isAppActive: Bool,
            selection: SidebarSelection?,
            workstreamID: UUID
        ) -> Bool {
            guard enabled else { return false }
            return !(isAppActive && selection?.workstreamID == workstreamID)
        }

        // MARK: - Delivery

        /// Shows (or replaces) the banner for one workstream.
        ///
        /// The request identifier is the workstream's id, so a second prompt
        /// while the first banner is still up replaces it instead of stacking a
        /// duplicate the user has to dismiss twice — and so `withdraw` can pull
        /// it again by the same name.
        func notify(workstreamID: UUID, title: String, body: String) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound(named: UNNotificationSoundName("notification.wav"))
            content.userInfo = [Self.userInfoKey: workstreamID.uuidString]

            center.add(
                UNNotificationRequest(
                    identifier: Self.identifier(for: workstreamID),
                    content: content,
                    trigger: nil
                ),
                withCompletionHandler: nil
            )
        }

        /// Pulls a delivered banner once its prompt has been answered. A banner
        /// that outlives the block sends the user to a pane with nothing waiting
        /// on it.
        func withdraw(workstreamID: UUID) {
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: workstreamID)])
        }

        private static func identifier(for workstreamID: UUID) -> String {
            workstreamID.uuidString
        }

        // MARK: - Click

        /// Turns a clicked banner into a `.focusWorkstream` post, or reports
        /// that it named no workstream.
        ///
        /// Returns false rather than posting with a nil object: a
        /// `.focusWorkstream` carrying nothing would move the selection nowhere
        /// and make the click look handled. Notifications from the terminal
        /// (bell, OSC 777) name no workstream and land here as nil.
        @discardableResult
        static func handleClick(
            workstreamID: UUID?,
            center: NotificationCenter = .default
        ) -> Bool {
            guard let workstreamID else { return false }
            center.post(name: .focusWorkstream, object: workstreamID)
            return true
        }

        /// The workstream a notification payload names, or nil if it names none.
        ///
        /// `nonisolated` because the delegate callback that reads it is: the
        /// payload is decoded where it arrives, so only a `UUID?` has to cross
        /// onto the main actor.
        nonisolated static func workstreamID(fromUserInfo userInfo: [AnyHashable: Any]) -> UUID? {
            guard let raw = userInfo[userInfoKey] as? String else { return nil }
            return UUID(uuidString: raw)
        }
    }
}
