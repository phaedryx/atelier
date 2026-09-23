// ABOUTME: Handles removing and purging workstreams from projects.
// ABOUTME: Shared by ContentView and ProjectSidebar to avoid duplicated workstream cleanup logic.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "workstream-archiver")

extension Workstream {
    enum Archiver {
        /// Paths currently being archived (background removal in progress).
        @MainActor static var archivingPaths: Set<String> = []

        /// Posted on MainActor when a background worktree removal finishes.
        static let archivingDidComplete = Notification.Name("FFWorktreeArchivingComplete")

        /// Posted on MainActor when a background worktree removal begins.
        static let archivingDidStart = Notification.Name("FFWorktreeArchivingStart")

        /// Removes a workstream from the project without deleting the worktree from disk.
        /// Kills running terminals and tmux sessions but leaves files intact.
        @MainActor
        static func remove(
            _ workstreamID: UUID,
            in project: inout Project,
            surfaceCache: TerminalSurfaceCache,
            tmuxPath: String?,
            verificationRunner: Verification.Runner? = nil,
            agentStateTracker: Workstream.AgentStateTracker
        ) {
            if let ws = project.workstreams.first(where: { $0.id == workstreamID }) {
                let projName = project.name
                let wsName = ws.name
                Task.detached {
                    if let tmuxPath {
                        TmuxSession.killWorkstreamSessions(tmuxPath: tmuxPath, project: projName, workstream: wsName)
                    }
                }
            }
            // Before the sweep in the shared tail, which cannot reach a check's
            // terminal: that sweep enumerates ids derived from
            // `WorkspaceModel`'s counters, and a check surface is keyed by
            // `Verification.Spawn.surfaceID`. Without this, removing a
            // workstream with rspec running leaves that terminal and its process
            // alive for the session with nothing able to reach either. Optional
            // only so the two call sites can adopt it without a third having to
            // invent a runner; both pass one.
            //
            // Deliberately **not** in `detachWorkstream`, however much it looks
            // like it belongs there. `purge` reaches the same call from inside
            // its detached task, awaited and only after `quiesceVerification`
            // has watched the checks actually die; hoisting it would run it
            // here, before the stop, which is the "signalled and moved on"
            // ordering that teardown exists to prevent.
            verificationRunner?.forget(workstreamID: workstreamID)
            // `Initialization.Runner.states` is in memory and keyed by the
            // workstream id this is about to drop from the project, so an entry
            // left here is unreachable for the life of the process — the same
            // leak, and the same discriminator, that `purge`'s own call to this
            // records at the end of its detached task. Not hoisted into
            // `detachWorkstream` for the reason `forget` above is not: `purge`
            // must clear *after* `Initialization.Runner.cancel`, which writes a
            // final `.cancelled` state, and an early clear there would be
            // overwritten by the very run it is meant to forget.
            Task { await Initialization.Runner.shared.clearState(for: workstreamID) }
            detachWorkstream(
                workstreamID,
                from: &project,
                surfaceCache: surfaceCache,
                agentStateTracker: agentStateTracker
            )
        }

