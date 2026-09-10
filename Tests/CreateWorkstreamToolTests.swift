// ABOUTME: Tests the create_workstream handler's refusals and the ordering that keeps them honest.
// ABOUTME: Also pins that a tab spawned into a never-rendered workstream survives that workstream being opened.

@testable import Atelier
import XCTest

/// What `IPC.Service.createWorkstream` decides before anything exists on disk.
///
/// **Coverage boundary, stated rather than implied.** The success path is not
/// exercised through `handle`: it calls `Git.Operations.createWorktree` with no
/// injection point, and starting an agent needs `TerminalApp.shared.app`, which
/// is nil under XCTest. `WorkstreamLauncherTests` covers the launch mechanics
/// with git injected, and what is left here is the part with an ordering
/// guarantee — every refusal below must happen *before* a worktree exists,
/// because a caller told it failed must not be left holding a workstream.
///
/// `@MainActor` on the whole class, and no `setUp`/`tearDown` overrides: the
/// bridge these tests install is main-isolated, and an isolated override of a
/// nonisolated declaration does not compile. Every test installs its own state
/// through `install`, so none inherits the previous one's.
@MainActor
final class CreateWorkstreamToolTests: XCTestCase {
    private let service = IPC.Service()
    /// Held strongly for the test's lifetime: `Launcher.projectList` is weak,
    /// so a list nothing else retained would deallocate before the call under
    /// test and every launch would report `bridgeUnavailable`.
    private var projectList: ProjectList?

    // MARK: - Helpers

    private func client(
        project: String?,
        workstreamID: UUID? = nil
    ) -> IPC.ClientIdentity {
        IPC.ClientIdentity(
            workstreamID: workstreamID?.uuidString,
            workstreamName: "bold-crimson-parser",
            projectDirectory: project,
            surfaceID: UUID().uuidString,
            peerID: nil
        )
    }

    private func create(_ arguments: [String: String], as client: IPC.ClientIdentity) async -> IPC.Response {
        await service.handle(
            IPC.Request(token: "unused", tool: .createWorkstream, arguments: arguments, client: client)
        )
    }

    /// Installs the bridge these tests act through. Always called, so no test
    /// sees the list a previous one left on the singleton.
    private func install(_ projects: [Project]) {
        let list = ProjectList()
        list.items = projects
        projectList = list
        Workstream.Launcher.shared.projectList = list
    }

    /// The state an agent meets before `ContentView` has run its `.onAppear`.
    private func installNoBridge() {
        projectList = nil
        Workstream.Launcher.shared.projectList = nil
    }

