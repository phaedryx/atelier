// ABOUTME: Per-workstream Claude agent roster derived from lifecycle hook events.
// ABOUTME: Tracks main + subagent runs (activity, stalls) and drives the sidebar UI.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "agent-state")

/// Tracks the live agent runs in each workstream.
///
/// State transitions are driven by hook events (`UserPromptSubmit` / `Stop`,
/// `PreToolUse` / `PostToolUse`, `SubagentStart` / `SubagentStop`). A run is
/// created when its agent spawns and removed when its stop hook arrives, so
/// the roster mirrors exactly what Claude Code reports — no artificial timers
/// govern visibility. The only timer is the stall sweep: a run that stops
/// emitting events while supposedly working flips to `.stalled`.
///
/// The high-level `AgentRunState` (driving the sidebar row dot) is kept in
/// sync alongside the roster.
extension Workstream {
    @MainActor
    final class AgentStateTracker: ObservableObject {
        static let shared = AgentStateTracker()

        enum NeedsReason: Equatable {
            case justFinished
            case permission
        }

        enum AgentRunState: Equatable {
            case idle
            case working
            /// No hook events for a while although the turn hasn't ended.
            case stalled
            case needsAttention(NeedsReason)

            /// Whether the agent's turn has ended, i.e. typing into its pane would
            /// land at a prompt rather than in the middle of someone's work.
            ///
            /// `.idle` and `.needsAttention(.justFinished)` are the same fact seen
            /// from two places — the tracker reports the first for the workstream
            /// the user is looking at and the second for the rest. Everything else
            /// means mid-turn, waiting on a permission prompt (where typed input
            /// would answer the prompt itself), or stalled without having ended
            /// the turn. Both typing paths — `AgentNudge` and `PromptInjector` —
            /// classify through this, so a policy change lands once.
            var turnHasEnded: Bool {
                switch self {
                case .idle, .needsAttention(.justFinished):
                    true
                case .working, .stalled, .needsAttention(.permission):
                    false
                }
            }

            /// Whether the agent has stopped and will not move until someone
            /// answers its permission prompt.
            var isAwaitingPermission: Bool {
                if case .needsAttention(.permission) = self {
                    return true
                }
                return false
            }
        }

        /// One live agent (main or subagent) inside a workstream.
        struct AgentRun: Identifiable, Equatable {
            enum RunState: Equatable {
                case working
                case stalled
            }

            /// Claude's agent id ("main" or a subagent id).
            let id: String
            /// Display name ("Claude" or the subagent type). Mutable: later events
            /// may refine it once the harness reports the agent type.
            var name: String
            let isMain: Bool
            var state: RunState
            /// What the agent is doing right now, e.g. "Editing Foo.swift".
            var activity: String?
            let startedAt: Date
            var lastEventAt: Date
            /// Set between `PreCompact` and `PostCompact`. Compaction is one long
            /// silent operation — no tool events for as long as it runs — so the
            /// stall sweep has to be told the difference between that and a wedge.
            var isCompacting: Bool = false
            /// Set between `PreToolUse` and `PostToolUse`: a tool is running
            /// right now.
            ///
            /// Tracked separately from `activity` even though the two move
            /// together, because `activity` is display text and may be nil for a
            /// tool the mapper had no phrase for. The sweep needs the *fact*,
            /// and a run whose tool is in flight is working however long it has
            /// been quiet — that silence is the tool's, and it is the single
            /// biggest source of stalls reported against healthy agents.
            var isRunningTool: Bool = false
        }

        /// Context-window consumption of a workstream's main session.
        struct ContextUsage: Equatable {
            /// Where the figures came from. Two channels report the same two
            /// numbers and they do not agree in quality, so the value carries
            /// which one it is rather than leaving the precedence to whichever
            /// wrote last.
            enum Source: Equatable {
                /// Claude Code's own figures, off the status line. The window
                /// size is reported rather than inferred.
                case statusLine
                /// Parsed out of the transcript tail, with the window inferred
                /// by `ContextLimits` from the model string.
                case transcript
            }

