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

    func testRefreshIsThrottledUnlessForced() async {
        var calls = 0
        let store = Usage.Store(fetch: { calls += 1; return nil })
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(calls, 1)
        await store.refresh(force: true)
        XCTAssertEqual(calls, 2)
    }
}
