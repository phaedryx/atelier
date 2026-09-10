// ABOUTME: Tests for the built-in palette command set.
// ABOUTME: Pins id uniqueness, availability gating, and that actions post the expected notifications.

@testable import Atelier
import XCTest

@MainActor
final class DefaultCommandsTests: XCTestCase {
    func testIDsAreUniqueAndTitlesNonEmpty() {
        let commands = defaultPaletteCommands()
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
        XCTAssertFalse(commands.contains { $0.title.isEmpty })
        XCTAssertFalse(commands.isEmpty)
    }

    func testWorkstreamCommandsRequireAnActiveWorkstream() throws {
        let commands = defaultPaletteCommands()
        let noWorkstream = PaletteContext(workstreamActive: false, editorActive: false)
        let terminal = try XCTUnwrap(commands.first { $0.id == "tab.newTerminal" })
        let settings = try XCTUnwrap(commands.first { $0.id == "app.settings" })

        XCTAssertFalse(terminal.isAvailable(noWorkstream))
        XCTAssertTrue(settings.isAvailable(noWorkstream))
    }

    func testEditorCommandsRequireAnActiveEditor() throws {
        let commands = defaultPaletteCommands()
        let workstreamOnly = PaletteContext(workstreamActive: true, editorActive: false)
        let editorToo = PaletteContext(workstreamActive: true, editorActive: true)
        let findFile = try XCTUnwrap(commands.first { $0.id == "editor.findFile" })

        XCTAssertFalse(findFile.isAvailable(workstreamOnly))
        XCTAssertTrue(findFile.isAvailable(editorToo))
    }

    func testExecutionCommandPostsToggleExecution() throws {
        let commands = defaultPaletteCommands()
        let execution = try XCTUnwrap(commands.first { $0.id == "tab.execution" })
        let posted = expectation(forNotification: .toggleExecution, object: nil)

        execution.action()

        wait(for: [posted], timeout: 1)
    }

    func testNewTerminalCommandPostsToggleTerminal() throws {
        let commands = defaultPaletteCommands()
        let terminal = try XCTUnwrap(commands.first { $0.id == "tab.newTerminal" })
        let posted = expectation(forNotification: .toggleTerminal, object: nil)

        terminal.action()

        wait(for: [posted], timeout: 1)
    }

    /// The palette advertises the same key the Tabs menu binds. Only the label
    /// is pinned here — `keyboardShortcut` lives in `AtelierApp`'s `commands`
    /// block, which no test can reach — so this catches the two drifting apart,
    /// not the binding going missing.
    func testNewTerminalCommandAdvertisesCommandT() throws {
        let commands = defaultPaletteCommands()
        let terminal = try XCTUnwrap(commands.first { $0.id == "tab.newTerminal" })

        XCTAssertEqual(terminal.shortcut, "⌘T")
    }

    /// The palette is the only surface for this one outside the Info tab, so a
    /// wrong notification name is invisible until someone presses it.
    func testRerunBootstrapCommandPostsRerunBootstrap() throws {
        let commands = defaultPaletteCommands()
        let rerun = try XCTUnwrap(commands.first { $0.id == "run.rerunBootstrap" })
        let posted = expectation(forNotification: .rerunBootstrap, object: nil)

        rerun.action()

        wait(for: [posted], timeout: 1)
    }

    /// Bootstrap is a phase, not the run — this must not be the same
    /// notification Start/Rerun posts.
    func testRerunBootstrapIsNotTheSameCommandAsStartRerun() throws {
        let commands = defaultPaletteCommands()
        let rerunBootstrap = try XCTUnwrap(commands.first { $0.id == "run.rerunBootstrap" })
        let startRerun = try XCTUnwrap(commands.first { $0.id == "run.startRerun" })

        XCTAssertNotEqual(rerunBootstrap.title, startRerun.title)
        XCTAssertFalse(rerunBootstrap.isAvailable(PaletteContext(workstreamActive: false, editorActive: false)))
        XCTAssertTrue(rerunBootstrap.isAvailable(PaletteContext(workstreamActive: true, editorActive: false)))
    }

    /// The four cycling commands work from a project row as well as a
    /// workstream, and their receivers already refuse when there is nothing to
    /// cycle. Gating them on `workstreamActive` would hide them in the one view
    /// where "next workstream" is the obvious next move.
    func testCyclingCommandsAreNotWorkstreamGated() throws {
        let commands = defaultPaletteCommands()
        let noWorkstream = PaletteContext(workstreamActive: false, editorActive: false)

        for id in ["nav.nextWorkstream", "nav.previousWorkstream", "nav.nextProject", "nav.previousProject"] {
            let command = try XCTUnwrap(commands.first { $0.id == id }, id)
            XCTAssertTrue(command.isAvailable(noWorkstream), id)
        }
    }