            let usedTokens: Int
            let limitTokens: Int
            var source: Source = .transcript
            var fraction: Double {
                limitTokens > 0 ? Double(usedTokens) / Double(limitTokens) : 0
            }
        }

        /// Silence that is worth *investigating* — not worth reporting.
        ///
        /// Crossing this asks `HookChannelProbe` whether hook events are still
        /// arriving at all, and changes nothing on screen. It used to set the
        /// yellow "Stalled" dot directly, which was wrong far more often than
        /// right: a build, a long model response and a slow MCP call all pass 45
        /// seconds of silence routinely, and none of them is a wedge. The
        /// question 45 seconds of silence actually raises is whether the app is
        /// still listening, and only the probe can answer that.
        static let silenceThreshold: TimeInterval = 45

        /// Silence long enough to report as a wedge.
        ///
        /// By this point a tool in flight has been exempted, compaction has been
        /// exempted, a permission prompt has been exempted, and the channel has
        /// been verified at the silence threshold — so what is left really is an
        /// agent that stopped without ending its turn.
        static let wedgeThreshold: TimeInterval = 300

        /// Upper bound on every "this run is doing known long work" exemption:
        /// compaction between `PreCompact` and `PostCompact`, and a tool between
        /// `PreToolUse` and `PostToolUse`.
        ///
        /// Both exemptions exist because the work is genuinely silent, and both
        /// are bounded for the same reason: the event that would lift the
        /// exemption may never arrive — the agent was killed mid-tool, or the
        /// POST carrying it was one of the ones `curl --max-time 1` dropped — and
        /// a missing end-event must not suppress the sweep for the rest of the
        /// session. Larger than `wedgeThreshold`, or it would never bind.
        static let longWorkGrace: TimeInterval = 1800
        private static let sweepInterval: TimeInterval = 15
        private static let contextReadInterval: TimeInterval = 5

        @Published private(set) var states: [UUID: AgentRunState] = [:]
        @Published private(set) var rosters: [UUID: [AgentRun]] = [:]
        /// Workstreams that have seen harness activity during this app launch.
        /// In-memory only by design ("part of my work today").
        @Published private(set) var liveSessionIDs: Set<UUID> = []
        /// Latest known context-window usage for each workstream's MAIN session.
        @Published private(set) var contextUsage: [UUID: ContextUsage] = [:]

        /// Turn state per *terminal surface*, for the agents whose hook events
        /// carried an `ATELIER_SURFACE_ID`. The workstream-level `states` above
        /// drives the sidebar and is unaffected; this exists because two agents
        /// sharing one worktree produce one workstream signal between them, which
        /// is too coarse to decide whether a particular pane may be interrupted.
        @Published private(set) var surfaceStates: [UUID: AgentRunState] = [:]
        /// Which workstream each known surface belongs to, so `clear` can drop it.
        private var surfaceWorkstream: [UUID: UUID] = [:]

        private var lastContextReadAt: [UUID: Date] = [:]
        /// Workstreams whose last transcript read found nothing, so the failure
        /// is logged once per spell rather than once per hook event.
        private var transcriptReadFailing: Set<UUID> = []

        /// Resolves a Claude `project_dir` payload to the matching workstream UUID.
        /// Set by `ContentView` whenever the project list changes.
        var workstreamLookup: ((String) -> UUID?)?

        /// Currently selected workstream — `Stop` while selected goes straight to
        /// `.idle` because the user is already looking at it.
        var currentSelection: UUID?

        /// Called once per sweep in which some run has been quiet past
        /// `silenceThreshold`. `AtelierApp` points it at `HookChannelProbe`.
        ///
        /// A closure rather than a direct call to the probe's singleton so the
        /// sweep's own logic stays testable without a process spawn, and so the
        /// tracker keeps knowing nothing about how the channel gets checked.
        var onProlongedSilence: (() -> Void)?

        private var sweepTimer: Timer?

        private init() {}

        // MARK: - Public API

