// ABOUTME: Tests the non-UI workstream-creation seam: project resolution, naming, and the notification sequence.
// ABOUTME: The git call is injected, so these run without a repository.

@testable import Atelier
import XCTest

final class WorkstreamLauncherTests: XCTestCase {
    private func project(
        name: String = "app",
        directory: String,
        checkoutDirectory: String? = nil,
        workstreams: [Workstream] = []
    ) -> Project {
        Project(
            name: name,
            directory: directory,
            checkoutDirectory: checkoutDirectory,
            workstreams: workstreams
        )
    }

    // MARK: - Resolving the project

    func testResolvesProjectByItsDirectory() {
        let projects = [project(directory: "/repos/app")]
        let target = Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app", in: projects)
        XCTAssertEqual(target?.projectID, projects[0].id)
    }

    /// `ATELIER_PROJECT_DIR` is `Project.directory` at every call site, so the
    /// checkout is not an accepted spelling of the project. Accepting it would
    /// not be leniency: in the container layout `checkout` is a worktree path,
    /// and one project's checkout can be another project's directory.
    func testCheckoutIsNotAnAcceptedSpellingOfTheProject() {
        let projects = [project(directory: "/repos/app", checkoutDirectory: "/repos/app/main")]
        XCTAssertNil(Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app/main", in: projects))
    }

    /// The ambiguity that rules out matching on `checkout`: `other` is a
    /// separate project whose directory is the first project's checkout. With
    /// both keys accepted, `first` would answer `app` here — creating a worktree
    /// in a repository the agent never named.
    func testOneProjectsCheckoutBeingAnothersDirectoryResolvesToTheRightProject() {
        let projects = [
            project(name: "app", directory: "/repos/app", checkoutDirectory: "/repos/app/main"),
            project(name: "other", directory: "/repos/app/main"),
        ]
        XCTAssertEqual(
            Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app/main", in: projects)?.projectName,
            "other"
        )
    }

    /// The trap this type exists to avoid: `checkout` goes to `createWorktree`
    /// and `directory` goes to bootstrap. A single "project path" field would
    /// make one of those wrong, silently, only in the container layout.
    func testTargetKeepsCheckoutAndDirectoryApart() {
        let projects = [project(directory: "/repos/app", checkoutDirectory: "/repos/app/main")]
        let target = Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app", in: projects)
        XCTAssertEqual(target?.directory, "/repos/app")
        XCTAssertEqual(target?.checkout, "/repos/app/main")
    }

    func testTrailingSlashDoesNotDecideWhetherAnAgentCanCreate() {
        let projects = [project(directory: "/repos/app")]
        XCTAssertNotNil(Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app/", in: projects))
        XCTAssertNotNil(Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app/./", in: projects))
    }

    func testUnknownDirectoryResolvesToNothing() {
        let projects = [project(directory: "/repos/app")]
        XCTAssertNil(Workstream.Launcher.resolveTarget(projectDirectory: "/repos/other", in: projects))
    }

    /// An empty `ATELIER_PROJECT_DIR` must not match the first project in the
    /// list — an agent launched outside Atelier has no project, and creating a
    /// workstream in whichever project happens to be first is worse than failing.
    func testEmptyDirectoryResolvesToNothing() {
        let projects = [project(directory: "/repos/app")]
        XCTAssertNil(Workstream.Launcher.resolveTarget(projectDirectory: "", in: projects))
        XCTAssertNil(Workstream.Launcher.resolveTarget(projectDirectory: "   ", in: projects))
    }

    func testTargetCarriesExistingWorkstreamNames() {
        let projects = [project(
            directory: "/repos/app",
            workstreams: [Workstream(name: "fix-a"), Workstream(name: "feat-b")]
        )]
        let target = Workstream.Launcher.resolveTarget(projectDirectory: "/repos/app", in: projects)
        XCTAssertEqual(target?.existingWorkstreamNames, ["fix-a", "feat-b"])
    }

    // MARK: - Resolving the name

    func testRequestedNameIsUsedWhenFree() {
        let resolved = Workstream.Launcher.resolveName(requested: "feat-ipc", existing: ["fix-a"])
        XCTAssertEqual(try? resolved.get(), "feat-ipc")
    }

    func testRequestedNameIsTrimmed() {
        let resolved = Workstream.Launcher.resolveName(requested: "  feat-ipc \n", existing: [])
        XCTAssertEqual(try? resolved.get(), "feat-ipc")
    }

    /// `createWorktree` uses this string as the branch name verbatim, so a name
    /// git will not take has to fail before the optimistic row is posted.
    func testUnusableBranchNameFails() {
        for name in ["has space", "-leading", "trailing.", "a..b", "a//b", "star*"] {
            let resolved = Workstream.Launcher.resolveName(requested: name, existing: [])
            guard case let .failure(failure) = resolved else {
                XCTFail("expected \(name) to be rejected as a branch name")
                continue
            }
            XCTAssertEqual(failure, .invalidName(name))
        }
    }

    /// The same rule as the `+` dialog, not a stricter one: a slash is a legal
    /// branch name and `worktreeDestination` sanitizes it out of the path.
    func testSlashedNameIsAcceptedJustAsTheDialogAcceptsIt() {
        XCTAssertEqual(try? Workstream.Launcher.resolveName(requested: "feat/ipc", existing: []).get(), "feat/ipc")
    }

    /// Validity is checked before the collision, so the more fundamental
    /// problem is the one reported.
    func testInvalidNameIsReportedEvenWhenItAlsoCollides() {
        let resolved = Workstream.Launcher.resolveName(requested: "has space", existing: ["has space"])
        guard case let .failure(failure) = resolved else {
            return XCTFail("an unusable branch name must fail")
        }
        XCTAssertEqual(failure, .invalidName("has space"))
    }

    func testDuplicateNameFailsRatherThanGeneratingASubstitute() {
        let resolved = Workstream.Launcher.resolveName(requested: "fix-a", existing: ["fix-a"])
        guard case let .failure(failure) = resolved else {
            return XCTFail("a name already in use must fail, not silently become another name")
        }
        XCTAssertEqual(failure, .nameInUse("fix-a"))
    }

    func testOmittedNameIsGeneratedAndAvoidsExistingNames() {
        let existing: Set = ["fix-a", "feat-b"]
        let resolved = try? Workstream.Launcher.resolveName(requested: nil, existing: existing).get()
        XCTAssertNotNil(resolved)
        XCTAssertFalse(existing.contains(resolved ?? "fix-a"))
    }

    func testBlankNameIsTreatedAsOmitted() {
        let resolved = try? Workstream.Launcher.resolveName(requested: "   ", existing: []).get()
        XCTAssertNotNil(resolved)
        XCTAssertFalse(resolved?.isEmpty ?? true)
    }

    // MARK: - The notification sequence

    /// Collects the seam's notifications in the order they are posted.
    ///
    /// `queue: nil` on purpose: the block then runs synchronously on the posting
    /// thread, so an assertion right after `launch` returns sees every event. An
    /// operation queue would defer them to a later runloop pass and the order
    /// these tests are about would be untestable.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(name: Notification.Name, userInfo: [AnyHashable: Any])] = []
        private var tokens: [NSObjectProtocol] = []

        var events: [(name: Notification.Name, userInfo: [AnyHashable: Any])] {
            lock.withLock { recorded }
        }

        init() {
            for name in [Notification.Name.workstreamCreated, .workstreamWorktreeReady, .workstreamCreationFailed] {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [weak self] note in
                    guard let self else { return }
                    lock.withLock { recorded.append((name, note.userInfo ?? [:])) }
                })
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }

    /// A value the injected `createWorktree` can write to from whichever thread
    /// it lands on.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Held for the test's lifetime on purpose: `Launcher.projectList` is
    /// `weak`, exactly as `AgentNudge.surfaceCache` is, so a list only the
    /// factory held would deallocate and every launch would report
    /// `bridgeUnavailable`.
    private var retainedProjectList: ProjectList?

    /// Resolves the target the way the handler does, so the launch tests
    /// exercise the same two steps production takes.
    @MainActor
    private func target(
        _ launcher: Workstream.Launcher,
        projectDirectory: String
    ) throws -> Workstream.Launcher.Target {
        try launcher.target(callerWorkstreamID: nil, projectDirectory: projectDirectory)
    }

    @MainActor
    private func makeLauncher(_ projects: [Project]) -> Workstream.Launcher {
        let list = ProjectList()
        list.items = projects
        retainedProjectList = list
        let launcher = Workstream.Launcher()
        launcher.projectList = list
        return launcher
    }

    @MainActor
    func testSuccessfulLaunchPostsCreatedThenReady() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        let launched = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, name in "/repos/app/\(name)" }
        )

