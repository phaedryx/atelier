// ABOUTME: The Execution tab's live process table with per-process controls.
// ABOUTME: State comes from process-compose's API; ports come from the port plan.

import SwiftUI

/// The height of one process-table row.
///
/// Pinned rather than inferred, for the reason `processChecklistRowHeight` is:
/// `processTableHeight` multiplies by it to decide the table's frame, so a row
/// that renders at some other height would make that arithmetic a guess.
///
/// Deliberately **not** shared with `processChecklistRowHeight`, which is the
/// intrinsic height of a checkbox control. This is a `Table` row's own chrome
/// around an 11pt label; the two numbers describe different things and have no
/// reason to stay equal.
///
/// Both numbers here are **measured, not chosen**: under `.tableStyle(.inset)`
/// the backing `NSTableView` reports `rowHeight == 24` and a header view
/// exactly 28 points tall. They are duplicated here because nothing exposes
/// them to the layout in time to be read, so a change to the table's style is
/// a reason to re-measure rather than to reason about.
let processTableRowHeight: CGFloat = 24

/// The height of the table's header row, measured the same way and for the
/// same reason. Separate from the row height because it is added once rather
/// than multiplied, and because the header is the thing this table gained.
let processTableHeaderHeight: CGFloat = 28

/// How tall the process table is: a header plus one row each, up to
/// `visibleRows`, and then it scrolls.
///
/// A `Table` is greedy in both axes, where the `HStack` rows it replaced were
/// intrinsically sized. Left unframed it takes the pane from the terminal
/// below it, which is the surface a run is actually read in — so growth is
/// capped here rather than negotiated in the layout. Below the cap it is
/// exactly as tall as its contents, for the reason `processChecklistHeight`
/// gives: a fixed height would hand a two-process stack six rows of dead space
/// above its terminal.
///
/// A free function, like its neighbours, so both ends can be tested without a
/// view.
func processTableHeight(
    count: Int,
    rowHeight: CGFloat = processTableRowHeight,
    headerHeight: CGFloat = processTableHeaderHeight,
    visibleRows: Int = 8
) -> CGFloat {
    headerHeight + CGFloat(min(max(count, 1), visibleRows)) * rowHeight
}

struct ProcessTableView: View {
    @ObservedObject var model: ProcessCompose.TableModel
    /// Variable name to port, so a row can show the port it owns.
    let portsByName: [String: String]

    /// Name-ascending to start with.
    ///
    /// The rows used to render in whatever order process-compose's API
    /// returned them. Sorting them here makes the order a property of the
    /// table, which is the rule `ProcessSelectionView.sortedProcesses` already
    /// states for the checklist that names the same processes — and the two
    /// lists reading differently was its own small lie.
    ///
    /// Sorting is on the status *string* rather than on `isRunning`, for the
    /// column that offers it: the string is what the row displays, and
    /// grouping equal strings together is what a user scanning thirty
    /// processes for the ones that are not up actually wants.
    @State private var sortOrder = [KeyPathComparator(\ProcessCompose.ProcessEntry.name)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            // Kept as a sentence rather than becoming a headered empty table.
            // "Nothing running." is a statement about the *run*, not about what
            // the project declares, and five column headings over no rows is
            // more chrome carrying less of it.
            if model.processes.isEmpty {
                Text("Nothing running.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                table
            }
        }
        // On the outer stack, not per-`Text`: selectability travels through the
        // environment, so one modifier covers every label a row renders and any
        // added later. The `Button`s are unaffected — they are controls, and a
        // control's label is not selectable text.
        //
        // It still reaches a `Table`'s cells, which was the open question when
        // the rows stopped being an `HStack`: a cell is hosted in its own
        // `TableCellHostingView` inside an `NSTableView`, and the environment
        // crosses that boundary. Verified by hand against this table and the
        // stack it replaced, side by side — drag-select a process name, copy,
        // and both yield the text. Keep the modifier here rather than moving it
        // onto the `Table`: the "Nothing running." sentence is a label too.
        //
        // The terminal beside this table needs no equivalent. `execute` is the
        // one phase that runs with process-compose's TUI (`PhaseRunner.command`
        // appends `-t=false` only for the non-interactive ones), and a TUI that
        // grabs the mouse is exactly what shift-drag exists to override — see
        // ghostty's `mouse-shift-capture`, which Atelier leaves at its default.
        // This modifier is for the rows the TUI does not draw.
        .textSelection(.enabled)
    }

