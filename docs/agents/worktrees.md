# Worktrees and the workstream lifecycle

How a workstream is created, what base branch it is cut from, and the two
different ways one ends.

### Workstream lifecycle
1. Creating a workstream: generates name, runs `git worktree add`; `Initialization.Runner` then runs the project's `initialization.yaml` steps in the background
2. Workspace view: a workstream opens with only Info (Cmd+I) and Agent (Cmd+Return), which are also the only permanent tabs. Every singleton but those two — Changes, Execution, Verification, Whiteboard, and whatever is added next — is opened on demand from the tab bar's quick-add buttons, the command palette, or their toggles, and closes and reorders like terminals/browsers once open. `WorkspaceTabKind.isCloseable` is where that set is declared; do not re-enumerate it here, which is how this sentence came to name three when there were four. `startupWorkspaceTabState` seeds the two permanent tabs and clamps the restored `activeTab` into that list; the seed and the clamp move together, because a saved `.changes` restored onto a strip with no Changes tab renders the pane with nothing selected
3. Tmux mode: wraps Coding Agent only in `tmux new-session -A`, on a socket named `AppConstants.appID` — so `-L atelier` for a release build and `-L atelier-debug` for a debug one
4. Terminal tabs: close on shell exit (Ctrl+D). Agent respawns.
5. Ending a workstream: two operations, not one — see below.

### Two ways to create a worktree, and they are not interchangeable
`Git.Operations.createWorktree` cuts a **new** branch from `BaseBranchSetting`. The GitHub
button on a project row goes through `createWorktreeTrackingRemote` instead, which checks out a
branch that already exists on origin. **Which one runs is named, once, as a value** —
`Workstream.Launcher.WorktreeSource`, dispatched by `Launcher.gitWorktreeCreator`, because a
choice assembled inline in a view is one no test can read back; the `create_workstream` section
in `docs/agents/ipc.md` has the rest of that story. Do not merge them or reroute one through the other:
`createWorktree` runs `worktree add --no-track -b <name> <dir> <start>`, so handing it a branch
that lives only as `origin/<name>` **succeeds** and produces a worktree named for that branch
while holding the base branch's code — and its `-b`-less fallback only rescues a *local* branch
of the name.

`createWorktreeTrackingRemote` fetches the branch, then `worktree add --track -b <branch> <dir>
origin/<branch>`. **In the `.bare` container layout the `-b` always fails and the fallback is the
ordinary path**, which is the non-obvious part: `git clone --bare` writes every branch into
`refs/heads`, and the refspec `BareRepoClone` configures afterwards only ever updates
`refs/remotes/origin/*`. So for every branch the clone captured, `refs/heads/<branch>` exists,
carries no upstream, and is as old as the clone. `adoptRemoteBranch` is what stops that becoming
"the worktree says `renovate/x` and holds three-week-old code": it sets the upstream and runs
`merge --ff-only origin/<branch>`, which advances a branch that is merely behind and refuses to
move one carrying unpushed commits. Do not "simplify" that to a `reset --hard`.

`remoteBranchTip` and `worktreePath(forBranch:)` are the dialog's pre-flight, and they run before
anything is created on purpose: git reports a missing branch and an already-checked-out branch as
ordinary failures, which arrive after the optimistic sidebar row is already drawn.

**The button that reaches all of this is gated on `AppEnvironment.hasGitHubRemote`, and which
cached fact that is matters more than it looks.** The whole flow is git: a typed branch name,
`remoteBranchTip`, `createWorktreeTrackingRemote`. None of it calls `gh`. It was gated on
`githubURL(for:)` instead, and that hid the button outright for every container-layout project —
`githubRepoCache` is written *only* by `refreshGitHubInfo`, which runs from `ProjectOverviewView`,
`WorkstreamInfoView` and `TerminalContainerView` and from nothing the sidebar draws, and the other
fallback is keyed by the project's *checkout*, so a lookup by `directory` cannot hit it however
many views have appeared. The feature shipped invisible. `hasGitHubRemote` and the GitHub browser
URL are now both filled by `refreshPathValidity`'s own sweep from one `git remote get-url`
(`GitHub.Operations.githubRemoteURL`), keyed by `directory`, so the row never depends on which
view the user happened to open — and `GitHub.Operations.shouldShowBranchButton` names the gate's
inputs outside the view body, the shape `Shortcut.Settings.shouldShowButton` already uses, because
a decision spelled inline in a row body is one nothing can pin.

### Remove vs purge
`Workstream.Archiver` exports both, and they are not the same thing.

