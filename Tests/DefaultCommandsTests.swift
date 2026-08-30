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

    func testWorkstreamCommandsRequireAnActiveWorkstream() {
        let commands = defaultPaletteCommands()
        let noWorkstream = PaletteContext(workstreamActive: false, editorActive: false)
        let terminal = commands.first { $0.id == "tab.newTerminal" }!
        let settings = commands.first { $0.id == "app.settings" }!

        XCTAssertFalse(terminal.isAvailable(noWorkstream))
        XCTAssertTrue(settings.isAvailable(noWorkstream))
    }

    func testEditorCommandsRequireAnActiveEditor() {
        let commands = defaultPaletteCommands()
        let workstreamOnly = PaletteContext(workstreamActive: true, editorActive: false)
        let editorToo = PaletteContext(workstreamActive: true, editorActive: true)
        let findFile = commands.first { $0.id == "editor.findFile" }!

        XCTAssertFalse(findFile.isAvailable(workstreamOnly))
        XCTAssertTrue(findFile.isAvailable(editorToo))
    }

    func testEnvironmentCommandPostsToggleEnvironment() {
        let commands = defaultPaletteCommands()
        let environment = commands.first { $0.id == "tab.environment" }!
        let posted = expectation(forNotification: .toggleEnvironment, object: nil)

        environment.action()

        wait(for: [posted], timeout: 1)
    }

    func testNewTerminalCommandPostsToggleTerminal() {
        let commands = defaultPaletteCommands()
        let terminal = commands.first { $0.id == "tab.newTerminal" }!
        let posted = expectation(forNotification: .toggleTerminal, object: nil)

        terminal.action()

        wait(for: [posted], timeout: 1)
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
