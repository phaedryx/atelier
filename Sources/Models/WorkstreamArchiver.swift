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
            // Before the surfaces go: an agent here may be stopped on a
            // permission request, and the banner that would answer it is about
            // to stop existing. Releasing hands it back to Claude Code instead
            // of leaving it to wait out a hold nothing will service.
            PermissionApprovalStore.shared.releaseAll(workstreamID: workstreamID)
            // Before the sweep below, which cannot reach a check's terminal: that
            // sweep enumerates ids derived from `WorkspaceModel`'s counters, and a
            // check surface is keyed by `Verification.Spawn.surfaceID`. Without
            // this, removing a workstream with rspec running leaves that terminal
            // and its process alive for the session with nothing able to reach
            // either. Optional only so the two call sites can adopt it without a
            // third having to invent a runner; both pass one.
            verificationRunner?.forget(workstreamID: workstreamID)
            surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
            // Fire-and-forget: reverting an in-memory dictionary entry back to
            // `.pending` carries none of the weight `verificationRunner?.forget`
            // above does (killing running processes, waiting on them), so this
            // does not need the injected-optional-parameter pattern that exists
            // for that heavier operation — same shape as the tmux-kill
            // `Task.detached` at the top of this function. A project with no
            // tasks, or a workstream with no claims, makes this a genuine no-op.
            Task { await IPC.Service.shared.releaseTaskClaims(inWorkstream: workstreamID) }
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
            guard let path = workstream.worktreePath else { return nil }
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
            // Absolute only. `URL(fileURLWithPath:)` resolves a relative string
            // against the *process's* working directory, which has nothing to do
            // with this project — so it never equals the protected set and sails
            // through the guard below. The raw string is then what
            // `removeWorktree` and `deleteLocalBranch` are handed, and they
            // resolve it against a working directory of their own. `~` is not
            // expanded for the same reason: only a path that already names one
            // directory can be reasoned about here.
            guard let stored = workstream.worktreePath else { return nil }
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
                // Capture the branch name before the worktree is removed
                let branchName = worktreePath.flatMap { Git.Operations.currentBranch(at: $0) }
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
                                // Before the worktree is removed: dispose runs
                                // in it.
                                runDispose(
                                    workstreamID: workstreamID,
                                    projectName: projName,
                                    workstreamName: wsName,
                                    worktreePath: worktreePath,
                                    projectDirectory: projectDir
                                )
                                Git.Operations.removeWorktree(projectPath: projectDir, worktreePath: worktreePath)
                                if let branchName {
                                    Git.Operations.deleteLocalBranch(at: projectDir, branchName: branchName)
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
            surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
            Task { await IPC.Service.shared.releaseTaskClaims(inWorkstream: workstreamID) }
            LaunchLogger.removeLog(for: workstreamID)
            project.workstreams.removeAll { $0.id == workstreamID }
            clearAgentState(workstreamID, tracker: agentStateTracker)
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
            let branchName = Git.Operations.currentBranch(at: worktreePath)
            archivingPaths.insert(standardizedPath)
            NotificationCenter.default.post(name: archivingDidStart, object: nil)
            Task.detached {
                defer {
                    Task { @MainActor in
                        archivingPaths.remove(standardizedPath)
                        NotificationCenter.default.post(name: archivingDidComplete, object: nil)
                    }
                }
                Git.Operations.removeWorktree(projectPath: projectDirectory, worktreePath: worktreePath)
                if let branchName {
                    Git.Operations.deleteLocalBranch(at: projectDirectory, branchName: branchName)
                }
                Git.Operations.fetchDefaultBranch(at: projectDirectory)
            }
        }
    }
}
