// ABOUTME: Tests for AppDelegate startup behaviors that interact with system callbacks.
// ABOUTME: Verifies notification authorization results are handled on the main thread.

@testable import Atelier
import UserNotifications
import XCTest

final class AppDelegateTests: XCTestCase {
    func testNotificationAuthorizationResultIsHandledOnMainThread() {
        let handledOnMainThread = expectation(description: "notification authorization handled on main thread")

        AppDelegate.handleNotificationAuthorizationResult(granted: false, error: nil) { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            handledOnMainThread.fulfill()
        }

        wait(for: [handledOnMainThread], timeout: 1)
    }

    func testNotificationAuthorizationRequestHandlesBackgroundCallbackOnMainThread() {
        let handledOnMainThread = expectation(description: "background authorization callback handled on main thread")
        let center = NotificationCenterStub()

        AppDelegate.requestNotificationAuthorization(using: center) { _, _ in
            XCTAssertTrue(center.didRequestAuthorization)
            XCTAssertEqual(center.requestedOptions, [.alert, .sound])
            XCTAssertTrue(Thread.isMainThread)
            handledOnMainThread.fulfill()
        }

        wait(for: [handledOnMainThread], timeout: 1)
    }

    /// The two tests above discard both closure parameters, so they hold for any
    /// implementation that logs *something* — including one that reported a denial as
    /// an error, or an error at `.info`. Which branch fired *is* the forwarded result
    /// here (there is no completion to inspect; `granted` and `error` are observable
    /// only through the message), so asserting the message and the level is the only
    /// way this file checks that either value arrives.
    func testADenialIsReportedAsInfoAndNotAsAnError() {
        let logged = expectation(description: "denial logged")
        let center = NotificationCenterStub(granted: false, error: nil)

        AppDelegate.requestNotificationAuthorization(using: center) { message, level in
            XCTAssertEqual(message, "Notification permission denied by user")
            XCTAssertEqual(level, .info)
            logged.fulfill()
        }

        wait(for: [logged], timeout: 1)
    }

    /// `granted: true` alongside an error is what makes this discriminate: an
    /// implementation that read only `granted` would log nothing and time out, and one
    /// that reported it at `.info` would fail the level assertion.
    func testAnErrorIsReportedAsAWarningAndTakesPrecedenceOverGranted() {
        let logged = expectation(description: "error logged")
        let center = NotificationCenterStub(granted: true, error: .denied)

        AppDelegate.requestNotificationAuthorization(using: center) { message, level in
            XCTAssertEqual(
                message,
                "Notification permission error: \(NotificationCenterStub.StubError.denied.localizedDescription)"
            )
            XCTAssertEqual(level, .warning)
            logged.fulfill()
        }

        wait(for: [logged], timeout: 1)
    }

    /// The silent branch. Nothing else pins it, so an implementation that logged a
    /// denial on success would go unnoticed.
    func testASuccessfulAuthorizationLogsNothing() {
        let logged = expectation(description: "nothing is logged when permission is granted")
        logged.isInverted = true
        let center = NotificationCenterStub(granted: true, error: nil)

        AppDelegate.requestNotificationAuthorization(using: center) { _, _ in
            logged.fulfill()
        }

        wait(for: [logged], timeout: 0.5)
    }
}

private final class NotificationCenterStub: NotificationAuthorizationRequesting, @unchecked Sendable {
    enum StubError: Error, Equatable {
        case denied
    }

    private(set) var didRequestAuthorization = false
    private(set) var requestedOptions: UNAuthorizationOptions = []

    private let granted: Bool
    private let error: StubError?

    /// A concrete `Sendable` error rather than `any Error`, so the configured value can
    /// cross the dispatch into the completion without weakening its sendability.
    init(granted: Bool = false, error: StubError? = nil) {
        self.granted = granted
        self.error = error
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        didRequestAuthorization = true
        requestedOptions = options

        let granted = granted
        let error = error
        DispatchQueue.global().async {
            completionHandler(granted, error)
        }
    }
}