        func state(for id: UUID) -> AgentRunState {
            states[id] ?? .idle
        }

        /// Turn state of one terminal surface, or nil if no agent has ever reported
        /// from it. Nil is meaningful: it means there is no evidence about this
        /// pane, not that the pane is idle.
        func state(forSurface id: UUID) -> AgentRunState? {
            surfaceStates[id]
        }

        /// Live agent runs for a workstream, main agent first.
        func runs(for id: UUID) -> [AgentRun] {
            rosters[id] ?? []
        }

        /// Number of live agent runs (main + subagents).
        func activeRunCount(for id: UUID) -> Int {
            rosters[id]?.count ?? 0
        }

        /// Clears the `.justFinished` blue state. Permission state is preserved
        /// because it still blocks Claude even after the user has looked at the row.
        func markSeen(workstreamID: UUID) {
            if case .needsAttention(.justFinished) = states[workstreamID] {
                states[workstreamID] = .idle
            }
        }

        /// True while the workstream has seen harness activity this app launch.
        func hasLiveSession(for id: UUID) -> Bool {
            liveSessionIDs.contains(id)
        }

        /// Records that a permission prompt was answered *in Atelier*.
        ///
        /// Two things happen here, and both are needed. The row stops reporting
        /// that it is waiting on the user: after an allow the tool's
        /// `PreToolUse` would do that a moment later anyway, but after a **deny**
        /// no tool runs, and nothing else would clear the state until the turn
        /// ended. And every run's clock is restarted, because the stall sweep
        /// *skips* a workstream whose row is awaiting permission — so a run
        /// released after a 90-second hold is already past `stallThreshold` the
        /// instant it stops being skipped, and the very next sweep would paint it
        /// yellow for having been answered slowly. Every run is stamped, not just
        /// the main one: nothing in the workstream could emit an event while they
        /// were all blocked behind the same prompt.
        ///
        /// Deliberately *not* called when a hold expires. The user is still being
        /// asked then — in the terminal instead of here — so the row is still
        /// telling the truth and the sweep should still skip it.
        func permissionAnswered(workstreamID: UUID) {
            let wasAwaitingPermission = states[workstreamID]?.isAwaitingPermission ?? false
            if case .needsAttention(.permission) = states[workstreamID] {
                states[workstreamID] = .working
            }
            // The same edge a hook-driven resolution posts. Without it, answering
            // here would clear the row while leaving the desktop banner up,
            // sending the user to a pane with nothing waiting on it — which is
            // the one thing `PermissionNotifier.withdraw` exists to prevent.
            postPermissionEdge(wsID: workstreamID, wasAwaitingPermission: wasAwaitingPermission)
            for (surfaceID, owner) in surfaceWorkstream where owner == workstreamID {
                if case .needsAttention(.permission) = surfaceStates[surfaceID] {
                    surfaceStates[surfaceID] = .working
                }
            }
            guard var list = rosters[workstreamID] else { return }
            let now = Date()
            for idx in list.indices {
                list[idx].lastEventAt = now
            }
            rosters[workstreamID] = list
        }

        /// Context usage of the workstream's main session, read from the Claude
        /// Code transcript tail. Returns nil until a transcript has been parsed.
        func mainContextUsage(for id: UUID) -> ContextUsage? {
            contextUsage[id]
        }

        /// Drops all tracked state for a workstream (called when it is removed).
        func clear(workstreamID: UUID) {
            let wasAwaitingPermission = states[workstreamID]?.isAwaitingPermission ?? false
            defer { postPermissionEdge(wsID: workstreamID, wasAwaitingPermission: wasAwaitingPermission) }
            states.removeValue(forKey: workstreamID)
            rosters.removeValue(forKey: workstreamID)
            liveSessionIDs.remove(workstreamID)
            contextUsage.removeValue(forKey: workstreamID)
            lastContextReadAt.removeValue(forKey: workstreamID)
            transcriptReadFailing.remove(workstreamID)
            for (surface, owner) in surfaceWorkstream where owner == workstreamID {
                surfaceStates.removeValue(forKey: surface)
                surfaceWorkstream.removeValue(forKey: surface)
            }
        }

