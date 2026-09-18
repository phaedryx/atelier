// ABOUTME: Creates a workstream from a non-UI caller, by posting the same notifications the sidebar posts.
// ABOUTME: The read half of the seam — resolving ATELIER_PROJECT_DIR to a project — is why this needs a bridge.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "workstream-launcher")

extension Workstream {
    /// Workstream creation for a caller that is not a SwiftUI view.
    ///
    /// **The write half needs no bridge.** `.workstreamCreated`,
    /// `.workstreamWorktreeReady` and `.workstreamCreationFailed` are declared on
    /// `Notification.Name` in `ContentView.swift` and already have two producers
    /// (`ProjectSidebar.launchWorkstream` and `ProjectOverviewView`), so a third
    /// is not a new pattern. Posting them gets append-and-persist, path storage,
    /// the HeadWatcher/agent-state/Shortcut refreshes, and — the part that
    /// matters most — `Initialization.Runner.run`, which runs the project's
    /// `initialization.yaml` steps. There is deliberately one path into that
    /// runner and this type reaches it by *not* calling it: a second call site
    /// would be a second creation path, and the list above is what the first one
    /// already remembers to do. Do not add an `Initialization.Runner.run` call
    /// here.
    ///
    /// **The read half is what needs a bridge.** `IPC.Service` is an actor that
    /// only ever compares `ClientIdentity.projectDirectory` strings for
    /// same-project scoping; it never resolves a `Project`. Creating a workstream
    /// needs the project's id, name, and *both* of its paths, plus the existing
    /// workstream names to generate or validate against. `projectList` is that
    /// bridge, and it is the shape `AgentNudge` and `PromptInjector` already use:
    /// a `@MainActor` singleton holding a `weak var` that `ContentView` sets in
    /// `.onAppear`, because the list is a `@StateObject` there rather than a
    /// singleton.
    @MainActor
    final class Launcher {
        /// The instance `ContentView` injects into, and therefore the only one
        /// with a live bridge. The IPC handler must use this rather than
        /// constructing a `Launcher`; a fresh instance has a nil `projectList`
        /// and every launch reports `.bridgeUnavailable`. Tests construct their
        /// own precisely to control that.
        static let shared = Launcher()

        /// Set by `ContentView` alongside `AgentNudge.shared.surfaceCache`.
        weak var projectList: ProjectList?

        init() {}

        /// What a non-UI caller needs to know about the project it named.
        ///
        /// `checkout` and `directory` are both here and neither is the "project
        /// path". `Git.Operations.createWorktree` needs a work tree, so it takes
        /// `checkout`; everything that locates an `execution.process-compose.yaml` or a
        /// `ports.yaml` needs the repository's home, so it takes `directory`. In
        /// the `.bare` container layout those are different directories, and
        /// collapsing them to one field is how the config lookups ended up
        /// running against `<container>/main`.
        struct Target: Equatable {
            let projectID: UUID
            let projectName: String
            /// `Project.checkout` — passed to `Git.Operations.createWorktree`.
            let checkout: String
            /// `Project.directory` — the repository's home, where `initialization.yaml` lives.
            let directory: String
            let existingWorkstreamNames: Set<String>
        }

        /// Why a launch could not start, or could not finish.
        ///
        /// Deliberately not localized. These are answers to an agent over IPC,
        /// the same as every string `IPC.Service` returns, and they are written
        /// to tell it what to do differently rather than to be read by the user.
        enum Failure: LocalizedError, Equatable {
            case bridgeUnavailable
            case notInAProject
            case projectNotFound(String)
            case invalidName(String)
            case nameInUse(String)
            case worktreeCreationFailed(String)

            var errorDescription: String? {
                switch self {
                case .bridgeUnavailable:
                    "Atelier's project list is not available yet; the app may still be starting."
                case .notInAProject:
                    "This tool only works from an agent running inside an Atelier workstream."
                case let .projectNotFound(directory):
                    "No open project matches \(directory). create_workstream can only create a workstream in the project the calling agent belongs to."
                case let .invalidName(name):
                    "\(name) is not a usable git branch name. Avoid spaces and ~^:?*[\\, a leading -, a trailing . or /, and .. or //."
                case let .nameInUse(name):
                    "A workstream named \(name) already exists in this project. Choose another name, or omit the name to have one generated."
                case let .worktreeCreationFailed(name):
                    "git worktree add failed for \(name). The branch may already be checked out in another worktree."
                }
            }
        }

        /// A workstream that exists, with a worktree on disk and initialization
        /// already dispatched.
        struct Launched: Equatable {
            let workstreamID: UUID
            let name: String
            let worktreePath: String
        }