        /// Archive every workstream of a project that is itself about to be
        /// dropped from the list.
        ///
        /// Three paths delete a project — the sidebar's Delete, the sweep that
        /// drops projects whose directory has gone, and Clear Projects — and all
        /// three used to do only `removeWorkstreamSurfaces` plus
        /// `AgentStateTracker.clear`, skipping everything else `remove` does. A
        /// running verification check kept its terminal and its process for the
        /// session with nothing able to reach either, an offscreen `WKWebView`
        /// and its window leaked per workstream, permission holds were never
        /// released, tmux sessions were left running, and the mcp-config,
        /// `--settings` and launch-log files stayed in Caches. AGENTS.md's own
        /// warning next to `clearAgentState` is that "a third archive path would
        /// forget it" — there were three.
        ///
        /// **By value, not `inout`.** Every caller deletes the project in the
        /// same breath, so there is nothing to write back — and the callers hold
        /// the list as a `Binding` onto a `@Published` array, where a write per
        /// workstream would publish the whole list N times over, each one
        /// re-running `onChange(of: projectList.items)`, for a project that is
        /// about to leave it anyway.
        ///
        /// Nothing here touches the project directory on disk, which is what
        /// makes it safe for the missing-directory sweep to call: the worktrees
        /// are left exactly as `remove` leaves them.
        @MainActor
        static func removeAllWorkstreams(
            in project: Project,
            surfaceCache: TerminalSurfaceCache,
            tmuxPath: String?,
            verificationRunner: Verification.Runner? = nil,
            agentStateTracker: Workstream.AgentStateTracker
        ) {
            var project = project
            let projectName = project.name
            let workstreamNames = project.workstreams.map(\.name)
            // Over a snapshot of the ids: `remove` drops each one from
            // `project.workstreams` as it goes.
            for workstreamID in project.workstreams.map(\.id) {
                remove(
                    workstreamID,
                    in: &project,
                    surfaceCache: surfaceCache,
                    // Deliberately nil, and the tmux kill is done once below
                    // instead. `remove` kills its workstream's sessions from a
                    // `Task.detached`, and `killWorkstreamSessions` is two
                    // `ProcessRunner` spawns — each blocking its thread for the
                    // child's whole life. One of those is the shape `remove`
                    // has always had; *N at once* is the documented production
                    // failure this codebase measured, where fourteen of
                    // fourteen cooperative threads parked in `capture` and
                    // every child was killed at its deadline, `tmux -V` blowing
                    // a 120s bound among them. Clearing a list of a dozen
                    // workstreams would have reached it directly.
                    tmuxPath: nil,
                    verificationRunner: verificationRunner,
                    agentStateTracker: agentStateTracker
                )
            }
            guard let tmuxPath, !workstreamNames.isEmpty else { return }
            // One queue, one thread, the kills serialized on it — rather than
            // `Task.detached`, which is the cooperative pool the paragraph above
            // is about. The names were snapshotted before the loop, because
            // `remove` has emptied `project.workstreams` by now.
            DispatchQueue.global(qos: .utility).async {
                for workstreamName in workstreamNames {
                    TmuxSession.killWorkstreamSessions(
                        tmuxPath: tmuxPath, project: projectName, workstream: workstreamName
                    )
                }
            }
        }

        /// Everything both archive paths do to end a workstream in the app,
        /// synchronously and on the main actor.
        ///
        /// The `Remove vs purge` table in AGENTS.md says purge does what remove
        /// does "plus" more, and for three of these steps it did not: releasing
        /// a permission hold, and dropping the mcp-config and `--settings`
        /// files, were written into `remove` alone. A purge of a workstream
        /// whose agent sat on a permission banner left that agent waiting out a
        /// deadline nothing would service, and leaked two files into Caches for
        /// good. One function is what keeps the table true — a fourth step added
        /// to one path cannot go missing from the other.
        ///
        /// What stays *out* of here is as load-bearing as what is in it, and a
        /// reviewer should expect to find each of these at its own call site
        /// rather than folded in: `Verification.Runner.forget` and
        /// `Initialization.Runner.clearState`, which both paths run but at
        /// different points (see `remove`); everything destructive, which is
        /// `purge`'s alone; and `clearWorkstreamState`, which is purge-only
        /// because `remove` keeps the worktree and destroys nothing.
        @MainActor
        private static func detachWorkstream(
            _ workstreamID: UUID,
            from project: inout Project,
            surfaceCache: TerminalSurfaceCache,
            agentStateTracker: Workstream.AgentStateTracker
        ) {
            // First, and before the surfaces go: an agent here may be stopped on
            // a permission request, and the banner that would answer it is about
            // to stop existing. Releasing hands it back to Claude Code instead
            // of leaving it to wait out a hold nothing will service. A
            // workstream holding nothing makes this a no-op, which is what lets
            // both paths call it unconditionally.
            PermissionApprovalStore.shared.releaseAll(workstreamID: workstreamID)
            // The whiteboard goes on **both** archive paths — and deliberately
            // *not* the way `clearWorkstreamState` is, which is purge-only
            // because `remove` keeps the worktree and destroys nothing. A
            // reviewer will pattern-match this to that rule, so:
            //
            // A board is keyed by the workstream's UUID, and both paths drop the
            // workstream from the project. Re-adopting the worktree mints a new
            // id, so nothing can ever reach that board again — left behind it is
            // unreachable bytes in a cache, not preserved work. That is the
            // discriminator.
            //
            // Host first, then the directory: the host holds a live webview with
            // a save still sitting on its debounce, and sweeping underneath it
            // would let one last save recreate what was just removed.
            surfaceCache.removeWhiteboardHost(for: workstreamID)
            Whiteboard.Store.sweep(for: workstreamID)
            surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
            // Fire-and-forget: reverting an in-memory dictionary entry back to
            // `.pending` carries none of the weight `Verification.Runner.forget`
            // does (killing running processes, waiting on them), so this does not
            // need the injected-optional-parameter pattern that exists for that
            // heavier operation — same shape as the tmux-kill `Task.detached` in
            // `remove`. A project with no tasks, or a workstream with no claims,
            // makes this a genuine no-op.
            Task { await IPC.Service.shared.releaseTaskClaims(inWorkstream: workstreamID) }
            // The agent's mcp-config JSON and its `--settings` file, both named
            // for this workstream id. Nothing re-reads either once the
            // workstream is gone, so a path that skips them leaks two files into
            // Caches per archive, for good.
            IPC.Config.remove(for: workstreamID)
            StatusLine.Config.remove(for: workstreamID)
            LaunchLogger.removeLog(for: workstreamID)
            project.workstreams.removeAll { $0.id == workstreamID }
            clearAgentState(workstreamID, tracker: agentStateTracker)
        }

