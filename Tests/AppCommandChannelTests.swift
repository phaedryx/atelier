// ABOUTME: Tests for AppCommandChannel — the typed replacement for the app-level notifications.
// ABOUTME: Pins delivery-once, no replay on subscription, and the payload semantics CLAUDE.md fixes.

@testable import Atelier
import Combine
import XCTest

@MainActor
final class AppCommandChannelTests: XCTestCase {
    private var subscriptions: Set<AnyCancellable> = []

    override func tearDown() {
        subscriptions.removeAll()
        super.tearDown()
    }

    func testSendDeliversOnceToOneSubscriber() {
        let channel = AppCommandChannel()
        var received: [AppCommand] = []
        channel.publisher.sink { received.append($0) }.store(in: &subscriptions)

        channel.send(.toggleSidebar)

        XCTAssertEqual(received, [.toggleSidebar])
    }

    func testEverySubscriberSeesEveryCommandInOrder() {
        let channel = AppCommandChannel()
        var first: [AppCommand] = []
        var second: [AppCommand] = []
        channel.publisher.sink { first.append($0) }.store(in: &subscriptions)
        channel.publisher.sink { second.append($0) }.store(in: &subscriptions)

        channel.send(.nextWorkstream)
        channel.send(.prevWorkstream)

        XCTAssertEqual(first, [.nextWorkstream, .prevWorkstream])
        XCTAssertEqual(second, first)
    }

    /// The reason this is a `PassthroughSubject` rather than a `@Published`
    /// value: a current-value publisher replays its latest element to every new
    /// subscriber, so a `ContentView` body evaluation would re-run the last
    /// command — re-opening a purge confirmation nobody asked for twice.
    func testASubscriberSeesNothingSentBeforeItSubscribed() {
        let channel = AppCommandChannel()
        channel.send(.archiveWorkstream)

        var received: [AppCommand] = []
        channel.publisher.sink { received.append($0) }.store(in: &subscriptions)

        XCTAssertTrue(received.isEmpty)
    }

    /// Nothing is buffered, so a command sent with no subscriber is dropped —
    /// exactly what a notification with no observer did. What changed is that a
    /// *case* nobody handles is now a compile error, not a silent no-op.
    func testACommandSentWithNoSubscriberIsDroppedRatherThanQueued() {
        let channel = AppCommandChannel()
        channel.send(.openHelp)

        var received: [AppCommand] = []
        channel.publisher.sink { received.append($0) }.store(in: &subscriptions)
        channel.send(.toggleCommandPalette)

        XCTAssertEqual(received, [.toggleCommandPalette])
    }

    /// A cancelled subscription stops receiving, so `ContentView` going away
    /// cannot leave a handler acting on a stale view's state.
    func testACancelledSubscriptionStopsReceiving() {
        let channel = AppCommandChannel()
        var received: [AppCommand] = []
        let subscription = channel.publisher.sink { received.append($0) }

        channel.send(.nextProject)
        subscription.cancel()
        channel.send(.prevProject)

        XCTAssertEqual(received, [.nextProject])
    }

    // MARK: - Payload semantics

    /// `purgeWorkstream(nil)` means "the selected workstream" and is what the
    /// palette sends; a named id is what `WorkstreamInfoView`'s merged-PR banner
    /// sends. The two must stay distinguishable — collapsing nil into some
    /// default id would purge a worktree nobody pointed at.
    func testPurgeDistinguishesTheSelectedWorkstreamFromANamedOne() {
        let wsID = UUID()
        XCTAssertNotEqual(AppCommand.purgeWorkstream(nil), .purgeWorkstream(wsID))
        XCTAssertEqual(AppCommand.purgeWorkstream(wsID), .purgeWorkstream(wsID))
    }

    /// A plain ⌘, toggles Settings; a named pane always opens that pane and is
    /// remembered. `nil` is the toggle and must never be read as a pane.
    func testOpenSettingsDistinguishesAPlainToggleFromADeepLink() {
        XCTAssertNotEqual(AppCommand.openSettings(pane: nil), .openSettings(pane: .general))
        for pane in SettingsPane.allCases {
            XCTAssertNotEqual(AppCommand.openSettings(pane: nil), .openSettings(pane: pane))
        }
    }

    /// `switchToProject` goes up one level from the selection; `focusProject`
    /// names its destination. They are different cases because the palette's
    /// go-to family needs the second and ⌘0 needs the first.
    func testGoingUpALevelIsNotTheSameAsJumpingToANamedProject() {
        XCTAssertNotEqual(AppCommand.switchToProject, .focusProject(UUID()))
    }
}