| | `Archiver.remove` | `Archiver.purge` |
|---|---|---|
| Alert | "Remove Workstream" | "Purge Workstream" |
| Reached by | ⌘⇧W, the menu's "Archive Workstream", the palette, the sidebar context menu's "Remove" — and, per workstream through `Archiver.removeAllWorkstreams`, the three paths that delete a whole project: the sidebar's Delete, the sweep that drops a project whose directory has gone, and Clear Projects | the sidebar context menu's "Purge", and the Purge button on `WorkstreamInfoView`'s merged-PR banner |
| Runs `dispose`? | no | yes, before the worktree goes |
| Files on disk | **kept** | `git worktree remove`, local branch deleted, default branch re-fetched |
| Also | kills tmux sessions, releases permission holds, evicts surfaces (including check terminals, via `Verification.Runner.forget` — nothing else can reach them) and the whiteboard host, releases project task claims, drops `IPC.Config`, the status-line settings file and the launch log, clears the initialization state entry, and clears the workstream's agent state | same, plus cancels a running initialization through `Initialization.Runner.cancel`, stops the dev stack, waits out running verification checks through `Verification.Runner.stopAndWait`, then `forget`s that workstream in the runner and runs `clearWorkstreamState`, which drops the Execution checklist's selection key, the per-check verification records, and the saved session checkpoint |
| Guarded by | nothing — it destroys nothing | `purgeWarning` / `destroyableWorktreePath` |

**The "plus" in that last row is structural, not a promise.**
`Archiver.detachWorkstream` is the one synchronous main-actor tail both paths
run — permission holds, the whiteboard host and directory, the surfaces, the
task claims, `IPC.Config`, `StatusLine.Config`, the launch log, the workstream's
removal from the project, and `AgentStateTracker.clear` last. It exists because
the table was false for three of those steps: they were written into `remove`
alone, so a purge left an agent stopped on a permission banner waiting out a
deadline nothing would service, and leaked its mcp-config and `--settings` files
into Caches for good. A step added to that function cannot go missing from the
other path.

Two things both paths run but at *different points*, so they stay at their own
call sites rather than joining that tail: `Verification.Runner.forget`, which
`purge` runs awaited and only after `quiesceVerification` has watched the checks
actually die, and `Initialization.Runner.clearState`, which `purge` must run
after `Initialization.Runner.cancel` writes its final `.cancelled` state.
`clearWorkstreamState` is the one that is genuinely purge-only.

And the three project-deletion paths are archive paths. Each used to do
`removeWorkstreamSurfaces` and `AgentStateTracker.clear` and nothing else —
leaving a running check's terminal and its process alive for the session, an
offscreen `WKWebView` and its window per workstream, tmux sessions running, and
every per-workstream file in Caches. They go through
`Archiver.removeAllWorkstreams`, which takes the project **by value**: each
caller deletes the project in the same breath, and writing back per workstream
would publish the whole `@Published` list N times for a project about to leave
it. Nothing in that path touches the project directory on disk, which is what
makes it safe for the missing-directory sweep to call.

The naming is not self-consistent and reading it as such is the trap: the *menu*
says "Archive", its *alert* says "Remove", and the one that actually deletes work
is neither. `purge` is the destructive path, and everything in these docs
about `dispose` running at the end of a workstream's life describes `purge`
alone.

`destroyableWorktreePath` returns nil when the resolved path is the project
directory itself, and every destructive step is scoped to it. The `?? projectDir`
fallback that used to stand there reached `removeWorktree`, `deleteLocalBranch`
and `dispose` against the user's main checkout. `purgeOrphanWorktree` is the same
operation for a worktree no workstream owns, with its own `orphanPurgeWarning`.

### Base branch
`BaseBranchSetting` (`atelier.baseBranch`, Settings → General) chooses the branch new worktrees
are cut from: `main`, `master`, `trunk`, `develop`, or `repositoryDefault`, which asks
`Git.Operations.defaultBranch`. It defaults to `.main`, and it replaced `.atelier.json`'s
`base_branch` when that reader was deleted.

It has **exactly one production reader**: `Git.Operations.createWorktree`, via
`BaseBranchSetting.resolve(for:)`. `fetchDefaultBranch` takes an optional `branch:` so the
branch that is fetched and the branch the worktree is cut from are the same one — swapping the
selection without that gave "pick develop, fetch main".

**The setting names a branch; the worktree is cut from `origin/<branch>`.** That indirection is
`Git.Operations.creationStartPoint`, and it is what makes the fetch above mean anything. A fetch
only ever writes `refs/remotes/origin/<base>`, while the bare name `main` resolves the *local*
`refs/heads/main` first — and in the container layout that ref is the trunk checkout's own
branch, which moves only when somebody pulls. So for a year the fetch updated a ref the
`worktree add` never read, and every workstream started from whenever main was last pulled. The
start point falls back to the name as given when origin has no such branch (no remote, a
local-only base) and when the name already carries an `origin/` prefix, which `repositoryDefault`
usually does. The local ref is deliberately **not** advanced the way `adoptRemoteBranch` advances
one: here that ref belongs to the trunk checkout the user has open, and moving it under them is a
larger promise than cutting one worktree from origin's tip. `Tests/WorktreeBaseBranchTests.swift`
pins the three cases, and `fetchDefaultBranch`'s own "local main must not move" test
(`Tests/GitOperationsTests.swift`) is still correct and still passing — it asserts what a *fetch*
does, which this did not change.

