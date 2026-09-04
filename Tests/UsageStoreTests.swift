// ABOUTME: Tests for Usage.Store's refresh throttling and last-good-report retention.

@testable import Atelier
import XCTest

@MainActor
final class UsageStoreTests: XCTestCase {
    private func report(session: Int) -> Usage.Report {
        Usage.Report(session: .init(percentUsed: session))
    }

    func testRefreshPublishesFetchedReport() async {
        let store = Usage.Store(fetch: { Usage.Report(session: .init(percentUsed: 42)) })
        await store.refresh()
        XCTAssertEqual(store.report?.session?.percentUsed, 42)
    }

    func testFailedFetchKeepsLastGoodReport() async {
        var results: [Usage.Report?] = [report(session: 42), nil]
        let store = Usage.Store(fetch: { results.removeFirst() })
        await store.refresh()
        await store.refresh(force: true)
        XCTAssertEqual(store.report?.session?.percentUsed, 42)
    }

    /// Every fetch used to return nil here, so `report` was nil either way and
    /// the assertion held whether or not the throttle worked. Successful fetches
    /// make the suppression observable in the published value, not just the count.
    func testASuccessfulRefreshIsSuppressedInsideTheWindow() async {
        var calls = 0
        let store = Usage.Store(fetch: {
            calls += 1
            return Usage.Report(session: .init(percentUsed: calls))
        })

        await store.refresh()
        XCTAssertEqual(store.report?.session?.percentUsed, 1)

        await store.refresh()
        XCTAssertEqual(calls, 1, "a second refresh inside the window must not probe")
        XCTAssertEqual(store.report?.session?.percentUsed, 1)

        await store.refresh(force: true)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.report?.session?.percentUsed, 2)
    }

    /// A failed probe used to stamp the throttle before awaiting the fetch, so a
    /// transient failure suppressed retries for the full interval — 300s by
    /// default — against a store that documents keeping the last good report and
    /// trying again.
    func testAFailedFetchDoesNotBurnTheWholeWindow() async {
        var results: [Usage.Report?] = [nil, report(session: 7)]
        // A success window long enough to suppress the retry outright, against a
        // failure backoff of nothing. The production defaults are 300s and 30s;
        // what matters here is that a failure is charged the second, not the first.
        let store = Usage.Store(
            minRefreshInterval: 60,
            failureRetryInterval: 0,
            fetch: { results.removeFirst() }
        )

        await store.refresh()
        XCTAssertNil(store.report)

        await store.refresh()
        XCTAssertEqual(
            store.report?.session?.percentUsed, 7,
            "the retry after a failure must not wait out the full success window"
        )
    }

    /// The meter's click is the one caller with a user waiting on it, and the
    /// in-flight guard used to turn it away in silence: `guard !isRefreshing`
    /// applied to `force: true` too, so clicking mid-refresh did nothing at all.
    func testAForcedRefreshDuringAnInFlightProbeJoinsIt() async {
        let probeStarted = Gate()
        var calls = 0
        var probeFinished = false
        var store: Usage.Store?

        store = Usage.Store(fetch: {
            calls += 1
            // Releases the waiter below, which then reaches `refresh(force:)`
            // while this probe is demonstrably still running.
            await probeStarted.open()
            await Task.yield()
            await Task.yield()
            probeFinished = true
            return Usage.Report(session: .init(percentUsed: 55))
        })

        let clicked = Task { @MainActor in
            await probeStarted.wait()
            await store?.refresh(force: true)
            return probeFinished
        }

        await store?.refresh()
        let sawProbeFinish = await clicked.value

        XCTAssertEqual(calls, 1, "joining the in-flight probe must not spawn a second one")
        XCTAssertEqual(
            sawProbeFinish, true,
            "a forced refresh must return with the probe's result, not early and empty"
        )
        XCTAssertEqual(store?.report?.session?.percentUsed, 55)
    }
}

/// One-shot suspension, so a test can hold a fetch open while it makes a second
/// call and then let both finish.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
