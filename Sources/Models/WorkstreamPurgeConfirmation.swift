// ABOUTME: Owns the pending target, warning and copy for a Remove/Purge confirmation.
// ABOUTME: The views attach `.purgeConfirmationAlert`; the asking lives here, the doing stays in Archiver.

import OSLog
import SwiftUI

private let logger = Logger(subsystem: "atelier", category: "purge-confirmation")

extension Workstream {
    /// The one owner of the *asking* half of Remove and Purge.
    ///
    /// `Archiver` owns `remove`, `purge` and `purgeOrphanWorktree`; it has never
    /// owned the confirmation. The pending target, the warning, the
    /// "Purge Anyway" button-title rule and the alert copy existed in full in
    /// `ContentView`, `ProjectSidebar` and — for the orphan variant —
    /// `ProjectOverviewView`, three copies that agreed only by convention. This
    /// type holds them once; `View.purgeConfirmationAlert` renders them once.
    ///
    /// **It moves the asking, not the doing.** In particular the
    /// `destroyableWorktreePath` decision for a *workstream* deliberately stays
    /// inside `Archiver.purge`, where it scopes each destructive step. Re-deciding
    /// it here would be the inlined second copy of a gate this codebase keeps
    /// warning about, and refusing on it here would be worse than a duplicate: it
    /// is nil for a workstream archived before `workstreamWorktreeReady` lands,
    /// and `purge` still has real work to do for one of those — dropping it from
    /// the project, evicting its surfaces, killing its tmux sessions, releasing
    /// its task claims. Refusing would strand that workstream with no Purge at
    /// all. The orphan path is the opposite case and is handled below.
    @MainActor
    final class PurgeConfirmation: ObservableObject {
        /// What a pending confirmation is aimed at.
        ///
        /// Two cases of one enum rather than the three `@State` pairs this
        /// replaced, so "a purge is pending" and "what it is pending on" cannot
        /// disagree — they did, as `workstreamToPurge` and `purgeWarningMessage`
        /// set and cleared in different places in each view.
        enum Target: Equatable {
            /// A workstream, resolved to its id. The destroyable-path decision
            /// belongs to `Archiver.purge` and is not taken here.
            case workstream(id: UUID, name: String)
            /// A worktree no workstream owns. Carries the directories
            /// `Archiver.destroyablePath` needs, because — unlike the workstream
            /// case — `purgeOrphanWorktree` has no guard of its own.
            case orphanWorktree(path: String, projectDirectory: String, checkoutDirectory: String?)
        }

        /// What actually happened, handed to the caller's post-purge closure.
        ///
        /// A workstream completion carries the project id because the callers'
        /// selection fallbacks need it and it cannot be resolved afterwards —
        /// the row it would have been looked up through is gone by then.
        enum Completion: Equatable {
            case workstream(id: UUID, projectID: UUID)
            case orphanWorktree(path: String)
        }

        /// Everything `perform` needs to reach `Archiver.purge`, assembled by the
        /// view in its own body.
        ///
        /// Passed in at perform time rather than stored on this object: a
        /// `@StateObject`'s initializer runs once, so dependencies captured there
        /// would be the ones that existed at first render — a stale `tmuxPath`
        /// and, worse, a `Binding` into an array the view has since replaced.
        /// Nil for a caller that can only ever hold an orphan target; a
        /// `.workstream` target with no context is refused rather than
        /// half-performed.
        struct ArchiveContext {
            var projects: Binding<[Project]>
            var surfaceCache: TerminalSurfaceCache
            var tmuxPath: String?
            var verificationRunner: Verification.Runner
            var agentStateTracker: Workstream.AgentStateTracker

            init(
                projects: Binding<[Project]>,
                surfaceCache: TerminalSurfaceCache,
                tmuxPath: String?,
                verificationRunner: Verification.Runner,
                agentStateTracker: Workstream.AgentStateTracker
            ) {
                self.projects = projects
                self.surfaceCache = surfaceCache
                self.tmuxPath = tmuxPath
                self.verificationRunner = verificationRunner
                self.agentStateTracker = agentStateTracker
            }
        }

        /// The `Archiver` entry points `perform` reaches, injected so a test can
        /// observe that a refused purge called none of them.
        ///
        /// Only the orphan purge is behind the seam. The workstream purge needs a
        /// live `TerminalSurfaceCache` and `Verification.Runner`, which nothing
        /// under `Tests/` builds, so putting it here would buy an assertion no
        /// test can make at the price of a second way into `Archiver.purge`.
        @MainActor
        struct Operations {
            var purgeOrphanWorktree: (_ projectDirectory: String, _ worktreePath: String) -> Void

