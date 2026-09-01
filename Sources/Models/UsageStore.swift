// ABOUTME: Observable store for Claude plan usage. Refreshes via UsageProbe off the main
// ABOUTME: actor, throttled; keeps the last good report when a probe transiently fails.

import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var report: UsageReport?

    private let fetch: () async -> UsageReport?
    private let minRefreshInterval: TimeInterval
    private var lastRefresh: Date?
    private var isRefreshing = false

    /// The probe spawns a `claude` process, so refreshes are throttled to
    /// `minRefreshInterval` unless forced (e.g. by a click on the meter).
    init(
        minRefreshInterval: TimeInterval = 300,
        fetch: @escaping () async -> UsageReport? = {
            await Task.detached(priority: .utility) { UsageProbe.fetch() }.value
        }
    ) {
        self.minRefreshInterval = minRefreshInterval
        self.fetch = fetch
    }

    func refresh(force: Bool = false) async {
        let now = Date()
        if !force, let last = lastRefresh, now.timeIntervalSince(last) < minRefreshInterval {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        // `defer`, not a trailing assignment: an early return or a cancelled
        // task would otherwise leave the flag set and the guard above would
        // reject every later refresh, including the meter's forced click.
        defer { isRefreshing = false }
        lastRefresh = now
        if let fetched = await fetch() {
            report = fetched
        }
    }
}