The `--no-track` on that `worktree add` is not decoration. `startPoint` is normally a
remote-tracking ref, and git's default `branch.autoSetupMerge` would give the new branch an
upstream of `origin/<base>` — a different name from the branch itself, which makes a bare
`git push` in the workstream's terminal fail under `push.default=simple` and empties the
`@{upstream}..HEAD` range `hasUnpushedCommits` guards a purge with. `pushCurrentBranch` passes
`-u`, so the app's own push still sets an upstream when there is something to push.

**Known limitation, deliberate and unfixed:** **two** comparison sites in `Git.Operations` call
`defaultBranch(at:)` directly and do *not* consult this setting — `mergeBase` (the Changes tab's
diff base) and `hasBranchCommits` (the ahead count). So with the setting on `develop` in a
repository whose git default is `main`, a worktree is cut from `develop` while its diff and its
ahead count are measured against `main`. Two reviewers disagreed on whether those sites should
follow the setting — a diff base and a creation base are arguably different questions — so it
stays a follow-up rather than a half-migration finished in the dark. Do not "fix" one of the two;
either both move or neither does.

**It was three, and the third was deleted rather than migrated.** `worktreeDetail` computed an
unmerged-commit log against `defaultBranch(at:)`, but the view that rendered it —
`WorktreeDetailSheet` — went in 2e6f2f8, and nothing read the field afterwards. So the rule was
discharged the way it always allowed: `unmergedCommits`, `unmergedCommitsUnavailable`, the
`UnmergedCommit` type and the `git log base..HEAD` call are **gone**, along with
`worktreeDetail`'s `mainRepoPath:` parameter, which existed only to resolve that base.
`worktreeDetail` itself is still live and still takes `at:` — `ProjectOverviewView` calls it for
the project's own repository and uses the file changes — it simply no longer resolves a base
branch at all, so it is not a comparison site and must not be counted as one.

That is the *only* sanctioned way to reduce the count. The all-or-none rule is about keeping one
question answered one way: a site may leave it by being **deleted**, never by being quietly
migrated on its own. Both survivors are load-bearing and user-visible, so neither has that exit —
if `mergeBase` or `hasBranchCommits` is ever pointed at `BaseBranchSetting`, the other moves in
the same change. And if the commit log is ever wired up again, it rejoins the count and the rule
binds three once more.

`defaultBranch(at:)` is also read to export `ATELIER_DEFAULT_BRANCH`, and **every producer of
that variable reads it** — `ProcessCompose.PhaseEnvironment.variables` is the assembler they all
go through, plus `TerminalContainerView` for a terminal surface. Those are *not* part of that
follow-up: the variable means "what git thinks this repository's default branch is", and they
deliberately agree with each other rather than with the setting. **The rule is stated rather than
enumerated on purpose** — the caller list was written out once, as four, and was six by the time
anyone checked; `WorkspaceActions.executionTarget` and `IPCService+AgentSpawn.codingAgentEnvironment`
had joined it and were exempted only by silence. A new producer inherits the rule by reading
`defaultBranch(at:)`, which is the only thing that has to stay true.

**`defaultBranch(at:)` is cached, per directory, inside `Git.Operations` itself.** Resolving costs up
to six sequential probes and the answer is a property of the repository, but both comparison
sites are called *per worktree*: `refreshPathValidity` runs `hasBranchCommits` for every
worktree on a 15-second timer, and `listWorktreesWithInfo` does the same on every project-overview
refresh. Twelve workstreams in two projects meant ~72 subprocesses a tick resolving two strings.
(There was a third caller on that hot path, `worktreeDetail`'s commit log, until it was deleted;
the cache predates that and is not affected by it.)

The cache lives there rather than in `AppEnvironment`, which is where it started, because half the
callers structurally cannot reach a `@MainActor` type: `diffFingerprint` is called from
`Verification.Runner`, `IPC.VerificationRunnerBridge` and `VerificationTabView`, and
`ChangesView.baseRef` is `nonisolated`. The alternative — threading a resolved branch down as a
parameter — would have had to stop at those call sites or point `Verification.Runner` at
`AppEnvironment`, which is the wrong direction for that dependency.
`AppEnvironment.defaultBranch(for:)` now **delegates** here and keeps only the two things a
`@MainActor` caller needs on top: somewhere off the main thread to run a blocking probe, and
in-flight de-duplication, which a lock gives no help with. One cache, one policy.

It deliberately does **not** cache the literal `"HEAD"`: that is the sentinel for "resolved
nothing", which for a freshly added project usually means `origin/HEAD` has not been fetched yet —
and `fetchOrigin` is running concurrently to fix exactly that. There is no other invalidation and no
TTL; a repository whose default branch genuinely renames mid-session serves the old answer until
relaunch. Both halves are pinned in `Tests/GitOperationsTests.swift` and
`Tests/AppEnvironmentDefaultBranchTests.swift`.

None of this touches the all-or-none rule above. That rule governs *which* branch is compared — git's
default versus `BaseBranchSetting` — not who pays to resolve it, and a cache that returns exactly
what `defaultBranch(at:)` would have returned leaves the question byte-identical. Say so in any
commit that touches it, because a reviewer will pattern-match it to the forbidden migration.
