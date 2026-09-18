// ABOUTME: Tests for the built-in palette command set.
// ABOUTME: Pins id uniqueness, availability gating, and that actions send/post what the receivers expect.

@testable import Atelier
import Combine
import XCTest

/// Collects everything sent on the shared channel while it lives.
///
/// The palette's command closures are built once in a free function with no
/// view context, so they send on `AppCommandChannel.shared` and there is
/// nothing to inject — subscribing to `shared` is how a test sees them. The
/// channel is a `PassthroughSubject`, so nothing is replayed and a collector
/// only ever sees what was sent after it started.
@MainActor
final class AppCommandCollector {
    private(set) var sent: [AppCommand] = []
    private var subscription: AnyCancellable?

    init(_ channel: AppCommandChannel = .shared) {
        subscription = channel.publisher.sink { [weak self] in self?.sent.append($0) }
    }

    // No `deinit` cancelling the subscription: a `deinit` is nonisolated and
    // cannot touch a non-`Sendable` `AnyCancellable`. Dropping the collector
    // drops its only strong reference to the `AnyCancellable`, which cancels
    // on its own way out — which is what keeps a collector from outliving its
    // test and seeing the next one's commands.
}

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

    func testVerificationCommandPostsToggleVerification() throws {
        let commands = defaultPaletteCommands()
        let verification = try XCTUnwrap(commands.first { $0.id == "tab.verification" })
        let posted = expectation(forNotification: .toggleVerification, object: nil)

        verification.action()

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
        let rerun = try XCTUnwrap(commands.first { $0.id == "run.rerunInitialization" })
        let posted = expectation(forNotification: .rerunInitialization, object: nil)

        rerun.action()

        wait(for: [posted], timeout: 1)
    }

    /// Bootstrap is a phase, not the run — this must not be the same
    /// notification Start/Rerun posts.
    func testRerunBootstrapIsNotTheSameCommandAsStartRerun() throws {
        let commands = defaultPaletteCommands()
        let rerunInitialization = try XCTUnwrap(commands.first { $0.id == "run.rerunInitialization" })
        let startRerun = try XCTUnwrap(commands.first { $0.id == "run.startRerun" })

        XCTAssertNotEqual(rerunInitialization.title, startRerun.title)
        XCTAssertFalse(rerunInitialization.isAvailable(PaletteContext(workstreamActive: false, editorActive: false)))
        XCTAssertTrue(rerunInitialization.isAvailable(PaletteContext(workstreamActive: true, editorActive: false)))
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

    /// Both directions of every cycling pair send a distinct command. A
    /// copy-paste that pointed "Previous" at the "Next" case would look right in
    /// the palette and move the wrong way.
    func testCyclingCommandsSendTheirOwnDirection() throws {
        let expected: [(String, AppCommand)] = [
            ("nav.nextWorkstream", .nextWorkstream),
            ("nav.previousWorkstream", .prevWorkstream),
            ("nav.nextProject", .nextProject),
            ("nav.previousProject", .prevProject),
        ]
        let commands = defaultPaletteCommands()

        for (id, expectedCommand) in expected {
            let command = try XCTUnwrap(commands.first { $0.id == id }, id)
            let collector = AppCommandCollector()
            command.action()
            XCTAssertEqual(collector.sent, [expectedCommand], id)
        }
    }

    /// The tab half of the same pair, still on `NotificationCenter` because
    /// `TerminalContainerView` is where it is received. Kept beside its sibling
    /// above so the two halves of the chord table stay visibly one table.
    func testTabCyclingCommandsPostTheirOwnDirection() throws {
        let expected: [(String, Notification.Name)] = [
            ("tab.next", .nextTab),
            ("tab.previous", .prevTab),
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
            let collector = AppCommandCollector()
            command.action()
            // The whole of what it sent, not just the first: a row that opened a
            // pane *and* did something else would otherwise pass.
            guard collector.sent.count == 1,
                  case let .openSettings(pane) = collector.sent[0], let pane
            else {
                return XCTFail("\(command.id) did not deep-link to exactly one pane")
            }
            reached.append(pane)
        }

        XCTAssertEqual(Set(reached), Set(SettingsPane.allCases))
        XCTAssertEqual(reached.count, SettingsPane.allCases.count)
    }

    /// Destructive, and one fuzzy match from "Archive Workstream" — so what it
    /// sends matters: `.purgeWorkstream(nil)`, which `ContentView` resolves to
    /// the selection and hands to `confirmPurge`. A command closure is built
    /// once and can never know which workstream is active, and a nil that
    /// became some *other* workstream's id would purge the wrong worktree.
    @MainActor
    func testPurgeCommandSendsNoWorkstreamIDAndIsWorkstreamGated() throws {
        let command = try XCTUnwrap(defaultPaletteCommands().first { $0.id == "workstream.purge" })

        XCTAssertFalse(command.isAvailable(PaletteContext(workstreamActive: false, editorActive: false)))
        XCTAssertTrue(command.isAvailable(PaletteContext(workstreamActive: true, editorActive: false)))

        let collector = AppCommandCollector()
        command.action()
        XCTAssertEqual(collector.sent, [.purgeWorkstream(nil)])
    }

    /// The add menu's two variants carry their choice as `.addNew`'s payload.
    /// Absent means "the default", which is what `create.new` posts — reading a
    /// missing payload as `false` would silently strip permissions from ⌘N.
    ///
    /// Still a notification, deliberately: `.addNew`'s receiver is
    /// `ProjectSidebar`, not `ContentView`, so it is outside `AppCommand`'s
    /// scope. See that type's doc comment.
    @MainActor
    func testNewWorkstreamVariantsCarryTheirPermissionChoice() throws {
        let commands = defaultPaletteCommands()
        for (id, expected) in [("create.newFullPermissions", true), ("create.newWithPrompts", false)] {
            let command = try XCTUnwrap(commands.first { $0.id == id }, id)
            let posted = expectation(forNotification: .addNew, object: nil) {
                $0.object as? Bool == expected
            }
            command.action()
            wait(for: [posted], timeout: 1)
        }

        let plain = try XCTUnwrap(commands.first { $0.id == "create.new" })
        let posted = expectation(forNotification: .addNew, object: nil) { $0.object == nil }
        plain.action()
        wait(for: [posted], timeout: 1)
    }

    /// One row per quick action, posting the raw value the receiver resolves.
    @MainActor
    func testQuickActionCommandsPostTheirOwnAction() throws {
        let commands = defaultPaletteCommands()
        for action in QuickAction.allCases {
            let command = try XCTUnwrap(commands.first { $0.id == "git.\(action.rawValue)" }, action.rawValue)
            let posted = expectation(forNotification: .runQuickAction, object: nil) {
                $0.object as? String == action.rawValue
            }
            command.action()
            wait(for: [posted], timeout: 1)
        }
    }

    /// Missing tools disable the row and say so, rather than dropping it: "gh is
    /// not installed" is a condition the user can act on, and the wording is
    /// `QuickAction.unavailableReason`'s — the same copy the toolbar menu
    /// disables its own buttons with.
    @MainActor
    func testQuickActionCommandsAreDisabledWithTheMenusOwnReason() throws {
        let commands = defaultPaletteCommands()
        let ready = PaletteContext(
            workstreamActive: true, editorActive: false,
            claudeInstalled: true, ghInstalled: true, bypassPermissions: true
        )
        let noTools = PaletteContext(
            workstreamActive: true, editorActive: false,
            claudeInstalled: false, ghInstalled: false, bypassPermissions: false
        )

        for action in QuickAction.allCases {
            let command = try XCTUnwrap(commands.first { $0.id == "git.\(action.rawValue)" }, action.rawValue)
            XCTAssertEqual(command.availability(ready), .available, action.rawValue)
            XCTAssertEqual(
                command.availability(noTools).reason,
                QuickAction.unavailableReason(
                    for: action, claudeInstalled: false, ghInstalled: false, bypassPermissions: false
                ),
                action.rawValue
            )
            // Hidden outside a workspace: there is nothing to act on, and
            // nothing the user could do about it from there.
            XCTAssertEqual(
                command.availability(PaletteContext(workstreamActive: false, editorActive: false)),
                .hidden,
                action.rawValue
            )
        }
    }

    /// Hidden rather than disabled when there is nothing to open — the same
    /// choice the sidebar's context menu makes by omitting the item.
    @MainActor
    func testOpenCommandsAreHiddenWhenThereIsNothingToOpen() throws {
        let commands = defaultPaletteCommands()
        let bare = PaletteContext(workstreamActive: true, editorActive: false)
        let everything = PaletteContext(
            workstreamActive: true, editorActive: false,
            hasGitHubRemote: true, hasPullRequest: true, hasShortcutStory: true
        )

        for id in ["workstream.openOnGitHub", "workstream.openPullRequest", "workstream.openInShortcut"] {
            let command = try XCTUnwrap(commands.first { $0.id == id }, id)
            XCTAssertEqual(command.availability(bare), .hidden, id)
            XCTAssertEqual(command.availability(everything), .available, id)
        }
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

    func testWorkstreamCommandSendsFocusWorkstreamWithItsID() throws {
        let workstream = Workstream(name: "one")
        let project = Project(name: "alpha", directory: "/tmp/alpha", workstreams: [workstream])
        let commands = gotoPaletteCommands(for: [project])
        let command = try XCTUnwrap(commands.first { $0.id.contains("workstream.") })

        let collector = AppCommandCollector()
        command.action()
        XCTAssertEqual(collector.sent, [.focusWorkstream(workstream.id)])
    }

    /// `.switchToProject` carries no payload and can only mean "the project of
    /// the selected workstream", so a named project jump needs `.focusProject`.
    func testProjectCommandSendsFocusProjectWithItsID() throws {
        let project = Project(name: "alpha", directory: "/tmp/alpha")
        let commands = gotoPaletteCommands(for: [project])
        let command = try XCTUnwrap(commands.first { $0.id.contains("project.") })

        let collector = AppCommandCollector()
        command.action()
        XCTAssertEqual(collector.sent, [.focusProject(project.id)])
    }
}

/// The verification family: one command per check `verification.yaml` declares,
/// synced into the registry under `verificationCommandPrefix`.
@MainActor
final class VerificationPaletteCommandTests: XCTestCase {
    func testEmitsOneCommandPerCheckUnderItsOwnPrefix() {
        let commands = verificationPaletteCommands(for: ["rspec", "rubocop"])

        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { $0.id.hasPrefix(verificationCommandPrefix) })
        XCTAssertEqual(Set(commands.map(\.id)).count, 2)
    }

    /// `CommandRegistry.sync` clears every id under the prefix it is handed, so
    /// a family under `run.` would delete `run.startRerun` and
    /// `run.rerunInitialization` on its first emission — the hazard the go-to
    /// family documents, one prefix over.
    func testNoBuiltInCommandSitsUnderTheVerificationPrefix() {
        let builtIns = defaultPaletteCommands().map(\.id)
        XCTAssertTrue(builtIns.allSatisfy { !$0.hasPrefix(verificationCommandPrefix) })
    }

    func testCommandPostsItsCheckName() throws {
        let command = try XCTUnwrap(verificationPaletteCommands(for: ["rspec"]).first)

        let posted = expectation(forNotification: .runVerificationCheck, object: nil) { note in
            note.object as? String == "rspec"
        }
        command.action()
        wait(for: [posted], timeout: 1)
    }

    /// Workstream-gated and nothing more: whether *this* check can run right now
    /// is `Verification.Runner.start`'s decision, and it loads the config again
    /// rather than trusting the list the palette drew from.
    func testCommandsAreWorkstreamGated() throws {
        let command = try XCTUnwrap(verificationPaletteCommands(for: ["rspec"]).first)

        XCTAssertFalse(command.isAvailable(PaletteContext(workstreamActive: false, editorActive: false)))
        XCTAssertTrue(command.isAvailable(PaletteContext(workstreamActive: true, editorActive: false)))
    }
}