        /// Drop the agent-state entry for a workstream both archive paths are ending.
        ///
        /// Here rather than at the two call sites for the reason
        /// `Verification.Runner.forget` moved here: it is cleanup belonging to
        /// archiving a workstream, it was copied into `ContentView` and
        /// `ProjectSidebar` alike, and a third archive path would forget it.
        ///
        /// **Last, and synchronous.** `clear` is not a plain state drop — it
        /// posts `.agentPermissionResolved` on its way out, which `ContentView`
        /// receives. Called as the final statement of each function's
        /// synchronous tail, that notification fires in the same main-actor turn
        /// and in the same order relative to `project.workstreams.removeAll` as
        /// it did when the views made the call themselves. In particular it does
        /// **not** belong in `purge`'s detached task beside
        /// `clearWorkstreamState`, however similar the flavour: that block runs
        /// after dispose and `git worktree remove`, which can be minutes later.
        @MainActor
        private static func clearAgentState(
            _ workstreamID: UUID,
            tracker: Workstream.AgentStateTracker
        ) {
            tracker.clear(workstreamID: workstreamID)
        }

        /// Check if purging a workstream would lose work. Returns a warning message
        /// describing what would be lost, or nil if it is safe to purge.
        static func purgeWarning(for workstream: Workstream) -> String? {
            purgeWarning(forWorktreeAt: workstream.worktreePath)
        }

        /// The same decision against a bare path.
        ///
        /// Split out so the probe can be handed to a background queue carrying
        /// only a `String`: this runs `git status --porcelain` and
        /// `git log @{upstream}..HEAD` through `ProcessRunner`, which blocks its
        /// thread for the child's whole life, and `Workstream` is not what needs
        /// to cross that boundary. See `PurgeConfirmation.present`.
        static func purgeWarning(forWorktreeAt path: String?) -> String? {
            guard let path else { return nil }
            // A probe that did not run must not read as "nothing here": this warning
            // is the only thing between the user and a --force removal.
            guard let uncommitted = Git.Operations.hasUncommittedChanges(at: path) else {
                return NSLocalizedString(
                    "This workstream's contents could not be read, so anything unsaved in it would be lost.",
                    comment: "Purge warning when the git probe failed"
                )
            }
            var warnings: [String] = []
            if uncommitted {
                warnings.append(NSLocalizedString("uncommitted changes", comment: ""))
            }
            // A probe that could not run must not drop out of the warning
            // silently — that is exactly the bug this half of the check exists
            // to close. Say "possibly unpushed" rather than staying quiet.
            switch Git.Operations.hasUnpushedCommits(at: path) {
            case true:
                warnings.append(NSLocalizedString("unpushed commits", comment: ""))
            case false:
                break
            case nil:
                warnings.append(NSLocalizedString("possibly unpushed commits", comment: ""))
            }
            guard !warnings.isEmpty else { return nil }
            let list = warnings.joined(separator: NSLocalizedString(" and ", comment: ""))
            return String(
                format: NSLocalizedString("This workstream has %@ that will be lost.", comment: ""),
                list
            )
        }

