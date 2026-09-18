// ABOUTME: Tests for what the Execution pane renders — the dev-command display and the checklist gate.
// ABOUTME: The run lifecycle's own rules moved with it; see RunSessionTests.

@testable import Atelier
import XCTest

final class ExecutionTabViewTests: XCTestCase {
    // MARK: - What the pane displays

    private let displayCommand = "process-compose up -U -f /repo/execution.process-compose.yaml"

    private func processComposeCommand() -> DevCommand {
        DevCommand(
            command: displayCommand,
            source: .processCompose,
            sourceDescription: "execution.process-compose.yaml"
        )
    }

    /// The pane shows which files are in play, which is what `ProcessCompose.RunCommandPlan`
    /// says the display is *for* — not a command.
    func testAProcessComposeSourceIsShownAsItsFiles() {
        let display = devCommandDisplayText(
            devCommand: processComposeCommand(),
            loadedFiles: ["/repo/execution.process-compose.yaml"]
        )

        XCTAssertEqual(display, "/repo/execution.process-compose.yaml")
    }

    /// `loadedFiles` is a list, and the display joins it, so that the pane stays
    /// honest if a config ever loads more than one file again.
    func testSeveralLoadedFilesAreAllShown() {
        let display = devCommandDisplayText(
            devCommand: processComposeCommand(),
            loadedFiles: ["/repo/a.yaml", "/repo/b.yaml"]
        )

        XCTAssertEqual(display, "/repo/a.yaml  /repo/b.yaml")
    }

    /// The footgun this closes: the pane rendered `process-compose up -U -f …`
    /// in a monospaced font. That string carries no `-n`, so anyone who copied
    /// it into a terminal ran every namespace — `bootstrap` and `dispose`
    /// included — with no `PhasePolicy` and no `ScriptTrust`. No input may
    /// produce it.
    func testNoProcessComposeInputIsEverDisplayedAsARunnableCommand() {
        for files in [[], ["/repo/execution.process-compose.yaml"], ["/a.yaml", "/b.yml"]] {
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
            "execution.process-compose.yaml"
        )
    }