        /// Drops one surface's turn state, called when the agent occupying it goes
        /// away. Without this a surface keeps whatever it last reported — typically
        /// `.idle` — and anything consulting it later acts on a dead agent's state.
        func clear(surfaceID: UUID) {
            surfaceStates.removeValue(forKey: surfaceID)
            surfaceWorkstream.removeValue(forKey: surfaceID)
        }

        /// Clears every tracked state. Used by tests to isolate cases.
        func resetForTesting() {
            states.removeAll()
            rosters.removeAll()
            liveSessionIDs.removeAll()
            contextUsage.removeAll()
            lastContextReadAt.removeAll()
            transcriptReadFailing.removeAll()
            surfaceStates.removeAll()
            surfaceWorkstream.removeAll()
            workstreamLookup = nil
            currentSelection = nil
            onProlongedSilence = nil
        }

        /// Backdates a run's last-event timestamp. Used by stall sweep unit tests.
        func _backdateRun(agentId: String, workstreamID: UUID, lastEventAt: Date) {
            guard var list = rosters[workstreamID],
                  let idx = list.firstIndex(where: { $0.id == agentId }) else { return }
            list[idx].lastEventAt = lastEventAt
            rosters[workstreamID] = list
        }

        /// Aggressive path normalization: resolves symlinks (e.g. `/private/var` ↔ `/var`)
        /// in addition to the `.standardized` collapse. Hook payloads and stored
        /// `worktreePath`s have come through different code paths and may differ in
        /// symlink form.
        static func normalize(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
        }

        // MARK: - Event Handling

        func handle(projectDir: String, event: AgentEvent) {
            guard let lookup = workstreamLookup, let wsID = lookup(projectDir) else {
                // Common: Claude sessions running outside any tracked workstream.
                logger.debug("No workstream match for projectDir: \(projectDir, privacy: .public)")
                return
            }

            ensureSweepTimer()
            liveSessionIDs.insert(wsID)
            updateRoster(wsID: wsID, event: event)
            if event.agentId == "main" {
                updateMainState(wsID: wsID, event: event)
                if let surfaceID = event.surfaceID.flatMap(UUID.init(uuidString:)) {
                    updateSurfaceState(surfaceID: surfaceID, wsID: wsID, event: event)
                }
                switch event.type {
                case .agentSessionStarted, .agentSessionEnded:
                    // A session's context window goes with the session. Reading
                    // the transcript here would put the totals we just dropped
                    // straight back — the payload still names the old file — and a
                    // fill level means nothing once there is nothing filling it.
                    contextUsage.removeValue(forKey: wsID)
                    lastContextReadAt.removeValue(forKey: wsID)
                default:
                    if let transcriptPath = event.transcriptPath {
                        // Forced at turn end and again once compaction finishes:
                        // both are the moments the number changes by a lot, and the
                        // read throttle would otherwise leave the pre-compaction
                        // figure on screen for the rest of the interval.
                        let force = event.type == .agentIdle || event.status == "compacted"
                        refreshContextUsage(
                            wsID: wsID,
                            projectDir: projectDir,
                            transcriptPath: transcriptPath,
                            force: force
                        )
                    }
                }
            }
        }

