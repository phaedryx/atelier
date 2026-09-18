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
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
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
            createWorktree: { _, _, _, name in "/repos/app/\(name)" },
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
                createWorktree: { _, _, _, _ in nil },
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
            createWorktree: { _, checkout, _, name in
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
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
        )

        XCTAssertEqual(recorder.events[0].userInfo["select"] as? Bool, false)
    }

    /// The other direction, which the sidebar's three entry points now depend on
    /// entirely: they were posting `.workstreamCreated` themselves and relying on
    /// `ContentView`'s `?? true`, and they now ask for the selection by name.
    @MainActor
    func testLaunchCanAskForTheSelection() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            select: true,
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
        )

        XCTAssertEqual(recorder.events[0].userInfo["select"] as? Bool, true)
    }

    /// The Shortcut flow's whole point: `syncShortcutStoryIDs` keys the staged
    /// story by the worktree path, and it can only promote a story the posted
    /// workstream already carries. The sidebar's own copy of the sequence built
    /// the `Workstream` itself and set this; the launcher's did not, so routing
    /// the sidebar through it without this parameter would have dropped every
    /// story id in silence.
    @MainActor
    func testShortcutStoryIDLandsOnThePostedWorkstream() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "sc-482-fix",
            shortcutStoryID: 482,
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
        )

        let posted = recorder.events[0].userInfo["workstream"] as? Workstream
        XCTAssertEqual(posted?.shortcutStoryID, 482)
    }

    /// Absent by default, so the two flows that have no story do not have to say
    /// so and a stale id cannot ride along from a previous launch.
    @MainActor
    func testAWorkstreamWithNoStoryCarriesNone() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
        )

        let posted = recorder.events[0].userInfo["workstream"] as? Workstream
        XCTAssertNil(posted?.shortcutStoryID)
    }

    /// The GitHub-branch flow does not get its own launch path — it names a
    /// different `WorktreeSource`, and that is the whole of the choice.
    ///
    /// CLAUDE.md, "Two ways to create a worktree, and they are not
    /// interchangeable": `createWorktree` cuts a *new* branch from the base
    /// branch, so running it for a branch that already exists on origin succeeds
    /// and produces a worktree named for that branch while holding the base
    /// branch's code. Nothing in the notification sequence can tell the two apart
    /// afterwards, which is why the choice is pinned at the point it is made.
    @MainActor
    func testAnExistingRemoteBranchReachesTheCreatorAsTheTrackingSource() async throws {
        let launcher = makeLauncher([project(name: "app", directory: "/repos/app")])
        let seen = Box<Workstream.Launcher.WorktreeSource?>(nil)

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "renovate/npm-foo-1.x",
            source: .existingRemoteBranch("renovate/npm-foo-1.x"),
            createWorktree: { source, _, _, _ in
                seen.value = source
                return "/repos/app/renovate--npm-foo-1.x"
            }
        )

        XCTAssertEqual(seen.value, .existingRemoteBranch("renovate/npm-foo-1.x"))
    }

    /// The default, which the `+` dialog and the Shortcut flow take by saying
    /// nothing. A source that defaulted the other way would silently give every
    /// generated name `createWorktreeTrackingRemote`, whose fetch of a branch
    /// origin has never heard of is an ordinary failure arriving after the
    /// optimistic row is drawn.
    @MainActor
    func testALaunchCutsANewBranchUnlessToldOtherwise() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let seen = Box<Workstream.Launcher.WorktreeSource?>(nil)

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { source, _, _, name in
                seen.value = source
                return "/repos/app/\(name)"
            }
        )

        XCTAssertEqual(seen.value, .newBranch)
    }

    /// The branch rides on the case, not on the workstream name. They are equal
    /// in the flow that produces this — the sidebar names the workstream for the
    /// branch — and a creator that read the name parameter instead would work
    /// until something created a workstream whose label differed from its branch.
    @MainActor
    func testTheTrackedBranchTravelsWithTheSourceRatherThanTheWorkstreamName() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let seen = Box<Workstream.Launcher.WorktreeSource?>(nil)

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "adopt-renovate",
            source: .existingRemoteBranch("renovate/npm-foo-1.x"),
            createWorktree: { source, _, _, _ in
                seen.value = source
                return "/repos/app/adopt-renovate"
            }
        )

        XCTAssertEqual(seen.value, .existingRemoteBranch("renovate/npm-foo-1.x"))
    }

    // MARK: - Adoption

    /// Adoption posts the same pair `launch` does, in the same order, so a
    /// consumer cannot tell an adopted workstream from a created one. It posts
    /// the optimistic row with a `nil` path for the same reason: the path arrives
    /// through `.workstreamWorktreeReady` and `attachWorktreePath`, which is what
    /// `ProjectOverviewView` was skipping when it posted `.workstreamCreated`
    /// alone with the path already filled in.
    ///
    /// There is deliberately no create closure to assert was not called: `adopt`
    /// does not take one. The worktree exists — that is the whole premise — and a
    /// parameter that could make it create one would be a fourth way to create a
    /// worktree.
    @MainActor
    func testAdoptPostsTheSameNotificationPairAsALaunch() {
        let projectID = UUID()
        let recorder = Recorder()

        let launched = Workstream.Launcher.shared.adopt(
            projectID: projectID,
            name: "renovate/npm-foo-1.x",
            worktreePath: "/repos/app/renovate--npm-foo-1.x"
        )

        XCTAssertEqual(recorder.events.map(\.name), [.workstreamCreated, .workstreamWorktreeReady])
        XCTAssertEqual(recorder.events[0].userInfo["projectID"] as? UUID, projectID)
        let posted = recorder.events[0].userInfo["workstream"] as? Workstream
        XCTAssertEqual(posted?.id, launched.workstreamID)
        XCTAssertEqual(posted?.name, "renovate/npm-foo-1.x")
        XCTAssertNil(posted?.worktreePath)
        XCTAssertEqual(recorder.events[1].userInfo["workstreamID"] as? UUID, launched.workstreamID)
        XCTAssertEqual(recorder.events[1].userInfo["worktreePath"] as? String, "/repos/app/renovate--npm-foo-1.x")
        XCTAssertEqual(launched.worktreePath, "/repos/app/renovate--npm-foo-1.x")
    }

    /// The one key that separates the two, and it states a fact rather than a
    /// decision: `ContentView` is what decides that a worktree the user already
    /// had does not get `initialization.yaml` run in it unprompted.
    @MainActor
    func testAdoptSaysTheWorktreeAlreadyExisted() {
        let recorder = Recorder()

        Workstream.Launcher.shared.adopt(
            projectID: UUID(),
            name: "feat-b",
            worktreePath: "/repos/app/feat-b"
        )

        XCTAssertEqual(recorder.events[1].userInfo["worktreeIsPreexisting"] as? Bool, true)
    }

    /// A launch must *not* carry it, or `ContentView` would skip initialization
    /// for the worktree it just created — the case the flag exists to leave
    /// alone.
    @MainActor
    func testALaunchDoesNotClaimItsWorktreeAlreadyExisted() async throws {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        _ = try await launcher.launch(
            in: target(launcher, projectDirectory: "/repos/app"),
            requestedName: "feat-ipc",
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
        )

        XCTAssertNil(recorder.events[1].userInfo["worktreeIsPreexisting"])
    }

    /// The overview's Adopt button is a button the user just pressed, so the row
    /// it creates takes the selection — the opposite default from `launch`, whose
    /// only caller that omits `select` is `create_workstream`.
    @MainActor
    func testAdoptTakesTheSelectionByDefault() {
        let recorder = Recorder()

        Workstream.Launcher.shared.adopt(
            projectID: UUID(),
            name: "feat-b",
            worktreePath: "/repos/app/feat-b"
        )

        XCTAssertEqual(recorder.events[0].userInfo["select"] as? Bool, true)
    }

    @MainActor
    func testFailedWorktreePostsCreationFailedAndThrows() async {
        let launcher = makeLauncher([project(directory: "/repos/app")])
        let recorder = Recorder()

        do {
            _ = try await launcher.launch(
                in: target(launcher, projectDirectory: "/repos/app"),
                requestedName: "feat-ipc",
                createWorktree: { _, _, _, _ in nil }
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
            createWorktree: { _, _, _, _ in nil }
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
            createWorktree: { _, _, _, name in "/repos/app/\(name)" }
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
}
