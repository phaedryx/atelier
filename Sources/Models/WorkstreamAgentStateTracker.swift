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
@MainActor
final class WorkstreamAgentStateTracker: ObservableObject {
    static let shared = WorkstreamAgentStateTracker()

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
    }

    /// Context-window consumption of a workstream's main session.
    struct ContextUsage: Equatable {
        let usedTokens: Int
        let limitTokens: Int
        var fraction: Double {
            limitTokens > 0 ? Double(usedTokens) / Double(limitTokens) : 0
        }
    }

    static let stallThreshold: TimeInterval = 45
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

    /// Resolves a Claude `project_dir` payload to the matching workstream UUID.
    /// Set by `ContentView` whenever the project list changes.
    var workstreamLookup: ((String) -> UUID?)?

    /// Currently selected workstream — `Stop` while selected goes straight to
    /// `.idle` because the user is already looking at it.
    var currentSelection: UUID?

    private var sweepTimer: Timer?

    private init() {}

    // MARK: - Public API

    func state(for id: UUID) -> AgentRunState {
        states[id] ?? .idle
    }

    /// The workstream's turn state only when something has actually reported it.
    ///
    /// `state(for:)` above defaults to `.idle` so a sidebar row has something to
    /// draw. That default is wrong for anything that acts on the state: it makes
    /// "no hook has ever arrived" — hooks not installed, or failing — read as
    /// "the agent finished its turn".
    func reportedState(for id: UUID) -> AgentRunState? {
        states[id]
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

    /// Context usage of the workstream's main session, read from the Claude
    /// Code transcript tail. Returns nil until a transcript has been parsed.
    func mainContextUsage(for id: UUID) -> ContextUsage? {
        contextUsage[id]
    }

    /// Drops all tracked state for a workstream (called when it is removed).
    func clear(workstreamID: UUID) {
        states.removeValue(forKey: workstreamID)
        rosters.removeValue(forKey: workstreamID)
        liveSessionIDs.remove(workstreamID)
        contextUsage.removeValue(forKey: workstreamID)
        lastContextReadAt.removeValue(forKey: workstreamID)
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
        surfaceStates.removeAll()
        surfaceWorkstream.removeAll()
        workstreamLookup = nil
        currentSelection = nil
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
            if let transcriptPath = event.transcriptPath {
                refreshContextUsage(wsID: wsID, transcriptPath: transcriptPath, force: event.type == .agentIdle)
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
            // workstreams whose main agent is awaiting the user.
            break
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
    private func refreshContextUsage(wsID: UUID, transcriptPath: String, force: Bool) {
        let now = Date()
        if !force, let last = lastContextReadAt[wsID], now.timeIntervalSince(last) < Self.contextReadInterval {
            return
        }
        lastContextReadAt[wsID] = now
        guard let parsed = TranscriptContextReader.usage(transcriptPath: transcriptPath) else { return }
        contextUsage[wsID] = ContextUsage(usedTokens: parsed.usedTokens, limitTokens: parsed.limitTokens)
    }

    private func updateMainState(wsID: UUID, event: AgentEvent) {
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

        case .agentToolStart, .agentToolDone:
            // Tool activity while we were awaiting permission means the user
            // already answered the prompt (there's no explicit "granted" hook).
            // Otherwise no state change — prevents flicker between tools.
            if case .needsAttention(.permission) = states[wsID] {
                states[wsID] = .working
            }

        case .agentCreated, .agentRemoved:
            break
        }
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

    /// Marks runs stalled when they haven't emitted an event since `now - stallThreshold`.
    /// Internal (not private) so tests can sweep with backdated timestamps.
    func sweepForStalls(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.stallThreshold)
        for (wsID, list) in rosters {
            var updated = list
            var changed = false
            let rowState = states[wsID] ?? .idle
            for idx in updated.indices {
                guard updated[idx].state == .working, updated[idx].lastEventAt < cutoff else { continue }
                // Waiting on the user isn't stalling.
                if case .needsAttention(.permission) = rowState {
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
                run.state == .working && run.lastEventAt >= cutoff
            }
            if updated.contains(where: { $0.isMain && $0.state == .stalled }),
               !hasFreshActivity,
               case .working = rowState
            {
                states[wsID] = .stalled
            }
        }
    }
}
