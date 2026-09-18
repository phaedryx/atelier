// ABOUTME: One workstream's Execution run: start, stop, restart, restore, and the state behind them.
// ABOUTME: Owned by TerminalSurfaceCache beside WorkspaceModel, so it outlives the view that drives it.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "run-session")

extension ProcessCompose {
    /// The dev-server run for one workstream.
    ///
    /// **Every decision that starts, stops or restores a run lives here, and the
    /// state it decides over lives here with it.** Both halves used to be split:
    /// `runStarted`, `runStoppedManually`, `runGeneration` and `runCommandString`
    /// sat on `WorkspaceModel` while `doStartRun`, `beginRun`, `stopRun`,
    /// `restartRun` and `restoreRunState` were private methods on
    /// `TerminalContainerView`, and four more fields — `browserStartPending`,
    /// `isReclaimingSocket`, the port plan — never reached a model at all and
    /// were `@State` on that view.
    ///
    /// That split is the shape of a bug this codebase has already shipped twice.
    /// `runGeneration` was view `@State` once: `ContentView` keys the container
    /// `.id(workstreamID)`, so navigating away destroyed the generation while
    /// `runStarted` survived on the model, and the view came back believing a run
    /// was live with the generation reset to 0 — Stop then removed a surface that
    /// did not exist while a real one kept serving. `browserStartPending` had
    /// exactly that shape until this type existed. And `close_tab(kind:
    /// "execution")` over IPC was **refused outright** for the same reason:
    /// stopping a run meant reaching into view-local `@State` that
    /// `WorkspaceActions` — a `MainActor` singleton with no view — could not
    /// reach.
    ///
    /// **This type consumes `RunCommandPlan`; it never re-decides one.** The
    /// resolved command arrives as a non-optional `StartContext.command`, which
    /// is what keeps the one-decision rule structural: the Start button is
    /// enabled on `RunCommandPlan.canRun`, the view resolves the same plan into a
    /// command, and a `restart` cannot "stop the run and then decline to start
    /// one" because there is no optional to decline on. The execute checklist's
    /// own gate (`TerminalContainerView.runnableExecuteSelection`) deliberately
    /// stays in the view — see CLAUDE.md on why it is not in the plan either.
    ///
    /// **Lifetime.** Created lazily by `TerminalSurfaceCache.runSession(for:)`
    /// and held there for the workstream's life, the same ownership
    /// `WorkspaceModel` has and for the same reason: it must survive the view
    /// going away and be readable from outside the view hierarchy. Nothing about
    /// a run is persisted across a launch — across one no surface exists and a
    /// restored command string would be a lie — which is why the tmux probe in
    /// `restore` is the only thing that carries a run over a relaunch.
    @MainActor
    final class RunSession: ObservableObject {
        let workstreamID: UUID

        // MARK: - State

        /// Whether a run is up. Set by `start`/`restore`, cleared by `stop` and
        /// by the run surface exiting.
        @Published private(set) var runStarted = false

        /// Whether the user stopped this run by hand, which suppresses the tmux
        /// restore on the next launch. Deliberately **not** set when the run
        /// surface exits on its own: the run died, the user did not stop it, and
        /// marking it manual would suppress a restore nobody asked to suppress.
        @Published private(set) var runStoppedManually = false

        /// The run surface's generation. Bumped on every start and stop so a
        /// fresh surface replaces the outgoing one rather than reattaching to it.
        @Published private(set) var runGeneration = 0

        /// The fully assembled command the run surface was created with —
        /// launcher wrap and tmux wrap included.
        @Published private(set) var runCommandString: String?

        /// Browser tabs hold their waiting overlay while this is true, so a page
        /// opened the moment a run starts does not navigate to the placeholder
        /// port. Self-clears after `browserStartGrace` so a spawn that never
        /// wrote any run state still falls through to the error view.
        @Published private(set) var browserStartPending = false

