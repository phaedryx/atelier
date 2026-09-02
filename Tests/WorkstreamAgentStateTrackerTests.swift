// ABOUTME: Tests for the per-workstream agent roster and row-level state machine.
// ABOUTME: Covers run lifecycle, activity text, permission handling, and stall sweeping.

@testable import Atelier
import XCTest

@MainActor
final class WorkstreamAgentStateTrackerTests: XCTestCase {
    private let wsID = UUID()
    private let projectDir = "/tmp/atelier-test-worktree"

    private var tracker: WorkstreamAgentStateTracker {
        WorkstreamAgentStateTracker.shared
    }

    override func setUp() {
        super.setUp()
        tracker.resetForTesting()
    }

    override func tearDown() {
        tracker.resetForTesting()
        super.tearDown()
    }

    /// Routes an event through the tracker, installing the lookup mapping on first use.
    private func handle(_ event: AgentEvent) {
        if tracker.workstreamLookup == nil {
            let expected = WorkstreamAgentStateTracker.normalize(projectDir)
            let mapped = wsID
            tracker.workstreamLookup = { dir in
                WorkstreamAgentStateTracker.normalize(dir) == expected ? mapped : nil
            }
        }
        tracker.handle(projectDir: projectDir, event: event)
    }

    private func backdateMainRun(secondsAgo: TimeInterval) {
        tracker._backdateRun(
            agentId: "main",
            workstreamID: wsID,
            lastEventAt: Date().addingTimeInterval(-secondsAgo)
        )
    }

    // MARK: - Run lifecycle

