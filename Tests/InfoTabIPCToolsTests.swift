// ABOUTME: Tests for get_initialization_state and get_shortcut_story — the Info tab's two facts over IPC.
// ABOUTME: The mappings are pure, so they are asserted directly rather than through the blocking socket harness.

@testable import Atelier
import XCTest

final class InfoTabIPCToolsTests: XCTestCase {
    // MARK: - Initialization state

    /// The key is a wire value an agent branches on. All five, spelled out —
    /// a renamed case must break this rather than quietly change what a tool
    /// reports.
    func test_everyInitializationState_hasItsOwnKey() {
        XCTAssertEqual(Initialization.State.idle.key, "idle")
        XCTAssertEqual(Initialization.State.inProgress(step: "Running “deps” (1 of 2)", progress: 0.5).key, "in_progress")
        XCTAssertEqual(Initialization.State.completed.key, "completed")
        XCTAssertEqual(Initialization.State.completedWithNote("no file").key, "completed_with_note")
        XCTAssertEqual(Initialization.State.failed("exit 1").key, "failed")
    }

    /// The sentence an agent is told and the sentence the user reads off the
    /// Setup row are one string, because they are one fact about one run. This
    /// is the rule `Verification.Runner.loadConfig` had to be corrected to, and
    /// it holds here by construction — `initializationRow` reads `State.detail`
    /// rather than wording its own.
    func test_theAgentAndTheSetupRow_areToldTheSameSentence() {
        let states: [Initialization.State] = [
            .idle,
            .inProgress(step: "Running “deps” (1 of 2)", progress: 0.5),
            .completed,
            .completedWithNote("This project has no initialization.yaml, so no setup ran."),
            .failed("Initialization failed at “deps”: exit 1"),
        ]
        for state in states {
            XCTAssertEqual(
                WorkspaceActions.initializationInfo(for: state).detail,
                initializationRow(for: state).detail,
                "\(state.key) says one thing to the user and another to an agent"
            )
        }
    }

    /// `.idle` is the case this tool ships wrong if nobody guards it.
    /// `Runner.states` is in memory, so every workstream reports it after a
    /// relaunch — including ones whose setup ran perfectly. The copy must claim
    /// neither that setup ran nor that it did not.
    func test_idleSpeaksForTheSessionOnly() {
        let info = WorkspaceActions.initializationInfo(for: .idle)
        XCTAssertEqual(info.state, "idle")
        XCTAssertEqual(info.detail, "Nothing reported this session.")
        XCTAssertNil(info.progress)
    }

    /// The tool's own description has to carry that warning, because `detail`
    /// alone does not: "Nothing reported this session." is true and still
    /// invites "so nothing needed doing".
    func test_theToolWarnsThatIdleIsNotEvidence() {
        let description = IPC.Tool.getInitializationState.spec.description
        XCTAssertTrue(
            description.contains("restarts"),
            "the description must say why every workstream reports idle after a relaunch"
        )
        XCTAssertTrue(
            description.contains("NOT evidence that setup never ran"),
            "an agent reading idle as 'setup never ran' is the failure this tool ships with otherwise"
        )
    }

    /// Progress rides along only while a step is running. A finished run
    /// reporting 1.0 would read as one still going.
    func test_progressIsCarriedOnlyWhileAStepRuns() {
        XCTAssertEqual(
            WorkspaceActions.initializationInfo(for: .inProgress(step: "Running “deps” (1 of 2)", progress: 0.5)).progress,
            0.5
        )
        for state: Initialization.State in [.idle, .completed, .completedWithNote("x"), .failed("y")] {
            XCTAssertNil(WorkspaceActions.initializationInfo(for: state).progress, "\(state.key) carries a progress")
        }
    }

    // MARK: - Shortcut story: the four ways to have none

    private func story(description: String? = nil) -> Shortcut.Story {
        Shortcut.Story(
            id: 17411,
            name: "Read the Info tab over IPC",
            description: description,
            appURL: "https://app.shortcut.com/x/story/17411",
            branchName: "tad/sc-17411/read-info-tab",
            workflowStateID: 500,
            storyType: "feature"
        )
    }

    /// Not every workstream comes from a story, and that is not a problem to
    /// report as one.
    func test_noStoryLinked_saysSoWithoutBlamingTheToken() {
        let info = WorkspaceActions.shortcutStoryInfo(storyID: nil, token: .absent, story: nil, stateName: nil)
        XCTAssertNil(info.story)
        let reason = try? XCTUnwrap(info.unavailableReason)
        XCTAssertTrue(reason?.contains("not created from a Shortcut story") == true)
        XCTAssertFalse(reason?.contains("token") == true, "a workstream with no story is not a token problem")
    }

    /// A story id with no token is a configuration problem, and the answer names
    /// the story so the user can see the two facts are unrelated.
    func test_aStoryWithNoToken_namesTheStoryAndWhereToFixIt() {
        let info = WorkspaceActions.shortcutStoryInfo(storyID: 17411, token: .absent, story: nil, stateName: nil)
        XCTAssertNil(info.story)
        let reason = try? XCTUnwrap(info.unavailableReason)
        XCTAssertTrue(reason?.contains("sc-17411") == true)
        XCTAssertTrue(reason?.contains("Settings") == true)
    }