    /// Tab cycling is the opposite case: there are no tabs outside a workspace.
    func testTabCyclingRequiresAWorkstream() throws {
        let commands = defaultPaletteCommands()
        let noWorkstream = PaletteContext(workstreamActive: false, editorActive: false)

        for id in ["tab.next", "tab.previous"] {
            let command = try XCTUnwrap(commands.first { $0.id == id }, id)
            XCTAssertFalse(command.isAvailable(noWorkstream), id)
        }
    }

    /// Both directions of every cycling pair post a distinct notification. A
    /// copy-paste that pointed "Previous" at the "Next" name would look right in
    /// the palette and move the wrong way.
    func testCyclingCommandsPostTheirOwnDirection() throws {
        let expected: [(String, Notification.Name)] = [
            ("tab.next", .nextTab),
            ("tab.previous", .prevTab),
            ("nav.nextWorkstream", .nextWorkstream),
            ("nav.previousWorkstream", .prevWorkstream),
            ("nav.nextProject", .nextProject),
            ("nav.previousProject", .prevProject),
        ]
        let commands = defaultPaletteCommands()

        for (id, name) in expected {
            let command = try XCTUnwrap(commands.first { $0.id == id }, id)
            let posted = expectation(forNotification: name, object: nil)
            command.action()
            wait(for: [posted], timeout: 1)
        }
    }

    func testCreateCommandsPostAddNotifications() throws {
        let commands = defaultPaletteCommands()
        let new = try XCTUnwrap(commands.first { $0.id == "create.new" })
        let newProject = try XCTUnwrap(commands.first { $0.id == "create.newProject" })

        let addNew = expectation(forNotification: .addNew, object: nil)
        new.action()
        wait(for: [addNew], timeout: 1)

        let addProject = expectation(forNotification: .addProject, object: nil)
        newProject.action()
        wait(for: [addProject], timeout: 1)
    }

    /// Every pane is reachable, and `.prompts` is reachable exactly once —
    /// `app.editPrompts` owns it under a better title, so the generated family
    /// must skip it rather than add a second row opening the same pane.
    func testEverySettingsPaneIsDeepLinkedExactlyOnce() {
        let deepLinks = defaultPaletteCommands().filter {
            $0.id.hasPrefix("app.settingsPane.") || $0.id == "app.editPrompts"
        }
        var reached: [SettingsPane] = []

        for command in deepLinks {
            let posted = expectation(forNotification: .openSettings, object: nil) { note in
                guard let pane = SettingsPane.deepLinkTarget(from: note) else { return false }
                reached.append(pane)
                return true
            }
            command.action()
            wait(for: [posted], timeout: 1)
        }

        XCTAssertEqual(Set(reached), Set(SettingsPane.allCases))
        XCTAssertEqual(reached.count, SettingsPane.allCases.count)
    }

    @MainActor
    func testSubmitReviewCommandIsWorkstreamGated() {
        let commands = defaultPaletteCommands()
        guard let command = commands.first(where: { $0.id == "changes.submitReview" }) else {
            return XCTFail("changes.submitReview not registered")
        }
        XCTAssertFalse(command.isAvailable(PaletteContext(workstreamActive: false, editorActive: false)))
        XCTAssertTrue(command.isAvailable(PaletteContext(workstreamActive: true, editorActive: false)))
    }
}

/// The go-to family: one command per project and one per workstream, synced
/// into the registry under `gotoCommandPrefix`.
@MainActor
final class GotoPaletteCommandTests: XCTestCase {
    private func project(_ name: String, workstreams: [String]) -> Project {
        Project(
            name: name,
            directory: "/tmp/\(name)",
            workstreams: workstreams.map { Workstream(name: $0) }
        )
    }

    func testEmitsOneCommandPerProjectAndWorkstream() {
        let commands = gotoPaletteCommands(for: [
            project("alpha", workstreams: ["one", "two"]),
            project("beta", workstreams: []),
        ])

        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(Set(commands.map(\.id)).count, 4)
        XCTAssertTrue(commands.allSatisfy { $0.id.hasPrefix(gotoCommandPrefix) })
    }

    /// The whole point of the family: reaching a workstream you are not already
    /// in. Gating on `workstreamActive` would make it useless from a project row.
    func testCommandsAreAvailableWithNoActiveWorkstream() {
        let commands = gotoPaletteCommands(for: [project("alpha", workstreams: ["one"])])
        let nothingActive = PaletteContext(workstreamActive: false, editorActive: false)

        XCTAssertTrue(commands.allSatisfy { $0.isAvailable(nothingActive) })
    }

