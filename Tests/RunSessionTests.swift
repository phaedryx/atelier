// ABOUTME: Tests for ProcessCompose.RunSession — the run lifecycle that used to live in TerminalContainerView.
// ABOUTME: Surface creation, tmux and the socket probe are injected, so none of this needs a view or a server.

@testable import Atelier
import XCTest

@MainActor
final class RunSessionTests: XCTestCase {
    /// Everything the session does to the world outside itself, recorded in
    /// order. The ordering is the point in more than one test here: the reclaim
    /// has to finish before the run begins, and the outgoing surface has to go
    /// before the generation moves.
    ///
    /// `@unchecked Sendable` behind a lock, because the reclaim stub really does
    /// run off the main actor — `RunSession.start` hands it to `Task.detached`,
    /// the way production's `down` has to, and a stub that could only be called
    /// on the main actor would be testing a different ordering than the one that
    /// ships.
    private final class Recorder: @unchecked Sendable {
        enum Event: Equatable {
            case ensureExecutionTab
            case removeSurface(UUID)
            case createSurface(id: UUID, command: String)
            case reclaim(socketPath: String)
            case killTmux(session: String)
            case launchLog(finalCommand: String)
        }

        private let lock = NSLock()
        private var events: [Event] = []
        var socketBusy = false
        var binary: String? = "/usr/local/bin/process-compose"
        var tmuxSessionExists = false

        func record(_ event: Event) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            events.removeAll()
        }

        var log: [Event] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        func contains(_ event: Event) -> Bool {
            log.contains(event)
        }

        func firstIndex(matching predicate: (Event) -> Bool) -> Int? {
            log.firstIndex(where: predicate)
        }