        private func updateRoster(wsID: UUID, event: AgentEvent) {
            let now = Date()
            var list = rosters[wsID] ?? []

            func upsert(_ agentId: String, name: String? = nil, isMain: Bool = true, mutate: (inout AgentRun) -> Void = { _ in }) {
                if let idx = list.firstIndex(where: { $0.id == agentId }) {
                    mutate(&list[idx])
                    // A later event may refine the display name once the harness
                    // reports the agent type; apply refinements.
                    if let name, !name.isEmpty, name != list[idx].name {
                        list[idx].name = name
                    }
                    list[idx].lastEventAt = now
                } else {
                    var run = AgentRun(
                        id: agentId,
                        name: name ?? "Claude",
                        isMain: isMain,
                        state: .working,
                        activity: nil,
                        startedAt: now,
                        lastEventAt: now
                    )
                    mutate(&run)
                    list.append(run)
                }
            }

            switch event.type {
            case .agentCreated:
                // A duplicate create refines the existing run's attributes
                // instead of recreating it.
                let fallbackName = NSLocalizedString("Sub-agent", comment: "Fallback name for an unnamed subagent")
                let name = event.name ?? fallbackName
                if let idx = list.firstIndex(where: { $0.id == event.agentId }) {
                    if !name.isEmpty, name != list[idx].name {
                        list[idx].name = name
                    }
                    list[idx].lastEventAt = now
                } else {
                    upsert(event.agentId, name: name, isMain: false)
                }

            case .agentRemoved:
                list.removeAll { $0.id == event.agentId }

            case .agentToolStart:
                upsert(event.agentId, name: event.name) { run in
                    run.activity = event.activity ?? run.activity
                    run.isRunningTool = true
                    if run.state == .stalled {
                        run.state = .working
                    }
                }
                if event.agentId == "main", state(for: wsID) == .stalled {
                    states[wsID] = .working
                }

            case .agentToolDone:
                if let idx = list.firstIndex(where: { $0.id == event.agentId }) {
                    list[idx].activity = nil
                    list[idx].isRunningTool = false
                    list[idx].lastEventAt = now
                }

            case .agentWaiting:
                upsert(event.agentId, name: event.name)

            case .agentIdle:
                // Main going idle ends the whole turn; a child idling removes
                // only that child.
                if event.agentId == "main" {
                    list.removeAll()
                } else {
                    list.removeAll { $0.id == event.agentId }
                }

            case .agentStatus:
                // Permission prompts don't change the roster; the sweep skips
                // workstreams whose main agent is awaiting the user. Compaction
                // does carry an activity — and takes it away again — but only for
                // a run that already exists: a status is not evidence that an
                // agent is running, and inventing a run from one would put a card
                // on screen that no stop hook ever removes.
                guard let idx = list.firstIndex(where: { $0.id == event.agentId }) else { break }
                switch event.status {
                case "compacting":
                    list[idx].activity = event.activity
                    list[idx].isCompacting = true
                    list[idx].lastEventAt = now
                case "compacted":
                    list[idx].activity = nil
                    list[idx].isCompacting = false
                    list[idx].lastEventAt = now
                default:
                    break
                }

            case .agentSessionStarted, .agentSessionEnded:
                // Both end a whole session rather than a turn, so every run goes —
                // subagents included. `agentIdle` cannot stand in for this: it
                // leaves the workstream looking like an agent that finished, when
                // in one case it has been replaced and in the other it is gone.
                list.removeAll()
            }

            if list.isEmpty {
                rosters.removeValue(forKey: wsID)
            } else {
                // Main agent first so the sidebar reads top-down.
                list.sort { ($0.isMain ? 0 : 1, $0.startedAt) < ($1.isMain ? 0 : 1, $1.startedAt) }
                rosters[wsID] = list
            }
        }

