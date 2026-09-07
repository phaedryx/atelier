// ABOUTME: Tests for the blocked-agent desktop notification: policy, delivery, withdrawal, click.
// ABOUTME: Also covers the tracker edges that post and clear it.

@testable import Atelier
import UserNotifications
import XCTest

@MainActor
final class WorkstreamPermissionNotifierTests: XCTestCase {
    private let wsID = UUID()
    private let otherID = UUID()

    // MARK: - Policy

    /// The setting is the only reason to stay silent when nothing is on screen,
    /// so this is what pins the toggle to the behaviour it names.
    func testSettingOffSuppressesEvenWhenNothingIsOnScreen() {
        XCTAssertFalse(Workstream.PermissionNotifier.shouldNotify(
            enabled: false,
            isAppActive: false,
            selection: nil,
            workstreamID: wsID
        ))
    }

    /// The one case the notification would be noise: its pane is frontmost, so
    /// the permission prompt is already in front of the user.
    func testSelectedAndActiveIsSuppressed() {
        XCTAssertFalse(Workstream.PermissionNotifier.shouldNotify(
            enabled: true,
            isAppActive: true,
            selection: .workstream(wsID),
            workstreamID: wsID
        ))
    }

    /// Selected but the app is in the background — the prompt is on a screen the
    /// user is not looking at, which is exactly what the banner is for. An
    /// implementation that checked only the selection would fail here.
    func testSelectedButInactiveStillNotifies() {
        XCTAssertTrue(Workstream.PermissionNotifier.shouldNotify(
            enabled: true,
            isAppActive: false,
            selection: .workstream(wsID),
            workstreamID: wsID
        ))
    }

    /// Frontmost, but on someone else's pane. An implementation that checked
    /// only `isAppActive` would fail here.
    func testAnotherWorkstreamSelectedNotifies() {
        XCTAssertTrue(Workstream.PermissionNotifier.shouldNotify(
            enabled: true,
            isAppActive: true,
            selection: .workstream(otherID),
            workstreamID: wsID
        ))
    }

    /// Settings and Help unmount the workspace entirely, so no pane is visible.
    func testNonWorkstreamSelectionNotifies() {
        for selection: SidebarSelection in [.settings, .help, .project(otherID)] {
            XCTAssertTrue(
                Workstream.PermissionNotifier.shouldNotify(
                    enabled: true,
                    isAppActive: true,
                    selection: selection,
                    workstreamID: wsID
                ),
                "\(selection) hides the workstream's pane, so it should not suppress"
            )
        }
    }

    // MARK: - Delivery

    func testNotifyPostsOneRequestCarryingTheWorkstream() {
        let center = NotificationCenterFake()
        let notifier = Workstream.PermissionNotifier(center: center)

        notifier.notify(workstreamID: wsID, title: "brave-otter", body: "app · feat/x")

        XCTAssertEqual(center.added.count, 1)
        let request = center.added[0]
        XCTAssertEqual(request.content.title, "brave-otter")
        XCTAssertEqual(request.content.body, "app · feat/x")
        XCTAssertEqual(
            Workstream.PermissionNotifier.workstreamID(fromUserInfo: request.content.userInfo),
            wsID
        )
    }

    /// One prompt at a time per workstream: the identifier is the workstream, so
    /// a second prompt replaces the first banner instead of stacking a second
    /// one the user has to dismiss twice. A `UUID()`-per-request implementation
    /// passes the test above and fails this one.
    func testASecondNotificationForTheSameWorkstreamReusesTheIdentifier() {
        let center = NotificationCenterFake()
        let notifier = Workstream.PermissionNotifier(center: center)

        notifier.notify(workstreamID: wsID, title: "brave-otter", body: "first")
        notifier.notify(workstreamID: wsID, title: "brave-otter", body: "second")

        XCTAssertEqual(center.added.count, 2)
        XCTAssertEqual(center.added[0].identifier, center.added[1].identifier)
    }