        /// True while `start` is awaiting `down` on a socket it has to reclaim.
        ///
        /// Start is otherwise synchronous, and that is what kept it safe to press
        /// twice: the second press found `runStarted` already true. The reclaim
        /// path awaits a child process before flipping any state, which reopens
        /// that window for as long as `down` takes — and a second press would then
        /// run a second `down` and a second `beginRun`, the later one bumping
        /// `runGeneration` and replacing the surface the earlier one just built.
        ///
        /// Rendered by the Execution pane as well as guarding `start`, because a
        /// button that silently swallows a press reads as broken. The guard still
        /// has to be there: ⌘⇧⏎ reaches the run without going through the button.
        @Published private(set) var isReclaimingSocket = false

        /// This worktree's resolved `ports.yaml`. Held here because it is run
        /// state — it is what the run's ports are — but read far beyond the run:
        /// it feeds `Workstream.Environment.variables` for **every** surface,
        /// the Coding Agent's included. See `refreshPortPlan` on why that
        /// refresh stays synchronous.
        @Published private(set) var portPlan: ProcessCompose.PortPlan = .empty

        /// The tmux session this run was actually started in, recorded when the
        /// run begins rather than read live when it ends.
        ///
        /// That is what makes `stop()` self-contained, and it is what lets
        /// `WorkspaceActions` call it with no view mounted. It is also strictly
        /// more correct than the live read it replaces: `killRunTmuxSession` used
        /// to consult the *current* tmux mode and tool path, so a run started
        /// under tmux and stopped after tmux mode was switched off killed
        /// nothing and left the session behind.
        private(set) var tmux: TmuxContext?

        /// The run surface's id. Derived from the generation, so a bump is what
        /// makes the next run a different surface.
        var runID: UUID {
            derivedUUID(from: workstreamID, salt: "env-run-\(runGeneration)")
        }

        // MARK: - Inputs

        /// Where a run's tmux session lives. `nil` on a `StartContext` means the
        /// run is not wrapped in tmux at all.
        struct TmuxContext: Equatable {
            let path: String
            let sessionName: String
        }

        /// Everything a run needs that the session cannot know on its own.
        ///
        /// Assembled by the view, which is the only thing that can resolve it:
        /// the command comes from `RunCommandPlan` plus the execute checklist,
        /// the environment from the worktree's variables, and the tmux context
        /// from live tool detection. Passing it per call rather than caching it
        /// is the point — a run must use the world as it is when Start is
        /// pressed, not as it was when the session was created.
        struct StartContext {
            /// The resolved dev command: the user's override, or the
            /// phase-scoped `prepare && execute` composed from the located
            /// config. Non-optional on purpose; see the type's doc comment.
            let command: String
            let workingDirectory: String
            let environment: [String: String]
            /// `atelier-run`, for port detection. Absent means the command is
            /// run bare through `scriptCommand`.
            let launcherPath: String?
            let tmux: TmuxContext?
            let shell: String
        }

        // MARK: - Seams

        private let ensureExecutionTab: () -> Void
        private let removeSurface: (UUID) -> Void
        private let createSurface: (_ id: UUID, _ command: String, _ workingDirectory: String, _ environment: [String: String]) -> Void
        private let isSocketBusy: (String) -> Bool
        private let resolveBinary: () -> String?
        private let reclaimSocket: @Sendable (_ binary: String, _ socketPath: String, _ workingDirectory: String) -> Void
        private let tmuxSessionExists: (_ tmuxPath: String, _ sessionName: String) -> Bool
        private let killTmuxSession: (_ tmuxPath: String, _ sessionName: String) -> Void
        private let logLaunch: (LaunchLogEntry) -> Void
        private let loadPortsConfig: (_ projectDirectory: String) throws -> ProcessCompose.PortsConfig?
        /// How long `browserStartPending` holds before clearing itself.
        /// Injected only by tests, the way `Verification.Runner.killGrace` is:
        /// the production value is a real wait no timing test should pay.
        private let browserStartGrace: Duration

        private var browserStartTask: Task<Void, Never>?
        /// The `.terminalTabExited` registration, in a box that unregisters it
        /// when the session is released.
        ///
        /// A box rather than a stored token plus a `deinit`, because a
        /// `@MainActor` type's `deinit` is nonisolated and cannot touch a
        /// non-`Sendable` `NSObjectProtocol`. The box owns the token, so
        /// releasing the session releases the box and the observer with it.
        private let exitObserver = ObserverBox()