    /// `CommandRegistry.sync` clears every id under the prefix it is handed, so
    /// a family named `workstream.` or `project.` would delete
    /// `workstream.rename` and `workstream.archive` on its first emission. This
    /// is the same hazard the stored-prompt family documents, one prefix over.
    func testNoBuiltInCommandSitsUnderTheGotoPrefix() {
        let builtIns = defaultPaletteCommands().map(\.id)
        XCTAssertTrue(builtIns.allSatisfy { !$0.hasPrefix(gotoCommandPrefix) })
    }

    func testSyncingTheFamilyLeavesTheStaticWorkstreamCommandsAlone() throws {
        let registry = try CommandRegistry(
            commands: defaultPaletteCommands(),
            defaults: XCTUnwrap(UserDefaults(suiteName: "atelier.tests.gotoPalette"))
        )

        registry.sync(
            idPrefix: gotoCommandPrefix,
            with: gotoPaletteCommands(for: [project("alpha", workstreams: ["one"])])
        )

        let ids = registry.commands.map(\.id)
        XCTAssertTrue(ids.contains("workstream.rename"))
        XCTAssertTrue(ids.contains("workstream.archive"))
        XCTAssertEqual(ids.filter { $0.hasPrefix(gotoCommandPrefix) }.count, 2)
    }

    /// A workstream's title leads with its project so two projects holding a
    /// workstream of the same name stay distinguishable, and either half finds
    /// it by typing. The rename override wins over the branch-tracked name,
    /// because that is what the sidebar shows.
    func testWorkstreamTitleCarriesTheProjectAndTheRenamedLabel() throws {
        var workstream = Workstream(name: "brave-otter")
        workstream.applyRename("Payment fixes")
        let project = Project(name: "alpha", directory: "/tmp/alpha", workstreams: [workstream])

        let commands = gotoPaletteCommands(for: [project])
        let command = try XCTUnwrap(commands.first { $0.id.contains("workstream.") })

        XCTAssertEqual(command.title, "alpha / Payment fixes")
        XCTAssertGreaterThan(FuzzyMatcher.score(query: "payment", candidate: command.title), 0)
        XCTAssertGreaterThan(FuzzyMatcher.score(query: "alpha", candidate: command.title), 0)
    }

    /// A rename keeps the workstream's id and changes only its label, so the
    /// rebuilt command collides with the one already registered — and
    /// `register` refuses duplicates. It is `sync`'s `removeAll` *before* the
    /// re-register that lets the new title through; an "optimization" that
    /// skipped ids already present would leave the palette showing the old name
    /// with nothing to reveal it.
    func testResyncingAfterARenameShowsTheNewTitle() throws {
        var workstream = Workstream(name: "brave-otter")
        var project = Project(name: "alpha", directory: "/tmp/alpha", workstreams: [workstream])
        let registry = try CommandRegistry(
            commands: [],
            defaults: XCTUnwrap(UserDefaults(suiteName: "atelier.tests.gotoPaletteRename"))
        )
        registry.sync(idPrefix: gotoCommandPrefix, with: gotoPaletteCommands(for: [project]))

        workstream.applyRename("Payment fixes")
        project.workstreams = [workstream]
        registry.sync(idPrefix: gotoCommandPrefix, with: gotoPaletteCommands(for: [project]))

        let titles = registry.commands.map(\.title)
        XCTAssertTrue(titles.contains("alpha / Payment fixes"))
        XCTAssertFalse(titles.contains("alpha / brave-otter"))
    }

    func testWorkstreamCommandPostsFocusWorkstreamWithItsID() throws {
        let workstream = Workstream(name: "one")
        let project = Project(name: "alpha", directory: "/tmp/alpha", workstreams: [workstream])
        let commands = gotoPaletteCommands(for: [project])
        let command = try XCTUnwrap(commands.first { $0.id.contains("workstream.") })

        let posted = expectation(forNotification: .focusWorkstream, object: nil) { note in
            note.object as? UUID == workstream.id
        }
        command.action()
        wait(for: [posted], timeout: 1)
    }

    /// `.switchToProject` carries no payload and can only mean "the project of
    /// the selected workstream", so a named project jump needs `.focusProject`.
    func testProjectCommandPostsFocusProjectWithItsID() throws {
        let project = Project(name: "alpha", directory: "/tmp/alpha")
        let commands = gotoPaletteCommands(for: [project])
        let command = try XCTUnwrap(commands.first { $0.id.contains("project.") })

        let posted = expectation(forNotification: .focusProject, object: nil) { note in
            note.object as? UUID == project.id
        }
        command.action()
        wait(for: [posted], timeout: 1)
    }
}