    /// Two workstreams blocked at once are two separate banners.
    func testDifferentWorkstreamsGetDifferentIdentifiers() {
        let center = NotificationCenterFake()
        let notifier = Workstream.PermissionNotifier(center: center)

        notifier.notify(workstreamID: wsID, title: "a", body: "a")
        notifier.notify(workstreamID: otherID, title: "b", body: "b")

        XCTAssertNotEqual(center.added[0].identifier, center.added[1].identifier)
    }

    /// A banner for a prompt that has already been answered is worse than none,
    /// so the delivered notification is pulled — by the same identifier it was
    /// posted under, and only that one.
    func testWithdrawRemovesOnlyThatWorkstreamsNotification() {
        let center = NotificationCenterFake()
        let notifier = Workstream.PermissionNotifier(center: center)

        notifier.notify(workstreamID: wsID, title: "a", body: "a")
        notifier.withdraw(workstreamID: wsID)

        XCTAssertEqual(center.removedIdentifiers, [center.added[0].identifier])
    }

    // MARK: - Click

    func testClickOnABlockedAgentBannerPostsFocusWorkstream() {
        let center = NotificationCenter()
        var focused: [UUID] = []
        let token = center.addObserver(forName: .focusWorkstream, object: nil, queue: nil) { note in
            if let id = note.object as? UUID {
                focused.append(id)
            }
        }
        defer { center.removeObserver(token) }

        let handled = Workstream.PermissionNotifier.handleClick(workstreamID: wsID, center: center)

        XCTAssertTrue(handled)
        XCTAssertEqual(focused, [wsID])
    }

    /// The terminal's bell notifications name no workstream, and clicking one
    /// must not post: a `.focusWorkstream` with a nil object would move the
    /// selection nowhere and make the click look handled.
    func testClickOnABannerNamingNoWorkstreamPostsNothing() {
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: .focusWorkstream, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }

        let handled = Workstream.PermissionNotifier.handleClick(workstreamID: nil, center: center)