        /// Unregisters a `NotificationCenter` observer when it is released.
        private final class ObserverBox: @unchecked Sendable {
            var token: NSObjectProtocol?
            deinit {
                if let token {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }

        static let defaultBrowserStartGrace: Duration = .seconds(4)

        init(
            workstreamID: UUID,
            ensureExecutionTab: @escaping () -> Void,
            removeSurface: @escaping (UUID) -> Void,
            createSurface: @escaping (UUID, String, String, [String: String]) -> Void,
            isSocketBusy: @escaping (String) -> Bool = { ProcessCompose.Client.isServerListening(atSocketPath: $0) },
            resolveBinary: @escaping () -> String? = { ProcessCompose.Settings.resolveBinary() },
            reclaimSocket: @escaping @Sendable (String, String, String) -> Void = { binary, socketPath, workingDirectory in
                ProcessCompose.PhaseExecutor.shutDown(
                    binary: binary,
                    socketPath: socketPath,
                    workingDirectory: workingDirectory
                )
            },
            tmuxSessionExists: @escaping (String, String) -> Bool = { TmuxSession.sessionExists(tmuxPath: $0, sessionName: $1) },
            killTmuxSession: @escaping (String, String) -> Void = { TmuxSession.killSession(tmuxPath: $0, sessionName: $1) },
            logLaunch: @escaping (LaunchLogEntry) -> Void = { LaunchLogger.log($0) },
            loadPortsConfig: @escaping (String) throws -> ProcessCompose.PortsConfig? = { try ProcessCompose.PortsConfig.load(from: $0) },
            browserStartGrace: Duration = RunSession.defaultBrowserStartGrace,
            observesSurfaceExits: Bool = true
        ) {
            self.workstreamID = workstreamID
            self.ensureExecutionTab = ensureExecutionTab
            self.removeSurface = removeSurface
            self.createSurface = createSurface
            self.isSocketBusy = isSocketBusy
            self.resolveBinary = resolveBinary
            self.reclaimSocket = reclaimSocket
            self.tmuxSessionExists = tmuxSessionExists
            self.killTmuxSession = killTmuxSession
            self.logLaunch = logLaunch
            self.loadPortsConfig = loadPortsConfig
            self.browserStartGrace = browserStartGrace
            if observesSurfaceExits {
                observeSurfaceExits()
            }
        }

        // MARK: - Starting

        /// Start, after reclaiming this workstream's execute socket if anything
        /// is still holding it.
        ///
        /// `process-compose up` refuses to bind a socket another server holds:
        /// `unix socket <path> is already in use`, exit 1. In the chained
        /// `prepare && execute` that `ProcessCompose.PhaseRunner.startCommand`
        /// builds, it refuses at the **end** — so the user waits out the entire
        /// prepare phase, which for a real project is an install, a package
        /// build and a bundle install, and is then told about a unix socket.
        ///
        /// Whatever holds it is this workstream's own orphaned run: the path is
        /// named for the workstream id. It happens because `stop` kills the tmux
        /// session and drops the surface without ever calling `down`, so a
        /// server can outlive the run Atelier believes it stopped — and
        /// `runStarted` then reads false while the socket is still bound, which
        /// is exactly the state that makes Start look available and fail.
        ///
        /// Reclaiming belongs to Start rather than to Stop, or as well as to
        /// Stop: Start already means "tear down and re-run", and a server
        /// stranded by a *crash*, or by a quit that raced `stopAllServers`, was
        /// never going to be cleaned up by a Stop that is not coming.
        ///
        /// A leftover socket *file* is deliberately not handled:
        /// process-compose overwrites one. See
        /// `ProcessCompose.Client.isServerListening`.
        ///
        /// Every way into a run comes through here — the Start button, Rerun via
        /// `restart`, and the browser tab — so the probe is paid once and cannot
        /// be routed around.
        func start(_ context: StartContext) {
            // A reclaim already in flight owns this press.
            guard !isReclaimingSocket else { return }

            let socketPath = ProcessCompose.PhaseRunner.socketPath(for: workstreamID)
            guard isSocketBusy(socketPath), let binary = resolveBinary() else {
                beginRun(context)
                return
            }

            logger.warning("[Atelier] RunSession.start: reclaiming execute socket still in use")
            let worktree = context.workingDirectory
            let reclaim = reclaimSocket
            isReclaimingSocket = true
            Task {
                // Cleared however this ends — a thrown or cancelled Task that
                // left the flag set would make Start permanently inert for this
                // workstream, which is worse than the double-press it prevents.
                defer { isReclaimingSocket = false }
                // `down` spawns a child and waits on it, so it stays off the
                // main actor. The run begins once the socket is free, not
                // before: that ordering is the whole point.
                await Task.detached {
                    reclaim(binary, socketPath, worktree)
                }.value
                beginRun(context)
            }
        }

        /// Rerun: stop what is running, then go through `start`.
        ///
        /// Routing through `stop` first, rather than teaching this path its own
        /// reclaim, is what keeps Stop out of the reclaim window: `runStarted`
        /// is false for the whole of it, and the Stop and Rerun controls are
        /// rendered only when it is true. A Stop landing mid-reclaim would
        /// otherwise be followed by the run it just cancelled.
        ///
        /// `stop` sets `runStoppedManually`, which suppresses the tmux restore —
        /// but `beginRun` clears it again on the far side.
        func restart(_ context: StartContext) {
            if runStarted {
                stop()
            }
            start(context)
        }

        /// Starts the run session. Nothing here is gated behind approval,
        /// because this is attended: the user pressed Start, the output lands in
        /// a surface in front of them, and Stop is to hand.
        private func beginRun(_ context: StartContext) {
            // A run always gets an Execution tab, because that tab is what can
            // see and stop it — and, since browser tabs stopped claiming the
            // run, the only thing that can. Opening a browser starts the dev
            // server and opens only a browser, so without this a run could
            // exist with no Execution tab at all and nothing left that stops it
            // short of quitting. This line is what keeps `closingTabStopsRun`'s
            // single owner present for every run.
            //
            // Ensure rather than activate: the browser tab the user just asked
            // for must keep focus.
            ensureExecutionTab()
            killRunTmuxSession()
            removeSurface(runID)
            tmux = context.tmux
            runStoppedManually = false
            runGeneration += 1
            runCommandString = buildRunCommand(context)
            runStarted = true
            markBrowserStartPending()
            preloadRunSurface(context)
        }

        func stop() {
            killRunTmuxSession()
            removeSurface(runID)
            runStoppedManually = true
            runStarted = false
            clearBrowserStartPending()
            runCommandString = nil
            runGeneration += 1
            tmux = nil
        }

        /// Stops the run when `tab` is the tab that owns it.
        ///
        /// The single place that question is answered, for both closing paths —
        /// the user's ⌘W through `TerminalContainerView.forceCloseTab`, and
        /// `close_tab` over IPC through `WorkspaceActions`. A second copy in
        /// either would be the drift this type exists to end.
        func stopIfTabOwnsRun(_ tab: WorkspaceTab) {
            guard Self.closingTabStopsRun(tab, runStarted: runStarted) else { return }
            stop()
        }

        // MARK: - Restoring

        /// Restores `runStarted` from a run session already alive in tmux —
        /// survives relaunch, or a session started before this container
        /// existed.
        ///
        /// Driven from the view on launch (once tool detection has resolved
        /// whether tmux is usable) and whenever detection changes; the guards
        /// make re-invocation harmless. Returns whether a run was adopted.
        @discardableResult
        func restore(_ context: StartContext) -> Bool {
            guard !runStarted, let tmuxContext = context.tmux else { return false }
            let exists = tmuxSessionExists(tmuxContext.path, tmuxContext.sessionName)
            guard Self.shouldRestoreRunSession(
                useTmux: true,
                hasRunScript: true,
                hasExistingRunSession: exists,
                wasStoppedManually: runStoppedManually
            ) else { return false }

            // The same guarantee `beginRun` makes, on the other path that can
            // set `runStarted`. Only the Execution tab's close stops a run, so a
            // restored run without that tab is a run nothing can stop short of
            // quitting — and the tab really can be absent here: a run surface
            // exiting clears `runStarted` and deliberately leaves
            // `runStoppedManually` alone, so the tab can be closed with no
            // consequence while tmux still has a session for the next launch to
            // find.
            ensureExecutionTab()
            tmux = tmuxContext
            runStarted = true
            // A restored session has no command string — nothing built one this
            // launch — so it is assembled here and the surface reattached to the
            // existing tmux session. This used to be an `.onChange(of:
            // runStarted)` observer in the view that noticed `runCommandString`
            // was nil and built one; that was a second builder beside
            // `beginRun`'s, on a view whose mount lifetime it depended on.
            runCommandString = buildRunCommand(context)
            preloadRunSurface(context)
            return true
        }

        // MARK: - The run surface exiting

        /// The dev-server surface died: no port is coming and the run is over.
        ///
        /// Observed here rather than on the view, because the view's mount
        /// lifetime is not the run's. A run surface that exits while the user is
        /// looking at another workstream used to go unrecorded: `runStarted`
        /// stayed true, and `TerminalSurfaceView.updateNSView` recreates a
        /// missing surface from the stored command on the next render — so
        /// stopping the last process rebooted the whole stack with no user
        /// action, and Stop acted on a run that did not exist until a render
        /// brought it back.
        private func observeSurfaceExits() {
            exitObserver.token = NotificationCenter.default.addObserver(
                forName: .terminalTabExited,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let id = notification.object as? UUID else { return }
                Task { @MainActor in
                    self?.handleSurfaceExit(id)
                }
            }
        }

        /// Compared against the **current** `runID`, so a stale generation's
        /// exit — the surface `beginRun` and `stop` remove on their way past —
        /// cannot clear the run that replaced it.
        func handleSurfaceExit(_ surfaceID: UUID) {
            guard runStarted, surfaceID == runID else { return }
            clearBrowserStartPending()
            runStarted = false
            runCommandString = nil
            // `runStoppedManually` is deliberately left alone: the run died on
            // its own, and marking it manual would suppress the tmux restore the
            // user never asked to suppress.
        }

        // MARK: - Browser hand-off

        /// Marks the start so browser tabs hold the waiting overlay until a port
        /// appears.
        private func markBrowserStartPending() {
            browserStartPending = true
            browserStartTask?.cancel()
            let grace = browserStartGrace
            browserStartTask = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                self?.browserStartPending = false
            }
        }