    /// Fails if the handler posted any part of the creation sequence.
    private final class SilenceCheck: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Notification.Name] = []
        private var tokens: [NSObjectProtocol] = []

        var posted: [Notification.Name] {
            lock.withLock { seen }
        }

        init() {
            for name in [Notification.Name.workstreamCreated, .workstreamWorktreeReady, .workstreamCreationFailed] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    lock.withLock { seen.append(name) }
                })
            }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    // MARK: - Argument refusals

    /// `arguments` is `[String: String]`, so this arrives as text. Reading
    /// "True" as false would start an agent without the flag the caller asked
    /// for and report success.
    func test_unparseableBypass_isRefusedRatherThanReadAsFalse() async {
        installNoBridge()
        let silence = SilenceCheck()
        let response = await create(["bypass_permissions": "True"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        let error = response.error ?? ""
        XCTAssertTrue(error.contains("bypass_permissions"), "the refusal must name the argument: \(error)")
        XCTAssertTrue(error.contains("True"), "the refusal must echo what arrived: \(error)")
        XCTAssertTrue(silence.posted.isEmpty, "a bad argument must be caught before anything is created")
    }

    /// Checked before the project is even resolved, so a caller cannot get a
    /// worktree out of a request that was malformed.
    func test_unparseableBypass_isCheckedBeforeTheProject() async {
        install([Project(name: "app", directory: "/repos/app")])
        let response = await create(
            ["bypass_permissions": "yes"],
            as: client(project: "/repos/nowhere-at-all")
        )
        XCTAssertTrue(response.error?.contains("bypass_permissions") ?? false, "expected the argument error, got: \(response.error ?? "nil")")
    }

    // MARK: - Caller refusals

    func test_withoutAProjectList_refusesRatherThanGuessing() async {
        installNoBridge()
        let silence = SilenceCheck()
        let response = await create([:], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertNotNil(response.error)
        XCTAssertTrue(silence.posted.isEmpty)
    }

    func test_anAgentOutsideAnyProject_isRefused() async {
        install([Project(name: "app", directory: "/repos/app")])
        let silence = SilenceCheck()

        let response = await create([:], as: client(project: nil))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("workstream") ?? false, "expected the not-in-a-workstream refusal, got: \(response.error ?? "nil")")
        XCTAssertTrue(silence.posted.isEmpty)
    }

    func test_anUnknownProject_isRefusedAndCreatesNothing() async {
        install([Project(name: "app", directory: "/repos/app")])
        let silence = SilenceCheck()

        let response = await create([:], as: client(project: "/repos/other"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("/repos/other") ?? false, "the refusal must name the directory: \(response.error ?? "nil")")
        XCTAssertTrue(silence.posted.isEmpty)
    }

    /// A name git will not take has to fail before the optimistic row is posted,
    /// not inside `git worktree add` after it.
    func test_anUnusableBranchName_isRefusedAndCreatesNothing() async {
        install([Project(name: "app", directory: "/repos/app")])
        let silence = SilenceCheck()

        let response = await create(["name": "has space"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(silence.posted.isEmpty, "an unusable name must be caught before the worktree is attempted")
    }

    func test_aNameAlreadyTaken_isRefusedAndCreatesNothing() async {
        install([
            Project(name: "app", directory: "/repos/app", workstreams: [Workstream(name: "feat-ipc")]),
        ])
        let silence = SilenceCheck()

        let response = await create(["name": "feat-ipc"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("feat-ipc") ?? false, "the refusal must name the collision: \(response.error ?? "nil")")
        XCTAssertTrue(silence.posted.isEmpty)
    }

    /// The caller's own workstream is the exact key; the directory it reports is
    /// the fallback. Here they disagree, and the workstream must win — so the
    /// collision is detected in `app`, the project the caller actually belongs
    /// to, rather than missed in `other`.
    func test_theCallersWorkstreamWinsOverTheDirectoryItReports() async {
        let mine = Workstream(name: "feat-ipc")
        install([
            Project(name: "other", directory: "/repos/other"),
            Project(name: "app", directory: "/repos/app", workstreams: [mine]),
        ])

        let response = await create(
            ["name": "feat-ipc"],
            as: client(project: "/repos/other", workstreamID: mine.id)
        )

        XCTAssertNil(response.payload)
        XCTAssertTrue(
            response.error?.contains("already exists") ?? false,
            "resolving by workstream id should have found the collision in `app`, got: \(response.error ?? "nil")"
        )
    }

    /// An agent was asked for and there is no `claude` to be one. Refusing here
    /// — before `launch` — is what makes the refusal text true: nothing was
    /// created, so "omit `prompt`" is advice the caller can still take.
    func test_aPromptWithNoClaude_isRefusedBeforeAnythingIsCreated() async {
        install([Project(name: "app", directory: "/repos/app")])
        WorkspaceActions.shared.appEnvironment = nil
        let silence = SilenceCheck()

        let response = await create(["prompt": "write the tests"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("claude") ?? false, "expected the missing-binary refusal, got: \(response.error ?? "nil")")
        XCTAssertTrue(
            silence.posted.isEmpty,
            "the worktree must not exist when the caller is told the agent could not start"
        )
    }
}

/// The ordering `open_agent_tab` never sees: a tab spawned into a workstream
/// that has not been rendered yet, and then that workstream being opened.
///
/// `create_workstream` is the only caller that does this. The tab lives in a
/// `WorkspaceModel` the *tool* created, and the view's first render asks for a
/// model of its own — if that render reseeded or reconciled the model away, the
/// agent would be running with no tab pointing at it.
@MainActor
final class SpawnedTabSurvivesFirstRenderTests: XCTestCase {
    func test_aTabAddedBeforeTheFirstRender_survivesTheWorkstreamBeingOpened() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()

        // What the tool does: build the model and add the tab, with the
        // workstream never having been on screen.
        let toolModel = cache.workspaceModel(for: workstreamID, seed: startupWorkspaceTabState(savedTab: nil))
        let surfaceID = toolModel.addTerminal()
        XCTAssertTrue(toolModel.tabs.contains(.terminal(surfaceID)))

        // What the view does on its first render of this workstream
        // (`ContentView.detailView`): ask the cache for a model, seeded from
        // saved state. The cache must hand back the one that already exists.
        let viewModel = cache.workspaceModel(
            for: workstreamID,
            seed: startupWorkspaceTabState(savedTab: WorkspaceStateStore.load(for: workstreamID))
        )
        XCTAssertTrue(viewModel === toolModel, "the view must not reseed a model the tool already built")
        XCTAssertTrue(viewModel.tabs.contains(.terminal(surfaceID)), "the spawned tab must survive the first render")
    }

    /// The other half: `reconcile` drops terminal tabs whose surface is gone.
    /// A tab whose surface the tool created eagerly is not gone, so it stays —
    /// but a tab recorded without one would be swept, which is why the tool
    /// creates the surface rather than only the tab.
    func test_reconcileKeepsATabWhoseSurfaceWasCreatedEagerly() {
        let cache = TerminalSurfaceCache()
        let workstreamID = UUID()
        let model = cache.workspaceModel(for: workstreamID, seed: startupWorkspaceTabState(savedTab: nil))
        let withSurface = model.addTerminal()
        let withoutSurface = model.addTerminal()

        model.reconcile(liveSurfaceIDs: [withSurface])

        XCTAssertTrue(model.tabs.contains(.terminal(withSurface)))
        XCTAssertFalse(
            model.tabs.contains(.terminal(withoutSurface)),
            "a tab with no live surface is exactly what reconcile exists to drop"
        )
    }
}