    func testPromptSubmitCreatesMainRun() {
        handle(.waiting(agentId: "main"))
        let runs = tracker.runs(for: wsID)
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].isMain)
        XCTAssertEqual(runs[0].name, "Claude")
        XCTAssertEqual(tracker.activeRunCount(for: wsID), 1)
    }

    func testStopRemovesMainRun() {
        handle(.waiting(agentId: "main"))
        handle(.idle(agentId: "main"))
        XCTAssertEqual(tracker.activeRunCount(for: wsID), 0)
    }

    func testSubagentStartStopLifecycle() {
        handle(.created(agentId: "sub-1", name: "Explore"))
        var runs = tracker.runs(for: wsID)
        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(runs[0].isMain)
        XCTAssertEqual(runs[0].name, "Explore")

        handle(.removed(agentId: "sub-1"))
        runs = tracker.runs(for: wsID)
        XCTAssertTrue(runs.isEmpty)
    }

    func testDuplicateSubagentStartDoesNotDuplicateRun() {
        handle(.created(agentId: "sub-1", name: "Explore"))
        handle(.created(agentId: "sub-1", name: "Explore"))
        XCTAssertEqual(tracker.activeRunCount(for: wsID), 1)
    }

    func testMainRunSortsFirstAmongSubagents() {
        handle(.waiting(agentId: "main"))
        handle(.created(agentId: "sub-a", name: "Explore"))
        handle(.created(agentId: "sub-b", name: "Plan"))
        let runs = tracker.runs(for: wsID)
        XCTAssertEqual(runs.map(\.id), ["main", "sub-a", "sub-b"])
    }

    func testEventsOutsideTrackedWorkstreamsAreIgnored() {
        tracker.workstreamLookup = { _ in nil }
        handle(.waiting(agentId: "main"))
        handle(.created(agentId: "sub-1", name: "Explore"))
        XCTAssertEqual(tracker.activeRunCount(for: wsID), 0)
    }

    // MARK: - Activity

    func testToolStartSetsActivityAndToolDoneClearsIt() {
        handle(.waiting(agentId: "main"))
        handle(.toolStart(agentId: "main", tool: "Edit", activity: "Editing Foo.swift"))
        XCTAssertEqual(tracker.runs(for: wsID).first?.activity, "Editing Foo.swift")

        handle(.toolDone(agentId: "main"))
        XCTAssertNil(tracker.runs(for: wsID).first?.activity)
    }

    func testSubagentActivityIsTrackedSeparately() {
        handle(.created(agentId: "sub-1", name: "Explore"))
        handle(.toolStart(agentId: "sub-1", tool: "Grep", activity: "Searching"))
        let sub = tracker.runs(for: wsID).first(where: { $0.id == "sub-1" })
        XCTAssertEqual(sub?.activity, "Searching")
    }

    // MARK: - Row-level state

    func testPromptSubmitMarksRowWorking() {
        handle(.waiting(agentId: "main"))
        XCTAssertEqual(tracker.state(for: wsID), .working)
    }

    func testStopOnUnselectedWorkstreamNeedsAttention() {
        handle(.waiting(agentId: "main"))
        handle(.idle(agentId: "main"))
        XCTAssertEqual(tracker.state(for: wsID), .needsAttention(.justFinished))
    }

    func testStopOnSelectedWorkstreamGoesIdle() {
        tracker.currentSelection = wsID
        handle(.waiting(agentId: "main"))
        handle(.idle(agentId: "main"))
        XCTAssertEqual(tracker.state(for: wsID), .idle)
    }

    func testPermissionStatusThenToolActivityResumesWorking() {
        tracker.currentSelection = wsID
        handle(.status(agentId: "main", status: "permissionRequired"))
        XCTAssertEqual(tracker.state(for: wsID), .needsAttention(.permission))

        // Tool activity implies the user answered the prompt.
        handle(.toolStart(agentId: "main", tool: "Bash"))
        XCTAssertEqual(tracker.state(for: wsID), .working)
    }

    func testMarkSeenClearsJustFinishedButKeepsPermission() {
        handle(.idle(agentId: "main"))
        tracker.markSeen(workstreamID: wsID)
        XCTAssertEqual(tracker.state(for: wsID), .idle)

        handle(.status(agentId: "main", status: "permissionRequired"))
        tracker.markSeen(workstreamID: wsID)
        XCTAssertEqual(tracker.state(for: wsID), .needsAttention(.permission))
    }

    // MARK: - Stall detection

    func testStaleRunSweepsToStalled() {
        handle(.waiting(agentId: "main"))
        backdateMainRun(secondsAgo: WorkstreamAgentStateTracker.stallThreshold + 10)

        tracker.sweepForStalls(now: Date())
        XCTAssertEqual(tracker.runs(for: wsID)[0].state, .stalled)
        XCTAssertEqual(tracker.state(for: wsID), .stalled)
    }

    func testFreshRunDoesNotStall() {
        handle(.waiting(agentId: "main"))
        backdateMainRun(secondsAgo: 5)

        tracker.sweepForStalls(now: Date())
        XCTAssertEqual(tracker.runs(for: wsID)[0].state, .working)
        XCTAssertEqual(tracker.state(for: wsID), .working)
    }

    func testStalledSweepSkippedWhileAwaitingPermission() {
        tracker.currentSelection = wsID
        handle(.waiting(agentId: "main"))
        handle(.status(agentId: "main", status: "permissionRequired"))
        backdateMainRun(secondsAgo: WorkstreamAgentStateTracker.stallThreshold + 10)

        tracker.sweepForStalls(now: Date())
        // Waiting on the user is not stalling.
        XCTAssertEqual(tracker.runs(for: wsID)[0].state, .working)
    }

    func testToolStartUnstallsRunAndRow() {
        handle(.waiting(agentId: "main"))
        backdateMainRun(secondsAgo: WorkstreamAgentStateTracker.stallThreshold + 10)
        tracker.sweepForStalls(now: Date())
        XCTAssertEqual(tracker.state(for: wsID), .stalled)

        handle(.toolStart(agentId: "main", tool: "Read", activity: "Reading Bar.swift"))
        XCTAssertEqual(tracker.runs(for: wsID)[0].state, .working)
        XCTAssertEqual(tracker.state(for: wsID), .working)
    }

    /// A stale main run waiting on a live subagent is delegation, not a
    /// stall — the row keeps its Working state until the whole workstream
    /// goes quiet.
    func testFreshSubagentKeepsRowWorkingWhenMainGoesQuiet() {
        handle(.waiting(agentId: "main"))
        handle(.created(agentId: "ses_build", name: "build"))
        backdateMainRun(secondsAgo: WorkstreamAgentStateTracker.stallThreshold + 10)

        tracker.sweepForStalls(now: Date())
        XCTAssertEqual(tracker.runs(for: wsID).first { $0.isMain }?.state, .stalled)
        XCTAssertEqual(tracker.state(for: wsID), .working)

        // Once the subagent goes quiet too, the row stalls.
        tracker._backdateRun(
            agentId: "ses_build",
            workstreamID: wsID,
            lastEventAt: Date().addingTimeInterval(-(WorkstreamAgentStateTracker.stallThreshold + 10))
        )
        tracker.sweepForStalls(now: Date())
        XCTAssertEqual(tracker.state(for: wsID), .stalled)
    }

    /// The main session's context figures must outlive the roster clear at
    /// turn end so the row's context bar persists at Done/Idle.
    func testContextUsageSurvivesMainIdle() throws {
        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 42_000)
        handle(.waiting(agentId: "main", transcriptPath: url.path))
        XCTAssertNotNil(tracker.mainContextUsage(for: wsID))

        handle(.idle(agentId: "main", transcriptPath: url.path))
        XCTAssertTrue(tracker.runs(for: wsID).isEmpty)

        let usage = tracker.mainContextUsage(for: wsID)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.usedTokens, 42_000)
        XCTAssertEqual(usage?.limitTokens, 200_000)
    }

    // MARK: - Cleanup

    func testClearRemovesAllStateForWorkstream() {
        handle(.waiting(agentId: "main"))
        handle(.created(agentId: "sub-1", name: "Explore"))
        tracker.clear(workstreamID: wsID)
        XCTAssertEqual(tracker.activeRunCount(for: wsID), 0)
        XCTAssertEqual(tracker.state(for: wsID), .idle)
    }

    // MARK: - Activity description mapping

    func testActivityDescriptionMapping() {
        let filePathInput: [String: Any] = ["file_path": "/repo/Sources/Foo.swift"]
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "Edit", toolInput: filePathInput), String(format: NSLocalizedString("Editing %@", comment: ""), "Foo.swift"))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "Read", toolInput: filePathInput), String(format: NSLocalizedString("Reading %@", comment: ""), "Foo.swift"))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "Grep", toolInput: nil), NSLocalizedString("Searching", comment: ""))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "Bash", toolInput: nil), NSLocalizedString("Running command", comment: ""))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "WebFetch", toolInput: nil), NSLocalizedString("Browsing", comment: ""))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "TodoWrite", toolInput: nil), NSLocalizedString("Planning", comment: ""))
        // Unknown tools surface verbatim so the row always says something specific.
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "SomeCustomTool", toolInput: nil), "SomeCustomTool")
    }

    // MARK: - Case-insensitive tool matching

    func testActivityDescriptionMatchesLowercaseToolNames() {
        let filePathInput: [String: Any] = ["file_path": "/repo/Sources/Foo.swift"]
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "edit", toolInput: filePathInput), String(format: NSLocalizedString("Editing %@", comment: ""), "Foo.swift"))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "read", toolInput: filePathInput), String(format: NSLocalizedString("Reading %@", comment: ""), "Foo.swift"))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "grep", toolInput: nil), NSLocalizedString("Searching", comment: ""))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "bash", toolInput: nil), NSLocalizedString("Running command", comment: ""))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "todowrite", toolInput: nil), NSLocalizedString("Planning", comment: ""))
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "task", toolInput: nil), NSLocalizedString("Delegating", comment: ""))
    }

    /// Unmapped custom/MCP tools surface verbatim so the row always shows
    /// something specific; an empty name still yields no activity.
    func testActivityDescriptionFallsBackToToolNameVerbatim() {
        XCTAssertEqual(HookEventReceiver.activityDescription(toolName: "mcp_custom_lookup", toolInput: nil), "mcp_custom_lookup")
        XCTAssertNil(HookEventReceiver.activityDescription(toolName: "", toolInput: nil))
    }

    /// A duplicate create refines the existing run instead of recreating or
    /// resetting it.
    func testDuplicateCreatedRefinesName() {
        handle(.created(agentId: "sub-1", name: "Sub-agent"))
        let originalStart = tracker.runs(for: wsID).first?.startedAt

        handle(.created(agentId: "sub-1", name: "explore", parentAgentId: "main"))

        let runs = tracker.runs(for: wsID)
        XCTAssertEqual(runs.count, 1)
        let sub = runs[0]
        XCTAssertEqual(sub.name, "explore")
        XCTAssertEqual(sub.startedAt, originalStart, "the run is refined, not recreated")
    }

    func testChildIdleRemovesOnlyThatChild() {
        handle(.waiting(agentId: "main"))
        handle(.created(agentId: "ses_child", name: "Explore"))
        handle(.idle(agentId: "ses_child"))
        XCTAssertEqual(tracker.runs(for: wsID).map(\.id), ["main"])
    }

    func testMainIdleClearsRemainingChildren() {
        handle(.waiting(agentId: "main"))
        handle(.created(agentId: "ses_a", name: "Explore"))
        handle(.idle(agentId: "main"))
        XCTAssertEqual(tracker.activeRunCount(for: wsID), 0)
    }

    // MARK: - Name and attribute refinement

    func testToolStartCreatesRunWithCarriedName() {
        var event = AgentEvent.toolStart(agentId: "ses_child", tool: "Edit")
        event.name = "explore"
        handle(event)
        XCTAssertEqual(tracker.runs(for: wsID).first?.name, "explore")
    }

    func testSubsequentEventRefinesExistingRunName() {
        var first = AgentEvent.toolStart(agentId: "ses_child", tool: "Bash")
        first.name = "Sub-agent"
        handle(first)
        XCTAssertEqual(tracker.runs(for: wsID).first?.name, "Sub-agent")

        // The hook reports the real agent type once known.
        var second = AgentEvent.toolStart(agentId: "ses_child", tool: "Read")
        second.name = "general-purpose"
        handle(second)
        XCTAssertEqual(tracker.runs(for: wsID).first?.name, "general-purpose")
    }

    // MARK: - Live session presence

    func testHasLiveSessionIsFalseByDefault() {
        XCTAssertFalse(tracker.hasLiveSession(for: wsID))
        XCTAssertTrue(tracker.liveSessionIDs.isEmpty)
    }

    func testHandledEventMarksLiveSession() {
        handle(.waiting(agentId: "main"))
        XCTAssertTrue(tracker.hasLiveSession(for: wsID))
        XCTAssertTrue(tracker.liveSessionIDs.contains(wsID))
    }

    func testClearRemovesLiveSessionFlag() {
        handle(.waiting(agentId: "main"))
        tracker.clear(workstreamID: wsID)
        XCTAssertFalse(tracker.hasLiveSession(for: wsID))
    }

    // MARK: - Context-window usage

    private func tempTranscriptURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-tracker-tests-\(UUID().uuidString).jsonl")
    }

    private func writeTranscript(url: URL, usedTokens: Int, model: String = "claude-sonnet-4-5") throws {
        let line = "{\"type\":\"assistant\",\"message\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(usedTokens),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
        try line.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTranscriptPathPopulatesContextUsage() throws {
        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 1234)

        handle(.waiting(agentId: "main", transcriptPath: url.path))

        let usage = try XCTUnwrap(tracker.contextUsage[wsID])
        XCTAssertEqual(usage.usedTokens, 1234)
        XCTAssertEqual(usage.limitTokens, 200_000)
        XCTAssertEqual(usage.fraction, Double(1234) / 200_000, accuracy: 1e-12)
    }

    func testContextUsageReadIsThrottledWithinFiveSeconds() throws {
        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 100)

        handle(.waiting(agentId: "main", transcriptPath: url.path))
        XCTAssertEqual(tracker.contextUsage[wsID]?.usedTokens, 100)

        // Rewrite the transcript; the throttle must skip the re-read.
        try writeTranscript(url: url, usedTokens: 9000)
        handle(.toolStart(agentId: "main", tool: "Bash", transcriptPath: url.path))
        XCTAssertEqual(tracker.contextUsage[wsID]?.usedTokens, 100)
    }

    func testAgentIdleAlwaysRereadsTranscript() throws {
        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 100)
        handle(.waiting(agentId: "main", transcriptPath: url.path))

        try writeTranscript(url: url, usedTokens: 9000)
        handle(.idle(agentId: "main", transcriptPath: url.path))
        XCTAssertEqual(tracker.contextUsage[wsID]?.usedTokens, 9000)
    }

    func testFailedReadKeepsPreviousContextUsage() throws {
        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 100)
        handle(.waiting(agentId: "main", transcriptPath: url.path))
        XCTAssertEqual(tracker.contextUsage[wsID]?.usedTokens, 100)

        // Remove the file so the forced idle re-read fails; the previous
        // value must stick.
        try FileManager.default.removeItem(at: url)
        handle(.idle(agentId: "main", transcriptPath: url.path))
        XCTAssertEqual(tracker.contextUsage[wsID]?.usedTokens, 100)
    }

    func testClearRemovesLiveSessionAndContextUsage() throws {
        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 10)
        handle(.waiting(agentId: "main", transcriptPath: url.path))
        XCTAssertTrue(tracker.hasLiveSession(for: wsID))
        XCTAssertNotNil(tracker.contextUsage[wsID])

        tracker.clear(workstreamID: wsID)
        XCTAssertFalse(tracker.hasLiveSession(for: wsID))
        XCTAssertNil(tracker.contextUsage[wsID])
    }

    /// Usage is nil until a transcript has been parsed — but once it has,
    /// the last reading persists past turn end (the row's bar dims instead
    /// of vanishing at Done/Idle).
    func testMainContextUsageNilUntilReportedThenPersists() throws {
        XCTAssertNil(tracker.mainContextUsage(for: wsID))

        let url = tempTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTranscript(url: url, usedTokens: 42_000)
        handle(.waiting(agentId: "main", transcriptPath: url.path))
        handle(.idle(agentId: "main", transcriptPath: url.path))

        let usage = tracker.mainContextUsage(for: wsID)
        XCTAssertEqual(usage?.usedTokens, 42_000)
    }

    // MARK: - Per-surface attribution

    /// Builds an event stamped with the surface it came from, the way
    /// `HookEventReceiver` does when the hook inherited ATELIER_SURFACE_ID.
    private func fromSurface(_ surfaceID: UUID, _ event: AgentEvent) -> AgentEvent {
        var stamped = event
        stamped.surfaceID = surfaceID.uuidString
        return stamped
    }

    func test_surfaceState_tracksTurnEndPerPane() {
        let paneA = UUID()
        let paneB = UUID()

        handle(fromSurface(paneA, .waiting(agentId: "main")))
        handle(fromSurface(paneB, .waiting(agentId: "main")))
        XCTAssertEqual(tracker.state(forSurface: paneA), .working)
        XCTAssertEqual(tracker.state(forSurface: paneB), .working)

        handle(fromSurface(paneA, .idle(agentId: "main")))
        XCTAssertEqual(tracker.state(forSurface: paneA), .idle)
        XCTAssertEqual(tracker.state(forSurface: paneB), .working, "one pane finishing says nothing about the other")
    }

    func test_surfaceState_isNilUntilThatSurfaceReports() {
        handle(.idle(agentId: "main"))
        XCTAssertNil(tracker.state(forSurface: UUID()), "no evidence must read as nil, not as idle")
    }

    func test_surfaceState_ignoresSubagents() {
        let pane = UUID()
        handle(fromSurface(pane, .waiting(agentId: "main")))
        handle(fromSurface(pane, .idle(agentId: "sub-1")))
        XCTAssertEqual(tracker.state(forSurface: pane), .working, "a subagent stopping is not the main turn ending")
    }

    func test_surfaceState_reportsAPermissionPrompt() {
        let pane = UUID()
        handle(fromSurface(pane, .status(agentId: "main", status: "permissionRequired")))
        XCTAssertEqual(tracker.state(forSurface: pane), .needsAttention(.permission))

        handle(fromSurface(pane, .toolStart(agentId: "main", tool: "Bash")))
        XCTAssertEqual(tracker.state(forSurface: pane), .working, "tool activity means the prompt was answered")
    }

    func test_clear_dropsTheWorkstreamsSurfaces() {
        let pane = UUID()
        handle(fromSurface(pane, .idle(agentId: "main")))
        XCTAssertNotNil(tracker.state(forSurface: pane))

        tracker.clear(workstreamID: wsID)
        XCTAssertNil(tracker.state(forSurface: pane))
    }

    func test_workstreamState_isUnaffectedBySurfaceStamping() {
        let pane = UUID()
        handle(fromSurface(pane, .idle(agentId: "main")))
        XCTAssertEqual(tracker.state(for: wsID), .needsAttention(.justFinished), "the sidebar's signal must not change")
    }

    func test_surfaceState_toolActivityMeansWorking() {
        let pane = UUID()
        handle(fromSurface(pane, .idle(agentId: "main")))
        XCTAssertEqual(tracker.state(forSurface: pane), .idle)

        // A dropped turn-start would otherwise leave this reading .idle for the
        // whole turn; a running tool is proof the agent is busy.
        handle(fromSurface(pane, .toolStart(agentId: "main", tool: "Bash")))
        XCTAssertEqual(tracker.state(forSurface: pane), .working)
    }

    func test_clearSurface_dropsOnlyThatSurface() {
        let paneA = UUID()
        let paneB = UUID()
        handle(fromSurface(paneA, .idle(agentId: "main")))
        handle(fromSurface(paneB, .idle(agentId: "main")))

        tracker.clear(surfaceID: paneA)
        XCTAssertNil(tracker.state(forSurface: paneA))
        XCTAssertEqual(tracker.state(forSurface: paneB), .idle)
    }

    func test_reportedState_isNilBeforeAnyEvent() {
        XCTAssertNil(tracker.reportedState(for: UUID()))
        XCTAssertEqual(tracker.state(for: UUID()), .idle, "the sidebar default is unchanged")
    }
}