        /// The worktree `purge` is allowed to destroy, or nil when there is none.
        ///
        /// Deliberately not `Workstream.workingDirectory(checkout:)`. That falls
        /// back to the project's checkout, which is the right answer for opening
        /// a terminal and the wrong one for everything `purge` does: a
        /// workstream archived before `workstreamWorktreeReady` lands has no
        /// worktree path, and the fallback handed the user's main checkout to
        /// `Git.Operations.removeWorktree` (which deletes the path it is given),
        /// to `deleteLocalBranch` (with whatever branch that checkout was on), and
        /// to `dispose` (which runs project-authored processes).
        ///
        /// A path that names one of those directories under a different spelling
        /// is refused for the same reason, so the check cannot be defeated by a
        /// trailing slash or a symlink the two paths disagree about.
        ///
        /// **Both directories, and both are load-bearing.** In the `.bare`
        /// container layout `Project.directory` is the container and
        /// `Project.checkout` is the default worktree inside it, and neither is
        /// ever a workstream: the container holds every workstream as a peer,
        /// and the checkout is the trunk. Naming only one would leave the other
        /// destroyable — and which one that is depends on which the caller
        /// happened to pass, which is exactly the ambiguity this change exists
        /// to remove.
        static func destroyableWorktreePath(
            for workstream: Workstream,
            projectDirectory: String,
            checkoutDirectory: String? = nil
        ) -> String? {
            destroyablePath(
                workstream.worktreePath,
                projectDirectory: projectDirectory,
                checkoutDirectory: checkoutDirectory
            )
        }

        /// The same decision for a path that belongs to no workstream.
        ///
        /// Extracted so the orphan path can ask it too: `purgeOrphanWorktree`
        /// takes a bare string straight to `removeWorktree` and
        /// `deleteLocalBranch` and has never had a guard of its own. The rule is
        /// the one `destroyableWorktreePath` states above and there is exactly
        /// one copy of it — an orphan purge that re-derived "is this the
        /// project's own directory" would be the inlined second copy this
        /// codebase keeps warning about, and the two would drift on the first
        /// spelling that only one of them canonicalized.
        static func destroyablePath(
            _ stored: String?,
            projectDirectory: String,
            checkoutDirectory: String? = nil
        ) -> String? {
            // Absolute only. `URL(fileURLWithPath:)` resolves a relative string
            // against the *process's* working directory, which has nothing to do
            // with this project — so it never equals the protected set and sails
            // through the guard below. The raw string is then what
            // `removeWorktree` and `deleteLocalBranch` are handed, and they
            // resolve it against a working directory of their own. `~` is not
            // expanded for the same reason: only a path that already names one
            // directory can be reasoned about here.
            guard let stored else { return nil }
            let path = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }

            // `String.canonicalPath` rather than `resolvingSymlinksInPath()`,
            // which is a no-op on a path that is not on disk and so answered
            // this correctly only while every path involved happened to exist.
            let resolved = path.canonicalPath
            let protected = Set(
                [projectDirectory, checkoutDirectory].compactMap(\.self).map(\.canonicalPath)
            )
            return protected.contains(resolved) ? nil : path
        }

