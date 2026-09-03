// ABOUTME: The Environment tab's live process table with per-process controls.
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

/// Which of `execute`'s processes the Start button will launch.
///
/// A view of its own, and rendered by `EnvironmentTabView` in **both** the
/// started and not-started states, because the process table it used to live
/// inside only renders once a run exists — so the control for choosing what to
/// start was unreachable until after starting, which is the one moment it is
/// no use.
///
/// The choices come from the config rather than from the live API for the same
/// reason: before Start there is nothing running to enumerate.
struct ProcessSelectionView: View {
    let workstreamID: UUID
    let declaredProcesses: [String]

    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Processes to start")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !selection.isEmpty {
                    // Stored as empty, the canonical "all" — see
                    // `processSelectionAfterToggling`.
                    Button("All") { store([]) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // Wraps across the pane's width rather than one per line. Six
            // processes is an ordinary stack and a vertical list of them pushed
            // the Start button off the useful part of the pane.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 105), spacing: 4, alignment: .leading)],
                alignment: .leading,
                spacing: 1
            ) {
                ForEach(sortedProcesses, id: \.self) { name in
                    Toggle(isOn: binding(for: name)) {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isLastSelected(name))
                    .help(isLastSelected(name)
                        ? NSLocalizedString("At least one process has to start.", comment: "")
                        : "")
                }
            }
            .padding(.horizontal, 12)
        }
        .onAppear {
            let cleaned = processSelectionOnLoad(
                stored: ProcessCompose.TableModel.selected(for: workstreamID),
                declared: declaredProcesses
            )
            selection = Set(cleaned)
            // Written back, not just filtered for display: otherwise Start
            // keeps reading the stale name straight out of UserDefaults.
            ProcessCompose.TableModel.setSelected(cleaned, for: workstreamID)
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
                store(next)
            }
        )
    }

    /// Whether unchecking this one would leave nothing selected. Disabled
    /// rather than silently refused, so the state reads as unavailable instead
    /// of as a click that did nothing.
    private func isLastSelected(_ name: String) -> Bool {
        effectiveSelection == [name]
    }

    private func store(_ canonical: [String]) {
        selection = Set(canonical)
        ProcessCompose.TableModel.setSelected(canonical, for: workstreamID)
    }
}
