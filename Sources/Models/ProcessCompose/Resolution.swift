// ABOUTME: One resolution of everything the Execution and Verification panes read about a config.
// ABOUTME: Published as a single value, so the Start button and the run cannot disagree.

import Foundation

extension ProcessCompose {
    /// Everything one workstream's panes need to know about its process-compose
    /// config, resolved together.
    ///
    /// **A single value, and that is the invariant this type exists for.**
    /// `RunCommandPlan.canRun` is what enables the Execution pane's Start button
    /// and `doStartRun` refuses on the same plan; those two used to be two
    /// questions asked in two places, and an unresolvable binary rendered an
    /// enabled Start that did nothing and said nothing. The rule that came out
    /// of it is *agreement, not freshness* — a plan a moment stale but
    /// consistent with the reason beside it is harmless. Eight separate
    /// `@State`s refreshed inside one function honoured that by convention;
    /// one struct assigned in one statement honours it by construction, which is
    /// what makes it safe to resolve off the main actor.
    ///
    /// What is deliberately **not** here:
    ///
    /// - **The checklist's selection.** `runnableExecuteSelection` reads the
    ///   selection store on every render on purpose: Start is reachable from the
    ///   palette and ⌘⇧⏎ with the Execution tab never opened, so a copy cached
    ///   here could disagree with what Start would actually run. The plan
    ///   answers "is there a safe command for this source"; the selection
    ///   answers "is there anything to run it for", and they dim different
    ///   things.
    /// - **The port plan.** Resolving it binds a socket per port to check
    ///   whether each is free, and it answers to a different trigger
    ///   (`ports.yaml`) than anything here.
    struct Resolution {
        /// What `DevCommand.Resolver` resolved: the user's per-workstream
        /// override, or the located config.
        var devCommand: DevCommand?
        /// What Start may run. Never re-derived beside a consumer — see the
        /// type doc.
        var plan: ProcessCompose.RunCommandPlan = .nothing
        /// Every file the run's config will load, shown in place of a command
        /// string. A `.processCompose` command is a display string that must
        /// never be executed, so the pane shows the files instead.
        var loadedFiles: [String] = []
        /// Why Start can do nothing, when the pane's own copy does not already
        /// explain it. Resolved in the same pass as `plan`, so the two cannot
        /// describe different states.
        var startUnavailableReason: String?
        /// The `execute` processes a run can be scoped to, already through
        /// `PhaseRunner.runnableProcesses` — the flag-injection filter — so the
        /// checklist cannot offer a name the command would drop.
        var declaredExecuteProcesses: [String] = []
        /// The checks to offer, and why none can run. One decision,
        /// `Verification.Config.Load`'s, which is the same load
        /// `Verification.Runner.start` performs and refuses on.
        var declaredVerifyChecks: [String] = []
        var verifyUnavailableReason: String?
        /// Whether this workstream's run is a process-compose run — i.e. the
        /// dev command came from a config rather than the user's own override —
        /// which is what decides whether there is a control socket worth
        /// polling.
        var usesProcessCompose = false
    }

    /// Resolves a workstream's `Resolution` and publishes it.
    ///
    /// The work is a `Config.locate` (a couple of `stat`s), a YAML decode per
    /// namespace question and a binary lookup. All of it ran synchronously on the main actor,
    /// on every tab switch, because the view refreshed it from
    /// `.onChange(of: model.activeTab)`. Here it runs off the actor and lands as
    /// one assignment.
    ///
    /// **The first resolution is synchronous, and that is not an oversight.**
    /// A pane with nothing resolved yet is not a neutral state: a nil
    /// `verifyUnavailableReason` reads as "everything is fine", which put an
    /// enabled Run over an empty check list — which is why the view took to
    /// resolving on `.onAppear` as well. Resolving in `init` closes that window
    /// rather than widening it; the cost the follow-up is about is per tab
    /// switch, not per mount.
    @MainActor
    final class ResolutionModel: ObservableObject {
        @Published private(set) var resolution: Resolution

        private let projectDirectory: String
        /// The per-workstream override, as the caller last passed it.
        ///
        /// Every entry point takes it explicitly rather than defaulting to
        /// "unchanged": clearing Customize *is* a change, and an API that read
        /// nil as "keep what you had" would silently keep resolving against an
        /// override the user had just deleted.
        private var override: String?
        private let searchPaths: [String]
        /// Bumped by every refresh, synchronous or not. A completion whose token
        /// no longer matches belongs to a pass this model has already
        /// superseded — the same guard `ChangesView.fullLoad` uses against its
        /// own git hop, and what keeps an out-of-order landing from replacing a
        /// newer answer.
        private var generation = 0

