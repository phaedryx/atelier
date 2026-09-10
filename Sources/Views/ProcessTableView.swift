// ABOUTME: The Execution tab's live process table with per-process controls.
// ABOUTME: State comes from process-compose's API; ports come from the port plan.

import SwiftUI

struct ProcessTableView: View {
    @ObservedObject var model: ProcessCompose.TableModel
    /// Variable name to port, so a row can show the port it owns.
    let portsByName: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if model.processes.isEmpty {
                Text("Nothing running.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.processes) { process in
                    row(for: process)
                }
            }
        }
        // On the outer stack, not per-`Text`: selectability travels through the
        // environment, so one modifier covers every label a row renders and any
        // added later. The `Button`s are unaffected — they are controls, and a
        // control's label is not selectable text.
        //
        // The terminal beside this table needs no equivalent. `execute` is the
        // one phase that runs with process-compose's TUI (`PhaseRunner.command`
        // appends `-t=false` only for the non-interactive ones), and a TUI that
        // grabs the mouse is exactly what shift-drag exists to override — see
        // ghostty's `mouse-shift-capture`, which Atelier leaves at its default.
        // This modifier is for the rows the TUI does not draw.
        .textSelection(.enabled)
    }

    private func row(for process: ProcessCompose.ProcessEntry) -> some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 140, alignment: .leading)

            Text(process.namespace)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)

            Text(process.status)
                .font(.system(size: 11))
                .foregroundStyle(process.isRunning ? Color.green : Color.secondary)
                .frame(width: 80, alignment: .leading)

            // Only meaningful when the process declares a probe; otherwise the
            // API reports "-" and a tick would be a lie.
            Text(process.hasReadyProbe ? process.isReady : "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            portCell(for: process)

            Spacer()

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    /// The port this process owns, matched by name against the port plan. An em
    /// dash rather than a blank, so an unmatched name reads as "no port known"
    /// instead of as a rendering gap. Not localized: the value is a `String`
    /// rather than a literal, and an em dash is punctuation, not prose.
    private func portCell(for process: ProcessCompose.ProcessEntry) -> some View {
        Text(ProcessCompose.TableModel.port(for: process.name, in: portsByName) ?? "\u{2014}")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
    }
}

/// The selection to store after toggling one checkbox, or nil if the toggle
/// must be refused.
///
/// `current` is the stored selection, where **empty means all** — that is what
/// `ProcessCompose.PhaseRunner` already means by it, since `up -n execute` with no names
/// starts the whole namespace. Keeping "all" canonical as empty is what lets a
/// project add a process to its YAML and have it included automatically.
///
/// The trap is that "nothing selected" wants the same representation. Storing
/// it made unchecking the last box self-contradictory: it stored empty, the
/// view read empty back as *all*, every checkbox re-checked itself, and Start
/// then ran the entire namespace — the opposite of what was asked. There is no
/// third state to store, because process-compose has no way to express "start
/// nothing"; so the toggle is refused instead, and the view disables that last
/// checkbox rather than accepting a click it would have to undo.
func processSelectionAfterToggling(
    _ name: String,
    on isOn: Bool,
    current: Set<String>,
    declared: [String]
) -> [String]? {
    let all = Set(declared)
    var next = current.isEmpty ? all : current
    if isOn {
        next.insert(name)
    } else {
        next.remove(name)
    }
    guard !next.isEmpty else { return nil }
    return next == all ? [] : next.sorted()
}

/// The stored selection, reconciled against what the config declares now.
///
/// A selection persists per workstream while the YAML it names does not. Rename
/// or remove a process and the stored name rides along forever: it matches
/// nothing, so `effectiveSelection` is non-empty but contains none of the real
/// names — every checkbox renders unchecked — and Start passes the dead name to
/// `up -n execute`, which does not know it.
///
/// Names that no longer exist are dropped. If nothing survives, the result is
/// empty, which is the canonical "all" — the same answer a fresh workstream
/// gets, and the only sane reading of "everything I chose is gone".
func processSelectionOnLoad(stored: [String], declared: [String]) -> [String] {
    let surviving = Set(stored).intersection(declared)
    return surviving.isEmpty || surviving == Set(declared) ? [] : surviving.sorted()
}

/// Where a checklist's selection is stored.
///
/// Injected rather than reached for, because there are now two checklists over
/// two namespaces: Execution's picks what `execute` starts, Verification's picks
/// which checks run. One key for both would make checking `rspec` uncheck `bff`.
struct ProcessSelectionStore: Sendable {
    let read: @Sendable (UUID) -> [String]
    let write: @Sendable ([String], UUID) -> Void

    static let execute = ProcessSelectionStore(
        read: { ProcessCompose.TableModel.selected(for: $0) },
        write: { ProcessCompose.TableModel.setSelected($0, for: $1) }
    )

    static let verify = ProcessSelectionStore(
        read: { Verification.selected(for: $0) },
        write: { Verification.setSelected($0, for: $1) }
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
/// Rendered **before a run only**, which is `showsProcessSelection`'s call and
/// documented there; a stale version of this comment claimed both states, and
/// leaving it editable mid-run was the other half of the same defect.
///
/// The choices come from the config rather than from the live API for the same
/// reason it moved out of the table: before Start there is nothing running to
/// enumerate.
struct ProcessSelectionView: View {
    let workstreamID: UUID
    let declaredProcesses: [String]
    let store: ProcessSelectionStore
    let lastSelectedHelp: String

    @State private var selection: Set<String> = []

    /// A bare vertical checklist, with no heading and no "All" button.
    ///
    /// The heading named a pane that no longer exists: sitting between the dev
    /// command and Start, a column of checkboxes reads as the thing Start will
    /// run without a label saying so. "All" went with it — checking every box canonicalises
    /// back to the stored empty set on its own, so it was a shortcut for
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
                    .disabled(isLastSelected(name))
                    .help(isLastSelected(name) ? lastSelectedHelp : "")
                }
            }
        }
        .defaultScrollAnchor(.top)
        .frame(height: processChecklistHeight(count: sortedProcesses.count))
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            let cleaned = processSelectionOnLoad(
                stored: store.read(workstreamID),
                declared: declaredProcesses
            )
            selection = Set(cleaned)
            // Written back, not just filtered for display: otherwise Start
            // keeps reading the stale name straight out of UserDefaults.
            store.write(cleaned, workstreamID)
        }
    }

    /// Alphabetical, and sorted here rather than trusted from the caller so
    /// the order is a property of the list itself.
    private var sortedProcesses: [String] {
        declaredProcesses.sorted()
    }

    /// What Start will run.
    ///
    /// Stored empty when everything is selected, because that is what
    /// `ProcessCompose.PhaseRunner` already means by empty: `up -n execute` with no names
    /// starts the whole namespace. Keeping "all" canonical as empty means a
    /// project that adds a process to its YAML picks it up automatically
    /// instead of silently excluding it.
    private var effectiveSelection: Set<String> {
        selection.isEmpty ? Set(declaredProcesses) : selection
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { effectiveSelection.contains(name) },
            set: { isOn in
                guard let next = processSelectionAfterToggling(
                    name, on: isOn, current: selection, declared: declaredProcesses
                ) else { return }
                persist(next)
            }
        )
    }

    /// Whether unchecking this one would leave nothing selected. Disabled
    /// rather than silently refused, so the state reads as unavailable instead
    /// of as a click that did nothing.
    private func isLastSelected(_ name: String) -> Bool {
        effectiveSelection == [name]
    }

    private func persist(_ canonical: [String]) {
        selection = Set(canonical)
        store.write(canonical, workstreamID)
    }
}