        XCTAssertFalse(handled)
        XCTAssertEqual(posts, 0)
    }

    /// What the delegate decodes before it hops to the main actor. Anything but
    /// a parseable uuid string under our own key has to come back nil, or a
    /// click would focus a workstream nobody named.
    func testOnlyAUUIDStringUnderOurKeyDecodesToAWorkstream() {
        XCTAssertEqual(
            Workstream.PermissionNotifier.workstreamID(
                fromUserInfo: [Workstream.PermissionNotifier.userInfoKey: wsID.uuidString]
            ),
            wsID
        )

        let unusable: [String: [AnyHashable: Any]] = [
            "missing key": [:],
            "junk string": [Workstream.PermissionNotifier.userInfoKey: "not-a-uuid"],
            "wrong type": [Workstream.PermissionNotifier.userInfoKey: 42],
            "other key": ["somethingElse": wsID.uuidString],
        ]

        for (name, userInfo) in unusable {
            XCTAssertNil(
                Workstream.PermissionNotifier.workstreamID(fromUserInfo: userInfo),
                "\(name) should decode to no workstream"
            )
        }
    }

    // MARK: - Tracker edges

    /// The `Notification` hook fires repeatedly while one prompt sits unanswered,
    /// so the post has to be an edge. Level-triggering it gives a banner every
    /// few seconds for a single prompt.
    func testBlockedIsPostedOnceForRepeatedPermissionEvents() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        recorder.handle(.status(agentId: "main", status: "permissionRequired"))

        XCTAssertEqual(recorder.blocked, [recorder.wsID])
        XCTAssertEqual(recorder.resolved, [])
    }

    /// Tool activity is how the tracker learns the prompt was answered (there is
    /// no "granted" hook), so it is also when the banner stops being true.
    func testToolActivityResolvesTheBlock() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        recorder.handle(.toolStart(agentId: "main", tool: "Bash", activity: "Running tests"))

        XCTAssertEqual(recorder.blocked, [recorder.wsID])
        XCTAssertEqual(recorder.resolved, [recorder.wsID])
    }

    /// A turn that ends while blocked — the user answered in the terminal and
    /// the agent ran to completion — leaves `.needsAttention(.justFinished)`,
    /// which is still a state the banner must not outlive.
    func testTurnEndingResolvesTheBlock() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        recorder.handle(.idle(agentId: "main"))

        XCTAssertEqual(recorder.resolved, [recorder.wsID])
    }

    /// Archiving a blocked workstream drops its state; the banner it posted
    /// points at a workstream that no longer exists.
    func testClearingAWorkstreamResolvesTheBlock() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        recorder.tracker.clear(workstreamID: recorder.wsID)

        XCTAssertEqual(recorder.resolved, [recorder.wsID])
    }

    /// `Notification` also fires for idle reminders, which the receiver maps to
    /// `idleNotification`. Those are not a block and must post nothing.
    func testANonPermissionStatusPostsNothing() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "idleNotification"))

        XCTAssertEqual(recorder.blocked, [])
        XCTAssertEqual(recorder.resolved, [])
    }

    /// Two prompts in one turn are two banners. A latch that fires once per
    /// workstream — or once per app launch — passes every test above.
    func testASecondPromptAfterResolutionPostsAgain() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        recorder.handle(.toolStart(agentId: "main", tool: "Bash", activity: "Running tests"))
        recorder.handle(.status(agentId: "main", status: "permissionRequired"))

        XCTAssertEqual(recorder.blocked, [recorder.wsID, recorder.wsID])
        XCTAssertEqual(recorder.resolved, [recorder.wsID])
    }

    /// Answering in Atelier's own banner resolves the block as surely as a tool
    /// starting does. It reaches the tracker by a different door —
    /// `permissionAnswered`, not a hook event — and a banner that outlives its
    /// prompt sends the user to a pane with nothing waiting on it.
    func testAnsweringInTheAppResolvesTheBlock() {
        let recorder = EdgeRecorder()

        recorder.handle(.status(agentId: "main", status: "permissionRequired"))
        XCTAssertEqual(recorder.blocked, [recorder.wsID])

        recorder.tracker.permissionAnswered(workstreamID: recorder.wsID)

        XCTAssertEqual(recorder.resolved, [recorder.wsID])
    }

    func testAnsweringAWorkstreamThatWasNotBlockedPostsNothing() {
        let recorder = EdgeRecorder()

        recorder.handle(.waiting(agentId: "main"))
        recorder.tracker.permissionAnswered(workstreamID: recorder.wsID)

        XCTAssertEqual(recorder.blocked, [])
        XCTAssertEqual(recorder.resolved, [], "an edge, not a level — nothing changed")
    }
}

/// Drives the shared tracker with hook events and records the permission edges
/// it posts. Observes `.default` because that is where the tracker posts; both
/// observers are torn down with the recorder.
@MainActor
private final class EdgeRecorder {
    let wsID = UUID()
    let projectDir = "/tmp/atelier-permission-notifier-test"
    var blocked: [UUID] = []
    var resolved: [UUID] = []

    var tracker: Workstream.AgentStateTracker {
        .shared
    }

    /// `nonisolated(unsafe)` so `deinit` can unsubscribe: the array is written
    /// once in `init` and read once there, both on the main actor.
    private nonisolated(unsafe) var tokens: [any NSObjectProtocol] = []

    init() {
        tracker.resetForTesting()
        let expected = Workstream.AgentStateTracker.normalize(projectDir)
        let mapped = wsID
        tracker.workstreamLookup = { dir in
            Workstream.AgentStateTracker.normalize(dir) == expected ? mapped : nil
        }
        tokens = [
            NotificationCenter.default.addObserver(
                forName: .agentBlockedOnPermission, object: nil, queue: nil
            ) { [weak self] note in
                if let id = note.object as? UUID {
                    self?.blocked.append(id)
                }
            },
            NotificationCenter.default.addObserver(
                forName: .agentPermissionResolved, object: nil, queue: nil
            ) { [weak self] note in
                if let id = note.object as? UUID {
                    self?.resolved.append(id)
                }
            },
        ]
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func handle(_ event: AgentEvent) {
        tracker.handle(projectDir: projectDir, event: event)
    }
}

/// Records what reached the notification centre instead of showing it.
private final class NotificationCenterFake: NotificationRequestAdding, @unchecked Sendable {
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?
    ) {
        added.append(request)
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}
