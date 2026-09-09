// ABOUTME: Tests for Project and Workstream models.
// ABOUTME: Validates creation, identity, equality, serialization, and workstream management.

@testable import Atelier
import XCTest

final class ProjectTests: XCTestCase {
    private static let testSuiteName = "atelier.tests"
    private let testDefaults = UserDefaults(suiteName: testSuiteName)!

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: Self.testSuiteName)
        super.tearDown()
    }

    func testCreation() {
        let project = Project(name: "myapp", directory: "/Users/test/myapp")
        XCTAssertEqual(project.name, "myapp")
        XCTAssertEqual(project.directory, "/Users/test/myapp")
    }

    func testUniqueIDs() {
        let a = Project(name: "a", directory: "/a")
        let b = Project(name: "b", directory: "/b")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testExplicitID() {
        let id = UUID()
        let project = Project(name: "test", directory: "/test", id: id)
        XCTAssertEqual(project.id, id)
    }

    func testHashable() {
        let id = UUID()
        let a = Project(name: "test", directory: "/test", id: id)
        let b = Project(name: "test", directory: "/test", id: id)
        XCTAssertEqual(a, b)

        var set: Set<Project> = []
        set.insert(a)
        XCTAssertTrue(set.contains(b))

        // Equality alone passed for a conformance that called everything equal, which
        // would silently collapse a project list into one entry.
        let other = Project(name: "test", directory: "/test")
        XCTAssertNotEqual(a, other, "a distinct id is a distinct project, same name and directory or not")
        XCTAssertFalse(set.contains(other))
        set.insert(other)
        XCTAssertEqual(set.count, 2)
    }

    func testMutableProperties() {
        var project = Project(name: "old", directory: "/old")
        project.name = "new"
        project.directory = "/new"
        XCTAssertEqual(project.name, "new")
        XCTAssertEqual(project.directory, "/new")
    }

    func testCodableRoundTrip() throws {
        let projects = [
            Project(name: "alpha", directory: "/Users/test/alpha"),
            Project(name: "beta", directory: "/Users/test/beta"),
        ]
        let data = try JSONEncoder().encode(projects)
        let decoded = try JSONDecoder().decode([Project].self, from: data)
        XCTAssertEqual(projects, decoded)
    }

    func testCodablePreservesID() throws {
        let original = Project(name: "test", directory: "/test")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.directory, decoded.directory)
    }

    func testProjectStoreRoundTrip() {
        let projects = [
            Project(name: "one", directory: "/one"),
            Project(name: "two", directory: "/two"),
        ]
        ProjectStore.save(projects, defaults: testDefaults)
        let loaded = ProjectStore.load(defaults: testDefaults)
        XCTAssertEqual(projects, loaded)
    }

    func testProjectDefaultsToNoWorkstreams() {
        let project = Project(name: "test", directory: "/test")
        XCTAssertTrue(project.workstreams.isEmpty)
    }

    func testWorkstreamCreation() {
        let ws = Workstream(name: "feature-auth")
        XCTAssertEqual(ws.name, "feature-auth")
    }

    func testProjectWithWorkstreams() {
        var project = Project(name: "app", directory: "/app")
        project.workstreams.append(Workstream(name: "backend"))
        project.workstreams.append(Workstream(name: "frontend"))
        XCTAssertEqual(project.workstreams.count, 2)
        XCTAssertNotEqual(project.workstreams[0].id, project.workstreams[1].id)
    }

    func testWorkstreamsCodableRoundTrip() throws {
        let project = Project(
            name: "app",
            directory: "/app",
            workstreams: [
                Workstream(name: "main"),
                Workstream(name: "bugfix"),
            ]
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(project, decoded)
        XCTAssertEqual(decoded.workstreams.count, 2)
        XCTAssertEqual(decoded.workstreams[0].name, "main")
        XCTAssertEqual(decoded.workstreams[1].name, "bugfix")
    }

    func testJSONWithStaleSpaceIDStillDecodes() throws {
        // Spaces were removed, but projects saved while the feature existed
        // still carry a `spaceID` key. A stale key must not break decoding of
        // the user's stored projects. The throwaway struct mirrors the OLD
        // Project shape so the default JSONEncoder/Decoder date handling stays
        // consistent, avoiding hardcoded date formats.
        struct ProjectWithSpaceID: Codable {
            let id: UUID
            var name: String
            var directory: String
            var workstreams: [Workstream]
            var lastAccessedAt: Date
            var spaceID: UUID?
        }

        let stored = ProjectWithSpaceID(
            id: UUID(),
            name: "legacy",
            directory: "/legacy",
            workstreams: [Workstream(name: "main")],
            lastAccessedAt: Date(),
            spaceID: UUID()
        )
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.id, stored.id)
        XCTAssertEqual(decoded.name, "legacy")
        XCTAssertEqual(decoded.directory, "/legacy")
        XCTAssertEqual(decoded.workstreams.count, 1)
    }

    func testProjectStoreWithWorkstreams() {
        let projects = [
            Project(name: "one", directory: "/one", workstreams: [
                Workstream(name: "dev"),
            ]),
        ]
        ProjectStore.save(projects, defaults: testDefaults)
        let loaded = ProjectStore.load(defaults: testDefaults)
        XCTAssertEqual(loaded.first?.workstreams.count, 1)
        XCTAssertEqual(loaded.first?.workstreams.first?.name, "dev")
    }

    // MARK: - Persisted blobs from earlier shapes

    /// `ProjectStore.load` decodes the whole `[Project]` array behind one
    /// `try?`, so a workstream that fails to decode takes every project with
    /// it. Blobs written while workstreams carried a `harness` are still on
    /// disk; the retired key must be ignored, not fatal.
    func testProjectStoreLoadsWorkstreamsWithRetiredHarnessKey() {
        let json = """
        [{
          "id": "\(UUID().uuidString)",
          "name": "one",
          "directory": "/one",
          "lastAccessedAt": 0,
          "workstreams": [
            {
              "id": "\(UUID().uuidString)",
              "name": "dev",
              "bypassPermissions": false,
              "lastAccessedAt": 0,
              "harness": "opencode"
            },
            {
              "id": "\(UUID().uuidString)",
              "name": "main",
              "bypassPermissions": false,
              "lastAccessedAt": 0,
              "harness": "claudeCode"
            }
          ]
        }]
        """
        testDefaults.set(Data(json.utf8), forKey: "atelier.projects")

        let loaded = ProjectStore.load(defaults: testDefaults)
        XCTAssertEqual(loaded.count, 1, "a retired harness key must not wipe the project list")
        XCTAssertEqual(loaded.first?.workstreams.map(\.name), ["dev", "main"])
    }

    // MARK: - One unreadable record must not take the rest with it

    /// The whole `[Project]` array went through a single `try?`, so any element
    /// the current shape could not read discarded every element — and the next
    /// save wrote the empty list back over the blob.
    func testProjectStoreKeepsTheProjectsItCanReadWhenOneIsUnreadable() {
        let good = UUID()
        let json = """
        [{
          "id": "\(good.uuidString)",
          "name": "good",
          "directory": "/good",
          "lastAccessedAt": 0,
          "workstreams": []
        },
        {
          "name": "no id, no directory, not a project"
        }]
        """
        testDefaults.set(Data(json.utf8), forKey: "atelier.projects")

        let loaded = ProjectStore.load(defaults: testDefaults)

        XCTAssertEqual(loaded.map(\.name), ["good"])
        XCTAssertEqual(loaded.first?.id, good)
    }

    /// A workstream is nested inside a project, so one that cannot be decoded
    /// used to take its project — and therefore every other project — with it.
    func testProjectStoreKeepsAProjectWhenOneOfItsWorkstreamsIsUnreadable() {
        let json = """
        [{
          "id": "\(UUID().uuidString)",
          "name": "one",
          "directory": "/one",
          "lastAccessedAt": 0,
          "workstreams": [
            {
              "id": "\(UUID().uuidString)",
              "name": "dev",
              "bypassPermissions": false,
              "lastAccessedAt": 0
            },
            { "name": "no id, not a workstream" }
          ]
        }]
        """
        testDefaults.set(Data(json.utf8), forKey: "atelier.projects")

        let loaded = ProjectStore.load(defaults: testDefaults)

        XCTAssertEqual(loaded.count, 1, "the project must survive its unreadable workstream")
        XCTAssertEqual(loaded.first?.workstreams.map(\.name), ["dev"])
    }

    /// Dropping what cannot be read is only safe if what was dropped is still
    /// somewhere: the next `save` overwrites the blob, and without this the
    /// bytes are gone for good.
    func testProjectStoreKeepsTheOriginalBlobWhenItCouldNotBeReadInFull() {
        let json = """
        [{ "name": "not a project" }]
        """
        testDefaults.set(Data(json.utf8), forKey: "atelier.projects")

        _ = ProjectStore.load(defaults: testDefaults)
        ProjectStore.save([Project(name: "new", directory: "/new")], defaults: testDefaults)

        let kept = testDefaults.data(forKey: "atelier.projects" + LossyStore.unreadableKeySuffix)
        XCTAssertEqual(kept.map { String(decoding: $0, as: UTF8.self) }, json)
    }

    /// A blob that reads cleanly must not leave a copy behind.
    func testProjectStoreKeepsNoBlobWhenEverythingReads() {
        ProjectStore.save([Project(name: "one", directory: "/one")], defaults: testDefaults)

        _ = ProjectStore.load(defaults: testDefaults)

        XCTAssertNil(testDefaults.data(forKey: "atelier.projects" + LossyStore.unreadableKeySuffix))
    }

    // MARK: - Inline rename

    // MARK: - checkout

    func testCheckoutFallsBackToTheDirectoryWhenThereIsNoneStored() {
        let project = Project(name: "plain", directory: "/repos/plain")
        XCTAssertEqual(project.checkout, "/repos/plain")
    }

    func testCheckoutIsTheStoredCheckoutWhenThereIsOne() {
        let project = Project(name: "app", directory: "/repos/app", checkoutDirectory: "/repos/app/main")
        XCTAssertEqual(project.directory, "/repos/app", "the container stays the project's directory")
        XCTAssertEqual(project.checkout, "/repos/app/main")
    }

    func testCheckoutSurvivesACodableRoundTrip() throws {
        let project = Project(name: "app", directory: "/repos/app", checkoutDirectory: "/repos/app/main")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.directory, "/repos/app")
        XCTAssertEqual(decoded.checkoutDirectory, "/repos/app/main")
    }

    // MARK: - matching and repairing an already-registered project

    private func location(
        directory: String,
        checkout: String? = nil,
        name: String = "app"
    ) -> Project.Location {
        Project.Location(directory: directory, name: name, checkoutDirectory: checkout)
    }

    func testNothingIsRegisteredForAnUnknownLocation() {
        let projects = [Project(name: "other", directory: "/repos/other")]
        XCTAssertNil(
            Project.existingRegistration(
                for: location(directory: "/repos/app", checkout: "/repos/app/main"),
                in: projects
            )
        )
    }

    func testAnAlreadyCorrectRegistrationNeedsNoRepair() throws {
        let projects = [Project(name: "app", directory: "/repos/app", checkoutDirectory: "/repos/app/main")]
        let found = try XCTUnwrap(
            Project.existingRegistration(
                for: location(directory: "/repos/app", checkout: "/repos/app/main"),
                in: projects
            )
        )
        XCTAssertEqual(found.index, 0)
        XCTAssertNil(found.repaired, "the pair is already what it should be")
    }

    /// The pre-0.2.0 cohort: the container was stored, but no checkout was ever
    /// recorded, so every work-tree read runs against a directory that has none.
    func testAContainerWithNoCheckoutIsRepairedInPlace() throws {
        let projects = [Project(name: "app", directory: "/repos/app")]
        let found = try XCTUnwrap(
            Project.existingRegistration(
                for: location(directory: "/repos/app", checkout: "/repos/app/main"),
                in: projects
            )
        )
        let repaired = try XCTUnwrap(found.repaired)
        XCTAssertEqual(repaired.directory, "/repos/app")
        XCTAssertEqual(repaired.checkoutDirectory, "/repos/app/main")
        XCTAssertEqual(repaired.id, projects[0].id, "the same row, not a second one")
    }

    /// The cohort the hoist could not prove: the checkout was stored as the
    /// project's directory, and there was no `.bare` beside it to settle it.
    func testACheckoutStoredAsTheDirectoryIsMatchedAndRepaired() throws {
        let projects = [Project(name: "app", directory: "/repos/app/main")]
        let found = try XCTUnwrap(
            Project.existingRegistration(
                for: location(directory: "/repos/app", checkout: "/repos/app/main"),
                in: projects
            )
        )
        let repaired = try XCTUnwrap(found.repaired)
        XCTAssertEqual(repaired.directory, "/repos/app", "hoisted to the container")
        XCTAssertEqual(repaired.checkoutDirectory, "/repos/app/main")
        XCTAssertEqual(repaired.id, projects[0].id)
    }

    func testWorkstreamsSurviveTheRepair() throws {
        var stored = Project(name: "app", directory: "/repos/app/main")
        stored.workstreams = [Workstream(name: "feat", worktreePath: "/repos/app/tad@feat")]
        let found = try XCTUnwrap(
            Project.existingRegistration(
                for: location(directory: "/repos/app", checkout: "/repos/app/main"),
                in: [stored]
            )
        )
        let repaired = try XCTUnwrap(found.repaired)
        XCTAssertEqual(repaired.workstreams.map(\.id), stored.workstreams.map(\.id))
    }

    /// A plain clone, and a container whose checkout is gone, both resolve with
    /// no checkout. Writing that over a recorded one would be a downgrade.
    func testARecordedCheckoutIsNotOverwrittenWithNothing() throws {
        let projects = [Project(name: "app", directory: "/repos/app", checkoutDirectory: "/repos/app/main")]
        let found = try XCTUnwrap(
            Project.existingRegistration(for: location(directory: "/repos/app"), in: projects)
        )
        XCTAssertEqual(found.index, 0)
        XCTAssertNil(found.repaired)
    }

    // MARK: - hoisting a directory saved under the older meaning

    /// Builds `<container>/{.bare, .git, <name>/.git}` on disk without git, since
    /// the hoist is filesystem-only by design.
    private func makeContainerLayout(
        named name: String = "app",
        checkout: String = "main",
        containerGitIsDirectory: Bool = false,
        gitdir: String? = nil
    ) throws -> (container: URL, checkout: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoist-\(UUID().uuidString)")
        let container = root.appendingPathComponent(name)
        let checkoutURL = container.appendingPathComponent(checkout)
        let bare = container.appendingPathComponent(".bare")
        // `worktrees/<checkout>` and not just `worktrees`, because that is where
        // the checkout's `gitdir:` points and git always creates it. The hoist no
        // longer needs it to exist — see `testHoistsWhenTheWorktreeAdminDirIsPruned`
        // — but a fixture that matches a real repository is worth keeping.
        try FileManager.default.createDirectory(
            at: bare.appendingPathComponent("worktrees/\(checkout)"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: checkoutURL, withIntermediateDirectories: true)

        let containerGit = container.appendingPathComponent(".git")
        if containerGitIsDirectory {
            try FileManager.default.createDirectory(at: containerGit, withIntermediateDirectories: true)
        } else {
            try "gitdir: ./.bare\n".write(to: containerGit, atomically: true, encoding: .utf8)
        }

        let pointer = gitdir ?? bare.appendingPathComponent("worktrees/\(checkout)").path
        try "gitdir: \(pointer)\n".write(
            to: checkoutURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (container, checkoutURL)
    }

    func testHoistsACheckoutSavedAsTheProjectDirectory() throws {
        let (container, checkout) = try makeContainerLayout()

        let hoisted = Project.hoistedLocation(directory: checkout.path)

        XCTAssertEqual(hoisted.directory, container.standardizedFileURL.path)
        XCTAssertEqual(hoisted.checkoutDirectory, checkout.standardizedFileURL.path)
    }

    func testDecodingABlobWithNoCheckoutFieldHoistsIt() throws {
        let (container, checkout) = try makeContainerLayout()
        // A blob written while `projectLocation` resolved a container forward:
        // the checkout stored as `directory`, and no `checkoutDirectory` at all.
        let json = """
        {"id":"\(UUID().uuidString)","name":"app","directory":"\(checkout.path)",
         "workstreams":[],"lastAccessedAt":0}
        """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.directory, container.standardizedFileURL.path)
        XCTAssertEqual(decoded.checkout, checkout.standardizedFileURL.path)
    }

    func testDoesNotHoistAContainerThatIsAlreadyTheDirectory() throws {
        let (container, _) = try makeContainerLayout()

        // Its `.git` is a file, but its *parent* holds no `.bare`, so there is
        // nothing above it to hoist to. A project saved before the forward
        // resolution existed is left exactly as it is.
        let hoisted = Project.hoistedLocation(directory: container.path)

        XCTAssertEqual(hoisted.directory, container.path)
        XCTAssertNil(hoisted.checkoutDirectory)
    }

    func testDoesNotHoistAnOrdinaryClone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoist-plain-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let hoisted = Project.hoistedLocation(directory: repo.path)

        XCTAssertEqual(hoisted.directory, repo.path, "`.git` is a directory here, so this is not a linked worktree")
        XCTAssertNil(hoisted.checkoutDirectory)
    }

    func testDoesNotHoistWhenTheParentIsAnOrdinaryRepository() throws {
        // The dangerous false positive: a worktree that happens to sit inside a
        // repository which happens to have a `.bare` directory of its own. The
        // parent's `.git` is a directory, not the `gitdir:` pointer file the
        // layout is built from.
        let (_, checkout) = try makeContainerLayout(containerGitIsDirectory: true)

        let hoisted = Project.hoistedLocation(directory: checkout.path)

        XCTAssertEqual(hoisted.directory, checkout.path)
        XCTAssertNil(hoisted.checkoutDirectory)
    }

    /// `git worktree add` records the pointer through whatever spelling it was
    /// given, so a container reached through a symlink writes an absolute gitdir
    /// that shares no textual prefix with the container's own path. Comparing
    /// the two unresolved refused a repair that should have happened.
    func testHoistsThroughASymlinkedContainerPath() throws {
        let (container, checkout) = try makeContainerLayout()
        let link = container.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: container)
        try "gitdir: \(link.appendingPathComponent(".bare/worktrees/main").path)\n".write(
            to: checkout.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let hoisted = Project.hoistedLocation(directory: checkout.path)

        XCTAssertEqual(hoisted.directory, container.standardizedFileURL.path)
        XCTAssertEqual(
            hoisted.checkoutDirectory,
            checkout.standardizedFileURL.path,
            "the paths returned are the ones the user registered, not the resolved ones"
        )
    }

    /// `git worktree prune` deletes `.bare/worktrees/<name>` and leaves the
    /// checkout's `.git` pointing at it. That spelling still names this
    /// container, but `resolvingSymlinksInPath()` no-ops on a path that is gone,
    /// so the comparison used to run on raw spellings and refuse to hoist.
    func testHoistsWhenTheWorktreeAdminDirIsPruned() throws {
        let (container, checkout) = try makeContainerLayout()
        try FileManager.default.removeItem(
            at: container.appendingPathComponent(".bare/worktrees/main")
        )

        let hoisted = Project.hoistedLocation(directory: checkout.path)

        XCTAssertEqual(hoisted.directory, container.standardizedFileURL.path)
        XCTAssertEqual(hoisted.checkoutDirectory, checkout.standardizedFileURL.path)
    }

    func testDoesNotHoistAWorktreeOwnedByADifferentContainer() throws {
        // Everything looks like the layout, but this worktree's git directory
        // lives somewhere else entirely — so the two files are not related, and
        // hoisting would hand the project a container that is not its own.
        let (_, checkout) = try makeContainerLayout(gitdir: "/somewhere/else/.bare/worktrees/main")

        let hoisted = Project.hoistedLocation(directory: checkout.path)

        XCTAssertEqual(hoisted.directory, checkout.path)
        XCTAssertNil(hoisted.checkoutDirectory)
    }

    func testDoesNotHoistABlobThatAlreadyCarriesACheckout() throws {
        let (container, checkout) = try makeContainerLayout()
        // Written under the current meaning. Even though the paths are hoistable,
        // the field being present means the answer is already recorded.
        let json = """
        {"id":"\(UUID().uuidString)","name":"app","directory":"\(checkout.path)",
         "checkoutDirectory":"\(container.path)","workstreams":[],"lastAccessedAt":0}
        """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.directory, checkout.path, "no repair when the field is there")
        XCTAssertEqual(decoded.checkoutDirectory, container.path)
    }

    /// The bug the whole change exists for. A `process-compose.yaml` placed where
    /// the README says — beside `.bare` and the worktrees — was invisible,
    /// because `ProcessCompose.Config.locate` was handed `<container>/main` as
    /// the project directory and looked for it there.
    func testAConfigInTheContainerIsFoundForAPeerWorktree() throws {
        let (container, checkout) = try makeContainerLayout()
        try "processes:\n  web:\n    command: echo hi\n".write(
            to: container.appendingPathComponent("process-compose.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let peer = container.appendingPathComponent("tad@feature")
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)

        // Stored under the older meaning, so this also proves the hoist and the
        // lookup agree.
        let json = """
        {"id":"\(UUID().uuidString)","name":"app","directory":"\(checkout.path)",
         "workstreams":[],"lastAccessedAt":0}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        let config = try XCTUnwrap(ProcessCompose.Config.locate(
            worktree: peer.path,
            projectDirectory: project.directory
        ))
        XCTAssertEqual(
            config.path,
            container.standardizedFileURL.appendingPathComponent("process-compose.yaml").path
        )
        XCTAssertFalse(
            config.isRepositoryProvided,
            "a config in the container sits outside git, so it needs no approval"
        )

        XCTAssertNil(
            ProcessCompose.Config.locate(worktree: peer.path, projectDirectory: project.checkout),
            "and the binding this change replaced still finds nothing"
        )
    }

    func testApplyRenameSetsDisplayNameOverride() {
        var ws = Workstream(name: "feat-auth")
        ws.applyRename("Login rework")
        XCTAssertEqual(ws.displayName, "Login rework")
        XCTAssertEqual(ws.label, "Login rework")
    }

    func testApplyRenameTrimsWhitespace() {
        var ws = Workstream(name: "feat-auth")
        ws.applyRename("  Login rework \n")
        XCTAssertEqual(ws.displayName, "Login rework")
    }

    func testApplyRenameEmptyInputClearsOverride() {
        var ws = Workstream(name: "feat-auth", displayName: "Login rework")
        ws.applyRename("   ")
        XCTAssertNil(ws.displayName)
        XCTAssertEqual(ws.label, "feat-auth")
    }

    func testApplyRenameMatchingBranchNameClearsOverride() {
        var ws = Workstream(name: "feat-auth", displayName: "Login rework")
        ws.applyRename("feat-auth")
        XCTAssertNil(ws.displayName, "renaming back to the branch-tracked name should drop the override")
    }

    /// The pre-harness Workstream shape must also still decode.
    func testLegacyWorkstreamJSONDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "legacy",
          "bypassPermissions": true,
          "lastAccessedAt": 0
        }
        """
        let decoded = try JSONDecoder().decode(Workstream.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "legacy")
        XCTAssertTrue(decoded.bypassPermissions)
    }

    func testWorkstreamWithoutShortcutStoryIDDecodesToNil() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "no-story",
          "bypassPermissions": false,
          "lastAccessedAt": 0
        }
        """
        let decoded = try JSONDecoder().decode(Workstream.self, from: Data(json.utf8))
        XCTAssertNil(decoded.shortcutStoryID)
    }

    func testShortcutStoryIDRoundTrips() throws {
        let original = Workstream(name: "tadthorley/sc-17411/some-title", shortcutStoryID: 17411)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workstream.self, from: data)
        XCTAssertEqual(decoded.shortcutStoryID, 17411)
    }

    /// The whole `[Project]` array is decoded from one UserDefaults key with `try?`, so a
    /// single workstream failing to decode silently yields `[]` and wipes every project.
    /// A build written before `shortcutStoryID` existed must therefore still load.
    func testProjectListWrittenBeforeShortcutStoryIDStillDecodes() throws {
        let json = """
        [
          {
            "id": "\(UUID().uuidString)",
            "name": "atelier",
            "directory": "/tmp/atelier",
            "lastAccessedAt": 0,
            "workstreams": [
              {
                "id": "\(UUID().uuidString)",
                "name": "older-workstream",
                "bypassPermissions": false,
                "lastAccessedAt": 0
              }
            ]
          }
        ]
        """
        let decoded = try JSONDecoder().decode([Project].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1, "a pre-upgrade project blob must not decode away to nothing")
        XCTAssertEqual(decoded.first?.workstreams.count, 1)
        XCTAssertNil(decoded.first?.workstreams.first?.shortcutStoryID)
    }
}