    /// An override is the user's own text and *is* what Start runs, so it is
    /// shown verbatim.
    func testAnOverrideIsShownAsTheCommandItIs() {
        XCTAssertEqual(
            devCommandDisplayText(
                devCommand: DevCommand(command: "just dev", source: .override, sourceDescription: nil),
                loadedFiles: ["/repo/execution.process-compose.yaml"]
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
            showsProcessSelection(
                runStarted: false, showsProcessTable: true, declaredProcesses: ["bff", "api"]
            )
        )
    }

    /// The other half of the same defect. The selection is read when Start is
    /// pressed, so a checkbox toggled during a run changes nothing until the
    /// next Stop and Start — an editable control that silently does nothing.
    func testTheSelectionListIsHiddenOnceTheRunHasStarted() {
        XCTAssertFalse(
            showsProcessSelection(
                runStarted: true, showsProcessTable: true, declaredProcesses: ["bff", "api"]
            )
        )
    }

    func testTheSelectionListIsHiddenWhenTheRunIsNotProcessCompose() {
        XCTAssertFalse(
            showsProcessSelection(
                runStarted: false, showsProcessTable: false, declaredProcesses: ["bff", "api"]
            )
        )
    }

    /// An unparseable config yields no declared processes, and an empty list of
    /// checkboxes is worse than none: it reads as "this project has no
    /// processes" rather than "Atelier could not read the file".
    func testTheSelectionListIsHiddenWithNoDeclaredProcesses() {
        XCTAssertFalse(
            showsProcessSelection(
                runStarted: false, showsProcessTable: true, declaredProcesses: []
            )
        )
    }

    // MARK: - Process selection toggling

    /// The reported bug, pinned twice over. Unchecking the last box used to
    /// store empty, which the view read back as "all": every checkbox
    /// re-checked itself and Start ran the whole namespace — the opposite of
    /// what was asked. The fix for *that* was to refuse the click, which left a
    /// checkbox dimmed for a reason nothing on the pane gave. It is now a state
    /// of its own, and Start is what goes quiet.
    func testUncheckingTheLastSelectedProcessLeavesNothingSelected() {
        XCTAssertEqual(
            processSelectionAfterToggling("b", on: false, current: .only(["b"]), declared: ["a", "b"]),
            .nothing
        )
    }

    /// The same click from the untouched state, where `.all` means every
    /// process: it must narrow to the others, never to nothing.
    func testUncheckingFromTheAllSelectedStateNarrows() {
        XCTAssertEqual(
            processSelectionAfterToggling("a", on: false, current: .all, declared: ["a", "b"]),
            .only(["b"])
        )
    }

    /// A single-process config has one box, and unchecking it is the whole
    /// selection going away — `.all` and `.nothing` name the same one process
    /// here, so only the type keeps them apart.
    func testUncheckingTheLastOfASingleProcessConfigLeavesNothingSelected() {
        XCTAssertEqual(
            processSelectionAfterToggling("only", on: false, current: .all, declared: ["only"]),
            .nothing
        )
    }

    /// Checking a box from nothing selected is how the user gets back, and the
    /// last one they check must canonicalise to `.all` like any other route to
    /// a full selection.
    func testCheckingABoxFromNothingSelectedStartsASubset() {
        XCTAssertEqual(
            processSelectionAfterToggling("a", on: true, current: .nothing, declared: ["a", "b"]),
            .only(["a"])
        )
        XCTAssertEqual(
            processSelectionAfterToggling("only", on: true, current: .nothing, declared: ["only"]),
            .all
        )
    }

    /// Re-checking everything canonicalises back to `.all`, so a process added
    /// to the YAML later is included instead of silently dropped.
    func testSelectingEveryProcessStoresAll() {
        XCTAssertEqual(
            processSelectionAfterToggling("a", on: true, current: .only(["b"]), declared: ["a", "b"]),
            .all
        )
    }

    func testCheckingAnotherProcessKeepsAnExplicitSubsetSorted() {
        XCTAssertEqual(
            processSelectionAfterToggling("b", on: true, current: .only(["c"]), declared: ["a", "b", "c"]),
            .only(["b", "c"])
        )
    }

    // MARK: - Reconciling a stored selection with the config

    /// Rename a process in the YAML and the stored name matched nothing, so
    /// every checkbox rendered unchecked and Start passed a name
    /// process-compose does not know.
    func testANameThatNoLongerExistsIsDropped() {
        XCTAssertEqual(
            processSelectionOnLoad(stored: .only(["gone", "bff"]), declared: ["api", "bff"]),
            .only(["bff"])
        )
    }

    /// Everything chosen is gone: fall back to all, which is what a fresh
    /// workstream gets. Not `.nothing` — a config edit the user did not make
    /// must not come back to them as a choice they made.
    func testASelectionWithNothingSurvivingBecomesAll() {
        XCTAssertEqual(processSelectionOnLoad(stored: .only(["gone", "also-gone"]), declared: ["api"]), .all)
    }

    /// And the other direction: an explicit empty selection is a choice, so no
    /// amount of reconciling turns it into "run everything".
    func testNothingSelectedSurvivesReconciliation() {
        XCTAssertEqual(processSelectionOnLoad(stored: .nothing, declared: ["api", "bff"]), .nothing)
        XCTAssertNil(processesToStart(stored: .nothing, declared: ["api", "bff"]))
    }

    func testASelectionCoveringEveryProcessCanonicalisesToAll() {
        XCTAssertEqual(processSelectionOnLoad(stored: .only(["api", "bff"]), declared: ["bff", "api"]), .all)
    }

    func testAnUntouchedSelectionStaysUntouched() {
        XCTAssertEqual(processSelectionOnLoad(stored: .all, declared: ["api", "bff"]), .all)
    }

    // MARK: - Names a run could not be scoped to

    /// The finding: a process named `-web` is legal YAML, so it was declared,
    /// offered in the checklist and stored — and then dropped by
    /// `PhaseRunner.command` on its way to the shell. As the *only* selection
    /// the filtered list was empty, which `up -n execute` reads as "start
    /// everything": the user's selection inverted into its opposite, through a
    /// guard that exists for security. It resolves to the canonical empty "all"
    /// here instead, which is what the checklist renders for a selection
    /// nothing survived.
    func testASelectionOfOnlyAFlagShapedNameDoesNotSurviveAsASelection() {
        XCTAssertEqual(processesToStart(stored: .only(["-web"]), declared: ["api", "-web"]), [])
    }

    /// The quieter half: a mixed selection had its flag-shaped member dropped
    /// somewhere the user could not see. It is not offered now, so the
    /// resolution names exactly what the checkboxes showed.
    func testAMixedSelectionKeepsOnlyTheNamesARunCanBeScopedTo() {
        XCTAssertEqual(
            processesToStart(stored: .only(["-web", "api"]), declared: ["api", "-web", "bff"]),
            ["api"]
        )
    }

    /// A flag-shaped name is not a declared process as far as the checklist is
    /// concerned, so selecting everything else is still "all" — and all is what
    /// starts it, since an empty selection passes no names at all.
    func testSelectingEveryRunnableProcessIsStillAll() {
        XCTAssertEqual(processesToStart(stored: .only(["api", "bff"]), declared: ["api", "-web", "bff"]), [])
    }

    /// The reconciliation the checklist does on load, done again for the run:
    /// Start is reachable from the palette and Cmd+Shift+Return without the
    /// Execution tab ever having been opened, so a stale stored name would
    /// otherwise reach `up -n execute`, which does not know it.
    func testARunReconcilesAStaleStoredNameWithoutTheChecklist() {
        XCTAssertEqual(processesToStart(stored: .only(["gone", "bff"]), declared: ["api", "bff"]), ["bff"])
    }

    // MARK: - Keeping Start reachable under the checklist

    /// The vertical list is the layout that pushed Start off the pane once
    /// already. Above the cap it stops growing and scrolls instead.
    func testALongChecklistIsCappedSoStartKeepsItsPlace() {
        XCTAssertEqual(processChecklistHeight(count: 20, rowHeight: 20, visibleRows: 8), 160)
        XCTAssertEqual(processChecklistHeight(count: 9, rowHeight: 20, visibleRows: 8), 160)
    }

    /// And below the cap it is exactly as tall as its rows — one fixed height
    /// for every list would give a small project rows of dead space above its
    /// Start button, which is the same theft by another route.
    func testAShortChecklistIsExactlyAsTallAsItsRows() {
        XCTAssertEqual(processChecklistHeight(count: 3, rowHeight: 20, visibleRows: 8), 60)
        XCTAssertEqual(processChecklistHeight(count: 8, rowHeight: 20, visibleRows: 8), 160)
    }

    /// `ExecutionTabView` does not render the checklist for an empty config,
    /// but a zero-height scroll view is a bad thing to depend on that for.
    func testAnEmptyChecklistStillHasARowOfHeight() {
        XCTAssertEqual(processChecklistHeight(count: 0, rowHeight: 20, visibleRows: 8), 20)
    }

    // MARK: - Selection storage

    /// `ProcessSelectionStore.execute` is a thin closure pair over
    /// `ProcessCompose.TableModel`; this is the direct proof the pair itself
    /// round-trips, now that Verification has no store of its own to compare
    /// it against.
    func test_executeSelectionStore_roundTrips() {
        let id = UUID()
        addTeardownBlock { ProcessSelectionStore.execute.write(.all, id) }
        ProcessSelectionStore.execute.write(.only(["bff"]), id)
        XCTAssertEqual(ProcessSelectionStore.execute.read(id), .only(["bff"]))
    }

    // MARK: - Keeping the terminal's share of the run pane

    /// A `Table` is greedy in both axes, where the rows it replaced were
    /// intrinsically sized, so the height is capped rather than negotiated in
    /// the layout: past the cap the table scrolls and the terminal below it
    /// keeps the rest of the pane.
    func testALongProcessTableIsCappedSoTheTerminalKeepsItsSpace() {
        XCTAssertEqual(processTableHeight(count: 30, rowHeight: 24, headerHeight: 28, visibleRows: 8), 28 + 192)
        XCTAssertEqual(processTableHeight(count: 9, rowHeight: 24, headerHeight: 28, visibleRows: 8), 28 + 192)
    }

    /// And below the cap it is exactly as tall as its rows plus its header —
    /// one fixed height for every stack would hand a two-process project rows
    /// of dead space between its table and its terminal.
    func testAShortProcessTableIsExactlyAsTallAsItsRowsAndHeader() {
        XCTAssertEqual(processTableHeight(count: 2, rowHeight: 24, headerHeight: 28, visibleRows: 8), 28 + 48)
        XCTAssertEqual(processTableHeight(count: 8, rowHeight: 24, headerHeight: 28, visibleRows: 8), 28 + 192)
    }

    /// The header is always paid for, and a table that is somehow empty still
    /// reserves one row: the view renders "Nothing running." instead in that
    /// case, but the arithmetic must not go below a header plus a row if it is
    /// ever asked.
    func testTheProcessTableAlwaysReservesItsHeaderAndOneRow() {
        XCTAssertEqual(processTableHeight(count: 0, rowHeight: 24, headerHeight: 28, visibleRows: 8), 28 + 24)
    }
}