        /// **No worktree.** Everything resolved here is a property of the
        /// *project*: `execution.process-compose.yaml` and `verification.yaml` both
        /// live in the project directory, and the override is passed in. The model
        /// took a worktree while `Config.locate` had a work-tree tier; putting one
        /// back would mean putting that tier back first.
        ///
        /// - Parameters:
        ///   - searchPaths: where to look for the process-compose binary.
        ///     Defaulted, and injected only by tests, for the reason
        ///     `ProcessCompose.Settings.resolveBinary` takes the same parameter:
        ///     the path stopped being configurable, so without a seam every
        ///     assertion about a resolved plan would depend on what the host
        ///     happens to have installed.
        init(
            projectDirectory: String,
            override: String?,
            searchPaths: [String] = ProcessCompose.Settings.searchPaths
        ) {
            self.projectDirectory = projectDirectory
            self.override = override
            self.searchPaths = searchPaths
            resolution = Self.resolve(
                projectDirectory: projectDirectory, override: override,
                searchPaths: searchPaths
            )
        }

        /// Re-resolve off the main actor.
        ///
        /// Until it lands, `resolution` keeps the previous pass *whole* — plan,
        /// reason, files and checklist all from one resolution — so a consumer
        /// reading it mid-flight reads a consistent world, which is the property
        /// the Start button needs. A momentarily stale plan cannot enable a
        /// button the run would refuse, because both read this same value.
        func refresh(override: String?) {
            self.override = override
            generation += 1
            let token = generation
            let projectDirectory = projectDirectory
            let override = self.override
            let searchPaths = searchPaths
            DispatchQueue.global(qos: .userInitiated).async {
                let resolved = Self.resolve(
                    projectDirectory: projectDirectory, override: override,
                    searchPaths: searchPaths
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, token == generation else { return }
                    resolution = resolved
                }
            }
        }

        /// Re-resolve now, on the caller's actor, and return the answer.
        ///
        /// For a caller that needs the result of a write it just made, rather
        /// than the state before it. An asynchronous refresh would answer about
        /// the world as it was before the click. It bumps the generation too, so a
        /// refresh already in flight cannot land on top of it.
        @discardableResult
        func refreshNow(override: String?) -> Resolution {
            self.override = override
            generation += 1
            resolution = Self.resolve(
                projectDirectory: projectDirectory, override: override,
                searchPaths: searchPaths
            )
            return resolution
        }

        /// The whole resolution, as a pure function of the project directory, the
        /// override and what is on disk.
        ///
        /// `nonisolated` because it is the half that must not run on the main
        /// actor. It touches UserDefaults (thread-safe), the file system and
        /// Yams, and nothing that is actor-bound.
        ///
        /// Verification is resolved here too, though it has nothing to do with
        /// process-compose any more: its checks come from the project's own
        /// `verification.yaml`. It rides along because this is the pass that
        /// already runs off the main actor on the triggers a config change
        /// arrives on, and splitting it out would mean a second resolver with the
        /// same lifecycle.
        nonisolated static func resolve(
            projectDirectory: String,
            override: String?,
            searchPaths: [String] = ProcessCompose.Settings.searchPaths
        ) -> Resolution {
            let devCommand = DevCommand.Resolver.resolve(
                projectDirectory: projectDirectory, override: override
            )
            let binary = ProcessCompose.Settings.resolveBinary(searchPaths: searchPaths)
            // **One locate, two questions.** The run's config is this same
            // config narrowed to the *run* — it disappears behind a
            // per-workstream override, which is right for Start and wrong for
            // dispose, which locates
            // unconditionally. Locating twice was two answers to the same
            // question from the same directory.
            let located = ProcessCompose.Config.locate(projectDirectory: projectDirectory)
            let runConfig = devCommand?.source == .processCompose ? located : nil

            let plan = ProcessCompose.RunCommandPlan.plan(
                devCommand: devCommand, config: runConfig, binary: binary
            )
            let declaredExecute: [String] = if case let .phaseScoped(config, _) = plan {
                // `PhaseRunner`'s own filter, so a process named `-web` is not
                // offered: selected alone it emptied the name list, and `up -n
                // execute` with no names runs the whole namespace.
                ProcessCompose.PhaseRunner.runnableProcesses(
                    config.declaredProcesses(in: ProcessCompose.Phase.execute.namespace) ?? []
                )
            } else {
                []
            }

            // The project's own checks, from the project directory and nowhere
            // else — never the worktree. See `Verification.Config`.
            let verification = Verification.Config.load(projectDirectory: projectDirectory)

            return Resolution(
                devCommand: devCommand,
                plan: plan,
                loadedFiles: runConfig?.loadedFiles ?? [],
                startUnavailableReason: ProcessCompose.RunCommandPlan.unavailableReason(
                    devCommand: devCommand, config: runConfig, binary: binary
                ),
                declaredExecuteProcesses: declaredExecute,
                declaredVerifyChecks: verification.checkNames,
                verifyUnavailableReason: verification.unavailableReason,
                usesProcessCompose: devCommand?.source == .processCompose
            )
        }
    }
}
