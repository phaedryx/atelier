// ABOUTME: The Environment tab's live process table with per-process controls.
// ABOUTME: State comes from process-compose's API; ports come from the port plan.

import SwiftUI

struct ProcessTableView: View {
    @ObservedObject var model: ProcessTableModel
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

    private func row(for process: ProcessComposeProcess) -> some View {
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
    private func portCell(for process: ProcessComposeProcess) -> some View {
        Text(ProcessTableModel.port(for: process.name, in: portsByName) ?? "\u{2014}")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
    }
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
                    Button("All") { store(Set(declaredProcesses)) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            ForEach(declaredProcesses, id: \.self) { name in
                Toggle(isOn: binding(for: name)) {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
            }
        }
        .onAppear { selection = Set(ProcessTableModel.selected(for: workstreamID)) }
    }

    /// What Start will run.
    ///
    /// Stored empty when everything is selected, because that is what
    /// `PhaseRunner` already means by empty: `up -n execute` with no names
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
                var next = effectiveSelection
                if isOn { next.insert(name) } else { next.remove(name) }
                store(next)
            }
        )
    }

    private func store(_ next: Set<String>) {
        let canonical = next == Set(declaredProcesses) ? [] : next.sorted()
        selection = Set(canonical)
        ProcessTableModel.setSelected(canonical, for: workstreamID)
    }
}
