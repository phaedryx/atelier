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
    /// matters most — `AsyncSetupService.setupExistingWorktree`, which runs
    /// `bootstrap` through `ProcessCompose.PhasePolicy.plan`. That gate is
    /// deliberately the only copy of those preconditions, so this type reaches it
    /// by *not* running bootstrap itself. Do not add a `setupExistingWorktree`
    /// call here.
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
        /// `checkout`; everything that locates a `process-compose.yaml` or a
        /// `ports.yaml` needs the repository's home, so it takes `directory`. In
        /// the `.bare` container layout those are different directories, and
        /// collapsing them to one field is how the config lookups ended up
        /// running against `<container>/main`.
        struct Target: Equatable {
            let projectID: UUID
            let projectName: String
            /// `Project.checkout` — passed to `Git.Operations.createWorktree`.
            let checkout: String
            /// `Project.directory` — the repository's home, passed to bootstrap.
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
            case invalidArgument(name: String, reason: String)
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
                case let .invalidArgument(name, reason):
                    "Invalid `\(name)`: \(reason)"
                case let .invalidName(name):
                    "\(name) is not a usable git branch name. Avoid spaces and ~^:?*[\\, a leading -, a trailing . or /, and .. or //."
                case let .nameInUse(name):
                    "A workstream named \(name) already exists in this project. Choose another name, or omit the name to have one generated."
                case let .worktreeCreationFailed(name):
                    "git worktree add failed for \(name). The branch may already be checked out in another worktree."
                }
            }
        }

        /// A workstream that exists, with a worktree on disk and `bootstrap`
        /// already dispatched.
        struct Launched: Equatable {
            let workstreamID: UUID
            let name: String
            let worktreePath: String
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

        private nonisolated static func target(for project: Project) -> Target {
            Target(
                projectID: project.id,
                projectName: project.name,
                checkout: project.checkout,
                directory: project.directory,
                existingWorkstreamNames: Set(project.workstreams.map(\.name))
            )
        }

        /// Reads an agent-supplied boolean.
        ///
        /// `IPC.Request.arguments` is `[String: String]`, so a bool arrives as
        /// text. Absent means false; anything that is not exactly `true` or
        /// `false` is an error rather than a default. A value that quietly reads
        /// false because the agent sent `True` is a silent no-op reported as a
        /// success, which is the failure mode this whole surface avoids.
        nonisolated static func parseBool(
            _ raw: String?,
            name: String
        ) -> Result<Bool, Failure> {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(false) }
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "true": return .success(true)
            case "false": return .success(false)
            default:
                return .failure(.invalidArgument(
                    name: name,
                    reason: "expected \"true\" or \"false\", received \"\(raw)\"."
                ))
            }
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

        /// Creates a workstream in the project the caller belongs to and returns
        /// once its worktree exists.
        ///
        /// Follows `ProjectSidebar.launchWorkstream` exactly: post the optimistic
        /// row, do the git work off the main thread, then post the outcome. The
        /// one difference is `select`, which this path passes as `false` — an
        /// agent creating a workstream should not pull the user out of the pane
        /// they are working in. The row still appears in the sidebar
        /// immediately, so the creation is visible without being disruptive.
        ///
        /// `createWorktree` is injected so the notification sequence can be
        /// tested without a git repository. Production callers use the default.
        func launch(
            in target: Target,
            requestedName: String?,
            bypassPermissions: Bool = false,
            select: Bool = false,
            createWorktree: @escaping @Sendable (_ checkout: String, _ projectName: String, _ workstreamName: String) -> String? = {
                Git.Operations.createWorktree(projectPath: $0, projectName: $1, workstreamName: $2)
            }
        ) async throws -> Launched {
            let name = try Self.resolveName(
                requested: requestedName,
                existing: target.existingWorkstreamNames
            ).get()

            let workstream = Workstream(
                name: name,
                worktreePath: nil,
                bypassPermissions: bypassPermissions
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
                    continuation.resume(returning: createWorktree(checkout, projectName, name))
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

            // This is what runs `bootstrap`, via ContentView's handler and
            // `AsyncSetupService`. It is also what makes the workstream
            // renderable, since `renderableWorkstreamID` requires a usable path.
            NotificationCenter.default.post(
                name: .workstreamWorktreeReady,
                object: nil,
                userInfo: ["workstreamID": workstream.id, "worktreePath": worktreePath]
            )
            logger.warning("[Atelier] Launcher: \(name, privacy: .public) ready at \(worktreePath, privacy: .public)")

            return Launched(workstreamID: workstream.id, name: name, worktreePath: worktreePath)
        }
    }
}
