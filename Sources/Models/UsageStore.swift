// ABOUTME: Observable store for Claude plan usage. Refreshes via Usage.Probe off the main
// ABOUTME: actor, throttled; keeps the last good report when a probe transiently fails.

import Foundation

extension Usage {
    @MainActor
    final class Store: ObservableObject {
        @Published private(set) var report: Usage.Report?

        private let fetch: () async -> Usage.Report?
        private let minRefreshInterval: TimeInterval
        private var lastRefresh: Date?
        private var isRefreshing = false

        /// The probe spawns a `claude` process, so refreshes are throttled to
        /// `minRefreshInterval` unless forced (e.g. by a click on the meter).
        init(
            minRefreshInterval: TimeInterval = 300,
            fetch: @escaping () async -> Usage.Report? = {
                await Task.detached(priority: .utility) { Usage.Probe.fetch() }.value
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
}