        /// Which of the two worktree operations a launch runs.
        ///
        /// A value rather than a closure, because CLAUDE.md's "Two ways to
        /// create a worktree, and they are not interchangeable" is a rule about
        /// a *choice*, and a choice buried in a closure a caller assembles is
        /// one nothing can read back. `ProjectSidebar` assembled exactly that,
        /// in a view no test mounts; saying it here makes the GitHub-branch
        /// flow's decision a thing `launch` carries and a test can assert.
        ///
        /// The two operations stay distinct and neither is routed through the
        /// other: `gitWorktreeCreator` below is the one place both are named,
        /// and it is a `switch` with no shared tail.
        enum WorktreeSource: Equatable, Sendable {
            /// Cut a new branch from `BaseBranchSetting`.
            case newBranch
            /// Check out a branch that already exists on origin.
            ///
            /// The branch travels with the case rather than being taken from the
            /// workstream name. They are equal in the only flow that uses this —
            /// the sidebar names the workstream for the branch — but that is
            /// that flow's choice, not an invariant this type should inherit.
            case existingRemoteBranch(String)
        }

        /// The seam `launch` calls, and the shape an injected one must match.
        ///
        /// It takes the source rather than being *chosen by* it, so a test sees
        /// which operation a caller asked for without a git repository to run
        /// either one in.
        typealias WorktreeCreator = @Sendable (
            _ source: WorktreeSource,
            _ checkout: String,
            _ projectName: String,
            _ workstreamName: String
        ) -> String?

        /// What every production launch uses.
        ///
        /// `checkout` and not `directory`: `Git.Operations` needs a work tree.
        /// See `Target` for why those are two fields.
        static let gitWorktreeCreator: WorktreeCreator = { source, checkout, projectName, workstreamName in
            switch source {
            case .newBranch:
                Git.Operations.createWorktree(
                    projectPath: checkout,
                    projectName: projectName,
                    workstreamName: workstreamName
                )
            case let .existingRemoteBranch(branch):
                Git.Operations.createWorktreeTrackingRemote(
                    projectPath: checkout,
                    projectName: projectName,
                    branch: branch
                )
            }
        }

        // MARK: - Reading

        /// Resolves the project an agent belongs to from the directory its
        /// terminal exported.
        ///
        /// Matches `Project.directory` and **only** that. `ATELIER_PROJECT_DIR`
        /// has one producer — `Workstream.Environment.variables`, whose
        /// `projectDirectory` argument is `project.directory` at every call site
        /// — so accepting `checkout` too would be tolerance for an input nothing
        /// emits. It would also make the match ambiguous rather than lenient: in
        /// the container layout `checkout` is `<container>/main`, a path that is
        /// itself a worktree, so one project's `checkout` can equal another
        /// project's `directory` and `first` would pick by array order. A wrong
        /// answer here creates a worktree in a repository the agent never named.
        ///
        /// Standardizing first so a trailing slash or a `.` does not decide
        /// whether an agent can create a workstream.
        ///
        /// Pure and `nonisolated` so the matching rules are testable without a
        /// project list, a main actor, or a running app.
        nonisolated static func resolveTarget(
            projectDirectory: String,
            in projects: [Project]
        ) -> Target? {
            let wanted = standardized(projectDirectory)
            guard !wanted.isEmpty else { return nil }

            guard let match = projects.first(where: { standardized($0.directory) == wanted }) else { return nil }
            return target(for: match)
        }

        /// The same answer, resolved from the caller's own workstream id.
        ///
        /// Preferred over the directory when the caller has one: a workstream id
        /// is exact, where a directory is a string comparison a symlink or a
        /// trailing slash can lose. The directory form stays because an agent
        /// Atelier launched outside a workstream has no id to offer.
        nonisolated static func resolveTarget(
            callerWorkstreamID: UUID,
            in projects: [Project]
        ) -> Target? {
            guard let match = projects.first(where: { project in
                project.workstreams.contains { $0.id == callerWorkstreamID }
            }) else { return nil }
            return target(for: match)
        }

        /// The project and workstream context a launch needs, resolved through
        /// the live bridge. Throws rather than returning nil so every refusal
        /// carries a sentence the calling agent can act on.
        func target(callerWorkstreamID: UUID?, projectDirectory: String?) throws -> Target {
            guard let projects = projectList?.items else { throw Failure.bridgeUnavailable }
            if let callerWorkstreamID,
               let resolved = Self.resolveTarget(callerWorkstreamID: callerWorkstreamID, in: projects)
            {
                return resolved
            }
            guard let projectDirectory, !projectDirectory.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Failure.notInAProject
            }
            guard let resolved = Self.resolveTarget(projectDirectory: projectDirectory, in: projects) else {
                throw Failure.projectNotFound(projectDirectory)
            }
            return resolved
        }

