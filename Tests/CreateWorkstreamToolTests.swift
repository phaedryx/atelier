// ABOUTME: Tests the create_workstream and create_shortcut_workstream handlers' refusals, and the ordering that keeps them honest.
// ABOUTME: Also pins the tmux wrapping the seeded Coding Agent shares with the Coding Agent tab.

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

    /// `claude` is installed and there is still nowhere to run it: the agent now
    /// goes on a terminal surface this handler creates itself, so the surface
    /// handle is a precondition exactly like the binary is.
    ///
    /// `TerminalApp.shared.app` is nil under XCTest, which is what makes this
    /// reachable — the real case is an agent calling the tool before
    /// `ContentView` has run its `.onAppear`. Ordering matters as much as the
    /// refusal: reporting "an agent started" with no surface running it would be
    /// a lie the caller then waits on.
    func test_aPromptWithNoTerminal_isRefusedBeforeAnythingIsCreated() async {
        install([Project(name: "app", directory: "/repos/app")])
        let environment = AppEnvironment()
        environment.toolStatus.claude = .found("/usr/local/bin/claude")
        WorkspaceActions.shared.appEnvironment = environment
        defer { WorkspaceActions.shared.appEnvironment = nil }
        let silence = SilenceCheck()

        let response = await create(["prompt": "write the tests"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(
            response.error?.contains("terminal is not ready") ?? false,
            "expected the no-surface refusal, got: \(response.error ?? "nil")"
        )
        XCTAssertTrue(
            silence.posted.isEmpty,
            "the worktree must not exist when the caller is told the agent could not start"
        )
    }

    // MARK: - create_shortcut_workstream

    private nonisolated static func story(
        id: Int = 17411,
        branchName: String = "tadthorley/sc-17411/org-import-run-card"
    ) -> Shortcut.Story {
        let json = """
        {
          "id": \(id),
          "name": "Org Import run card",
          "description": null,
          "story_type": "bug",
          "app_url": "https://app.shortcut.com/sixfifty/story/\(id)",
          "formatted_vcs_branch_name": "\(branchName)",
          "workflow_state_id": 500000030
        }
        """
        return try! JSONDecoder().decode(Shortcut.Story.self, from: Data(json.utf8))
    }

    private func createFromShortcut(
        _ arguments: [String: String],
        as client: IPC.ClientIdentity
    ) async -> IPC.Response {
        await service.handle(
            IPC.Request(token: "unused", tool: .createShortcutWorkstream, arguments: arguments, client: client)
        )
    }

    /// The Branch Name Pattern is a real user default, and this host shares the
    /// app's defaults domain — so a test that asserts on a rendered name has to
    /// say which pattern rendered it rather than inherit whatever is stored.
    private func pinBranchTemplate(_ template: String) {
        let key = Shortcut.Settings.branchTemplateKey
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(template, forKey: key)
        addTeardownBlock {
            UserDefaults.standard.set(previous, forKey: key)
        }
    }

    /// Records the ids the handler asked for, so ordering assertions can say
    /// *when* the network was reached rather than only what came back.
    private final class FetchCount: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []

        var ids: [Int] {
            lock.withLock { seen }
        }

        var count: Int {
            ids.count
        }

        func answering(_ story: Shortcut.Story) -> @Sendable (Int) async throws -> Shortcut.Story {
            { id in
                self.lock.withLock { self.seen.append(id) }
                return story
            }
        }
    }

    /// A story the parser will not take. `Shortcut.StoryID.parse` is deliberately
    /// strict — an ordinary branch name has to come back nil rather than be
    /// coerced into an id — so this must refuse rather than create a workstream
    /// under a nonsense story.
    func test_anUnparseableStory_isRefusedAndCreatesNothing() async {
        install([Project(name: "app", directory: "/repos/app")])
        let fetches = FetchCount()
        await service.setStoryFetch(fetches.answering(Self.story()))
        let silence = SilenceCheck()

        let response = await createFromShortcut(["story": "release-2"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("story") ?? false, "the refusal must name the argument: \(response.error ?? "nil")")
        XCTAssertEqual(fetches.count, 0, "an unparseable id must be caught before the network")
        XCTAssertTrue(silence.posted.isEmpty)
    }

    /// The three spellings the sheet accepts, because an agent has whichever one
    /// its own Shortcut tooling handed it — a bare id, `sc-`, or a pasted URL.
    func test_aStoryMayArriveBare_prefixed_orAsAURL() async {
        for spelling in ["17411", "sc-17411", "https://app.shortcut.com/sixfifty/story/17411/some-title"] {
            install([Project(name: "app", directory: "/repos/app")])
            let fetches = FetchCount()
            await service.setStoryFetch(fetches.answering(Self.story()))

            _ = await createFromShortcut(["story": spelling], as: client(project: "/repos/app"))

            XCTAssertEqual(fetches.ids, [17411], "\(spelling) should have been read as story 17411")
        }
    }

    /// The project is resolved before the story is fetched, so a caller that
    /// could never have succeeded pays no round trip and Shortcut sees no
    /// traffic for it.
    func test_anUnknownProject_isRefusedBeforeTheStoryIsFetched() async {
        install([Project(name: "app", directory: "/repos/app")])
        let fetches = FetchCount()
        await service.setStoryFetch(fetches.answering(Self.story()))
        let silence = SilenceCheck()

        let response = await createFromShortcut(["story": "17411"], as: client(project: "/repos/other"))

        XCTAssertTrue(response.error?.contains("/repos/other") ?? false, "expected the project refusal, got: \(response.error ?? "nil")")
        XCTAssertEqual(fetches.count, 0)
        XCTAssertTrue(silence.posted.isEmpty)
    }

    /// A missing or revoked token is the commonest failure here, and Shortcut's
    /// own message is the only thing that says which — so it travels rather than
    /// being flattened into "the story could not be read".
    func test_aFailedFetch_reportsShortcutsOwnMessageAndCreatesNothing() async {
        pinBranchTemplate("sc-${STORY_ID}")
        install([Project(name: "app", directory: "/repos/app")])
        await service.setStoryFetch { _ in throw Shortcut.Error.noToken }
        let silence = SilenceCheck()

        let response = await createFromShortcut(["story": "17411"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertEqual(response.error, Shortcut.Error.noToken.message)
        XCTAssertTrue(silence.posted.isEmpty)
    }

    func test_aStoryThatAlreadyHasAWorkstream_isRefusedAndCreatesNothing() async {
        pinBranchTemplate("sc-${STORY_ID}")
        install([
            Project(
                name: "app",
                directory: "/repos/app",
                workstreams: [Workstream(name: "already-on-it", shortcutStoryID: 17411)]
            ),
        ])
        await service.setStoryFetch { _ in Self.story() }
        let silence = SilenceCheck()

        let response = await createFromShortcut(["story": "17411"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(
            response.error?.contains("already-on-it") ?? false,
            "the refusal must name the workstream that already covers the story: \(response.error ?? "nil")"
        )
        XCTAssertTrue(silence.posted.isEmpty)
    }

    /// The other collision, and a different sentence: the name is held by a
    /// workstream carrying no story at all, so pointing the caller at it as
    /// "this story's workstream" would be wrong.
    func test_aRenderedNameAlreadyTaken_isRefusedAndCreatesNothing() async {
        pinBranchTemplate("sc-${STORY_ID}")
        install([
            Project(name: "app", directory: "/repos/app", workstreams: [Workstream(name: "sc-17411")]),
        ])
        await service.setStoryFetch { _ in Self.story() }
        let silence = SilenceCheck()

        let response = await createFromShortcut(["story": "17411"], as: client(project: "/repos/app"))

        XCTAssertNil(response.payload)
        XCTAssertTrue(
            response.error?.contains("sc-17411") ?? false,
            "the refusal must name the collision: \(response.error ?? "nil")"
        )
        XCTAssertTrue(silence.posted.isEmpty)
    }

    /// The agent preconditions are `create_workstream`'s, checked here too and
    /// *before* the fetch — so a caller told its agent could not start has not
    /// also spent a round trip finding that out.
    func test_aPromptWithNoClaude_isRefusedBeforeTheStoryIsFetched() async {
        install([Project(name: "app", directory: "/repos/app")])
        WorkspaceActions.shared.appEnvironment = nil
        let fetches = FetchCount()
        await service.setStoryFetch(fetches.answering(Self.story()))
        let silence = SilenceCheck()

        let response = await createFromShortcut(
            ["story": "17411", "prompt": "write the tests"],
            as: client(project: "/repos/app")
        )

        XCTAssertNil(response.payload)
        XCTAssertTrue(response.error?.contains("claude") ?? false, "expected the missing-binary refusal, got: \(response.error ?? "nil")")
        XCTAssertEqual(fetches.count, 0)
        XCTAssertTrue(silence.posted.isEmpty)
    }
}

/// The tmux wrapping both agent-start paths share.
///
/// `create_workstream` seeds the Coding Agent's surface itself, so it wraps its
/// own command rather than waiting for `TerminalContainerView` to do it. Both go
/// through `AgentCommand.tmuxWrapped` for one reason: the session name. A second
/// copy deriving it differently would put the seeded agent in a session
/// `Workstream.Archiver` does not kill, and leave a live tmux server behind
/// every workstream an agent created.
final class AgentCommandTmuxWrappingTests: XCTestCase {
    private let command = "/bin/zsh -lic 'exec sh -c claude'"

    /// Nil covers both "tmux mode is off" and "tmux is not installed", and the
    /// answer to each is the same — run the command as built.
    func test_withoutTmux_theCommandIsUnchanged() {
        XCTAssertEqual(
            Workstream.AgentCommand.tmuxWrapped(
                command,
                tmuxPath: nil,
                projectName: "app",
                workstreamName: "bold-crimson-parser",
                environmentVars: [:]
            ),
            command
        )
    }

    /// The name is the assertion. The wrapping's shape is `TmuxSession`'s
    /// business; what this pins is that an agent seeded into a new workstream
    /// lands in the session `TmuxSession.sessionName(role: "agent")` names — the
    /// one the Coding Agent tab would have used and the one archiving kills.
    func test_withTmux_theSessionIsTheWorkstreamsAgentSession() {
        let wrapped = Workstream.AgentCommand.tmuxWrapped(
            command,
            tmuxPath: "/opt/homebrew/bin/tmux",
            projectName: "app",
            workstreamName: "bold-crimson-parser",
            environmentVars: [:]
        )
        let expected = TmuxSession.sessionName(
            project: "app",
            workstream: "bold-crimson-parser",
            role: "agent"
        )

        XCTAssertNotEqual(wrapped, command, "tmux mode on must wrap the command")
        XCTAssertTrue(
            wrapped.contains(expected),
            "expected the workstream's agent session \(expected) in: \(wrapped)"
        )
    }
}
