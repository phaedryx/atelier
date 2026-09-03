// ABOUTME: Detects installed tools, apps, and git repo status.
// ABOUTME: Shared across the app as an environment object with async background updates.

import OSLog
import SwiftUI

private let logger = Logger(subsystem: "atelier", category: "environment")

extension Worktree {
    struct State {
        var hasUncommittedChanges: Bool = false
        var hasUnpushedCommits: Bool = false
        var hasBranchCommits: Bool = false
        var hasRemote: Bool = false
    }
}

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

    /// Worktree path validity cache
    private var pathValidityCache: [String: Bool] = [:]

    /// Branch name cache per worktree path
    private var branchNameCache: [String: String] = [:]

    /// Git repo detection cache per project directory
    private var gitRepoCache: [String: Bool] = [:]

    /// Working tree state cache per worktree path
    private var worktreeStateCache: [String: Worktree.State] = [:]

    /// Active port cache per workstream ID
    private var activePortCache: Set<UUID> = []

    /// Task description cache per worktree path
    private var taskDescriptionCache: [String: String] = [:]

    /// GitHub remote detection cache per project directory (lightweight git check)
    private var githubRemoteCache: [String: Bool] = [:]

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
            let dir = project.directory
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

            if let lastRefresh = repoInfoTimestamps[project.directory],
               now.timeIntervalSince(lastRefresh) < minInterval
            {
                continue
            }

            repoInfoTimestamps[project.directory] = now
            let dir = project.directory
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

    func isPathValid(_ path: String?) -> Bool {
        guard let path else { return true }
        return pathValidityCache[path] ?? true
    }

    func branchName(for worktreePath: String?) -> String? {
        guard let path = worktreePath else { return nil }
        return branchNameCache[path]
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
        guard branchNameCache[worktreePath] != branch else { return }
        commitChanges {
            if let branch {
                branchNameCache[worktreePath] = branch
            } else {
                branchNameCache.removeValue(forKey: worktreePath)
            }
        }
    }

    // MARK: - Shortcut

    /// Fetched story per worktree path. Keyed by path, not story id, because
    /// `WorkstreamInfoView` receives `workingDirectory` but never the `Workstream`
    /// itself — the same reason `taskDescriptionCache` is keyed this way.
    private var shortcutStoryCache: [String: Shortcut.Story] = [:]
    /// Worktree path to story id, populated from the project list, which is the only
    /// place that knows the mapping.
    private var shortcutStoryIDs: [String: Int] = [:]
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
        shortcutStoryIDs[worktreePath] = id

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
        let stalePaths = Set(shortcutStoryIDs.keys).subtracting(livePaths)
        guard !stalePaths.isEmpty else { return }
        commitChanges {
            for path in stalePaths {
                shortcutStoryIDs.removeValue(forKey: path)
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
        guard let storyID = shortcutStoryIDs[worktreePath] else { return }

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
            guard shortcutStoryCache[worktreePath] != story else { return }
            commitChanges { shortcutStoryCache[worktreePath] = story }
        } catch {
            // Any cached copy deliberately stays on screen rather than blanking the tab,
            // but a revoked token or deleted story would otherwise be invisible — the
            // stale copy would keep rendering as though it were current.
            logger.warning("[Atelier] shortcut: story \(storyID, privacy: .public) refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    func isGitRepo(_ directory: String) -> Bool {
        gitRepoCache[directory] ?? false
    }

    func hasGitHubRemote(_ directory: String) -> Bool {
        githubRemoteCache[directory] ?? false
    }

    /// Browser-openable GitHub URL for a project directory.
    /// Prefers the canonical URL from `gh`, falls back to converting the git remote URL.
    func githubURL(for directory: String) -> URL? {
        if let ghURL = githubRepoCache[directory]?.url {
            return URL(string: ghURL)
        }
        if let remoteURL = repoInfoCache[directory]?.remoteURL {
            return GitHub.Operations.browserURL(from: remoteURL)
        }
        return nil
    }

    func worktreeState(for path: String) -> Worktree.State {
        worktreeStateCache[path] ?? Worktree.State()
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
            let state = Worktree.State(
                hasUncommittedChanges: Git.Operations.hasUncommittedChanges(at: path),
                hasUnpushedCommits: Git.Operations.hasUnpushedCommits(at: path),
                hasBranchCommits: Git.Operations.hasBranchCommits(at: path, projectPath: projectDir),
                hasRemote: Git.Operations.hasRemote(at: path)
            )
            await self.deferWorktreeStateUpdate(state, for: path)
        }
    }

    private func deferWorktreeStateUpdate(_ state: Worktree.State, for path: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.commitChanges {
                self.worktreeStateCache[path] = state
            }
        }
    }

    func hasActivePort(_ workstreamID: UUID) -> Bool {
        activePortCache.contains(workstreamID)
    }

    func taskDescription(for worktreePath: String?) -> String? {
        guard let path = worktreePath else { return nil }
        return taskDescriptionCache[path]
    }

    /// Returns IDs of projects whose directories no longer exist.
    var missingProjectIDs: Set<UUID> = []

    func refreshPathValidity(projects: [Project]) {
        Task.detached {
            var results: [String: Bool] = [:]
            var missing: Set<UUID> = []
            var gitRepoResults: [String: Bool] = [:]
            var githubRemoteResults: [String: Bool] = [:]
            var portResults: Set<UUID> = []
            var descriptionResults: [String: String] = [:]

            // Collect valid worktree paths that need git info
            var validPaths: [String] = []

            for project in projects {
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDir) && isDir.boolValue
                if !exists {
                    logger.warning("[Atelier] refreshPathValidity: project \(project.name, privacy: .public) directory MISSING: \(project.directory, privacy: .public)")
                    missing.insert(project.id)
                }

                gitRepoResults[project.directory] = Git.Operations.isGitRepo(at: project.directory)
                githubRemoteResults[project.directory] = GitHub.Operations.hasGitHubRemote(at: project.directory)

                for ws in project.workstreams {
                    if RunStateStore.loadValidated(for: ws.id)?.detectedPorts.isEmpty == false {
                        portResults.insert(ws.id)
                    }
                    guard let path = ws.worktreePath else { continue }
                    var wsIsDir: ObjCBool = false
                    let valid = FileManager.default.fileExists(atPath: path, isDirectory: &wsIsDir) && wsIsDir.boolValue
                    results[path] = valid
                    if valid {
                        validPaths.append(path)
                        let descURL = URL(fileURLWithPath: path)
                            .appendingPathComponent(".atelier-state/description")
                        if let data = try? Data(contentsOf: descURL),
                           let text = String(data: data, encoding: .utf8)
                        {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                descriptionResults[path] = trimmed
                            }
                        }
                    }
                }
            }

            // Map worktree paths to their project directory for state detection
            var worktreeToProject: [String: String] = [:]
            for project in projects {
                for ws in project.workstreams {
                    if let path = ws.worktreePath, validPaths.contains(path) {
                        worktreeToProject[path] = project.directory
                    }
                }
            }

            // Run git info calls in parallel
            let branches: [String: String] = await withTaskGroup(
                of: (String, String?).self
            ) { group in
                for path in validPaths {
                    group.addTask {
                        let info = Git.Operations.repoInfo(at: path)
                        return (path, info.branch)
                    }
                }
                var collected: [String: String] = [:]
                for await (path, branch) in group {
                    if let branch {
                        collected[path] = branch
                    }
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
                            hasUncommittedChanges: Git.Operations.hasUncommittedChanges(at: path),
                            hasUnpushedCommits: Git.Operations.hasUnpushedCommits(at: path),
                            hasBranchCommits: Git.Operations.hasBranchCommits(at: path, projectPath: projectDir),
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

            await MainActor.run {
                self.commitChanges {
                    self.pathValidityCache.merge(results) { _, new in new }
                    self.branchNameCache.merge(branches) { _, new in new }
                    self.missingProjectIDs = missing
                    self.gitRepoCache.merge(gitRepoResults) { _, new in new }
                    self.githubRemoteCache.merge(githubRemoteResults) { _, new in new }
                    self.worktreeStateCache.merge(worktreeStates) { _, new in new }
                    self.activePortCache = portResults
                    self.taskDescriptionCache = descriptionResults
                }
            }
        }
    }

    // MARK: - GitHub

    var ghAvailable: Bool {
        toolStatus.gh.isInstalled && toolStatus.ghAuthDetail != "Not authenticated"
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

    func clearBranchPR(for directory: String, branch: String) {
        commitChanges {
            githubBranchPRCache.removeValue(forKey: "\(directory)|\(branch)")
        }
    }

    func refreshGitHubInfo(for directory: String, branch: String? = nil) {
        guard ghAvailable, let ghPath = toolStatus.gh.path else { return }
        guard GitHub.Operations.hasGitHubRemote(at: directory) else { return }

        Task.detached {
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
            let prsByBranch = GitHub.PR.byBranch(prs)
            await MainActor.run {
                self.commitChanges {
                    for branch in branches {
                        let key = "\(directory)|\(branch)"
                        if let pr = prsByBranch[branch] {
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
        lastBranchPRRefresh = now

        guard ghAvailable, let ghPath = toolStatus.gh.path else { return }

        // Collect branches per project directory
        var projectBranches: [String: Set<String>] = [:]
        for project in projects {
            var branches: Set<String> = []
            for ws in project.workstreams {
                guard let path = ws.worktreePath,
                      let branch = branchNameCache[path] else { continue }
                branches.insert(branch)
            }
            if !branches.isEmpty {
                projectBranches[project.directory] = branches
            }
        }

        guard !projectBranches.isEmpty else { return }

        // Which branches already have a badge on screen. A branch missing from the bulk
        // result only warrants a targeted lookup if it had one — otherwise it is simply a
        // branch that has never been opened as a PR.
        var cachedKeys: Set<String> = []
        for (dir, branches) in projectBranches {
            for branch in branches where githubBranchPRCache["\(dir)|\(branch)"] != nil {
                cachedKeys.insert("\(dir)|\(branch)")
            }
        }

        Task.detached {
            // One gh call per project, now covering every PR state. That is what collapses
            // the open-then-merged two-phase lookup this used to need: a merged PR arrives
            // in the same response as an open one.
            var allPRs: [(String, [GitHub.PR])] = []
            await withTaskGroup(of: (String, [GitHub.PR]).self) { group in
                for (dir, _) in projectBranches {
                    group.addTask {
                        (dir, GitHub.Operations.recentPRs(ghPath: ghPath, at: dir, limit: 100))
                    }
                }
                for await result in group {
                    allPRs.append(result)
                }
            }

            var missing: [(dir: String, branch: String, key: String)] = []
            for (dir, prs) in allPRs {
                let branches = projectBranches[dir] ?? []
                let prsByBranch = GitHub.PR.byBranch(prs)

                await MainActor.run {
                    self.commitChanges {
                        for branch in branches {
                            let key = "\(dir)|\(branch)"
                            if let pr = prsByBranch[branch] {
                                self.githubBranchPRCache[key] = pr
                            } else if cachedKeys.contains(key) {
                                missing.append((dir: dir, branch: branch, key: key))
                            }
                        }
                    }
                }
            }

            // A branch with a badge that fell out of the bulk result is usually just older
            // than the 100 most recent PRs, so ask about it directly rather than blanking a
            // badge that is still correct. Only a lookup that finds nothing clears the cache.
            guard !missing.isEmpty else { return }
            await withTaskGroup(of: (String, GitHub.PR?).self) { group in
                for lookup in missing {
                    group.addTask {
                        (lookup.key, GitHub.Operations.prForBranch(ghPath: ghPath, at: lookup.dir, branch: lookup.branch))
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
    }
}