    /// `KeychainTokenStore.ReadOutcome` exists because "no token" and "the
    /// keychain would not hand it over" are different problems — the second
    /// sends a user to re-paste a token they already have. That distinction must
    /// survive the trip to an agent rather than being flattened back here.
    func test_aKeychainRefusal_isNotReportedAsAMissingToken() {
        let info = WorkspaceActions.shortcutStoryInfo(
            storyID: 17411, token: .failed(-25300), story: nil, stateName: nil
        )
        XCTAssertNil(info.story)
        let reason = try? XCTUnwrap(info.unavailableReason)
        XCTAssertTrue(reason?.contains("-25300") == true, "the status is the only handle on a keychain problem")
        XCTAssertTrue(reason?.contains("not the same as having no token") == true)
    }

    /// `refreshShortcutStory` logs its error and swallows it, so an empty cache
    /// after a fetch is the only evidence the fetch failed. It must not read as
    /// "this workstream has no story".
    func test_aFailedFetch_isNotReportedAsNoStory() {
        let info = WorkspaceActions.shortcutStoryInfo(storyID: 17411, token: .token("t"), story: nil, stateName: nil)
        XCTAssertNil(info.story)
        let reason = try? XCTUnwrap(info.unavailableReason)
        XCTAssertTrue(reason?.contains("failed") == true)
        XCTAssertTrue(reason?.contains("sc-17411") == true)
    }

    /// Non-nil `unavailableReason` exactly when `story` is nil, so the two can
    /// never describe different states — the pairing `VerificationChecksInfo`
    /// uses.
    func test_aStoryAndAReason_areNeverBothPresentOrBothAbsent() {
        let cases: [(Int?, KeychainTokenStore.ReadOutcome, Shortcut.Story?)] = [
            (nil, .absent, nil),
            (17411, .absent, nil),
            (17411, .failed(-25300), nil),
            (17411, .token("t"), nil),
            (17411, .token("t"), story()),
        ]
        for (id, token, found) in cases {
            let info = WorkspaceActions.shortcutStoryInfo(
                storyID: id, token: token, story: found, stateName: "In Progress"
            )
            XCTAssertEqual(
                info.story == nil, info.unavailableReason != nil,
                "a story and a reason disagree for storyID=\(String(describing: id))"
            )
        }
    }

    // MARK: - Shortcut story: the story itself

    func test_aFetchedStory_carriesTheFourFieldsItWasAskedFor() {
        let info = WorkspaceActions.shortcutStoryInfo(
            storyID: 17411, token: .token("t"), story: story(), stateName: "In Progress"
        )
        let detail = try? XCTUnwrap(info.story)
        XCTAssertEqual(detail?.id, 17411)
        XCTAssertEqual(detail?.name, "Read the Info tab over IPC")
        XCTAssertEqual(detail?.storyType, "feature")
        XCTAssertEqual(detail?.state, "In Progress")
        XCTAssertNil(detail?.stateUnavailableReason)
        XCTAssertNil(info.unavailableReason)
    }

    /// The workflow list is a second round trip and fails on its own. The state
    /// is one of the things this tool exists to answer, so an absent one needs a
    /// reason — without it, a story with an unfetched workflow list reads as a
    /// story that has no state.
    func test_anUnfetchedWorkflowList_explainsTheMissingStateRatherThanOmittingIt() {
        let info = WorkspaceActions.shortcutStoryInfo(
            storyID: 17411, token: .token("t"), story: story(), stateName: nil, hasWorkflows: false
        )
        let detail = try? XCTUnwrap(info.story)
        XCTAssertNil(detail?.state)
        XCTAssertTrue(detail?.stateUnavailableReason?.contains("could not be fetched") == true)
        XCTAssertNil(info.unavailableReason, "the story itself is fine; only its state name is missing")
    }

    /// `shortcutStateName` returns nil for two reasons and they are different
    /// facts: Shortcut was unreachable, or the list we have does not contain
    /// this story's state id. Naming the wrong one is the mistake
    /// `KeychainTokenStore.ReadOutcome` exists to prevent one layer down.
    func test_aStateIDMissingFromAFetchedList_isNotBlamedOnTheNetwork() {
        let reason = WorkspaceActions.stateUnavailableReason(
            stateName: nil, hasWorkflows: true, workflowStateID: 500
        )
        XCTAssertTrue(reason?.contains("does not contain") == true)
        XCTAssertTrue(reason?.contains("500") == true, "the state id is the only handle on this one")
        XCTAssertFalse(reason?.contains("could not be fetched") == true, "the list was fetched; it lacks this id")
    }

    func test_aResolvedState_needsNoReason() {
        XCTAssertNil(WorkspaceActions.stateUnavailableReason(
            stateName: "In Progress", hasWorkflows: true, workflowStateID: 500
        ))
    }

