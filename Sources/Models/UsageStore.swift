// ABOUTME: Observable store for Claude plan usage. Refreshes via Usage.Probe off the main
// ABOUTME: actor, throttled; keeps the last good report when a probe transiently fails.

import Foundation

extension Usage {
    @MainActor
    final class Store: ObservableObject {
        @Published private(set) var report: Usage.Report?

        private let fetch: () async -> Usage.Report?
        private let minRefreshInterval: TimeInterval
        /// When the next probe is allowed. A *successful* fetch pushes this out by
        /// the full interval; a failed one by `failureRetryInterval`, so a
        /// transient failure does not cost the same as a good report.
        private var nextAllowedRefresh: Date?
        /// The probe currently running, so a second caller can join it instead of
        /// spawning another `claude` — or being turned away.
        private var inFlight: Task<Void, Never>?

        /// How long a *failed* probe suppresses the next attempt.
        ///
        /// Not `minRefreshInterval`: this store promises to keep the last good
        /// report across a transient failure, and charging a failure the full
        /// window (300 s by default) meant one bad sample froze the meter for five
        /// minutes. Not zero either — `refresh()` runs on every window activation,
        /// and a probe failing because `claude` is missing would then spawn a
        /// process per activation. Never longer than the success window, which
        /// would be backwards.
        private let failureRetryInterval: TimeInterval

        /// The probe spawns a `claude` process, so refreshes are throttled to
        /// `minRefreshInterval` unless forced (e.g. by a click on the meter).
        init(
            minRefreshInterval: TimeInterval = 300,
            failureRetryInterval: TimeInterval = 30,
            fetch: @escaping () async -> Usage.Report? = {
                await Task.detached(priority: .utility) { Usage.Probe.fetch() }.value
            }
        ) {
            self.minRefreshInterval = minRefreshInterval
            self.failureRetryInterval = min(failureRetryInterval, minRefreshInterval)
            self.fetch = fetch
        }

        func refresh(force: Bool = false) async {
            if !force, let next = nextAllowedRefresh, Date() < next {
                return
            }

            if let inFlight {
                // A forced refresh must not be a silent no-op. It used to be: the
                // in-flight guard turned away the meter's own click, which is the
                // one caller that has a user waiting on it. Joining the running
                // probe answers it with fresh data and still spawns one process.
                if force {
                    await inFlight.value
                }
                return
            }

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let fetched = await fetch()
                if let fetched {
                    report = fetched
                }
                nextAllowedRefresh = Date().addingTimeInterval(
                    fetched == nil ? failureRetryInterval : minRefreshInterval
                )
            }
            inFlight = task
            // `defer`, not a trailing assignment: a cancelled task would otherwise
            // leave `inFlight` set and the guard above would reject every later
            // refresh, including the meter's forced click.
            defer { inFlight = nil }
            await task.value
        }
    }
}