        /// Called once the port detector reports a status: the session has
        /// materialised and the overlay is driven by that status from here on.
        func clearBrowserStartPending() {
            browserStartTask?.cancel()
            browserStartTask = nil
            browserStartPending = false
        }

        // MARK: - Ports

        /// Re-reads `ports.yaml` and resolves it for this worktree. A malformed
        /// file leaves the plan empty and logs; nothing here throws into a view
        /// update.
        ///
        /// **Synchronous, deliberately.** The plan feeds
        /// `Workstream.Environment.variables` for every surface including the
        /// Coding Agent's, and a surface's environment is never compared after
        /// creation — so a plan that lands after `preloadSurfaces` is a
        /// divergence that is permanent for that surface's life. The caller
        /// refreshes before preloading; do not turn this into a `Task` because
        /// it now lives on an `ObservableObject`.
        func refreshPortPlan(projectDirectory: String, workingDirectory: String) {
            do {
                guard let config = try loadPortsConfig(projectDirectory) else {
                    portPlan = .empty
                    return
                }
                portPlan = ProcessCompose.PortPlan.resolve(config, workingDirectory: workingDirectory)
            } catch {
                logger.warning("ports.yaml: \(error.localizedDescription, privacy: .public)")
                portPlan = .empty
            }
        }