        /// Reads context usage from the transcript tail. Throttled to one read per
        /// `contextReadInterval` — except at turn end (idle), where the final
        /// totals must land even if a read just happened. A failed read keeps any
        /// previous value.
        ///
        /// **The fallback channel.** A workstream whose status line has reported
        /// is left alone: that channel carries Claude Code's own figures,
        /// including the real window size, and re-deriving them here by
        /// inference would swap a known number for a guessed one every five
        /// seconds. The transcript stays for sessions with no status line
        /// configured, which is where `StatusLine.Config.write` declines to
        /// register.
        private func refreshContextUsage(wsID: UUID, projectDir: String, transcriptPath: String, force: Bool) {
            // Before the throttle, and before the read: this is not a failed
            // attempt to be retried sooner, it is a channel that has been
            // superseded.
            if contextUsage[wsID]?.source == .statusLine {
                return
            }

            let now = Date()
            if !force, let last = lastContextReadAt[wsID], now.timeIntervalSince(last) < Self.contextReadInterval {
                return
            }
            guard let reading = TranscriptContextReader.usage(transcriptPath: transcriptPath) else {
                // Logged on the edge only. The read is retried on every hook
                // event until it succeeds — deliberately, see below — so an
                // unconditional line here would be one per tool call for the
                // whole life of a session whose transcript never appears, which
                // is exactly the session this is meant to make diagnosable.
                if !transcriptReadFailing.contains(wsID) {
                    transcriptReadFailing.insert(wsID)
                    logger.info("Context usage unavailable: no readable transcript at \(transcriptPath, privacy: .public)")
                }
                return
            }
            transcriptReadFailing.remove(wsID)
            // Stamped only on a read that produced something. Stamping first burned
            // the whole interval on a failure, so a transcript that was mid-write
            // when it was first sampled stayed unread for another full interval —
            // and the doc comment above promises only that a failure *keeps* the
            // previous value, not that it suppresses the next attempt.
            lastContextReadAt[wsID] = now
            // The window is not in the transcript: Claude Code records the
            // resolved model ("claude-opus-5") whether or not the 1M beta is
            // on, so the model selection in its settings has to supply the
            // "[1m]" part. Resolved from `projectDir` — the hook's
            // `CLAUDE_PROJECT_DIR`, which is the root Claude Code itself reads
            // project settings from — rather than the transcript's `cwd`, which
            // follows the session as it wanders between directories.
            let limit = ContextLimits.limitTokens(
                transcriptModel: reading.model,
                configuredModel: ClaudeCodeSettings.configuredModel(cwd: projectDir),
                usedTokens: reading.usedTokens
            )
            contextUsage[wsID] = ContextUsage(
                usedTokens: reading.usedTokens,
                limitTokens: limit,
                source: .transcript
            )
        }

        /// Records a status line's report of its session's context window.
        ///
        /// Takes over from the transcript for that workstream from here on, and
        /// deliberately does **not** insert into `liveSessionIDs`: a rendered
        /// status line is not evidence that an agent is alive in the sense the
        /// row's status word means, and `HookChannelBanner` reads that set to
        /// decide whether any row can speak at all. A workstream Atelier has
        /// heard no hook from stays silent, which is the honest answer — the
        /// hook channel really is down.
        ///
        /// **Only the main session's reading is taken**, the same restriction
        /// the transcript path gets from `event.agentId == "main"`. Two agents
        /// can share a worktree — `open_agent_tab` registers the status line for
        /// the one it spawns too — and both report the same `project_dir`, so
        /// without this the bar would alternate between two unrelated fill
        /// levels. The Coding Agent tab's surface id *is* the workstream id,
        /// which is what makes the main session identifiable here. Compared as
        /// `UUID` rather than as text: `ATELIER_SURFACE_ID` is exported
        /// uppercase and the workstream id is written lowercase, so a string
        /// comparison would reject every real Coding Agent tab.
        ///
        /// A payload carrying no surface id is a Claude session started by hand
        /// in the worktree, and it is taken for the same reason the hook channel
        /// takes one: it is the only agent Atelier knows of there.
        ///
        /// An *unparseable* surface id is dropped rather than treated as an
        /// absent one, and the asymmetry is deliberate. Absent means "no Atelier
        /// surface exported one", which is a session this workstream owns by
        /// elimination. A value that is there but is not a UUID means something
        /// other than Atelier set `ATELIER_SURFACE_ID`, and a reading that
        /// cannot be attributed to the main session must not be attributed to it
        /// by default — the bar would then show a second agent's fill level.
        func handleStatusLine(projectDir: String, surfaceID: String?, reading: StatusLine.Reading) {
            guard let lookup = workstreamLookup, let wsID = lookup(projectDir) else { return }
            if let surfaceID, UUID(uuidString: surfaceID) != wsID {
                return
            }
            contextUsage[wsID] = ContextUsage(
                usedTokens: reading.usedTokens,
                limitTokens: reading.limitTokens,
                source: .statusLine
            )
        }

