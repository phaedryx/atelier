// ABOUTME: Desktop notification an agent raises itself when it wants the user to come and look.
// ABOUTME: Sibling of PermissionNotifier — same click routing, deliberately a different identifier.

import Foundation
import UserNotifications

extension Workstream {
    /// The banner an agent asks for through `request_attention`.
    ///
    /// Distinct from `PermissionNotifier`, which reports a *derived* fact — the
    /// agent is blocked, as `AgentStateTracker` sees it — on the edges into and
    /// out of that state. This one reports an *asserted* fact: the agent says it
    /// wants the user. Nothing infers it and nothing withdraws it on a state
    /// change, because no state change means "the agent stopped wanting you".
    ///
    /// **The identifier is namespaced, and that is the point.**
    /// `PermissionNotifier` keys its request on the bare workstream UUID so a
    /// second permission prompt replaces the first. Reusing that identifier here
    /// would make an attention request and a permission block silently evict one
    /// another — two different facts, one of which the user would never see. A
    /// prefix keeps replacement working *within* each kind and not across them.
    ///
    /// Suppression is deliberately weaker than `PermissionNotifier`'s. That one
    /// suppresses when the workstream is selected and the app is frontmost,
    /// because the prompt it is announcing is already on screen. An agent asking
    /// for attention has nothing on screen to be redundant with — the whole
    /// point is that its terminal output is not enough — so a selected,
    /// frontmost workstream still gets a banner. The rate limit, not the
    /// suppression rule, is what keeps that from becoming noise.
    @MainActor
    final class AttentionNotifier {
        static let shared = AttentionNotifier()

        /// Longest an agent-supplied reason may be before it is truncated. A
        /// notification body is a glance, and the agent has a whole terminal for
        /// anything longer.
        nonisolated static let reasonLimit = 200

        /// Minimum gap between two banners for the same workstream. An agent in
        /// a loop must not be able to paper the user's screen; further requests
        /// inside the window are refused with a message saying so, rather than
        /// dropped silently.
        nonisolated static let cooldown: TimeInterval = 30

        private let center: any NotificationRequestAdding
        private var lastRequest: [UUID: Date] = [:]

        init(center: any NotificationRequestAdding = UNUserNotificationCenter.current()) {
            self.center = center
        }

        /// Whether a request is allowed right now. Pure, so the rate limit is
        /// testable without a notification centre.
        nonisolated static func shouldNotify(lastRequest: Date?, now: Date = Date()) -> Bool {
            guard let lastRequest else { return true }
            return now.timeIntervalSince(lastRequest) >= cooldown
        }

        /// Raises the banner, or returns the number of seconds still to wait.
        ///
        /// Returning the wait rather than a bare `false` is what lets the tool
        /// tell the agent *when* to try again — an agent told only "no" will
        /// either retry immediately or give up, and both are wrong.
        @discardableResult
        func notify(
            workstreamID: UUID,
            workstreamName: String,
            reason: String,
            now: Date = Date()
        ) -> Result<Void, Refusal> {
            guard Self.shouldNotify(lastRequest: lastRequest[workstreamID], now: now) else {
                let elapsed = now.timeIntervalSince(lastRequest[workstreamID] ?? now)
                return .failure(.tooSoon(secondsRemaining: Int((Self.cooldown - elapsed).rounded(.up))))
            }
            lastRequest[workstreamID] = now

            let content = UNMutableNotificationContent()
            content.title = workstreamName
            content.body = Self.truncate(reason)
            content.sound = UNNotificationSound(named: UNNotificationSoundName("notification.wav"))
            // The same key PermissionNotifier uses, so a click routes through
            // AppDelegate's existing `.focusWorkstream` path unchanged.
            content.userInfo = [PermissionNotifier.userInfoKey: workstreamID.uuidString]

            center.add(
                UNNotificationRequest(
                    identifier: Self.identifier(for: workstreamID),
                    content: content,
                    trigger: nil
                ),
                withCompletionHandler: nil
            )
            return .success(())
        }

        enum Refusal: Error, LocalizedError {
            case tooSoon(secondsRemaining: Int)

            var errorDescription: String? {
                switch self {
                case let .tooSoon(seconds):
                    "Too soon after the last attention request for this workstream. Try again in \(seconds)s."
                }
            }
        }

        /// Trims an agent-supplied reason to one glanceable line.
        ///
        /// Newlines collapse to spaces: a notification body renders them, and an
        /// agent pasting a stack trace would otherwise get a banner the user
        /// cannot read at a glance and cannot scroll.
        nonisolated static func truncate(_ reason: String, limit: Int = reasonLimit) -> String {
            let flattened = reason
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard flattened.count > limit else { return flattened }
            return String(flattened.prefix(limit - 1)) + "…"
        }

        private static func identifier(for workstreamID: UUID) -> String {
            "attention-\(workstreamID.uuidString)"
        }
    }
}