        /// The same value, for a caller that already holds the `Project`.
        ///
        /// `ProjectSidebar` and `ProjectOverviewView` are rendering the project
        /// they are about to create in, so the resolution above — which exists
        /// because `IPC.Service` has only a directory string — is a step they do
        /// not need. It is the same struct either way, so the launch they get is
        /// the same launch.
        nonisolated static func target(for project: Project) -> Target {
            Target(
                projectID: project.id,
                projectName: project.name,
                checkout: project.checkout,
                directory: project.directory,
                existingWorkstreamNames: Set(project.workstreams.map(\.name))
            )
        }

        /// The name a launch will use: the caller's, once it is known to be
        /// usable and free, or a generated one that avoids every name taken.
        ///
        /// `isValidBranchName` runs here for the same reason `ProjectSidebar`
        /// runs it on a typed name (`ProjectSidebar.swift:813`):
        /// `createWorktree` uses this string as the branch name verbatim, so an
        /// unusable one fails inside `git worktree add` after the optimistic row
        /// has been posted. An agent-supplied name needs the check more than a
        /// typed one, not less. Deliberately the *same* rule rather than a
        /// stricter one — a slash is allowed here exactly as it is in the `+`
        /// dialog, and `worktreeDestination` sanitizes it out of the path.
        ///
        /// The duplicate check is on `name` — the branch-tracked name, which is
        /// what becomes the git branch — and not on `label`, which a rename can
        /// point anywhere. Two workstreams may share a label; they may not share
        /// a branch.
        nonisolated static func resolveName(
            requested: String?,
            existing: Set<String>
        ) -> Result<String, Failure> {
            let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                return .success(NameGenerator.generate(avoiding: existing))
            }
            guard Git.Operations.isValidBranchName(trimmed) else {
                return .failure(.invalidName(trimmed))
            }
            guard !existing.contains(trimmed) else {
                return .failure(.nameInUse(trimmed))
            }
            return .success(trimmed)
        }

        private nonisolated static func standardized(_ path: String) -> String {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "" }
            return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
        }

        // MARK: - Launching

        /// Creates a workstream in the project the caller names and returns once
        /// its worktree exists.
        ///
        /// **This is the only place that sequence is written.** Post the
        /// optimistic row, do the git work off the main thread, then post the
        /// outcome — the seam CLAUDE.md describes, and what a second copy would
        /// forget: path persistence, the HeadWatcher, the agent-state lookup,
        /// the Shortcut story id, and `Initialization.Runner`. `ProjectSidebar`
        /// held a hand-rolled copy of it until this became the only one; it now
        /// hands its three entry points here and keeps what only a mounted view
        /// can do — its sheets, the expanded-project set, and the failure alert.
        ///
        /// `select` is the one thing the producers disagree about: the sidebar's
        /// are buttons the user just pressed and pass `true`, while
        /// `create_workstream` passes `false`, because an agent creating a
        /// workstream must not pull the user out of the pane they are working
        /// in. The row appears in the sidebar immediately either way.
        ///
        /// `source` is the GitHub-branch flow's whole contribution: it says the
        /// branch already exists on origin, so `gitWorktreeCreator` runs
        /// `createWorktreeTrackingRemote` rather than `createWorktree`. See
        /// CLAUDE.md, "Two ways to create a worktree, and they are not
        /// interchangeable" — the two stay distinct and neither is routed
        /// through the other.
        ///
        /// `createWorktree` is injected so the notification sequence can be
        /// tested without a git repository. Production callers use the default.
        ///
        /// `beforeReady` runs once the worktree exists and **before**
        /// `.workstreamWorktreeReady` is posted. That ordering is the whole
        /// point of the hook: that notification is what makes the workstream
        /// renderable, and the first render creates the Coding Agent's surface
        /// with the command the *view* builds. Anything that needs to own that
        /// surface — `create_workstream` seeding an agent into it — has to be in
        /// place first, or it loses a race to a user clicking the sidebar row
        /// that has been sitting there since `.workstreamCreated`. Errors are
        /// deliberately not propagated: the worktree exists either way and still
        /// needs its initialization, so the notification posts regardless and the
        /// caller reports the failure itself.
        ///
        /// It is `@Sendable`, so it runs **off** the main actor and the hitch of
        /// whatever it does — resolving a default branch, probing ports — is not
        /// paid on screen. What closes the window is not holding the actor but
        /// the notification itself: `.workstreamCreated` appends the workstream
        /// with a nil `worktreePath`, and `workstreamHasUsablePath` refuses that,
        /// so nothing can render this workstream however long the hook takes.
        func launch(
            in target: Target,
            requestedName: String?,
            bypassPermissions: Bool = false,
            select: Bool = false,
            shortcutStoryID: Int? = nil,
            source: WorktreeSource = .newBranch,
            createWorktree: @escaping WorktreeCreator = Launcher.gitWorktreeCreator,
            beforeReady: (@Sendable (Launched) async -> Void)? = nil
        ) async throws -> Launched {
            let name = try Self.resolveName(
                requested: requestedName,
                existing: target.existingWorkstreamNames
            ).get()

            let workstream = Workstream(
                name: name,
                worktreePath: nil,
                bypassPermissions: bypassPermissions,
                shortcutStoryID: shortcutStoryID
            )
            logger.warning("[Atelier] Launcher: creating \(name, privacy: .public) in \(target.projectName, privacy: .public)")

            NotificationCenter.default.post(
                name: .workstreamCreated,
                object: nil,
                userInfo: [
                    "projectID": target.projectID,
                    "workstream": workstream,
                    "select": select,
                ]
            )

            let checkout = target.checkout
            let projectName = target.projectName
            let worktreePath = await withCheckedContinuation { continuation in
                // Off the main thread for the same reason `ProjectSidebar` does
                // it: `createWorktree` checks out a whole tree, and it runs under
                // `ProcessRunner.Timeout.userCommand` rather than a short one.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: createWorktree(source, checkout, projectName, name))
                }
            }

            guard let worktreePath else {
                logger.warning("[Atelier] Launcher: createWorktree FAILED for \(name, privacy: .public), rolling back")
                NotificationCenter.default.post(
                    name: .workstreamCreationFailed,
                    object: nil,
                    userInfo: ["projectID": target.projectID, "workstreamID": workstream.id]
                )
                throw Failure.worktreeCreationFailed(name)
            }

            let launched = Launched(workstreamID: workstream.id, name: name, worktreePath: worktreePath)
            await beforeReady?(launched)

            // This is what runs initialization, via ContentView's handler and
            // `Initialization.Runner`. It is also what makes the workstream
            // renderable, since `renderableWorkstreamID` requires a usable path
            // — which is why `beforeReady` runs above it and not below.
            NotificationCenter.default.post(
                name: .workstreamWorktreeReady,
                object: nil,
                userInfo: ["workstreamID": workstream.id, "worktreePath": worktreePath]
            )
            logger.warning("[Atelier] Launcher: \(name, privacy: .public) ready at \(worktreePath, privacy: .public)")

            return launched
        }

        /// Registers a worktree git already has as a workstream.
        ///
        /// `ProjectOverviewView`'s adoption used to post `.workstreamCreated`
        /// alone, with the path already filled in, and skip
        /// `.workstreamWorktreeReady` on the reasoning that there was nothing
        /// left to wait for. What that skipped was the *handler*:
        /// `attachWorktreePath` is where the path is persisted,
        /// `refreshPathValidity` runs, the HeadWatcher starts watching and a
        /// staged Shortcut story is promoted. Most of those are reached a second
        /// way — `ContentView`'s `.onChange(of: projectList.items)` — which is
        /// why nobody noticed, and is exactly the accidental redundancy a third
        /// creation path accumulates. So adoption posts the same pair, in the
        /// same order, with a `nil` path on the optimistic row: a consumer
        /// reading these notifications cannot tell an adopted workstream from a
        /// created one.
        ///
        /// **Except for one key, and it carries a fact rather than a decision.**
        /// `worktreeIsPreexisting` says only that the tree was not made by this
        /// call. `ContentView` is what decides what that means, and what it
        /// decides is not to run `initialization.yaml` in a directory the user
        /// already had: adoption registers a worktree, it does not build one,
        /// and running the project's setup commands unprompted in a tree that
        /// may hold work in progress is a side effect nobody asked for. The
        /// Info tab renders the resulting `.idle` as "Nothing reported this
        /// session." with Rerun enabled beside it, so the steps stay one press
        /// away for a worktree that genuinely needs them.
        ///
        /// Synchronous, unlike `launch`: there is no git work to wait for.
        @discardableResult
        func adopt(
            projectID: UUID,
            name: String,
            worktreePath: String,
            select: Bool = true
        ) -> Launched {
            let workstream = Workstream(name: name, worktreePath: nil)
            logger.warning("[Atelier] Launcher: adopting \(name, privacy: .public) at \(worktreePath, privacy: .public)")

            NotificationCenter.default.post(
                name: .workstreamCreated,
                object: nil,
                userInfo: [
                    "projectID": projectID,
                    "workstream": workstream,
                    "select": select,
                ]
            )
            NotificationCenter.default.post(
                name: .workstreamWorktreeReady,
                object: nil,
                userInfo: [
                    "workstreamID": workstream.id,
                    "worktreePath": worktreePath,
                    "worktreeIsPreexisting": true,
                ]
            )

            return Launched(workstreamID: workstream.id, name: name, worktreePath: worktreePath)
        }
    }
}