        XCTAssertEqual(launched.name, "feat-ipc")
        XCTAssertEqual(launched.worktreePath, "/repos/app/feat-ipc")
        XCTAssertEqual(recorder.events.map(\.name), [.workstreamCreated, .workstreamWorktreeReady])
        XCTAssertEqual(recorder.events[1].userInfo["worktreePath"] as? String, "/repos/app/feat-ipc")
        XCTAssertEqual(recorder.events[1].userInfo["workstreamID"] as? UUID, launched.workstreamID)
    }

    /// The ordering `create_workstream` depends on, and the reason `beforeReady`
    /// exists at all.
    ///
    /// `.workstreamWorktreeReady` is what makes a workstream renderable, and the
    /// first render creates the Coding Agent's surface with the command the view
    /// builds. An agent seeded into that surface has to be there first, or a user
    /// clicking the sidebar row — which has been sitting there since
    /// `.workstreamCreated`, seconds earlier — takes the surface and the prompt
    /// is lost in silence. Recording the notifications the hook has seen *at the
    /// moment it runs* is what pins the order; asserting afterwards would pass
    /// either way.
    @MainActor
    func testBeforeReadyRunsWhileTheWorkstreamIsStillUnrenderable() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()
        let seen = Box<[Notification.Name]?>(nil)
        let launchedAtHook = Box<Workstream.Launcher.Launched?>(nil)

        let launched = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, name in "/repos/app/\(name)" },
            beforeReady: { launched in
                seen.value = recorder.events.map(\.name)
                launchedAtHook.value = launched
            }
        )

        XCTAssertEqual(
            seen.value,
            [.workstreamCreated],
            "beforeReady must run before .workstreamWorktreeReady, or the agent races the first render"
        )
        XCTAssertEqual(recorder.events.map(\.name), [.workstreamCreated, .workstreamWorktreeReady])
        XCTAssertEqual(
            launchedAtHook.value,
            launched,
            "the hook must be handed the same workstream the caller gets back"
        )
    }

    /// A worktree that could not be created has nothing to seed an agent into,
    /// and the caller is about to be thrown at — running the hook would give it a
    /// path that does not exist.
    @MainActor
    func testBeforeReadyDoesNotRunWhenTheWorktreeFails() async {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let ran = Box(false)

        do {
            _ = try await launcher.launch(
                in: target(launcher, projectDirectory: "/repos/app"),
                requestedName: "feat-ipc",
                createWorktree: { _, _, _ in nil },
                beforeReady: { _ in ran.value = true }
            )
            XCTFail("expected the launch to throw")
        } catch {
            XCTAssertFalse(ran.value, "there is no worktree to start an agent in")
        }
    }

    /// `createWorktree` takes the work tree, not the repository's home. In the
    /// container layout those differ, and handing it `directory` would run
    /// `git worktree add` in a directory with no work tree.
    @MainActor
    func testLaunchPassesCheckoutToGitNotDirectory() async throws {
        let launcher = makeLauncher([
            project(directory: "/repos/app", checkoutDirectory: "/repos/app/main"),
        ])
        let seenPath = Box<String?>(nil)

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { checkout, _, name in
                seenPath.value = checkout
                return "/repos/app/\(name)"
            }
        )

        XCTAssertEqual(seenPath.value, "/repos/app/main")
    }

    /// An agent creating a workstream must not move the user's selection, and
    /// the UI producers that should must keep working — so the flag is opt-out
    /// with a default of true, and the launcher passes false.
    @MainActor
    func testLaunchAsksNotToStealTheSelection() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, name in "/repos/app/\(name)" }
        )

        XCTAssertEqual(recorder.events[0].userInfo["select"] as? Bool, false)
    }

    @MainActor
    func testFailedWorktreePostsCreationFailedAndThrows() async {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        do {
            _ = try await launcher.launch(
                in: target(launcher, projectDirectory: "/repos/app"),
                requestedName: "feat-ipc",
                createWorktree: { _, _, _ in nil }
            )
            XCTFail("a failed worktree must throw rather than report a workstream that does not exist")
        } catch {
            XCTAssertEqual(error as? Workstream.Launcher.Failure, .worktreeCreationFailed("feat-ipc"))
        }

        XCTAssertEqual(recorder.events.map(\.name), [.workstreamCreated, .workstreamCreationFailed])
    }

    /// The rollback has to name the project as well as the workstream:
    /// ContentView's handler finds the row by project index first.
    @MainActor
    func testRollbackCarriesTheProjectID() async {
        let projects = [project(directory: "/repos/app")]
        let launcher = makeLauncher(projects)
        let recorder = Recorder()

        _ = try? await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, _ in nil }
        )

        XCTAssertEqual(recorder.events.last?.userInfo["projectID"] as? UUID, projects[0].id)
    }

    /// Nothing is posted when the request cannot be honoured, so a caller
    /// naming an unknown project never leaves a row behind.
    @MainActor
    func testUnknownProjectPostsNothing() throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        XCTAssertThrowsError(try target(launcher, projectDirectory: "/repos/other")) { error in
            XCTAssertEqual(error as? Workstream.Launcher.Failure, .projectNotFound("/repos/other"))
        }

        XCTAssertTrue(recorder.events.isEmpty)
    }

    @MainActor
    func testDuplicateNamePostsNothing() async {
        let launcher = makeLauncher([
            project(directory: "/repos/app", workstreams: [Workstream(name: "feat-ipc")]),
        ])
        let recorder = Recorder()

        _ = try? await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, name in "/repos/app/\(name)" }
        )

        XCTAssertTrue(recorder.events.isEmpty)
    }

    /// Without a project list there is nothing to resolve against. Failing is
    /// the only honest answer; guessing a project would create a worktree in a
    /// repository the agent never named.
    @MainActor
    func testMissingBridgeFails() {
        let launcher = Workstream.Launcher()

        XCTAssertThrowsError(try target(launcher, projectDirectory: "/repos/app")) { error in
            XCTAssertEqual(error as? Workstream.Launcher.Failure, .bridgeUnavailable)
        }
    }

    // MARK: - Resolving the caller

    /// Preferred over the directory because it is exact — no symlink, no
    /// trailing slash, no two-projects-one-path ambiguity.
    @MainActor
    func testCallerWorkstreamIDResolvesItsOwnProject() throws {
        let mine = Workstream(name: "fix-a")
        let launcher = makeLauncher([
            project(name: "other", directory: "/repos/other"),
            project(name: "app", directory: "/repos/app", workstreams: [mine]),
        ])
        let resolved = try launcher.target(callerWorkstreamID: mine.id, projectDirectory: "/repos/other")
        XCTAssertEqual(resolved.projectName, "app", "the caller's own workstream must win over its reported directory")
    }

    /// An agent Atelier launched outside a workstream has no id to offer, so
    /// the directory is the fallback rather than the primary key.
    @MainActor
    func testDirectoryIsTheFallbackWhenThereIsNoCallerWorkstream() throws {
        let launcher = makeLauncher([project(name: "app", directory: "/repos/app")])
        XCTAssertEqual(
            try launcher.target(callerWorkstreamID: nil, projectDirectory: "/repos/app").projectName,
            "app"
        )
    }

    /// A workstream id Atelier no longer knows falls through to the directory
    /// rather than failing outright — the workstream may have been archived
    /// while its agent kept running.
    @MainActor
    func testStaleCallerWorkstreamFallsBackToTheDirectory() throws {
        let launcher = makeLauncher([project(name: "app", directory: "/repos/app")])
        XCTAssertEqual(
            try launcher.target(callerWorkstreamID: UUID(), projectDirectory: "/repos/app").projectName,
            "app"
        )
    }

    @MainActor
    func testNoWorkstreamAndNoDirectoryIsRefused() {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        XCTAssertThrowsError(try launcher.target(callerWorkstreamID: nil, projectDirectory: nil)) { error in
            XCTAssertEqual(error as? Workstream.Launcher.Failure, .notInAProject)
        }
        XCTAssertThrowsError(try launcher.target(callerWorkstreamID: nil, projectDirectory: "  ")) { error in
            XCTAssertEqual(error as? Workstream.Launcher.Failure, .notInAProject)
        }
    }

    // MARK: - Reading an agent-supplied bool

    func testAbsentBoolIsFalse() {
        XCTAssertEqual(try? Workstream.Launcher.parseBool(nil, name: "bypass_permissions").get(), false)
        XCTAssertEqual(try? Workstream.Launcher.parseBool("", name: "bypass_permissions").get(), false)
        XCTAssertEqual(try? Workstream.Launcher.parseBool("  ", name: "bypass_permissions").get(), false)
    }

    func testBoolParsesTrueAndFalse() {
        XCTAssertEqual(try? Workstream.Launcher.parseBool("true", name: "b").get(), true)
        XCTAssertEqual(try? Workstream.Launcher.parseBool(" true ", name: "b").get(), true)
        XCTAssertEqual(try? Workstream.Launcher.parseBool("false", name: "b").get(), false)
    }

    /// The whole point: a value that quietly reads false because the agent sent
    /// "True" is a silent no-op reported as a success.
    func testUnrecognizedBoolIsAnErrorRatherThanFalse() {
        for raw in ["True", "TRUE", "yes", "1", "on", "y"] {
            guard case let .failure(failure) = Workstream.Launcher.parseBool(raw, name: "bypass_permissions") else {
                XCTFail("expected \(raw) to be rejected rather than read as false")
                continue
            }
            guard case let .invalidArgument(name, reason) = failure else {
                return XCTFail("expected an invalidArgument failure")
            }
            XCTAssertEqual(name, "bypass_permissions")
            XCTAssertTrue(reason.contains(raw), "the refusal must echo what arrived: \(reason)")
        }
    }
}
