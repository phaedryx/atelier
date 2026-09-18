// ABOUTME: One value carrying everything the app knows about a single worktree.
// ABOUTME: Plus the pure fold that lays a sweep's findings over what is already known.

import Foundation

extension Worktree {
    /// Whether the working tree has uncommitted changes — including the third
    /// answer, "nobody looked".
    ///
    /// `Git.RepoInfo` already keeps that distinction (`isDirtyUnknown`) and
    /// `Worktree.Info` keeps it again (`cleanlinessUnknown`), for the reason
    /// stated at both: a `false` that means "`git status` did not run" rendered
    /// as a green *Clean* is the app asserting something it never checked.
    /// Collapsing it here would have thrown it away one layer further in.
    enum Cleanliness: Equatable {
        case clean
        case dirty
        /// The probe did not run, or could not answer.
        case unknown

        init(isDirty: Bool, isDirtyUnknown: Bool) {
            if isDirtyUnknown {
                self = .unknown
            } else {
                self = isDirty ? .dirty : .clean
            }
        }
    }

    struct State: Equatable {
        var hasUncommittedChanges: Bool = false
        var hasUnpushedCommits: Bool = false
        var hasBranchCommits: Bool = false
        var hasRemote: Bool = false
    }

    /// Everything `AppEnvironment` knows about one worktree, as one value.
    ///
    /// This replaced five dictionaries keyed by worktree path, each with its own
    /// accessor and its own reader sites. The dictionaries were not wrong
    /// individually; what they cost was that a view wanting two facts about one
    /// worktree had to ask twice and then correlate the answers itself — which is
    /// how `branch.flatMap { appEnv.githubPR(for: dir, branch: $0) }` came to be
    /// written out verbatim at six call sites.
    ///
    /// **Two facts deliberately stayed out**, and both for the same reason: they
    /// are not keyed by worktree path.
    ///
    /// - A **pull request** belongs to a *branch*, and `ProjectOverviewView`'s
    ///   worktree list renders a PR badge for worktrees that are not workstreams
    ///   at all — rows fed by `listWorktreesWithInfo`, which no path-keyed cache
    ///   filled from `project.workstreams` can ever cover. It stays in
    ///   `githubBranchPRCache`, keyed `"dir|branch"`, and
    ///   `AppEnvironment.pullRequest(forWorktree:in:)` is the one place the two
    ///   lookups are composed.
    /// - `hasGitHubRemote` and the GitHub browser URL belong to a **project**,
    ///   keyed by its `directory`. The sidebar's branch button is gated on the
    ///   first, and re-keying it by worktree is how that button came to be hidden
    ///   for every container-layout project once before.
    ///
    /// `Equatable` is load-bearing rather than decorative: `AppEnvironment`
    /// publishes through `commitChanges`, which sends `objectWillChange`
    /// unconditionally, so the sweep has to compare *before* it calls — otherwise
    /// every row in the app re-renders every fifteen seconds whether or not
    /// anything moved.
    struct Facts: Equatable {
        /// Defaults to `true`, matching what `isPathValid` answered for a path it
        /// had never swept: a workstream is not struck through until something
        /// has actually looked and found its directory gone.
        var isPathValid: Bool = true
        var branch: String?
        var cleanliness: Cleanliness = .unknown
        /// The worktree's `.atelier-state/description`, trimmed. Nil when absent
        /// or empty.
        var taskDescription: String?
        var hasActivePort: Bool = false
        /// The Shortcut story this worktree was created for.
        ///
        /// The one field no sweep can learn: it lives on `Workstream`, and
        /// `ContentView.syncShortcutStoryIDs` is the only place holding both the
        /// project list and the environment. That is why `applying` carries it
        /// forward rather than assigning a whole new value.
        var shortcutStoryID: Int?
        var state: State = .init()
    }
}

extension Worktree.Facts {
    /// What one pass of `AppEnvironment.refreshPathValidity` learned about one
    /// worktree — the sweep's output, before it is laid over what is already
    /// known.
    ///
    /// The optional fields are not "absent values"; they mean **the sweep did not
    /// look**, and the existing answer stands. That is exactly the semantics the
    /// six separate caches had between them, and it is worth spelling out because
    /// they disagreed: four were `merge`d (so an unvisited path kept its answer)
    /// while `taskDescriptionCache` and `activePortCache` were replaced wholesale
    /// (so it lost it). Folding them into one value without saying which rule
    /// each field follows is how `shortcutStoryID` would have been silently
    /// dropped on the next tick.
    struct Swept: Equatable {
        /// Always overwrites — every workstream path the sweep saw is stat'd.
        var isPathValid: Bool
        /// Nil means the git probe did not run or reported no branch; the last
        /// known branch stands, which is what `branchNameCache.merge` did.
        var branch: String?
        /// Nil means the probe did not run. `.unknown` is a real answer — git ran
        /// and could not tell — and must not be confused with it.
        var cleanliness: Worktree.Cleanliness?
        /// Always overwrites, including with nil: a description file that has been
        /// deleted stops being reported.
        var taskDescription: String?
        /// Always overwrites.
        var hasActivePort: Bool = false
        /// Nil means the probe did not run; the last known state stands.
        var state: Worktree.State?
    }

    /// Lay one worktree's sweep findings over what is already known about it.
    ///
    /// Pure, and the single place each field's carry-forward rule is written
    /// down. `shortcutStoryID` appears nowhere in `Swept`, so it can only survive
    /// by being carried — which is the whole reason this is a fold and not an
    /// assignment.
    static func applying(_ swept: Swept, to existing: Worktree.Facts?) -> Worktree.Facts {
        var facts = existing ?? Worktree.Facts()
        facts.isPathValid = swept.isPathValid
        if let branch = swept.branch {
            facts.branch = branch
        }
        if let cleanliness = swept.cleanliness {
            facts.cleanliness = cleanliness
        }
        if let state = swept.state {
            facts.state = state
        }
        facts.taskDescription = swept.taskDescription
        facts.hasActivePort = swept.hasActivePort
        return facts
    }

    /// The same fold across a whole sweep.
    ///
    /// Paths the sweep did not visit are **kept unchanged** rather than pruned. A
    /// sweep carries a snapshot of the project list taken when it started, and a
    /// workstream created while it was in flight is not in that snapshot — so
    /// pruning here would delete facts that `refreshBranchName` had just written
    /// for a worktree the user is looking at. Entries for archived workstreams
    /// are the price, and they are inert: nothing asks for a path it no longer
    /// renders. (`shortcutStoryID` is the exception that *is* reconciled, by
    /// `pruneShortcutStories`, because a reused path would otherwise show the
    /// previous workstream's story.)
    static func applying(
        _ swept: [String: Swept],
        to existing: [String: Worktree.Facts]
    ) -> [String: Worktree.Facts] {
        var updated = existing
        for (path, entry) in swept {
            updated[path] = applying(entry, to: existing[path])
        }
        return updated
    }
}
