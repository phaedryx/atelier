// ABOUTME: Detects installed tools, apps, and git repo status.
// ABOUTME: Shared across the app as an environment object with async background updates.

import OSLog
import SwiftUI

private let logger = Logger(subsystem: "atelier", category: "environment")

@MainActor
final class AppEnvironment: ObservableObject {
    // Published backing values are mutated through `commitChanges` so a batch of
    // cache updates produces a single `objectWillChange` notification.
    var toolStatus = ToolStatus()
    var installedTerminals: [AppInfo] = []
    var installedBrowsers: [AppInfo] = []
    var isDetecting = false

    // Cached repo info per directory, refreshed asynchronously
    private var repoInfoCache: [String: Git.RepoInfo] = [:]
    private var repoInfoTimestamps: [String: Date] = [:]

    /// Everything known about each worktree, keyed by worktree path.
    ///
    /// One value per worktree rather than one dictionary per fact. See
    /// `Worktree.Facts` for what is in it, what deliberately is not, and why.
    /// Written by `refreshPathValidity`'s sweep, by `refreshBranchName` and
    /// `refreshWorktreeState` for a single field each, and by
    /// `registerShortcutStory`; every one of those goes through `mutateFacts` or
    /// the sweep's own equality guard, so nothing publishes unless a value moved.
    private var factsCache: [String: Worktree.Facts] = [:]

    /// Git repo detection cache per project directory
    private var gitRepoCache: [String: Bool] = [:]

    /// GitHub remote detection cache per project directory (lightweight git check)
    private var githubRemoteCache: [String: Bool] = [:]

    /// Browser URL for each project's GitHub origin, keyed by the repository's home like
    /// `githubRemoteCache` and filled from the same git call in the same sweep. It exists
    /// because the other two sources cannot answer for a `.bare` container: `githubRepoCache`
    /// is only ever written by `refreshGitHubInfo`, which lives on views the sidebar does not
    /// draw, and `repoInfoCache` is keyed by the *checkout*, so a lookup by `directory` misses
    /// it outright. Between them a container-layout project had no GitHub URL until its
    /// overview had been opened — and none at all without `gh`.
    private var githubBrowserURLCache: [String: URL] = [:]

    // GitHub info cache
    private var githubRepoCache: [String: GitHub.RepoInfo] = [:]
    private var githubPRCache: [String: [GitHub.PR]] = [:]
    private var githubBranchPRCache: [String: GitHub.PR] = [:] // key: "dir|branch"

    /// Send a single `objectWillChange` notification around a batch of mutations.
    /// Callers should batch every coherent refresh cycle into one call so subscribers
    /// invalidate once per transaction rather than once per property.
    @discardableResult
    private func commitChanges<T>(_ body: () -> T) -> T {
        objectWillChange.send()
        return body()
    }

    func refresh() {
        commitChanges { isDetecting = true }
        Task.detached {
            let tools = ToolStatus.detect()
            let terminals = AppInfo.detectTerminals()
            let browsers = AppInfo.detectBrowsers()
            await MainActor.run {
                self.commitChanges {
                    self.toolStatus = tools
                    self.installedTerminals = terminals
                    self.installedBrowsers = browsers
                    self.isDetecting = false
                }
            }
        }
    }

    // MARK: - Origin Fetch

    private var lastOriginFetch: [String: Date] = [:]
    private static let originFetchInterval: TimeInterval = 120 // 2 minutes

    /// Fetch the default branch from origin for each project directory.
    /// Throttled to once every 2 minutes per project. Skips repos without
    /// a remote and fails silently on network errors.
    func fetchOrigin(projects: [Project]) {
        let now = Date()
        for project in projects {
            let dir = project.checkout
            if let lastFetch = lastOriginFetch[dir],
               now.timeIntervalSince(lastFetch) < Self.originFetchInterval
            {
                continue
            }
            lastOriginFetch[dir] = now
            Task.detached {
                Git.Operations.fetchDefaultBranch(at: dir)
            }
        }
    }

    // MARK: - Default Branch

    /// Lookups still in flight, so the workstreams of one project share a single
    /// probe rather than each starting their own.
    ///
    /// This is the half `Git.Operations`' own cache cannot provide: a lock
    /// serialises concurrent misses but does not merge them, so without this the
    /// launch fan-out — every workstream mounting at once — would resolve one
    /// directory N times before the first answer landed. The cached-value half
    /// lives in `Git.Operations.defaultBranch(at:)`, where callers that cannot
    /// reach a `@MainActor` type can also see it.
    ///
    /// Untested, and knowingly: pinning it needs a seam to count probes through,
    /// and the only honest one is injecting the git call, which would put a
    /// parameter on `defaultBranch(for:)` that exists for the test alone. The
    /// cache either side of it is pinned — see
    /// `Tests/AppEnvironmentDefaultBranchTests.swift` and
    /// `Tests/GitOperationsTests.swift`.
    private var defaultBranchTasks: [String: Task<String, Never>] = [:]