    /// No selection binding, deliberately. Nothing in this pane acts on "the
    /// selected process" — every action is a button on its own row — so a
    /// selection would be a gesture with no meaning, and one that the
    /// borderless buttons in the trailing column would then have to compete
    /// with for the click.
    private var table: some View {
        Table(model.processes.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { process in
                Text(process.name)
                    .font(.system(size: 11, design: .monospaced))
            }
            .width(min: 90, ideal: 160)

            TableColumn("Namespace", value: \.namespace) { process in
                Text(process.namespace)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Status", value: \.status) { process in
                Text(process.status)
                    .font(.system(size: 11))
                    .foregroundStyle(process.isRunning ? Color.green : Color.secondary)
            }
            .width(min: 60, ideal: 90)

            // Only meaningful when the process declares a probe; otherwise the
            // API reports "-" and a tick would be a lie. The blank now sits
            // under a heading that names the column, which is what it was
            // missing: an empty cell in an unlabelled 24-point strip was
            // indistinguishable from a column that was not there.
            //
            // Not sortable: it is derived from two fields rather than being one.
            TableColumn("Ready") { process in
                Text(process.hasReadyProbe ? process.isReady : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 56)

            // Not sortable either: the value comes from the port plan passed in,
            // not from `ProcessEntry`, so there is no key path to compare on —
            // and inventing a stored property on the model to make one would put
            // the plan inside the row.
            TableColumn("Port") { process in
                portCell(for: process)
            }
            .width(min: 48, ideal: 60)

            // Unlabelled on purpose. Buttons say what they do, and a heading
            // over them would name the column after the controls in it.
            TableColumn("") { process in
                controls(for: process)
            }
            .width(min: 100, ideal: 124)
        }
        .tableStyle(.inset)
        .frame(height: processTableHeight(count: model.processes.count))
    }

    private func controls(for process: ProcessCompose.ProcessEntry) -> some View {
        HStack(spacing: 8) {
            if process.isRunning {
                Button("Stop") { Task { await model.stop(process.name) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("Restart") { Task { await model.restart(process.name) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Button("Start") { Task { await model.start(process.name) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
    }

    /// The port this process owns, matched by name against the port plan. An em
    /// dash rather than a blank, so an unmatched name reads as "no port known"
    /// instead of as a rendering gap. Not localized: the value is a `String`
    /// rather than a literal, and an em dash is punctuation, not prose.
    private func portCell(for process: ProcessCompose.ProcessEntry) -> some View {
        Text(ProcessCompose.TableModel.port(for: process.name, in: portsByName) ?? "\u{2014}")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

/// The selection to store after toggling one checkbox.
///
/// `current` is the stored selection, where `.all` is canonical for "every
/// declared process" — that is what `ProcessCompose.PhaseRunner` already means
/// by an empty name list, since `up -n execute` with no names starts the whole
/// namespace, and keeping it canonical is what lets a project add a process to
/// its YAML and have it included automatically.
///
/// Unchecking the last box gives `.nothing`, which is a state and not a
/// refusal. It used to be refused — the last checked box was `.disabled`, so a
/// selection could never empty — because the store had no way to say "nothing"
/// that the view did not read back as "all". `ProcessSelection` has one now, so
/// the click is accepted and the Start button is what goes quiet.
func processSelectionAfterToggling(
    _ name: String,
    on isOn: Bool,
    current: ProcessSelection,
    declared: [String]
) -> ProcessSelection {
    let all = Set(declared)
    var next: Set<String> = switch current {
    case .all:
        all
    case .nothing:
        []
    case let .only(names):
        Set(names)
    }
    if isOn {
        next.insert(name)
    } else {
        next.remove(name)
    }
    if next.isEmpty {
        return .nothing
    }
    return next == all ? .all : .only(next.sorted())
}

/// The stored selection, reconciled against what the config declares now.
///
/// A selection persists per workstream while the YAML it names does not. Rename
/// or remove a process and the stored name rides along forever: it matches
/// nothing, so the selection is a non-empty subset containing none of the real
/// names — every checkbox renders unchecked — and Start passes the dead name to
/// `up -n execute`, which does not know it.
///
/// Names that no longer exist are dropped. If nothing survives, the result is
/// `.all` — the same answer a fresh workstream gets, and the only sane reading
/// of "everything I chose is gone". That is deliberately *not* `.nothing`:
/// nothing selected is a thing the user did, and a config edit they did not
/// make must not be reported back to them as a choice they made.
///
/// `.nothing` itself survives any config change, for the same reason: it names
/// no processes, so there is nothing in it for a rename to invalidate.
func processSelectionOnLoad(stored: ProcessSelection, declared: [String]) -> ProcessSelection {
    switch stored {
    case .all:
        return .all
    case .nothing:
        return .nothing
    case let .only(names):
        let surviving = Set(names).intersection(declared)
        return surviving.isEmpty || surviving == Set(declared) ? .all : .only(surviving.sorted())
    }
}

/// Where a checklist's selection is stored.
///
/// Injected rather than reached for, which is what makes `ProcessSelectionView`
/// testable and reusable. `.execute` is the only member now — Verification had
/// its own key and its own constant here, keyed separately for a reason worth
/// keeping: one key for both would have made checking a check in Verification
/// uncheck a process in Execution. Verification's checklist was removed along
/// with that key; Execution's is what is left.
struct ProcessSelectionStore: Sendable {
    let read: @Sendable (UUID) -> ProcessSelection
    let write: @Sendable (ProcessSelection, UUID) -> Void

    static let execute = ProcessSelectionStore(
        read: { ProcessCompose.TableModel.selection(for: $0) },
        write: { ProcessCompose.TableModel.setSelection($0, for: $1) }
    )
}

/// The height of one checklist row.
///
/// Pinned rather than inferred. `processChecklistHeight` multiplies by it to
/// decide the list's frame, so a row that renders at some other height would
/// make that arithmetic a guess: a checkbox's intrinsic height comes from the
/// control, not from the 11pt label, and undershooting it by two points would
/// scroll a three-process list that was meant to fit exactly. The rows are
/// given this height explicitly so the sum is right by construction.
let processChecklistRowHeight: CGFloat = 20

/// How tall the checklist is: one row each, up to `visibleRows`, and then it
/// scrolls.
///
/// The choices used to wrap into an adaptive grid, because a vertical column of
/// six processes pushed the Start button off the useful part of the pane. The
/// list is vertical again by request, so that failure is prevented here instead
/// of by the layout: past `visibleRows` entries the column stops growing.
///
/// The cap outlived the layout that needed it and is still the right rule. In
/// `ExecutionTabView`'s control section the checklist sits between the dev
/// command and the buttons, both anchored to the top left, so a long list can
/// no longer push Start off the pane — but it can push it past the process
/// table and the terminal the section sits above, turning a corner of controls
/// into most of the tab.
///
/// Exactly as tall as its contents below the cap, which matters as much as the
/// cap itself — a single fixed height would hand a three-process project five
/// rows of dead space between its checkboxes and its Start button, which is
/// the same theft by another route.
///
/// A free function, like its neighbours, so both ends can be tested without a
/// view.
func processChecklistHeight(
    count: Int,
    rowHeight: CGFloat = processChecklistRowHeight,
    visibleRows: Int = 8
) -> CGFloat {
    CGFloat(min(max(count, 1), visibleRows)) * rowHeight
}

/// Which of `execute`'s processes the Start button will launch.
///
/// A view of its own rather than a section of the process table, which is where
/// it used to live: the table only renders once a run exists, so the control
/// for choosing what to start was unreachable until after starting — the one
/// moment it is no use.
///
/// Rendered **before a run only** — see `showsProcessSelection`'s own doc for
/// why. Execution is this view's only caller now: Verification once rendered
/// it too, under the same rule, before its checklist was removed entirely. A
/// stale version of this comment claimed Verification kept the list visible
/// and merely `.disabled(isLive)` it during a run; that let a user click a box
/// that could not take effect, since the runner read the stored selection
/// only when Start was pressed. Hiding it before a run was the fix.
///
/// The choices come from the config rather than from the live API for the same
/// reason it moved out of the table: before Start there is nothing running to
/// enumerate.
///
/// **Every box may be unchecked.** The last checked one used to be `.disabled`,
/// so a selection could never empty — the store had no way to say "nothing"
/// that this view did not read back as "all". It has one now
/// (`ProcessSelection`), and the consequence of an empty checklist is that the
/// button which would start it is disabled and says why: `runControls` for
/// Execution, `actionRow` for Verification. The refusal moved to where it can
/// be explained, rather than living here as a checkbox that dimmed for reasons
/// only a tooltip on a disabled control could have given.
struct ProcessSelectionView: View {
    let workstreamID: UUID
    let declaredProcesses: [String]
    let store: ProcessSelectionStore
    /// Told that the stored selection changed — including the reconciled value
    /// `onAppear` writes back, which is a change the user did not make and the
    /// owner still has to hear about.
    ///
    /// A bare ping, carrying no value on purpose. The owner re-reads the store,
    /// which is the one authoritative copy; handing it the new selection here
    /// would invite it to keep a second one, and a second copy is free to
    /// disagree with what Start would actually run.
    let onSelectionChange: () -> Void

    @State private var selection: ProcessSelection = .all

    /// A bare vertical checklist, with no heading and no "All" button.
    ///
    /// The heading named a pane that no longer exists: sitting between the dev
    /// command and Start, a column of checkboxes reads as the thing Start will
    /// run without a label saying so. "All" went with it — checking every box
    /// canonicalises back to `.all` on its own, so it was a shortcut for
    /// something the checkboxes already do.
    ///
    /// Always a `ScrollView`, even for the two-process case that cannot
    /// overflow. Branching on the count instead would give the two shapes
    /// different view identities, so crossing the cap — a process added to the
    /// YAML — would tear the subtree down and re-fire `onAppear`. One arm, one
    /// identity; `processChecklistHeight` is what makes the short case look
    /// like no scroll view at all.
    ///
    /// Sized to its rows in *both* directions, which is why there is no
    /// `maxWidth: .infinity` and no horizontal padding here. `ExecutionTabView`
    /// renders this in a leading-aligned column with the dev command above it
    /// and the buttons below, and that column already owns the padding; a
    /// `ScrollView` is greedy across its scroll axis, so without
    /// `fixedSize(horizontal:)` this one would stretch to the pane's full width
    /// and hang a scroll gutter off the far right of a group nothing else in it
    /// reaches.
    ///
    /// `defaultScrollAnchor(.top)` because otherwise a list past the cap opens
    /// scrolled to the *bottom* — a ten-process config rendered `proc-03` first
    /// and hid the two above it with no sign they were there. A checklist whose
    /// first rows are off-screen on arrival is worse than one that is too tall.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sortedProcesses, id: \.self) { name in
                    Toggle(isOn: binding(for: name)) {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .frame(height: processChecklistRowHeight)
                }
            }
        }
        .defaultScrollAnchor(.top)
        .frame(height: processChecklistHeight(count: sortedProcesses.count))
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            // Written back, not just filtered for display: otherwise Start
            // keeps reading the stale name straight out of UserDefaults.
            persist(processSelectionOnLoad(
                stored: store.read(workstreamID),
                declared: declaredProcesses
            ))
        }
    }

    /// Alphabetical, and sorted here rather than trusted from the caller so
    /// the order is a property of the list itself.
    private var sortedProcesses: [String] {
        declaredProcesses.sorted()
    }

    /// Which boxes are ticked. `.all` is canonical for "everything", because
    /// that is what `ProcessCompose.PhaseRunner` already means by an empty name
    /// list: `up -n execute` with no names starts the whole namespace, so a
    /// project that adds a process to its YAML picks it up automatically
    /// instead of being silently excluded.
    private func isSelected(_ name: String) -> Bool {
        switch selection {
        case .all:
            true
        case .nothing:
            false
        case let .only(names):
            names.contains(name)
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { isSelected(name) },
            set: { isOn in
                persist(processSelectionAfterToggling(
                    name, on: isOn, current: selection, declared: declaredProcesses
                ))
            }
        )
    }

    private func persist(_ canonical: ProcessSelection) {
        selection = canonical
        store.write(canonical, workstreamID)
        onSelectionChange()
    }
}