        /// Purges a workstream by stopping everything still running in its worktree — the dev
        /// stack, an initialization, a verification check — then running its `dispose` phase, removing the git
        /// worktree from disk, deleting the local branch, updating the default branch to latest,
        /// killing tmux sessions, and evicting terminal surfaces from the cache.
        ///
        /// `verificationRunner` is required rather than optional: it is how the
        /// verify run is stopped *through its owner* instead of behind its back
        /// — see `quiesceVerification` — and an optional would make forgetting
        /// to pass it a silent return to the bug that API exists to close. Both
        /// call sites are views `ContentView` builds, and it holds the one
        /// runner the app has.
        ///
        /// `agentStateTracker` is required on the same terms, in both this and
        /// `remove`: it is a `@MainActor` singleton any caller can reach, so the
        /// migration concession behind `verificationRunner`'s optionality does
        /// not apply, and a forgotten `clear` fails silently — stale `states`,
        /// `rosters` and `surfaceStates` entries, and a permission edge that is
        /// never posted.
        @MainActor
        static func purge(
            _ workstreamID: UUID,
            in project: inout Project,
            surfaceCache: TerminalSurfaceCache,
            tmuxPath: String?,
            verificationRunner: Verification.Runner,
            agentStateTracker: Workstream.AgentStateTracker
        ) {
            if let ws = project.workstreams.first(where: { $0.id == workstreamID }) {
                let projectDir = project.directory
                // Everything destructive below is scoped to this, and it is nil for a
                // workstream whose worktree does not exist yet. See
                // `destroyableWorktreePath`: the `?? projectDir` fallback that used to
                // stand here reached `removeWorktree`, `deleteLocalBranch` and
                // `dispose` — none of which had any business touching the user's main
                // checkout.
                let worktreePath = destroyableWorktreePath(
                    for: ws,
                    projectDirectory: projectDir,
                    checkoutDirectory: project.checkoutDirectory
                )
                let standardizedPath = URL(fileURLWithPath: worktreePath ?? projectDir).standardizedFileURL.path
                let wsName = ws.name
                let projName = project.name
                archivingPaths.insert(standardizedPath)
                NotificationCenter.default.post(name: archivingDidStart, object: nil)
                Task.detached {
                    defer {
                        Task { @MainActor in
                            archivingPaths.remove(standardizedPath)
                            NotificationCenter.default.post(name: archivingDidComplete, object: nil)
                        }
                    }
                    // Initialization for this workstream may still be running: it
                    // goes on in the background behind an already-open terminal, so
                    // "created a workstream, then archived it" overlaps them. Stop
                    // it before dispose runs in the same directory and before
                    // `git worktree remove` deletes that directory underneath it.
                    // Before anything else: stop the dev stack. In tmux mode the
                    // surface removal above only detaches, so without this the
                    // `execute` run kept going *through* dispose — two
                    // process-compose runs over one project — and then through
                    // `git worktree remove --force`, which deletes the tree under
                    // it.
                    if let tmuxPath {
                        TmuxSession.killRunSession(tmuxPath: tmuxPath, project: projName, workstream: wsName)
                    }
                    await Initialization.Runner.shared.cancel(
                        for: workstreamID,
                        worktreePath: worktreePath ?? projectDir
                    )
                    // A running check is the project's own command executing in
                    // this worktree, so it is stopped before `dispose` runs beside
                    // it and long before `git worktree remove --force` deletes the
                    // tree under a running rspec.
                    //
                    // Through the runner, and awaited, rather than by killing the
                    // process group here: `stop` only asks, and `stopAndWait` is
                    // what watches the process actually go. A purge that signalled
                    // and moved on would delete the tree under a check that had not
                    // died yet.
                    let verifyQuiet = await quiesceVerification(
                        workstreamID: workstreamID, runner: verificationRunner
                    )
                    if !verifyQuiet {
                        // Reported rather than acted on: nothing here can stop
                        // the archive, and the user has already said to remove
                        // it. See `quiesceVerification`.
                        logger.warning(
                            "Verification checks in \(wsName, privacy: .public) were still live at their stop deadline; purging anyway"
                        )
                    }
                    // Before anything below writes, and before the wait's other
                    // outcome matters. On the ordinary path every check is already
                    // finished and recorded; on an expired wait this is what stops
                    // the completion pass recording a result, or announcing one, for
                    // a workstream that is being deleted. It also drops the check
                    // surfaces. See `Runner.forget`.
                    await verificationRunner.forget(workstreamID: workstreamID)
                    // Everything below blocks: dispose is a whole process-compose
                    // phase at up to `Timeout.userCommand`, and each git call waits
                    // on a child. On the cooperative pool that pins a thread for
                    // minutes, so it goes to a utility queue — the same bridge
                    // `Initialization.Runner` uses for setup, and for the same
                    // reason.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            if let worktreePath {
                                // Read before anything below removes the
                                // worktree, and read *here* rather than on the
                                // main actor where it used to be: this goes
                                // through `ProcessRunner`, which blocks its
                                // thread for the child's whole life, so on a
                                // large repository it froze the UI before the
                                // confirmation alert had even been answered.
                                // This queue, not the enclosing `Task.detached`,
                                // for the reason the comment above it gives —
                                // a blocking child on the cooperative pool is
                                // the documented way to park every thread in it.
                                let branchName = Git.Operations.currentBranch(at: worktreePath)
                                // Before the worktree is removed: dispose runs
                                // in it.
                                runDispose(
                                    workstreamID: workstreamID,
                                    projectName: projName,
                                    workstreamName: wsName,
                                    worktreePath: worktreePath,
                                    projectDirectory: projectDir
                                )
                                // Logged here rather than left to the caller: a purge
                                // that cannot remove the worktree used to be found out
                                // from a *later* `worktree list`, which says the
                                // worktree is still registered and not one word about
                                // why. git's own stderr — "contains modified files",
                                // "is a main working tree" — is the answer, and this
                                // is the only place it exists.
                                if case let .failure(failure) = Git.Operations.removeWorktree(
                                    projectPath: projectDir, worktreePath: worktreePath
                                ) {
                                    logger.error("[Atelier] purge could not remove the worktree: \(failure.description, privacy: .public)")
                                }
                                if let branchName,
                                   case let .failure(failure) = Git.Operations.deleteLocalBranch(
                                       at: projectDir, branchName: branchName
                                   )
                                {
                                    logger.error("[Atelier] purge could not delete branch \(branchName, privacy: .public): \(failure.description, privacy: .public)")
                                }
                            }
                            Git.Operations.fetchDefaultBranch(at: projectDir)
                            if let tmuxPath {
                                TmuxSession.killWorkstreamSessions(tmuxPath: tmuxPath, project: projName, workstream: wsName)
                            }
                            // Clean up the agent launch script for this workstream.
                            try? FileManager.default.removeItem(atPath: AppConstants.agentScriptPath(for: workstreamID))
                            continuation.resume()
                        }
                    }
                    // The state entry outlives the workstream otherwise: nothing
                    // else called this, so `states` grew by one per archive for the
                    // life of the process.
                    await Initialization.Runner.shared.clearState(for: workstreamID)
                    // Same reason, and last on purpose: the verify teardown above
                    // makes the run loop seal, and `seal` writes the run to this
                    // very key. Clearing it beside that teardown would be
                    // overwritten a moment later. A late seal can no longer
                    // reach the key at all — `forget` above drops the in-memory
                    // run, and `seal` writes nothing for a workstream it cannot
                    // find — so this is now only about what was already stored.
                    clearWorkstreamState(for: workstreamID)
                }
            }
            // The same tail `remove` runs, and that is the whole of the "plus"
            // in AGENTS.md's table: everything above this line is purge's alone.
            detachWorkstream(
                workstreamID,
                from: &project,
                surfaceCache: surfaceCache,
                agentStateTracker: agentStateTracker
            )
        }

        /// Stop this workstream's verification checks and wait until none of them
        /// is live, before anything below deletes the tree they are running in.
        ///
        /// Returns whether the runner reports it gone. **False does not stop the
        /// purge**, and that is the same rule `runDispose` states: a workstream
        /// stranded half-archived is worse than cleanup that did not happen, and
        /// the user has already said to remove it. What false buys is that the
        /// caller knows, can log it, and can still make its own best-effort
        /// teardown attempt afterwards.
        ///
        /// Split out and internal for the reason `disposePlan` is: `purge`
        /// proper destroys a worktree, so the wiring is only observable if there
        /// is a seam beside it. A test can drive a runner whose control server
        /// never answers and watch this refuse to report it quiet — which is the
        /// binding window a direct `ProcessCompose.PhaseExecutor.shutDown` used
        /// to sail straight through.
        @MainActor
        @discardableResult
        static func quiesceVerification(
            workstreamID: UUID,
            runner: Verification.Runner,
            timeout: TimeInterval = ProcessRunner.Timeout.userCommand
        ) async -> Bool {
            await runner.stopAndWait(workstreamID: workstreamID, timeout: timeout)
        }

        /// Drop every per-workstream UserDefaults key a purge must not leave
        /// behind.
        ///
        /// Three keys, and that is the reason this is a function rather than a
        /// few lines inline: `atelier.processSelection.<id>` is Execution's
        /// checklist selection, `atelier.verifyChecks.<id>` is Verification's
        /// per-check results — it has no checklist or selection of its own, only
        /// results a check can be re-run to replace — and
        /// `atelier.sessionCheckpoint.<id>` is the IPC session-checkpoint tools'
        /// saved note. Named together here so a fourth key has one place to
        /// join.
        ///
        /// Nonisolated: `purge` calls it from a detached task, and none of these
        /// reads touches the main actor.
        ///
        /// Purge only. `remove` keeps the worktree on disk and destroys nothing,
        /// so a selection, result, or checkpoint it left behind is the shape
        /// that has always been there and is not this function's to change.
        static func clearWorkstreamState(for workstreamID: UUID) {
            ProcessCompose.TableModel.clearSelection(for: workstreamID)
            // The Verification tab has no checklist and no selection key; what outlives
            // a purged workstream is its per-check results, and only those. The run
            // store that used to be cleared here is gone — runs live in memory for the
            // session and `Runner.forget` drops them.
            Verification.CheckStore.clear(for: workstreamID)
            IPC.CheckpointStore.clear(for: workstreamID)
        }

        /// What archiving would run, and why it would not.
        ///
        /// Split out from `runDispose` and left internal so the wiring is
        /// observable: a `runDispose` that stopped consulting `PhasePolicy`
        /// altogether would still pass every test of the policy itself. This is the
        /// seam a test can hold, since `runDispose` proper spawns process-compose
        /// and `purge` destroys a worktree.
        static func disposePlan(worktreePath _: String, projectDirectory: String) -> PhasePolicy.Plan {
            PhasePolicy.plan(
                phase: .dispose,
                config: ProcessCompose.Config.locate(projectDirectory: projectDirectory),
                binary: ProcessCompose.Settings.resolveBinary()
            )
        }

        /// Run the project's `dispose` namespace before the worktree goes away.
        ///
        /// This replaces the `teardown` script: a project now says what archiving
        /// should clean up in the same file it uses for everything else.
        ///
        /// The preconditions are not restated here. `PhasePolicy.plan` owns
        /// them — a config located, a binary to run it with, and approval of every
        /// repository-provided file process-compose will load — and dispose is
        /// unattended with nobody watching, so a second inline copy
        /// would be a second security policy with no tests and no way to follow a
        /// change made to the first.
        ///
        /// Nothing here can stop the archive. Every refusal returns quietly and a
        /// failure is logged and swallowed: a workstream stranded half-archived is
        /// worse than cleanup that did not happen, and the user has already said to
        /// remove it. `ProcessCompose.PhaseExecutor` bounds the run at `Timeout.userCommand`, so a
        /// wedged dispose delays the archive rather than blocking it forever.
        private static func runDispose(
            workstreamID: UUID,
            projectName: String,
            workstreamName: String,
            worktreePath: String,
            projectDirectory: String
        ) {
            let plan = disposePlan(worktreePath: worktreePath, projectDirectory: projectDirectory)
            let config: ProcessCompose.Config
            let binary: String
            switch plan {
            case let .run(planned, planBinary):
                config = planned
                binary = planBinary
            case let .nothingToDo(message):
                logger.info("No dispose for \(worktreePath, privacy: .public): \(message, privacy: .public)")
                return
            }

            // The same variables `prepare` and `execute` see. A `dispose` process
            // that has to reach the project directory or a declared port cannot do
            // it from the app's own environment; see `ProcessCompose.PhaseEnvironment`.
            let environment = ProcessCompose.PhaseEnvironment.variables(
                workstreamID: workstreamID,
                projectName: projectName,
                workstreamName: workstreamName,
                projectDirectory: projectDirectory,
                worktreePath: worktreePath,
                defaultBranch: Git.Operations.defaultBranch(at: projectDirectory)
            )

            let outcome = ProcessCompose.PhaseExecutor.run(
                phase: .dispose,
                config: config,
                binary: binary,
                workstreamID: workstreamID,
                workingDirectory: worktreePath,
                environment: environment,
                timeout: ProcessRunner.Timeout.userCommand
            )
            if case let .failed(detail) = outcome {
                logger.warning("Dispose for \(worktreePath, privacy: .public) failed: \(detail, privacy: .public)")
            }
        }

        /// Warning describing what work would be lost if the orphan worktree at `path`
        /// is purged, or nil if it is safe to purge.
        static func orphanPurgeWarning(at path: String) -> String? {
            guard let uncommitted = Git.Operations.hasUncommittedChanges(at: path) else {
                return NSLocalizedString(
                    "This worktree's contents could not be read, so anything unsaved in it would be lost.",
                    comment: "Orphan purge warning when the git probe failed"
                )
            }
            var warnings: [String] = []
            if uncommitted {
                warnings.append(NSLocalizedString("uncommitted changes", comment: ""))
            }
            // See `purgeWarning` above: a probe that could not run must not
            // drop out of the warning silently.
            switch Git.Operations.hasUnpushedCommits(at: path) {
            case true:
                warnings.append(NSLocalizedString("unpushed commits", comment: ""))
            case false:
                break
            case nil:
                warnings.append(NSLocalizedString("possibly unpushed commits", comment: ""))
            }
            guard !warnings.isEmpty else { return nil }
            let list = warnings.joined(separator: NSLocalizedString(" and ", comment: ""))
            return String(
                format: NSLocalizedString("This worktree has %@ that will be lost.", comment: ""),
                list
            )
        }

        /// Purges an orphan worktree (one that is not associated with any workstream):
        /// removes the worktree from disk, deletes the local branch, and refreshes
        /// the default branch. Does not touch workstream-only state (terminals,
        /// tmux, agent script) because there is none.
        @MainActor
        static func purgeOrphanWorktree(projectDirectory: String, worktreePath: String) {
            let standardizedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
            archivingPaths.insert(standardizedPath)
            NotificationCenter.default.post(name: archivingDidStart, object: nil)
            Task.detached {
                defer {
                    Task { @MainActor in
                        archivingPaths.remove(standardizedPath)
                        NotificationCenter.default.post(name: archivingDidComplete, object: nil)
                    }
                }
                // Every git call below blocks its thread for the child's whole
                // life, so they go to a utility queue rather than staying on the
                // cooperative pool this detached task runs on — the same bridge
                // `purge` uses, and for the reason stated there. `currentBranch`
                // in particular used to run on the *main actor*, before the
                // caller's confirmation alert had been drawn.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        // Before the worktree is removed out from under it.
                        let branchName = Git.Operations.currentBranch(at: worktreePath)
                        // Same as `purge`: git's stderr is the only account of why an
                        // orphan could not be removed, and nothing downstream can recover it.
                        if case let .failure(failure) = Git.Operations.removeWorktree(
                            projectPath: projectDirectory, worktreePath: worktreePath
                        ) {
                            logger.error("[Atelier] orphan purge could not remove the worktree: \(failure.description, privacy: .public)")
                        }
                        if let branchName,
                           case let .failure(failure) = Git.Operations.deleteLocalBranch(
                               at: projectDirectory, branchName: branchName
                           )
                        {
                            logger.error("[Atelier] orphan purge could not delete branch \(branchName, privacy: .public): \(failure.description, privacy: .public)")
                        }
                        Git.Operations.fetchDefaultBranch(at: projectDirectory)
                        continuation.resume()
                    }
                }
            }
        }
    }
}