    /// This repository's default branch, off the main actor and de-duplicated.
    ///
    /// The caching and the never-cache-`"HEAD"` rule belong to
    /// `Git.Operations.defaultBranch(at:)`; this adds the two things a
    /// `@MainActor` caller needs on top — somewhere to run a blocking git probe
    /// that is not the main thread, and a way for concurrent callers to share one.
    func defaultBranch(for directory: String) async -> String {
        if let inFlight = defaultBranchTasks[directory] {
            return await inFlight.value
        }

        // Detached because `defaultBranch` is synchronous and blocks its thread
        // for the length of several child processes.
        let task = Task.detached(priority: .userInitiated) {
            Git.Operations.defaultBranch(at: directory)
        }
        defaultBranchTasks[directory] = task
        let branch = await task.value
        defaultBranchTasks.removeValue(forKey: directory)
        return branch
    }

    // MARK: - Repo Info

    func repoInfo(for directory: String) -> Git.RepoInfo? {
        repoInfoCache[directory]
    }

    func refreshRepoInfo(for directory: String) {
        // Skip if refreshed within the last 5 seconds
        if let lastRefresh = repoInfoTimestamps[directory],
           Date().timeIntervalSince(lastRefresh) < 5
        {
            return
        }
        repoInfoTimestamps[directory] = Date()

        Task.detached {
            let info = Git.Operations.repoInfo(at: directory)
            await MainActor.run {
                self.commitChanges {
                    self.repoInfoCache[directory] = info
                }
            }
        }
    }

    /// Refresh repo info for all tracked projects. Recently active projects
    /// refresh more often than stale ones.
    func refreshAllRepoInfo(projects: [Project]) {
        let now = Date()
        for project in projects {
            let age = now.timeIntervalSince(project.lastAccessedAt)
            let minInterval: TimeInterval = age < 300 ? 10 : 60 // 10s for recent, 60s for stale

            if let lastRefresh = repoInfoTimestamps[project.checkout],
               now.timeIntervalSince(lastRefresh) < minInterval
            {
                continue
            }

            repoInfoTimestamps[project.checkout] = now
            let dir = project.checkout
            Task.detached {
                let info = Git.Operations.repoInfo(at: dir)
                await MainActor.run {
                    self.commitChanges {
                        self.repoInfoCache[dir] = info
                    }
                }
            }
        }
    }

    // MARK: - Path Validity

    /// Everything known about one worktree, or nil for a path nothing has swept.
    ///
    /// The accessors below are thin wrappers over this. They are kept because
    /// each answers a question with a default a caller would otherwise have to
    /// remember — an unswept path is *valid*, not invalid — and because keeping
    /// them let the value type land without rewriting every reader in the same
    /// change.
    func facts(for worktreePath: String?) -> Worktree.Facts? {
        guard let path = worktreePath else { return nil }
        return factsCache[path]
    }

    func isPathValid(_ path: String?) -> Bool {
        guard let path else { return true }
        return facts(for: path)?.isPathValid ?? true
    }

    func branchName(for worktreePath: String?) -> String? {
        facts(for: worktreePath)?.branch
    }

    /// Apply one change to one worktree's facts, publishing only if it moved.
    ///
    /// The guard is outside `commitChanges` on purpose: that method sends
    /// `objectWillChange` as its first act, so an equality check inside it would
    /// publish and then decline to change anything — which is the churn this
    /// whole value exists to remove.
    ///
    /// An absent entry is compared as a default `Facts` rather than as nil, so a
    /// write that lands nothing new — `refreshBranchName` finding no branch for a
    /// path nothing has swept — creates no entry and publishes nothing. Absence
    /// and a default value read identically through every accessor above.
    private func mutateFacts(for worktreePath: String, _ body: (inout Worktree.Facts) -> Void) {
        let existing = factsCache[worktreePath] ?? Worktree.Facts()
        var facts = existing
        body(&facts)
        guard facts != existing else { return }
        commitChanges { factsCache[worktreePath] = facts }
    }

    /// Re-read the branch for a single worktree and publish it if it changed.
    ///
    /// Deliberately narrow: this runs off a filesystem event from
    /// `Worktree.HeadWatcher`, which fires on any git activity in the worktree,
    /// so it must stay one `git rev-parse` for one path — not the full
    /// `refreshPathValidity` sweep, which is roughly nine subprocesses per
    /// worktree across every project.
    ///
    /// The cache write — and the `objectWillChange` it carries — happens only
    /// when the branch actually moved, so an incidental event redraws nothing.
    ///
    /// Async and `@MainActor` on purpose. A completion closure would have to
    /// cross into a detached task, and so would a weakly captured `self`; both
    /// are exactly what strict concurrency objects to. Isolating the whole
    /// method to the main actor means the only value crossing an isolation
    /// boundary is the `String?` coming back out of the subprocess, and the
    /// caller sequences its follow-up work with `await`.
    ///
    /// The caller must still act even when this publishes nothing — the 15s
    /// poll writes the same cache and can land the new branch first.
    @MainActor
    func refreshBranchName(for worktreePath: String) async {
        let branch = await Task.detached { Git.Operations.currentBranch(at: worktreePath) }.value
        // Nil keeps the last known branch — the rule `Worktree.Facts.Swept`
        // states and `applying` enforces for the sweep's own answer, applied
        // here so the single-field writers cannot contradict it. `currentBranch`
        // answers nil for a **detached HEAD**, which is what the middle of a
        // rebase or a bisect looks like, and this fires off the HeadWatcher on
        // any git activity in the worktree — so an unconditional assignment
        // wiped the branch out of the sidebar label, the PR badge and Copy
        // Branch Name the moment a rebase started, and left them empty until the
        // next successful probe.
        guard let branch else { return }
        mutateFacts(for: worktreePath) { $0.branch = branch }
    }

