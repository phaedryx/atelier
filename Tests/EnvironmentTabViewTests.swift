// ABOUTME: Tests for environment tab session restoration decisions.
// ABOUTME: Verifies run panes reappear when tmux already has a persisted run session.

@testable import Atelier
import XCTest

final class EnvironmentTabViewTests: XCTestCase {
    func testRunSessionRestoresOnlyWhenTmuxSessionExists() {
        XCTAssertTrue(shouldRestoreRunSession(useTmux: true, hasRunScript: true, hasExistingRunSession: true, wasStoppedManually: false))
        XCTAssertFalse(shouldRestoreRunSession(useTmux: false, hasRunScript: true, hasExistingRunSession: true, wasStoppedManually: false))
        XCTAssertFalse(shouldRestoreRunSession(useTmux: true, hasRunScript: false, hasExistingRunSession: true, wasStoppedManually: false))
        XCTAssertFalse(shouldRestoreRunSession(useTmux: true, hasRunScript: true, hasExistingRunSession: false, wasStoppedManually: false))
    }

    func testRunSessionDoesNotRestoreAfterManualStop() {
        XCTAssertFalse(shouldRestoreRunSession(useTmux: true, hasRunScript: true, hasExistingRunSession: true, wasStoppedManually: true))
    }

    func testRunScriptWrapsInLoginShell() {
        let command = scriptCommand(script: "just local", shell: "/bin/zsh")

        XCTAssertTrue(command.hasPrefix("/bin/zsh -lic "))
        XCTAssertTrue(command.contains("just local"))
    }

    func testRunScriptCommandUsesLoginShell() {
        let command = runScriptCommand(script: "bun dev", workstreamID: UUID(), launcherPath: "/path/to/atelier-run", shell: "/bin/zsh")

        XCTAssertTrue(command.contains("/bin/zsh -lic"))
        XCTAssertFalse(command.contains("/bin/sh"))
    }

    // MARK: - What the pane displays

    private let displayCommand = "process-compose up -U -f /repo/ws/process-compose.yaml"

    private func processComposeCommand() -> DevCommand {
        DevCommand(
            command: displayCommand,
            source: .processCompose,
            sourceDescription: "process-compose.yaml"
        )
    }

    /// The pane shows which files are in play, which is what `RunCommandPlan`
    /// says the display is *for* — not a command.
    func testAProcessComposeSourceIsShownAsItsFiles() {
        let display = devCommandDisplayText(
            devCommand: processComposeCommand(),
            loadedFiles: ["/repo/ws/process-compose.yaml", "/repo/ws/process-compose.override.yml"]
        )

        XCTAssertEqual(
            display,
            "/repo/ws/process-compose.yaml  /repo/ws/process-compose.override.yml"
        )
    }

    /// The footgun this closes: the pane rendered `process-compose up -U -f …`
    /// in a monospaced font. That string carries no `-n`, so anyone who copied
    /// it into a terminal ran every namespace — `bootstrap` and `dispose`
    /// included — with no `PhasePolicy` and no `ScriptTrust`. No input may
    /// produce it.
    func testNoProcessComposeInputIsEverDisplayedAsARunnableCommand() {
        for files in [[], ["/repo/ws/process-compose.yaml"], ["/a.yaml", "/b.yml"]] {
            let display = devCommandDisplayText(
                devCommand: processComposeCommand(), loadedFiles: files
            ) ?? ""
            XCTAssertNotEqual(display, displayCommand, "files: \(files)")
            XCTAssertFalse(display.contains("up -U"), "files: \(files)")
            XCTAssertFalse(display.contains("-f "), "files: \(files)")
            XCTAssertFalse(display.contains("process-compose up"), "files: \(files)")
        }
    }

    /// With no located files there is still something honest to show — the name
    /// of the config the resolver found — rather than falling back to the
    /// command string.
    func testAProcessComposeSourceWithNoFilesFallsBackToTheFileName() {
        XCTAssertEqual(
            devCommandDisplayText(devCommand: processComposeCommand(), loadedFiles: []),
            "process-compose.yaml"
        )
    }

    /// An override is the user's own text and *is* what Start runs, so it is
    /// shown verbatim.
    func testAnOverrideIsShownAsTheCommandItIs() {
        XCTAssertEqual(
            devCommandDisplayText(
                devCommand: DevCommand(command: "just dev", source: .override, sourceDescription: nil),
                loadedFiles: ["/repo/ws/process-compose.yaml"]
            ),
            "just dev"
        )
    }

    func testNoDevCommandDisplaysNothing() {
        XCTAssertNil(devCommandDisplayText(devCommand: nil, loadedFiles: []))
    }

    // MARK: - The selection list must be reachable before Start

    /// The regression this pins: the list lived inside ProcessTableView, which
    /// renders only under `if runStarted`, so the control for choosing what to
    /// start appeared only after starting. `showsProcessSelection` takes no
    /// run state at all, which is the structural half; this is the documented
    /// half.
    func testTheSelectionListShowsForAProcessComposeRunThatHasNotStarted() {
        XCTAssertTrue(
            showsProcessSelection(showsProcessTable: true, declaredProcesses: ["bff", "api"])
        )
    }

    func testTheSelectionListIsHiddenWhenTheRunIsNotProcessCompose() {
        XCTAssertFalse(
            showsProcessSelection(showsProcessTable: false, declaredProcesses: ["bff", "api"])
        )
    }

    /// An unparseable config yields no declared processes, and an empty list of
    /// checkboxes is worse than none: it reads as "this project has no
    /// processes" rather than "Atelier could not read the file".
    func testTheSelectionListIsHiddenWithNoDeclaredProcesses() {
        XCTAssertFalse(showsProcessSelection(showsProcessTable: true, declaredProcesses: []))
    }
}