        private func updateMainState(wsID: UUID, event: AgentEvent) {
            let wasAwaitingPermission = states[wsID]?.isAwaitingPermission ?? false
            defer { postPermissionEdge(wsID: wsID, wasAwaitingPermission: wasAwaitingPermission) }

            switch event.type {
            case .agentWaiting:
                states[wsID] = .working

            case .agentIdle:
                if currentSelection == wsID {
                    states[wsID] = .idle
                } else {
                    states[wsID] = .needsAttention(.justFinished)
                }

            case .agentStatus:
                if event.status == "permissionRequired" {
                    states[wsID] = .needsAttention(.permission)
                }
                // Compaction is the agent busy. Worth saying explicitly because a
                // manual `/compact` starts from an idle row, and leaving it idle
                // would invite typing into a session that cannot answer yet.
                if event.status == "compacting" {
                    states[wsID] = .working
                }

            case .agentToolStart, .agentToolDone:
                // Tool activity while we were awaiting permission means the user
                // already answered the prompt (there's no explicit "granted" hook).
                // Otherwise no state change — prevents flicker between tools.
                if case .needsAttention(.permission) = states[wsID] {
                    states[wsID] = .working
                }

            case .agentSessionStarted, .agentSessionEnded:
                // Not `.needsAttention(.justFinished)`, which is the blue "come
                // look at what your agent did" state: a session that has been
                // replaced or has exited has nothing waiting to be read.
                states[wsID] = .idle

            case .agentCreated, .agentRemoved:
                break
            }
        }

        /// Announces a change in whether the workstream is blocked on a
        /// permission prompt, so the desktop notification can be shown and
        /// withdrawn.
        ///
        /// An edge, not a level: Claude's `Notification` hook fires repeatedly
        /// while one prompt sits unanswered, and posting on each would give a
        /// banner every few seconds for a single question. A `NotificationCenter`
        /// post rather than a callback because the receiver needs the
        /// workstream's name and the current selection, which live in
        /// `ContentView` — a closure installed from there would capture a
        /// snapshot of both and go stale.
        private func postPermissionEdge(wsID: UUID, wasAwaitingPermission: Bool) {
            let isAwaitingPermission = states[wsID]?.isAwaitingPermission ?? false
            guard isAwaitingPermission != wasAwaitingPermission else { return }
            NotificationCenter.default.post(
                name: isAwaitingPermission ? .agentBlockedOnPermission : .agentPermissionResolved,
                object: wsID
            )
        }

        /// Mirrors `updateMainState` for a single surface.
        ///
        /// Two deliberate differences. There is no selected/unselected split —
        /// `.needsAttention(.justFinished)` exists to colour a sidebar row, and a
        /// surface that finished its turn is simply `.idle`. And there is no stall
        /// sweep: a surface whose agent dies mid-turn stays `.working` and is never
        /// interrupted, which is the safe direction to fail.
        private func updateSurfaceState(surfaceID: UUID, wsID: UUID, event: AgentEvent) {
            surfaceWorkstream[surfaceID] = wsID

            switch event.type {
            case .agentWaiting:
                surfaceStates[surfaceID] = .working

            case .agentIdle:
                surfaceStates[surfaceID] = .idle

            case .agentStatus:
                if event.status == "permissionRequired" {
                    surfaceStates[surfaceID] = .needsAttention(.permission)
                }
                if event.status == "compacting" {
                    surfaceStates[surfaceID] = .working
                }

            case .agentSessionStarted:
                surfaceStates[surfaceID] = .idle

            case .agentSessionEnded:
                // Cleared rather than set to `.idle`, which would read as "the
                // turn ended, the pane is at an agent prompt" — and `.idle` is
                // what `AgentNudge` and `PromptInjector` check before typing into
                // it. The agent is gone, so the honest report is no evidence at
                // all, the same thing `clear(surfaceID:)` does when a peer
                // retires.
                surfaceStates.removeValue(forKey: surfaceID)
                surfaceWorkstream.removeValue(forKey: surfaceID)

            case .agentToolStart, .agentToolDone:
                // A running tool is proof of an active turn, so this sets .working
                // outright rather than only clearing a permission prompt the way
                // `updateMainState` does. That difference is deliberate: hook
                // delivery is a one-second curl that fails silently, and a dropped
                // turn-start would otherwise leave the surface reading .idle for the
                // rest of the turn. Any tool call recovers it. The sidebar keeps its
                // no-flicker behaviour; only this per-surface state changes.
                surfaceStates[surfaceID] = .working

            case .agentCreated, .agentRemoved:
                break
            }
        }