        // MARK: - Command assembly

        /// Assembles the final run command: `atelier-run` wrap (port detection)
        /// + tmux wrap, and writes the launch log entry that records all three
        /// layers.
        private func buildRunCommand(_ context: StartContext) -> String {
            let baseCommand: String = if let launcherPath = context.launcherPath {
                runScriptCommand(
                    script: context.command,
                    workstreamID: workstreamID,
                    launcherPath: launcherPath,
                    shell: context.shell
                )
            } else {
                Self.scriptCommand(script: context.command, shell: context.shell)
            }

            let finalCommand: String = if let tmuxContext = context.tmux {
                TmuxSession.wrapCommand(
                    tmuxPath: tmuxContext.path,
                    sessionName: tmuxContext.sessionName,
                    command: baseCommand,
                    environmentVars: context.environment
                )
            } else {
                baseCommand
            }

            var intermediates = [context.command, baseCommand]
            if finalCommand != baseCommand {
                intermediates.append(finalCommand)
            }
            logLaunch(LaunchLogEntry(
                workstreamID: workstreamID,
                event: "run-start",
                finalCommand: finalCommand,
                intermediateCommands: intermediates,
                environmentVariables: context.environment,
                workingDirectory: context.workingDirectory,
                toolPaths: LaunchLogEntry.ToolPaths(
                    claude: nil,
                    tmux: context.tmux?.path,
                    ffRun: context.launcherPath
                ),
                settings: LaunchLogEntry.Settings(
                    tmuxMode: context.tmux != nil,
                    bypassPermissions: false,
                    autoRenameBranch: false,
                    allowOutsideWorktree: false
                ),
                shell: context.shell
            ))

            return finalCommand
        }

