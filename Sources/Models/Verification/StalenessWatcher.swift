// ABOUTME: Watches a worktree for the edits no git-directory watcher can see, for staleness.
// ABOUTME: Armed only while there is a run to compare against, and rate-limited by a floor.

import Foundation

extension Verification {
    /// Tells the Verification tab when the worktree may have changed under a
    /// result it is showing.
    ///
    /// **Why a second watcher exists at all.** Staleness was driven entirely by
    /// `.worktreeGitActivity`, which `Worktree.HeadWatcher` posts from the
    /// worktree's *git directory*. That covers commits, index writes and branch
    /// moves — and nothing else. An ordinary editor save, or an agent rewriting
    /// a file, touches nothing inside `.git`, so a result the tab was already
    /// showing kept reading fresh for as long as the tab stayed mounted. Tab
    /// entry (`.onAppear`) covered the common case of coming back to look; it
    /// cannot cover sitting on the tab while the tree changes.
    ///
    /// **A worktree watcher is recursive and indiscriminate, which is the cost.**
    /// `DirectoryWatcher` is FSEvents over the whole tree with file-level
    /// events, so it fires for `node_modules`, build output and `.git` itself —
    /// every git operation now reaches the tab twice, once through here and once
    /// through the notification. Sustained activity, not a burst, is the hazard:
    /// each fire costs a `Git.Operations.diffFingerprint`, which is `git
    /// rev-parse`, `git diff --stat`, `git ls-files` and batched `git
    /// hash-object`, and `VerificationTabView.refreshStaleness`'s in-flight
    /// guard would happily chain one hop after another for a whole build.
    ///
    /// So two things bound it, and both are this type's reason for existing
    /// rather than a closure in the view:
    ///
    /// - **A floor**, not just a debounce. At most one callback per
    ///   `minimumInterval`, however many events arrive. A debounce alone would
    ///   let a build at one event a second fire a git sweep a second.
    /// - **Armed only while there is a run to compare against.** With no run the
    ///   tab renders no staleness at all, so a watcher would be paying for
    ///   nothing.
    ///
    /// A change arriving while a callback is already queued is **absorbed, not
    /// queued behind it**: the queued one reads the tree when it runs, which is
    /// at least as late as anything arriving now — the same argument
    /// `refreshStaleness`'s own in-flight guard makes.
    @MainActor
    final class StalenessWatcher {
        /// How long to wait after an event before reporting it, so the burst
        /// FSEvents delivers for one save becomes one callback.
        static let debounce: Duration = .milliseconds(500)
        /// The floor between two callbacks. Sized against what one costs — four
        /// or more git spawns — rather than against how fast a tree can change;
        /// the banner it feeds is a yes/no, so it does not need to be prompt to
        /// the second.
        static let minimumInterval: Duration = .seconds(10)

        private let onChange: () -> Void
        private var watcher: DirectoryWatcher?
        /// The path currently watched, so re-arming with the same one is free —
        /// the tab's triggers fire more than once for one mount.
        private var watchedPath: String?
        private var pendingCallback: Task<Void, Never>?
        private var lastFired: ContinuousClock.Instant?

        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }

        deinit {
            // `watcher` is the FSEvents stream; `DirectoryWatcher.deinit` stops
            // it, and a callback already queued on the main run loop is
            // disarmed rather than left to reach a freed box. Nothing else here
            // needs tearing down — `pendingCallback` captures `self` weakly.
            watcher?.stop()
        }

        /// Whether a worktree watcher is running. For tests and for reading the
        /// armed/disarmed decision at a glance.
        var isArmed: Bool {
            watcher != nil
        }

        /// Start watching `path`, or leave the existing watcher alone if it is
        /// already watching it.
        func arm(path: String) {
            guard watchedPath != path || watcher == nil else { return }
            disarm()
            watchedPath = path
            watcher = DirectoryWatcher(path: path) { [weak self] in
                self?.noteChange()
            }
        }

        /// Stop watching, and drop a callback that has not fired yet.
        ///
        /// `lastFired` deliberately survives: re-arming on tab entry must not
        /// hand the floor a clean slate, or switching tabs in a loop would be a
        /// way to run a git sweep per switch.
        func disarm() {
            watcher?.stop()
            watcher = nil
            watchedPath = nil
            pendingCallback?.cancel()
            pendingCallback = nil
        }

        /// One FSEvents notification, debounced and floored.
        ///
        /// Internal rather than private so a test can exercise the rate limit
        /// without waiting on the file system; `arm`'s watcher is its only
        /// production caller.
        func noteChange() {
            // Absorbed, not queued: see the type's own doc. This is also what
            // makes a continuous stream of events safe — a trailing debounce
            // that rescheduled on every event would be pushed out for as long
            // as the activity lasted, and then fire once at the end.
            guard pendingCallback == nil else { return }
            let delay = delayBeforeNextCallback()
            pendingCallback = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                lastFired = .now
                pendingCallback = nil
                onChange()
            }
        }

        /// The debounce, or whatever is left of the floor — whichever is longer.
        private func delayBeforeNextCallback() -> Duration {
            guard let lastFired else { return Self.debounce }
            let remaining = Self.minimumInterval - (ContinuousClock.now - lastFired)
            return remaining > Self.debounce ? remaining : Self.debounce
        }
    }
}