        // MARK: - Stall Detection

        private func ensureSweepTimer() {
            guard sweepTimer == nil else { return }
            let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sweepForStalls()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            sweepTimer = timer
        }

        /// Reports runs that have gone quiet, in the two stages that silence
        /// actually means something.
        ///
        /// At `silenceThreshold` nothing is reported and the hook channel is
        /// asked whether it is still delivering — because "the agent is quiet"
        /// and "the app has stopped hearing" produce identical evidence here,
        /// and no amount of further silence distinguishes them.
        ///
        /// At `wedgeThreshold` a run that is still quiet, is not mid-tool, is
        /// not compacting and is not holding a permission prompt is marked
        /// `.stalled`.
        ///
        /// Internal (not private) so tests can sweep with backdated timestamps.
        func sweepForStalls(now: Date = Date()) {
            let silenceCutoff = now.addingTimeInterval(-Self.silenceThreshold)
            let wedgeCutoff = now.addingTimeInterval(-Self.wedgeThreshold)
            var sawProlongedSilence = false

            for (wsID, list) in rosters {
                var updated = list
                var changed = false
                let rowState = states[wsID] ?? .idle
                for idx in updated.indices {
                    guard updated[idx].state == .working, updated[idx].lastEventAt < silenceCutoff else { continue }

                    // Worth asking about the channel even when something below
                    // explains the silence: a tool in flight is explained by a
                    // `PreToolUse` that arrived, but the `PostToolUse` that
                    // should have followed is exactly the kind of event a
                    // broken channel loses.
                    sawProlongedSilence = true

                    guard updated[idx].lastEventAt < wedgeCutoff else { continue }

                    // Waiting on the user isn't stalling.
                    if case .needsAttention(.permission) = rowState {
                        continue
                    }
                    // Neither is a tool that is still running. `PreToolUse`
                    // fires when the agent starts a command and nothing else
                    // arrives until it returns, so this exemption is what stops
                    // a long build — the original complaint — reporting a
                    // wedged agent.
                    if updated[idx].isRunningTool,
                       now.timeIntervalSince(updated[idx].lastEventAt) < Self.longWorkGrace
                    {
                        continue
                    }
                    // Nor is compacting: it emits nothing between PreCompact
                    // and PostCompact.
                    if updated[idx].isCompacting,
                       now.timeIntervalSince(updated[idx].lastEventAt) < Self.longWorkGrace
                    {
                        continue
                    }
                    updated[idx].state = .stalled
                    changed = true
                }
                guard changed else { continue }
                rosters[wsID] = updated
                // Surface a stalled main run at row level unless something more
                // important already needs attention there. A fresh sibling run
                // (a live subagent) means the workstream is still actively
                // working through it — keep the row Working.
                let hasFreshActivity = updated.contains { run in
                    run.state == .working && run.lastEventAt >= silenceCutoff
                }
                if updated.contains(where: { $0.isMain && $0.state == .stalled }),
                   !hasFreshActivity,
                   case .working = rowState
                {
                    states[wsID] = .stalled
                }
            }

            // Once per sweep, not once per quiet run: ten workstreams falling
            // silent together is one question about the channel.
            if sawProlongedSilence {
                onProlongedSilence?()
            }
        }
    }
}