    // MARK: - A cached story is not a current one

    /// `refreshShortcutStory` keeps a cached story when the fetch fails, and
    /// `registerShortcutStory` caches one at creation — so a revoked token or a
    /// deleted story would otherwise hand an agent an old copy as a current
    /// answer, with the tool's own description promising it is current.
    func test_aCachedStoryThatCouldNotBeRefreshed_isMarkedStale() {
        let info = WorkspaceActions.shortcutStoryInfo(
            storyID: 17411, token: .token("t"), story: story(), stateName: "In Progress", didFetch: false
        )
        let detail = try? XCTUnwrap(info.story)
        XCTAssertEqual(detail?.isStale, true)
        XCTAssertNil(info.unavailableReason, "there is a story to hand back; what is wrong is its currency")
    }

    func test_aFreshlyFetchedStory_isNotStale() {
        let info = WorkspaceActions.shortcutStoryInfo(
            storyID: 17411, token: .token("t"), story: story(), stateName: "In Progress", didFetch: true
        )
        XCTAssertEqual(info.story?.isStale, false)
    }

    // MARK: - Description budget

    func test_anOrdinaryDescription_isNotTrimmed() {
        let (text, trimmed) = IPC.ShortcutStoryDetail.trimmedDescription("A short brief.")
        XCTAssertEqual(text, "A short brief.")
        XCTAssertFalse(trimmed)
    }

    func test_aMissingDescription_isNotReportedAsTrimmed() {
        let (text, trimmed) = IPC.ShortcutStoryDetail.trimmedDescription(nil)
        XCTAssertNil(text)
        XCTAssertFalse(trimmed)
    }

    /// A story body is the only unbounded field here, and it rides along on a
    /// call made for four short ones. The cut is reported, the way
    /// `ExecutionLogs` reports a trimmed tail.
    func test_aLongDescription_isCutAndSaysSo() {
        let long = String(repeating: "x", count: 20_000)
        let (text, trimmed) = IPC.ShortcutStoryDetail.trimmedDescription(long)
        XCTAssertTrue(trimmed)
        XCTAssertEqual(text?.utf8.count, IPC.ShortcutStoryDetail.descriptionBudgetBytes)
    }

    /// The beginning is kept, not the end: a story's first paragraph is the one
    /// that says what the work is. The opposite of a log tail, deliberately.
    func test_aLongDescription_keepsItsBeginning() {
        let long = "THE BRIEF STARTS HERE. " + String(repeating: "y", count: 20_000)
        let (text, _) = IPC.ShortcutStoryDetail.trimmedDescription(long)
        XCTAssertTrue(text?.hasPrefix("THE BRIEF STARTS HERE.") == true)
    }

    /// Cutting on a byte budget with multi-byte characters must not split one.
    func test_aCutNeverSplitsACharacter() {
        let emoji = String(repeating: "🚀", count: 5000)
        let (text, trimmed) = IPC.ShortcutStoryDetail.trimmedDescription(emoji, budgetBytes: 10)
        XCTAssertTrue(trimmed)
        // Two rockets is 8 bytes; a third would be 12.
        XCTAssertEqual(text, "🚀🚀")
    }

    // MARK: - Tool tables

    /// Both are reads of the caller's own workstream, which is exactly what
    /// `.workspaceRead` means — no new surface, and no gate.
    func test_bothToolsAreWorkspaceReads() {
        XCTAssertEqual(IPC.Tool.getInitializationState.surface, .workspaceRead)
        XCTAssertEqual(IPC.Tool.getShortcutStory.surface, .workspaceRead)
    }

    /// Reads change nothing by running twice, so a helper that lost its
    /// connection may re-send them.
    func test_bothToolsAreReplayable() {
        XCTAssertTrue(IPC.Tool.getInitializationState.isSafeToReplay)
        XCTAssertTrue(IPC.Tool.getShortcutStory.isSafeToReplay)
    }

    /// An actor read gets the 15s tier; a network round trip does not. The
    /// Shortcut fetch is two requests — the story and, once per launch, the
    /// workflow list.
    func test_theShortcutFetchWaitsLongerThanAnActorHop() {
        XCTAssertEqual(IPC.Tool.getInitializationState.replyDeadline, IPC.ToolSpec.Deadline.immediate)
        XCTAssertEqual(IPC.Tool.getShortcutStory.replyDeadline, IPC.ToolSpec.Deadline.mainActorWork)
    }

    /// `advertisedOrder` is order-only and not compiler-enforced, so a tool left
    /// out of it is one no agent can see. `IPCToolRegistryTests` pins membership
    /// for every case; this pins that these two are reachable at all.
    func test_bothToolsAreAdvertised() {
        let advertised = IPC.ToolSpec.advertised.map(\.tool)
        XCTAssertTrue(advertised.contains(.getInitializationState))
        XCTAssertTrue(advertised.contains(.getShortcutStory))
    }
}