        /// Create the run surface eagerly so the dev server starts even while
        /// the browser tab is active and the Execution pane is not rendered.
        private func preloadRunSurface(_ context: StartContext) {
            guard let commandString = runCommandString else { return }
            createSurface(runID, commandString, context.workingDirectory, context.environment)
        }

        private func killRunTmuxSession() {
            guard let tmux else { return }
            killTmuxSession(tmux.path, tmux.sessionName)
        }

        // MARK: - The rules

        /// Whether a run alive in tmux should be adopted.
        ///
        /// A pure rule, so which runs come back can be tested without standing
        /// up a view or a tmux server.
        static func shouldRestoreRunSession(
            useTmux: Bool,
            hasRunScript: Bool,
            hasExistingRunSession: Bool,
            wasStoppedManually: Bool
        ) -> Bool {
            useTmux && hasRunScript && hasExistingRunSession && !wasStoppedManually
        }

        /// Whether closing `tab` stops this workstream's run.
        ///
        /// The Execution tab is the run's sole owner. It is the pane that lists
        /// the processes and the pane Stop lives on, and `beginRun` opens one for
        /// every run, so no other tab has to stand in as the way out.
        ///
        /// A browser tab used to claim the same ownership, guarded by a "no
        /// browser tabs left" check that matched only browser tabs and so could
        /// not see an open Execution tab. Closing the last browser therefore
        /// stopped a run that tab was still watching, and set
        /// `runStoppedManually` on the way out, so it did not come back on the
        /// next launch either.
        ///
        /// `runStarted` is folded in here rather than left to the caller because
        /// forgetting it is the same defect in a second place: `stop` sets
        /// `runStoppedManually`, and closing a tab that was running nothing must
        /// not suppress the next launch's tmux restore.
        static func closingTabStopsRun(_ tab: WorkspaceTab, runStarted: Bool) -> Bool {
            guard runStarted else { return false }
            if case .execution = tab {
                return true
            }
            return false
        }

        /// Wraps a command for a login shell, so it sees the PATH and shell
        /// functions the user's own terminal would. Used when the `atelier-run`
        /// launcher is unavailable and the command has to be run bare.
        static func scriptCommand(script: String, shell: String = CommandBuilder.userShell) -> String {
            // POSIX quoting for the same reason `RunLauncher.runScriptCommand`
            // uses it: the outer shell that strips this layer is ghostty's
            // `/bin/bash -c`, not the login shell named here, and double quotes
            // would leave backticks in the script live for bash to substitute.
            "\(shell) -lic \(CommandBuilder.shellQuote(script))"
        }
    }
}