        var createdSurfaceIDs: [UUID] {
            log.compactMap {
                if case let .createSurface(id, _) = $0 {
                    return id
                }
                return nil
            }
        }
    }

    private let workstreamID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func makeSession(
        _ recorder: Recorder,
        browserStartGrace: Duration = .milliseconds(50)
    ) -> ProcessCompose.RunSession {
        ProcessCompose.RunSession(
            workstreamID: workstreamID,
            ensureExecutionTab: { recorder.record(.ensureExecutionTab) },
            removeSurface: { recorder.record(.removeSurface($0)) },
            createSurface: { id, command, _, _ in
                recorder.record(.createSurface(id: id, command: command))
            },
            isSocketBusy: { _ in recorder.socketBusy },
            resolveBinary: { recorder.binary },
            reclaimSocket: { _, socketPath, _ in
                recorder.record(.reclaim(socketPath: socketPath))
            },
            tmuxSessionExists: { _, _ in recorder.tmuxSessionExists },
            killTmuxSession: { _, session in recorder.record(.killTmux(session: session)) },
            logLaunch: { recorder.record(.launchLog(finalCommand: $0.finalCommand)) },
            loadPortsConfig: { _ in nil },
            browserStartGrace: browserStartGrace,
            // The session's own `.terminalTabExited` subscription is exercised
            // through `handleSurfaceExit` directly; leaving it registered would
            // make every test in this file listen to every other one's teardown.
            observesSurfaceExits: false
        )
    }

    private func context(
        command: String = "just dev",
        tmux: ProcessCompose.RunSession.TmuxContext? = nil
    ) -> ProcessCompose.RunSession.StartContext {
        ProcessCompose.RunSession.StartContext(
            command: command,
            workingDirectory: "/repo/feature",
            environment: ["ATELIER_PORT": "4000"],
            launcherPath: nil,
            tmux: tmux,
            shell: "/bin/zsh"
        )
    }

    private let tmuxContext = ProcessCompose.RunSession.TmuxContext(
        path: "/opt/homebrew/bin/tmux",
        sessionName: "atelier-proj-work-run"
    )

    // MARK: - Starting

    func test_start_onAFreeSocket_runsWithoutReclaiming() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())

        XCTAssertTrue(session.runStarted)
        XCTAssertEqual(session.runGeneration, 1)
        XCTAssertFalse(recorder.log.contains {
            if case .reclaim = $0 {
                true
            } else {
                false
            }
        })
        XCTAssertEqual(recorder.createdSurfaceIDs, [session.runID])
    }

    /// `process-compose up` refuses to bind a socket another server holds, and
    /// refuses at the *end* of the chained `prepare && execute` — so the user
    /// waits out an entire install before being told about a unix socket. The
    /// reclaim exists to shut that server down first, and the ordering is the
    /// whole of it: a `down` that landed after the run began would kill the run.
    func test_start_onABusySocket_reclaimsBeforeTheRunBegins() async throws {
        let recorder = Recorder()
        recorder.socketBusy = true
        let session = makeSession(recorder)

        session.start(context())

        // The reclaim awaits a child process, so the run has not begun yet.
        XCTAssertTrue(session.isReclaimingSocket)
        XCTAssertFalse(session.runStarted)

        await drain(until: { !session.isReclaimingSocket })

        XCTAssertTrue(session.runStarted)
        let reclaimIndex = recorder.firstIndex {
            if case .reclaim = $0 {
                true
            } else {
                false
            }
        }
        let createIndex = recorder.firstIndex {
            if case .createSurface = $0 {
                true
            } else {
                false
            }
        }
        XCTAssertNotNil(reclaimIndex)
        XCTAssertNotNil(createIndex)
        XCTAssertLessThan(try XCTUnwrap(reclaimIndex), try XCTUnwrap(createIndex))
    }

    /// Start is otherwise synchronous, which is what kept it safe to press
    /// twice: the second press found `runStarted` already true. The reclaim
    /// reopens that window, and a second press would run a second `down` and a
    /// second run, the later one replacing the surface the earlier built.
    func test_start_refusesASecondPressWhileReclaiming() async {
        let recorder = Recorder()
        recorder.socketBusy = true
        let session = makeSession(recorder)

        session.start(context())
        session.start(context())

        await drain(until: { !session.isReclaimingSocket })

        XCTAssertEqual(recorder.log.filter {
            if case .reclaim = $0 {
                true
            } else {
                false
            }
        }.count, 1)
        XCTAssertEqual(session.runGeneration, 1)
    }

    /// A workstream torn down while its socket reclaim is in flight must not
    /// get a run out of that reclaim.
    ///
    /// `start` awaits `process-compose down` before `beginRun`, and that wait
    /// used to retain the session through its own `Task` — so an archive that
    /// dropped the session from `TerminalSurfaceCache.runSessions` did not stop
    /// the run that landed afterwards, and `beginRun` put a dev-server surface
    /// (cwd = a worktree being deleted) into the long-lived surface cache with
    /// nothing left to evict it. `teardown` cancels it, and the cancellation is
    /// checked on the way back out because it does not propagate into the
    /// detached child.
    ///
    /// Deterministic without sleeps: `start` returns as soon as it has
    /// *scheduled* the task, so `teardown` on the next line lands in the same
    /// main-actor turn, before the task body has run at all.
    func test_teardownDuringAReclaim_abandonsTheRunItWouldHaveStarted() async {
        let recorder = Recorder()
        recorder.socketBusy = true
        let session = makeSession(recorder)

        session.start(context())
        XCTAssertTrue(session.isReclaimingSocket)
        session.teardown()

        await drain(until: { !session.isReclaimingSocket })

        XCTAssertTrue(
            recorder.createdSurfaceIDs.isEmpty,
            "a cancelled reclaim must not create a run surface for a workstream that is going away"
        )
        XCTAssertFalse(session.runStarted)
        XCTAssertEqual(session.runGeneration, 0)
    }

    /// No binary to run `down` with is not a reason to refuse the run: the
    /// probe is a best-effort cleanup, and `RunCommandPlan` is what decides
    /// whether there is anything to start.
    func test_start_onABusySocketWithNoBinary_startsAnyway() {
        let recorder = Recorder()
        recorder.socketBusy = true
        recorder.binary = nil
        let session = makeSession(recorder)

        session.start(context())

        XCTAssertTrue(session.runStarted)
        XCTAssertFalse(session.isReclaimingSocket)
    }

    // MARK: - Stopping

    func test_stop_afterStart_clearsTheRunAndMovesTheGeneration() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context(tmux: tmuxContext))
        let startedID = session.runID
        recorder.reset()

        session.stop()

        XCTAssertFalse(session.runStarted)
        XCTAssertTrue(session.runStoppedManually)
        XCTAssertNil(session.runCommandString)
        XCTAssertEqual(session.runGeneration, 2)
        XCTAssertNotEqual(session.runID, startedID)
        XCTAssertTrue(recorder.contains(.removeSurface(startedID)))
        XCTAssertTrue(recorder.contains(.killTmux(session: tmuxContext.sessionName)))
    }

    /// The tmux session is recorded when the run begins, not read live when it
    /// ends. That is what lets `WorkspaceActions` stop a run with no view
    /// mounted — and it is more correct than the live read it replaced, which
    /// killed nothing if tmux mode had been switched off mid-run.
    func test_stop_killsTheSessionTheRunActuallyStartedIn() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context(tmux: tmuxContext))
        // Nothing tells the session tmux is "off" now — it does not ask.
        recorder.reset()
        session.stop()

        XCTAssertEqual(
            recorder.log.filter {
                if case .killTmux = $0 {
                    true
                } else {
                    false
                }
            },
            [.killTmux(session: tmuxContext.sessionName)]
        )
    }

    func test_stop_withoutTmux_killsNothing() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        session.stop()

        XCTAssertFalse(recorder.log.contains {
            if case .killTmux = $0 {
                true
            } else {
                false
            }
        })
    }

    /// The first Start of a launch, with a tmux session left over from the last
    /// one.
    ///
    /// `restore` returns early whenever the view cannot resolve a command — an
    /// empty execute selection, an unresolvable binary — so `tmux` is still nil
    /// when the user fixes that and presses Start. `TmuxSession.wrapCommand`
    /// uses `new-session -A`, so a Start that killed only the session it had
    /// *recorded* silently reattached to the old server, still running the old
    /// selection, while `runStarted` flipped true.
    func test_start_killsAStaleTmuxSessionItNeverRecorded() {
        let recorder = Recorder()
        let session = makeSession(recorder)
        // Nothing has been recorded: no prior `beginRun`, no adopted `restore`.
        XCTAssertNil(session.tmux)

        session.start(context(tmux: tmuxContext))

        XCTAssertTrue(
            recorder.contains(.killTmux(session: tmuxContext.sessionName)),
            "the session the run is about to start in must be killed, not only the one already recorded"
        )
    }

    /// And it is killed exactly once when the two are the same session, which is
    /// the ordinary case — the name is derived from the project and workstream,
    /// so a re-Start names what the last Start recorded.
    func test_start_killsTheSessionOnceWhenTheRecordedAndIncomingOnesMatch() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context(tmux: tmuxContext))
        recorder.reset()
        session.start(context(tmux: tmuxContext))

        XCTAssertEqual(
            recorder.log.filter {
                if case .killTmux = $0 {
                    true
                } else {
                    false
                }
            },
            [.killTmux(session: tmuxContext.sessionName)]
        )
    }

    // MARK: - Restarting

    /// `stop` sets `runStoppedManually`, which suppresses the tmux restore —
    /// and `beginRun` clears it again on the far side, so a Rerun does not leave
    /// the next launch believing the user stopped this run by hand.
    func test_restart_stopsThenStarts_andLeavesTheRunUnstopped() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        session.restart(context())

        XCTAssertTrue(session.runStarted)
        XCTAssertFalse(session.runStoppedManually)
        XCTAssertEqual(session.runGeneration, 3)
    }

    // MARK: - Restoring from tmux

    func test_restore_adoptsALiveTmuxSession() {
        let recorder = Recorder()
        recorder.tmuxSessionExists = true
        let session = makeSession(recorder)

        XCTAssertTrue(session.restore(context(tmux: tmuxContext)))

        XCTAssertTrue(session.runStarted)
        XCTAssertNotNil(session.runCommandString)
        XCTAssertTrue(recorder.contains(.ensureExecutionTab))
        XCTAssertEqual(recorder.createdSurfaceIDs, [session.runID])
    }

    func test_restore_doesNothingWithNoTmuxSession() {
        let recorder = Recorder()
        recorder.tmuxSessionExists = false
        let session = makeSession(recorder)

        XCTAssertFalse(session.restore(context(tmux: tmuxContext)))
        XCTAssertFalse(session.runStarted)
    }

    func test_restore_doesNothingWithoutTmux() {
        let recorder = Recorder()
        recorder.tmuxSessionExists = true
        let session = makeSession(recorder)

        XCTAssertFalse(session.restore(context(tmux: nil)))
        XCTAssertFalse(session.runStarted)
    }

    /// A run the user stopped by hand must not come back on the next launch.
    func test_restore_declinesAfterAManualStop() {
        let recorder = Recorder()
        recorder.tmuxSessionExists = true
        let session = makeSession(recorder)

        session.start(context(tmux: tmuxContext))
        session.stop()

        XCTAssertFalse(session.restore(context(tmux: tmuxContext)))
        XCTAssertFalse(session.runStarted)
    }

    /// The restore is re-invoked from the view on every tool-detection change,
    /// so it has to be harmless over a run that is already up.
    func test_restore_isANoOpWhileARunIsUp() {
        let recorder = Recorder()
        recorder.tmuxSessionExists = true
        let session = makeSession(recorder)

        session.start(context(tmux: tmuxContext))
        let generation = session.runGeneration

        XCTAssertFalse(session.restore(context(tmux: tmuxContext)))
        XCTAssertEqual(session.runGeneration, generation)
    }

    // MARK: - Closing the tab that owns the run

    func test_closingTheExecutionTab_stopsTheRun() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        session.stopIfTabOwnsRun(.execution)

        XCTAssertFalse(session.runStarted)
        XCTAssertTrue(session.runStoppedManually)
    }

    /// A browser tab is one view onto a running server; the last one closing
    /// says nothing about whether the server is still wanted. It used to stop
    /// the run and set `runStoppedManually` on the way out.
    func test_closingAnyOtherTab_leavesTheRunAlone() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        session.stopIfTabOwnsRun(.browser(UUID()))
        session.stopIfTabOwnsRun(.changes)
        session.stopIfTabOwnsRun(.verification)

        XCTAssertTrue(session.runStarted)
    }

    /// Closing the Execution tab over a workstream that is running nothing must
    /// not set `runStoppedManually` — that would suppress the next launch's
    /// tmux restore for a run nobody stopped.
    func test_closingTheExecutionTabWithNoRun_doesNotSuppressTheNextRestore() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.stopIfTabOwnsRun(.execution)

        XCTAssertFalse(session.runStoppedManually)
        XCTAssertEqual(session.runGeneration, 0)
    }

    // MARK: - The browser hand-off flag

    func test_browserStartPending_isSetOnStartAndClearedOnStop() {
        let recorder = Recorder()
        let session = makeSession(recorder, browserStartGrace: .seconds(60))

        session.start(context())
        XCTAssertTrue(session.browserStartPending)

        session.stop()
        XCTAssertFalse(session.browserStartPending)
    }

    /// A spawn that never wrote any run state must still fall through to the
    /// error view rather than leaving the browser on its waiting overlay.
    func test_browserStartPending_clearsItselfAfterTheGrace() async {
        let recorder = Recorder()
        let session = makeSession(recorder, browserStartGrace: .milliseconds(20))

        session.start(context())
        XCTAssertTrue(session.browserStartPending)

        await drain(until: { !session.browserStartPending })
        XCTAssertFalse(session.browserStartPending)
    }

    // MARK: - The run surface exiting

    /// The run died on its own: recorded, but never as a manual stop — marking
    /// it manual would suppress a tmux restore the user never asked to suppress.
    func test_surfaceExit_endsTheRunWithoutMarkingItManuallyStopped() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        session.handleSurfaceExit(session.runID)

        XCTAssertFalse(session.runStarted)
        XCTAssertNil(session.runCommandString)
        XCTAssertFalse(session.runStoppedManually)
        XCTAssertFalse(session.browserStartPending)
    }

    /// `beginRun` and `stop` both drop the outgoing generation's surface on
    /// their way past. That surface's exit must not clear the run that replaced
    /// it.
    func test_surfaceExit_ignoresAStaleGeneration() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        let firstID = session.runID
        session.restart(context())

        session.handleSurfaceExit(firstID)

        XCTAssertTrue(session.runStarted)
    }

    func test_surfaceExit_ignoresAnotherWorkstreamsSurface() {
        let recorder = Recorder()
        let session = makeSession(recorder)

        session.start(context())
        session.handleSurfaceExit(UUID())

        XCTAssertTrue(session.runStarted)
    }

    // MARK: - The pure rules, moved with the lifecycle that reads them

    func test_shouldRestoreRunSession_needsTmuxAScriptAndALiveSession() {
        typealias Session = ProcessCompose.RunSession
        XCTAssertTrue(Session.shouldRestoreRunSession(useTmux: true, hasRunScript: true, hasExistingRunSession: true, wasStoppedManually: false))
        XCTAssertFalse(Session.shouldRestoreRunSession(useTmux: false, hasRunScript: true, hasExistingRunSession: true, wasStoppedManually: false))
        XCTAssertFalse(Session.shouldRestoreRunSession(useTmux: true, hasRunScript: false, hasExistingRunSession: true, wasStoppedManually: false))
        XCTAssertFalse(Session.shouldRestoreRunSession(useTmux: true, hasRunScript: true, hasExistingRunSession: false, wasStoppedManually: false))
        XCTAssertFalse(Session.shouldRestoreRunSession(useTmux: true, hasRunScript: true, hasExistingRunSession: true, wasStoppedManually: true))
    }

    func test_closingTabStopsRun_namesExactlyOneOwner() {
        typealias Session = ProcessCompose.RunSession
        XCTAssertTrue(Session.closingTabStopsRun(.execution, runStarted: true))
        XCTAssertFalse(Session.closingTabStopsRun(.execution, runStarted: false))
        XCTAssertFalse(Session.closingTabStopsRun(.browser(UUID()), runStarted: true))
        XCTAssertFalse(Session.closingTabStopsRun(.changes, runStarted: true))
        XCTAssertFalse(Session.closingTabStopsRun(.verification, runStarted: true))
        XCTAssertFalse(Session.closingTabStopsRun(.terminal(UUID()), runStarted: true))
    }

    func test_scriptCommand_wrapsInALoginShell() {
        let command = ProcessCompose.RunSession.scriptCommand(script: "just local", shell: "/bin/zsh")

        XCTAssertTrue(command.hasPrefix("/bin/zsh -lic "))
        XCTAssertTrue(command.contains("just local"))
    }

    /// Both wrappers hand the script to the login shell as its `-c` argument,
    /// and that argument sits inside a string ghostty's own `/bin/bash -c`
    /// reads first. So it is POSIX-quoted — fish-quoting it, as both sites used
    /// to, left every backtick in the script for bash to substitute.
    func test_scriptWrappersPosixQuoteTheScriptEvenForFish() {
        let fish = "/opt/homebrew/bin/fish"
        let script = "just local `whoami`"
        let wrapped = ProcessCompose.RunSession.scriptCommand(script: script, shell: fish)

        XCTAssertTrue(wrapped.hasSuffix("-lic 'just local `whoami`'"), wrapped)
        XCTAssertTrue(
            runScriptCommand(
                script: script,
                workstreamID: UUID(),
                launcherPath: "/path/to/atelier-run",
                shell: fish
            ).hasSuffix("-lic 'just local `whoami`'")
        )
    }

    func test_runScriptCommandUsesLoginShell() {
        let command = runScriptCommand(script: "bun dev", workstreamID: UUID(), launcherPath: "/path/to/atelier-run", shell: "/bin/zsh")

        XCTAssertTrue(command.contains("/bin/zsh -lic"))
        XCTAssertFalse(command.contains("/bin/sh"))
    }

    // MARK: - Ownership

    /// The session is the surface cache's, not the view's. That is the whole
    /// reason it exists: `ContentView` keys the container `.id(workstreamID)`,
    /// so navigating to another workstream and back destroys the view — and a
    /// run that lost its generation to that came back with Stop pointing at a
    /// surface id nothing was using while a real server kept running.
    func test_theCacheHandsOutOneSessionPerWorkstream() {
        let cache = TerminalSurfaceCache()
        let id = UUID()

        XCTAssertTrue(cache.runSession(for: id) === cache.runSession(for: id))
        XCTAssertFalse(cache.runSession(for: id) === cache.runSession(for: UUID()))
    }

    /// Archiving drops the session with the model. The sweep that removes a
    /// workstream's surfaces reads `runGeneration` to bound itself, and it reads
    /// it *from the session* now — so this also pins that the two are captured
    /// and released together rather than one outliving the other.
    func test_archivingAWorkstreamDropsItsSession() {
        let cache = TerminalSurfaceCache()
        cache.terminalApp = { nil }
        let id = UUID()
        let session = cache.runSession(for: id)
        session.start(context())
        XCTAssertEqual(session.runGeneration, 1)

        cache.removeWorkstreamSurfaces(for: id)

        XCTAssertFalse(cache.runSession(for: id) === session)
        XCTAssertEqual(cache.runSession(for: id).runGeneration, 0)
    }

    // MARK: - Helpers

    /// Lets the main actor run queued work until `condition` holds, or a short
    /// bound expires. The session's asynchronous edges are a detached child
    /// process and a sleep, both of which finish in microseconds against the
    /// stubs here; the bound is only so a regression fails rather than hangs.
    private func drain(until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