    /// `refreshBranchName`'s wider sibling: one `repoInfo`, for the branch *and*
    /// the working tree's cleanliness.
    ///
    /// `WorkstreamInfoView` needs both the moment it appears, and the sweep that
    /// normally supplies cleanliness runs on a fifteen-second timer — so waiting
    /// for it would render "State unknown" on a tab the user has just opened.
    /// That tab used to run this same `repoInfo` itself and hold the answer in
    /// its own `@State`, which is what made the branch there a second, quietly
    /// divergent copy of the one in this cache.
    ///
    /// Deliberately *not* what `Worktree.HeadWatcher` calls: that fires on any
    /// git activity in a worktree, and `repoInfo` is several subprocesses where
    /// `refreshBranchName`'s `rev-parse` is one.
    @MainActor
    func refreshGitFacts(for worktreePath: String) async {
        let info = await Task.detached { Git.Operations.repoInfo(at: worktreePath) }.value
        mutateFacts(for: worktreePath) {
            // Carried forward when nil, for the reason `refreshBranchName`
            // states: a detached HEAD is not "this worktree has no branch".
            if let branch = info.branch {
                $0.branch = branch
            }
            $0.cleanliness = Worktree.Cleanliness(isDirty: info.isDirty, isDirtyUnknown: info.isDirtyUnknown)
        }
    }

    // MARK: - Shortcut

    /// Fetched story per worktree path. Keyed by path, not story id, because
    /// `WorkstreamInfoView` receives `workingDirectory` but never the `Workstream`
    /// itself — the same reason `Worktree.Facts` is keyed this way.
    ///
    /// Only the story *id* lives in `Worktree.Facts`; the fetched story stays
    /// here because it is the one fact on this path that comes off the network
    /// rather than off the disk, and it is reconciled with the id by
    /// `pruneShortcutStories`.
    private var shortcutStoryCache: [String: Shortcut.Story] = [:]
    /// Workflow states are shared across all stories and change rarely, so they are
    /// fetched once per launch rather than per story.
    private var shortcutWorkflows: [Shortcut.Workflow] = []

    func shortcutStory(for worktreePath: String?) -> Shortcut.Story? {
        guard let worktreePath else { return nil }
        return shortcutStoryCache[worktreePath]
    }

    /// The story's workflow state name, e.g. "In Progress". Nil until the workflow
    /// list has been fetched, since stories carry only a state id.
    func shortcutStateName(for worktreePath: String?) -> String? {
        guard let story = shortcutStory(for: worktreePath) else { return nil }
        return shortcutWorkflows.stateName(for: story.workflowStateID)
    }

    /// Stories fetched before their worktree exists, held by story id until a path shows up.
    ///
    /// Creation fetches the story to learn its branch name, so the description is already
    /// in hand — but the worktree path, which is how the cache is keyed, is only known once
    /// `git worktree add` finishes. Staging keeps that first fetch instead of discarding it
    /// and round-tripping again when the info tab opens.
    private var shortcutStoryStaging: [Int: Shortcut.Story] = [:]

    func stageShortcutStory(_ story: Shortcut.Story) {
        shortcutStoryStaging[story.id] = story
    }

    func registerShortcutStory(id: Int, for worktreePath: String) {
        mutateFacts(for: worktreePath) { $0.shortcutStoryID = id }

        // Promote the staged copy now that there is a path to key it by. The removal happens
        // before the equality guard: leaving it after meant a re-registration with the story
        // already cached returned early and stranded the staged copy for the session.
        guard let staged = shortcutStoryStaging.removeValue(forKey: id) else { return }
        guard shortcutStoryCache[worktreePath] != staged else { return }
        commitChanges { shortcutStoryCache[worktreePath] = staged }
    }

    /// Drops cache entries for worktrees that no longer exist.
    ///
    /// Unlike `taskDescriptionCache`, which is rebuilt wholesale on every refresh and so
    /// prunes itself, these are only ever inserted into. Without this, archiving a
    /// Shortcut workstream and creating a plain one that reuses the path — likelier now
    /// that worktree directories are named after the branch — renders the old story.
    func pruneShortcutStories(keeping livePaths: Set<String>) {
        let carryingAStory = factsCache.filter { $0.value.shortcutStoryID != nil }.keys
        let stalePaths = Set(carryingAStory).subtracting(livePaths)
        guard !stalePaths.isEmpty else { return }
        commitChanges {
            for path in stalePaths {
                factsCache[path]?.shortcutStoryID = nil
                shortcutStoryCache.removeValue(forKey: path)
            }
        }
    }

    /// Re-reads one story and publishes it only when it changed.
    ///
    /// Shaped after `refreshBranchName(for:)`: `@MainActor` with the network work
    /// awaited off it, so the only value crossing an isolation boundary is the decoded
    /// story. The info tab calls this on every appearance, so the equality guard is what
    /// keeps a revisit from redrawing.
    @MainActor
    func refreshShortcutStory(for worktreePath: String) async {
        guard let storyID = factsCache[worktreePath]?.shortcutStoryID else { return }
        await refreshShortcutStory(for: worktreePath, storyID: storyID)
    }