            static let live = Operations(
                purgeOrphanWorktree: { projectDirectory, worktreePath in
                    Archiver.purgeOrphanWorktree(
                        projectDirectory: projectDirectory, worktreePath: worktreePath
                    )
                }
            )
        }

        @Published private(set) var target: Target?
        @Published private(set) var warning: String?

        private let operations: Operations

        init(operations: Operations = .live) {
            self.operations = operations
        }

        // MARK: - What the alert renders

        /// Settable so the modifier can bind to it. Only the false direction is
        /// honoured: an alert is raised by `confirm`, which has a warning to
        /// compute, never by flipping a boolean.
        var isPresented: Bool {
            get { target != nil }
            set {
                if !newValue {
                    cancel()
                }
            }
        }

        var title: String {
            switch target {
            case .orphanWorktree:
                NSLocalizedString("Purge Worktree", comment: "Title of the orphan worktree purge confirmation")
            case .workstream, nil:
                NSLocalizedString("Purge Workstream", comment: "Title of the workstream purge confirmation")
            }
        }

        var message: String {
            warning ?? NSLocalizedString(
                "The worktree and its branch will be permanently deleted.",
                comment: "Purge confirmation message when nothing would be lost"
            )
        }

        /// "Purge Anyway" exactly when there is a warning to overrule.
        ///
        /// Localized, where the ternary this replaced was not: three copies of
        /// `Button(warning != nil ? "Purge Anyway" : "Purge", …)` produced a
        /// `String`, which binds SwiftUI's `StringProtocol` overload and skips
        /// the table. Both keys are already in `Localizable.strings`; English is
        /// unchanged.
        var confirmButtonTitle: String {
            warning == nil
                ? NSLocalizedString("Purge", comment: "Purge confirmation button")
                : NSLocalizedString("Purge Anyway", comment: "Purge confirmation button when work would be lost")
        }

        // MARK: - Asking

        func confirm(workstream: Workstream) {
            warning = Archiver.purgeWarning(for: workstream)
            target = .workstream(id: workstream.id, name: workstream.name)
        }

        func confirm(orphanWorktree path: String, projectDirectory: String, checkoutDirectory: String? = nil) {
            warning = Archiver.orphanPurgeWarning(at: path)
            target = .orphanWorktree(
                path: path, projectDirectory: projectDirectory, checkoutDirectory: checkoutDirectory
            )
        }

        func cancel() {
            target = nil
            warning = nil
        }

        // MARK: - Doing

        /// Runs the `Archiver` method this target names, then `then` — and only
        /// then. A refusal runs neither: the callers' post-purge closures save
        /// the project list, move the selection and refresh a worktree list, and
        /// every one of those reads as "it happened".
        ///
        /// The target is cleared either way, because the alert is answered
        /// either way.
        func perform(archiving context: ArchiveContext?, then: (Completion) -> Void) {
            guard let target else { return }
            self.target = nil
            warning = nil

            switch target {
            case let .workstream(id, name):
                guard let context else {
                    logger.error("Purge of \(name, privacy: .public) had no archive context; refusing")
                    return
                }
                var projects = context.projects.wrappedValue
                guard let index = projects.firstIndex(where: {
                    $0.workstreams.contains(where: { $0.id == id })
                }) else { return }
                let projectID = projects[index].id
                Archiver.purge(
                    id,
                    in: &projects[index],
                    surfaceCache: context.surfaceCache,
                    tmuxPath: context.tmuxPath,
                    verificationRunner: context.verificationRunner,
                    agentStateTracker: context.agentStateTracker
                )
                context.projects.wrappedValue = projects
                then(.workstream(id: id, projectID: projectID))

            case let .orphanWorktree(path, projectDirectory, checkoutDirectory):
                // The guard the workstream path gets from inside `Archiver.purge`
                // and this one has never had: `purgeOrphanWorktree` hands its
                // argument to `removeWorktree`, which deletes the path it is
                // given. Unreachable from today's UI — `WorktreeInfoRow` offers
                // Purge only for a row that is neither `isMain` nor `isProtected`
                // — so this is the belt to that row's braces, and it refuses
                // rather than hides so a future caller that skips the row cannot
                // walk past it.
                guard let destroyable = Archiver.destroyablePath(
                    path, projectDirectory: projectDirectory, checkoutDirectory: checkoutDirectory
                ) else {
                    logger.error(
                        "Refusing to purge \(path, privacy: .public): it names the project's own directory"
                    )
                    return
                }
                operations.purgeOrphanWorktree(projectDirectory, destroyable)
                then(.orphanWorktree(path: destroyable))
            }
        }
    }
}