    /// The same refresh, for a caller that already holds the story id.
    ///
    /// `get_shortcut_story` reads the id off `Workstream.shortcutStoryID`, which
    /// is persisted, rather than off `factsCache`, which is filled by
    /// `ContentView.syncShortcutStoryIDs` — so the sweep having run or not is
    /// something the tool must not depend on. Going through the version above
    /// would have made a workstream whose facts had not been synced yet report
    /// "this workstream has no Shortcut story", which is the wrong answer and an
    /// unfalsifiable one.
    ///
    /// **Returns whether the story fetch itself succeeded**, which is not the
    /// same as whether anything was published — an unchanged story is a
    /// successful fetch that writes nothing. `get_shortcut_story` needs the
    /// distinction because the `catch` below deliberately *keeps* any cached
    /// copy: a story cached at creation by `registerShortcutStory` would
    /// otherwise be handed to an agent as a current answer after the token was
    /// revoked or the story deleted. The tab ignores it and goes on rendering
    /// the stale copy, which is the right call for a pane the user can see is
    /// not moving.
    @MainActor @discardableResult
    func refreshShortcutStory(for worktreePath: String, storyID: Int) async -> Bool {
        if shortcutWorkflows.isEmpty {
            do {
                let workflows = try await Shortcut.Client().workflows()
                commitChanges { shortcutWorkflows = workflows }
            } catch {
                // Only costs the state name; the story itself still renders.
                logger.warning("[Atelier] shortcut: workflows fetch failed: \(String(describing: error), privacy: .public)")
            }
        }

        do {
            let story = try await Shortcut.Client().story(id: storyID)
            if shortcutStoryCache[worktreePath] != story {
                commitChanges { shortcutStoryCache[worktreePath] = story }
            }
            return true
        } catch {
            // Any cached copy deliberately stays on screen rather than blanking the tab,
            // but a revoked token or deleted story would otherwise be invisible — the
            // stale copy would keep rendering as though it were current.
            logger.warning("[Atelier] shortcut: story \(storyID, privacy: .public) refresh failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Whether Shortcut's workflow list has been fetched this launch.
    ///
    /// `shortcutStateName` returns nil for two reasons — no workflow list, or a
    /// story whose state id is not in the list we have — and they are different
    /// facts. Naming the wrong one is the mistake `KeychainTokenStore.ReadOutcome`
    /// exists to prevent, one layer down.
    var hasShortcutWorkflows: Bool {
        !shortcutWorkflows.isEmpty
    }

    func isGitRepo(_ directory: String) -> Bool {
        gitRepoCache[directory] ?? false
    }

    func hasGitHubRemote(_ directory: String) -> Bool {
        githubRemoteCache[directory] ?? false
    }

    /// Browser-openable GitHub URL for a project directory.
    /// Prefers the canonical URL from `gh`, falls back to converting the git remote URL.
    ///
    /// The middle branch is the one that answers for every project: it is filled by the
    /// routine path-validity sweep, keyed by the same `directory` callers ask with, and needs
    /// no `gh`. The `repoInfoCache` branch is kept because it is the freshest answer for an
    /// ordinary clone, where `directory` and `checkout` are the same string — but it is
    /// nothing to rely on, since in the container layout that key is never written.
    func githubURL(for directory: String) -> URL? {
        if let ghURL = githubRepoCache[directory]?.url {
            return URL(string: ghURL)
        }
        if let fromRemote = githubBrowserURLCache[directory] {
            return fromRemote
        }
        if let remoteURL = repoInfoCache[directory]?.remoteURL {
            return GitHub.Operations.browserURL(from: remoteURL)
        }
        return nil
    }

    func worktreeState(for path: String) -> Worktree.State {
        facts(for: path)?.state ?? Worktree.State()
    }

    private var worktreeStateTimestamps: [String: Date] = [:]
    private static let worktreeStateRefreshInterval: TimeInterval = 5

    /// Refresh working tree state for a single worktree path. Throttled to once
    /// every `worktreeStateRefreshInterval` seconds per path so chatty terminal
    /// activity doesn't spawn git subprocesses on every keystroke.
    func refreshWorktreeState(for worktreePath: String, projectDirectory: String) {
        let now = Date()
        if let last = worktreeStateTimestamps[worktreePath],
           now.timeIntervalSince(last) < Self.worktreeStateRefreshInterval
        {
            return
        }
        worktreeStateTimestamps[worktreePath] = now

        let path = worktreePath
        let projectDir = projectDirectory
        Task.detached {
            // One dirtiness probe, feeding both fields — the same rule the sweep
            // follows, stated there. This path runs no `repoInfo`, so the probe
            // stays; what it must not do is write only half the pair and leave
            // `cleanliness` reading whatever the last sweep found.
            let dirty = Git.Operations.hasUncommittedChanges(at: path)
            let state = Worktree.State(
                // Advisory UI only — this picks which quick action is offered, and
                // unknown offers nothing. Both actions gated on these spawn work rather
                // than a dialog: `.commit` runs `claude -p "Stage and commit all
                // changes"`, so suggesting it on a tree that may be clean spends an agent
                // run to find nothing — and it sits ahead of push and openPR in the
                // chain, so it would keep doing that. Not surfacing a shortcut costs the
                // user a menu; nothing is lost or hidden.
                hasUncommittedChanges: dirty ?? false,
                hasUnpushedCommits: Git.Operations.hasUnpushedCommits(at: path) ?? false,
                hasBranchCommits: Git.Operations.hasBranchCommits(at: path, projectPath: projectDir) ?? false,
                hasRemote: Git.Operations.hasRemote(at: path)
            )
            await self.deferWorktreeStateUpdate(
                state,
                cleanliness: Worktree.Cleanliness(isDirty: dirty ?? false, isDirtyUnknown: dirty == nil),
                for: path
            )
        }
    }

    private func deferWorktreeStateUpdate(
        _ state: Worktree.State,
        cleanliness: Worktree.Cleanliness,
        for path: String
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.mutateFacts(for: path) {
                $0.state = state
                $0.cleanliness = cleanliness
            }
        }
    }

    /// Whether the workstream at this worktree has a detected listening port.
    ///
    /// Re-keyed from the workstream's UUID to its worktree path when the facts
    /// were folded into one value. The one consequence: a workstream with no
    /// `worktreePath` — which the sweep already skips for every other fact —
    /// no longer reports a port. There is nothing for one to be detected in.
    func hasActivePort(for worktreePath: String?) -> Bool {
        facts(for: worktreePath)?.hasActivePort ?? false
    }

    func taskDescription(for worktreePath: String?) -> String? {
        facts(for: worktreePath)?.taskDescription
    }

    /// Returns IDs of projects whose directories no longer exist.
    var missingProjectIDs: Set<UUID> = []

    /// When the sweep currently in flight started, or nil when none is.
    private var pathValiditySweepStartedAt: Date?

    /// The projects a request that arrived mid-sweep wanted swept, so it is
    /// coalesced into one follow-up rather than dropped. Only the newest is kept:
    /// each is a full snapshot, so an older one has nothing the newer lacks.
    private var pendingPathValidityProjects: [Project]?

    /// How long a sweep may be believed to be in flight before another is admitted
    /// regardless. Comfortably above `ProcessRunner.Timeout.local` (60s), which
    /// bounds every probe a sweep makes, so this cannot fire for a sweep that is
    /// merely slow — only for one whose completion never arrived.
    ///
    /// The ceiling is the point of using a timestamp rather than a bool. A flag
    /// cleared in the completion block fails in the worst available direction: a
    /// detached task that dies before reaching it would disable the 15-second
    /// sweep for the rest of the session, which is a worse bug than the stacking
    /// this prevents.
    static let pathValiditySweepCeiling: TimeInterval = 90

    /// Whether a new sweep may start, given when the one believed to be in flight
    /// began. Pure and `static` so the ceiling's behaviour can be pinned without
    /// hanging a real sweep to produce the state it guards.
    static func admitsPathValiditySweep(inFlightSince startedAt: Date?, now: Date = Date()) -> Bool {
        guard let startedAt else { return true }
        return now.timeIntervalSince(startedAt) >= pathValiditySweepCeiling
    }

    /// Re-reads every project's and worktree's on-disk state. One sweep at a time.
    ///
    /// The re-entrancy guard exists because the 15-second timer in `ContentView`
    /// spawned a fresh `Task.detached` unconditionally, so a sweep that outlived
    /// its own period stacked — and each sweep fans a blocking `ProcessRunner`
    /// capture out per worktree, every one of which parks the thread it runs on
    /// for the life of its child. Stacked sweeps multiply that occupancy by
    /// however many ticks the slow one spans.
    func refreshPathValidity(projects: [Project]) {
        guard Self.admitsPathValiditySweep(inFlightSince: pathValiditySweepStartedAt) else {
            // Deferred rather than dropped: `attachWorktreePath` and
            // `.projectCreated` call this for a path that just appeared, and making
            // them wait out a tick of the timer would show a stale row for a
            // workstream the user is looking at.
            pendingPathValidityProjects = projects
            return
        }
        let startedAt = Date()
        pathValiditySweepStartedAt = startedAt
        // Superseded: this sweep carries a newer snapshot than anything deferred,
        // so a pending request left behind by a sweep that died before its
        // completion block has nothing to add. Clearing it here rather than only
        // on completion is what keeps a stranded pending snapshot unreachable
        // instead of merely unlikely — the same reason the guard is a timestamp
        // and not a flag.
        pendingPathValidityProjects = nil

        Task.detached {
            // One entry per worktree path the sweep sees, folded over what is
            // already known at the end. Six dictionaries used to be assembled
            // here, and the reason that mattered is not tidiness: two of them
            // were assigned wholesale and four were merged, so which rule a
            // given fact followed lived only in the shape of the write.
            // `Worktree.Facts.Swept` states each rule at the field.
            var swept: [String: Worktree.Facts.Swept] = [:]
            var missing: Set<UUID> = []
            var gitRepoResults: [String: Bool] = [:]
            var githubRemoteResults: [String: Bool] = [:]
            var githubBrowserURLResults: [String: URL] = [:]

            // Collect valid worktree paths that need git info
            var validPaths: [String] = []

            for project in projects {
                // Both, because they are different failures with the same
                // symptom. The repository's home going missing takes everything
                // with it; a `.bare` container losing the checkout that
                // represents it leaves the container standing while every
                // work-tree read against it fails. Before `directory` meant the
                // container, this one check covered both by accident.
                let exists = FileManager.default.isDirectory(at: URL(fileURLWithPath: project.directory))
                    && FileManager.default.isDirectory(at: URL(fileURLWithPath: project.checkout))
                if !exists {
                    logger.warning("[Atelier] refreshPathValidity: project \(project.name, privacy: .public) directory MISSING: \(project.directory, privacy: .public) checkout: \(project.checkout, privacy: .public)")
                    missing.insert(project.id)
                }

                // Keyed by the repository's home, not its checkout. Both probes
                // need only a git directory — the container has a `.git` file
                // and a remote — and `TerminalContainerView` reads these caches
                // back with the project directory it was handed, having no
                // checkout of its own to pass. Same for every `github*` cache
                // below. `repoInfo` is the exception, and is keyed by the
                // checkout, because `git status` in a container fails outright.
                gitRepoResults[project.directory] = Git.Operations.isGitRepo(at: project.directory)
                // One `git remote get-url` answers both: whether this is a GitHub project,
                // and where it lives in a browser. Asking `gh` for the second is what left
                // the sidebar without either until some other view happened to appear.
                let githubRemote = GitHub.Operations.githubRemoteURL(at: project.directory)
                githubRemoteResults[project.directory] = githubRemote != nil
                githubBrowserURLResults[project.directory] = githubRemote
                    .flatMap(GitHub.Operations.browserURL(from:))

                for ws in project.workstreams {
                    guard let path = ws.worktreePath else { continue }
                    let hasPort = RunState.Store.loadValidated(for: ws.id)?.detectedPorts.isEmpty == false
                    var wsIsDir: ObjCBool = false
                    let valid = FileManager.default.fileExists(atPath: path, isDirectory: &wsIsDir) && wsIsDir.boolValue
                    var entry = Worktree.Facts.Swept(isPathValid: valid, hasActivePort: hasPort)
                    if valid {
                        validPaths.append(path)
                        let descURL = URL(fileURLWithPath: path)
                            .appendingPathComponent(".atelier-state/description")
                        if let data = try? Data(contentsOf: descURL),
                           let text = String(data: data, encoding: .utf8)
                        {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                entry.taskDescription = trimmed
                            }
                        }
                    }
                    swept[path] = entry
                }
            }

            // Map worktree paths to their project directory for state detection
            var worktreeToProject: [String: String] = [:]
            for project in projects {
                for ws in project.workstreams {
                    if let path = ws.worktreePath, validPaths.contains(path) {
                        worktreeToProject[path] = project.checkout
                    }
                }
            }

            // Run git info calls in parallel.
            //
            // Cleanliness is free here: this `repoInfo` call already computes it
            // and used to throw it away, keeping only the branch. Taking it is
            // what lets the Info tab stop shelling out for the same answer — and
            // it arrives with `isDirtyUnknown` intact, which that tab's own
            // probe was collapsing into a green "Clean".
            let probes: [String: (branch: String?, cleanliness: Worktree.Cleanliness)] = await withTaskGroup(
                of: (String, String?, Worktree.Cleanliness).self
            ) { group in
                for path in validPaths {
                    group.addTask {
                        let info = Git.Operations.repoInfo(at: path)
                        return (
                            path,
                            info.branch,
                            Worktree.Cleanliness(isDirty: info.isDirty, isDirtyUnknown: info.isDirtyUnknown)
                        )
                    }
                }
                var collected: [String: (branch: String?, cleanliness: Worktree.Cleanliness)] = [:]
                for await (path, branch, cleanliness) in group {
                    collected[path] = (branch, cleanliness)
                }
                return collected
            }

            // Compute worktree state in parallel
            let worktreeStates: [String: Worktree.State] = await withTaskGroup(
                of: (String, Worktree.State).self
            ) { group in
                for (path, projectDir) in worktreeToProject {
                    group.addTask {
                        let state = Worktree.State(
                            // Filled in from `probes` below rather than probed here. It
                            // is the same question `repoInfo`'s `isDirty` already
                            // answered — the same `git status --porcelain
                            // --ignore-submodules=dirty` — so asking twice was a second
                            // spawn per worktree per tick whose answers could *disagree*,
                            // and did: the Info tab renders the `cleanliness` half and
                            // the quick-action menu renders this one.
                            hasUncommittedChanges: false,
                            hasUnpushedCommits: Git.Operations.hasUnpushedCommits(at: path) ?? false,
                            hasBranchCommits: Git.Operations.hasBranchCommits(at: path, projectPath: projectDir) ?? false,
                            hasRemote: Git.Operations.hasRemote(at: path)
                        )
                        return (path, state)
                    }
                }
                var collected: [String: Worktree.State] = [:]
                for await (path, state) in group {
                    collected[path] = state
                }
                return collected
            }

            // Fold the two parallel probes back onto the entries they belong to.
            for (path, probe) in probes {
                swept[path]?.branch = probe.branch
                swept[path]?.cleanliness = probe.cleanliness
            }
            for (path, state) in worktreeStates {
                var state = state
                // The one dirtiness answer, taken from the `repoInfo` the probe
                // group already ran. Folded in here rather than awaited inside the
                // state group, so the two groups stay concurrent — sequencing them
                // would turn a max() into a sum, per worktree, on a fifteen-second
                // timer.
                //
                // `.unknown` maps to false, which is the mapping the deleted
                // `?? false` made and for the reason stated where this used to be
                // probed: this is advisory UI that picks which quick action is
                // offered, both offers spawn work rather than a dialog, and unknown
                // offering nothing costs the user a menu item.
                state.hasUncommittedChanges = probes[path]?.cleanliness == .dirty
                swept[path]?.state = state
            }
            let sweptFacts = swept

            await MainActor.run {
                let updatedFacts = Worktree.Facts.applying(sweptFacts, to: self.factsCache)
                var gitRepos = self.gitRepoCache
                gitRepos.merge(gitRepoResults) { _, new in new }
                var githubRemotes = self.githubRemoteCache
                githubRemotes.merge(githubRemoteResults) { _, new in new }
                var githubBrowserURLs = self.githubBrowserURLCache
                githubBrowserURLs.merge(githubBrowserURLResults) { _, new in new }

                // Compared before publishing, not inside `commitChanges` — which
                // sends `objectWillChange` as its first act. The sweep runs every
                // fifteen seconds and almost always finds the world unchanged, so
                // an unconditional publish redrew every row in the app on a timer.
                let changed = updatedFacts != self.factsCache
                    || missing != self.missingProjectIDs
                    || gitRepos != self.gitRepoCache
                    || githubRemotes != self.githubRemoteCache
                    || githubBrowserURLs != self.githubBrowserURLCache
                if changed {
                    self.commitChanges {
                        self.factsCache = updatedFacts
                        self.missingProjectIDs = missing
                        self.gitRepoCache = gitRepos
                        self.githubRemoteCache = githubRemotes
                        self.githubBrowserURLCache = githubBrowserURLs
                    }
                }
                // Compared rather than assigned nil: a sweep admitted past the
                // ceiling has already claimed the slot, and a late completion from
                // the sweep it replaced must not release it.
                if self.pathValiditySweepStartedAt == startedAt {
                    self.pathValiditySweepStartedAt = nil
                }
                if let pending = self.pendingPathValidityProjects {
                    self.pendingPathValidityProjects = nil
                    self.refreshPathValidity(projects: pending)
                }
            }
        }
    }

    // MARK: - GitHub

    var ghAvailable: Bool {
        toolStatus.gh.isInstalled && toolStatus.ghAuthenticated
    }

    func githubRepo(for directory: String) -> GitHub.RepoInfo? {
        githubRepoCache[directory]
    }

    func githubPRs(for directory: String) -> [GitHub.PR] {
        githubPRCache[directory] ?? []
    }

    func githubPR(for directory: String, branch: String) -> GitHub.PR? {
        githubBranchPRCache["\(directory)|\(branch)"]
    }

    /// The pull request for whatever branch a worktree currently holds.
    ///
    /// The composition of the two lookups, in one place. It was written out
    /// verbatim — `branch.flatMap { appEnv.githubPR(for: dir, branch: $0) }` — at
    /// six call sites, which is what a fact split across two differently-keyed
    /// caches costs its readers.
    ///
    /// The PR itself stays keyed by `"dir|branch"` rather than moving into
    /// `Worktree.Facts`, because `ProjectOverviewView`'s worktree list renders a
    /// badge for worktrees that are not workstreams at all — rows a path-keyed
    /// cache filled from `project.workstreams` can never cover. That row asks
    /// `githubPR(for:branch:)` directly, and is the one caller that should.
    func pullRequest(forWorktree worktreePath: String?, in projectDirectory: String) -> GitHub.PR? {
        guard let branch = branchName(for: worktreePath) else { return nil }
        return githubPR(for: projectDirectory, branch: branch)
    }

    func clearBranchPR(for directory: String, branch: String) {
        commitChanges {
            githubBranchPRCache.removeValue(forKey: "\(directory)|\(branch)")
        }
    }

    func refreshGitHubInfo(for directory: String, branch: String? = nil) {
        guard ghAvailable, let ghPath = toolStatus.gh.path else { return }

        Task.detached {
            // `hasGitHubRemote` spawns `git remote get-url` synchronously, so it
            // belongs inside the detached task — checking it above blocked the
            // main actor on a subprocess for every refresh.
            guard GitHub.Operations.hasGitHubRemote(at: directory) else { return }

            let repo = GitHub.Operations.repoInfo(ghPath: ghPath, at: directory)
            let prs = GitHub.Operations.openPRs(ghPath: ghPath, at: directory)
            // One call now covers every state, so the old open-then-merged fallback is gone.
            let branchPR = branch.flatMap {
                GitHub.Operations.prForBranch(ghPath: ghPath, at: directory, branch: $0)
            }

            await MainActor.run {
                self.commitChanges {
                    if let repo {
                        self.githubRepoCache[directory] = repo
                    }
                    self.githubPRCache[directory] = prs
                    if let branch, let pr = branchPR {
                        self.githubBranchPRCache["\(directory)|\(branch)"] = pr
                    }
                }
            }
        }
    }

    // MARK: - Branch PR Refresh

    private var lastBranchPRRefresh: Date = .distantPast

    /// Refresh PRs for all workstream branches. One gh call per project.
    /// Populate the branch PR cache for a set of branches in a single `gh` call.
    func refreshBranchPRs(for directory: String, branches: Set<String>) {
        guard ghAvailable, let ghPath = toolStatus.gh.path, !branches.isEmpty else { return }
        Task.detached {
            let prs = GitHub.Operations.recentPRs(ghPath: ghPath, at: directory, limit: 100)
            await self.reconcileBranchPRs(
                directory: directory,
                branches: branches,
                prsByBranch: GitHub.PR.byBranch(prs),
                ghPath: ghPath
            )
        }
    }

    /// Fold one project's bulk `pr list` result into the branch PR cache.
    ///
    /// Shared by both refreshers because the interesting decision is the one they
    /// disagreed about: what a branch's *absence* from the bulk result means. It means
    /// almost nothing. `recentPRs` asks for the 100 most recent PRs in any state, so in a
    /// busy repository a long-lived workstream's PR falls out of that window while still
    /// being the live PR for its branch. Blanking on absence put a **Create PR** action
    /// (`GitHubActionMenu.primaryAction`, which branches on `prState == nil`) on a branch
    /// that already had one — and it was sticky, because the only thing that would have
    /// restored the badge was a targeted lookup this refresher never made.
    ///
    /// So absence is a question, not an answer: a branch that has a badge gets asked about
    /// directly with `prForBranch`, and only a lookup that comes back empty clears the
    /// cache. A branch with no badge and no bulk hit needs no lookup at all — it is a
    /// branch nobody has opened a PR for.
    ///
    /// `nonisolated` because the `gh` calls must not run on the main actor; every cache
    /// touch is inside a `MainActor.run`.
    private nonisolated func reconcileBranchPRs(
        directory: String,
        branches: Set<String>,
        prsByBranch: [String: GitHub.PR],
        ghPath: String
    ) async {
        // Which branches the bulk result did not cover *and* still show a badge. Read here
        // rather than snapshotted before the network hop, so a PR that arrived from
        // `refreshGitHubInfo` while the hop was in flight is defended too.
        let unanswered: [(branch: String, key: String)] = await MainActor.run {
            var unanswered: [(branch: String, key: String)] = []
            self.commitChanges {
                for branch in branches {
                    let key = "\(directory)|\(branch)"
                    if let pr = prsByBranch[branch] {
                        self.githubBranchPRCache[key] = pr
                    } else if self.githubBranchPRCache[key] != nil {
                        unanswered.append((branch: branch, key: key))
                    }
                }
            }
            return unanswered
        }

        guard !unanswered.isEmpty else { return }

        await withTaskGroup(of: (String, GitHub.PR?).self) { group in
            for lookup in unanswered {
                group.addTask {
                    (lookup.key, GitHub.Operations.prForBranch(ghPath: ghPath, at: directory, branch: lookup.branch))
                }
            }
            for await (key, pr) in group {
                await MainActor.run {
                    self.commitChanges {
                        if let pr {
                            self.githubBranchPRCache[key] = pr
                        } else {
                            self.githubBranchPRCache.removeValue(forKey: key)
                        }
                    }
                }
            }
        }
    }

    /// Throttled to run at most every 30 seconds.
    func refreshAllBranchPRs(projects: [Project]) {
        let now = Date()
        guard now.timeIntervalSince(lastBranchPRRefresh) >= 30 else { return }

        guard ghAvailable, let ghPath = toolStatus.gh.path else { return }

        // Collect branches per project directory
        var projectBranches: [String: Set<String>] = [:]
        for project in projects {
            var branches: Set<String> = []
            for ws in project.workstreams {
                guard let path = ws.worktreePath,
                      let branch = factsCache[path]?.branch else { continue }
                branches.insert(branch)
            }
            if !branches.isEmpty {
                projectBranches[project.directory] = branches
            }
        }

        guard !projectBranches.isEmpty else { return }

        // Stamped only once a refresh is actually going out. Stamping above the
        // guards burned the whole 30s window on a call that did nothing — which
        // is every call made before tool detection finishes at launch.
        lastBranchPRRefresh = now

        Task.detached {
            // One gh call per project, now covering every PR state. That is what collapses
            // the open-then-merged two-phase lookup this used to need: a merged PR arrives
            // in the same response as an open one.
            //
            // Each project's result is reconciled as it lands, in its own child task, so one
            // project's targeted follow-up lookups do not hold up another project's badges.
            await withTaskGroup(of: Void.self) { group in
                for (dir, branches) in projectBranches {
                    group.addTask {
                        let prs = GitHub.Operations.recentPRs(ghPath: ghPath, at: dir, limit: 100)
                        await self.reconcileBranchPRs(
                            directory: dir,
                            branches: branches,
                            prsByBranch: GitHub.PR.byBranch(prs),
                            ghPath: ghPath
                        )
                    }
                }
            }
        }
    }
}
