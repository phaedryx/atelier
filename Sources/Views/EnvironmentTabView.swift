// ABOUTME: View for the run script / dev server in the Environment tab.
// ABOUTME: Shows a terminal for the running server, or start instructions when not configured.

import SwiftUI

func shouldRestoreRunSession(useTmux: Bool, hasRunScript: Bool, hasExistingRunSession: Bool, wasStoppedManually: Bool) -> Bool {
    useTmux && hasRunScript && hasExistingRunSession && !wasStoppedManually
}

/// What the Environment pane shows for the effective dev command.
///
/// An override is shown as the command it is — the user typed it, and it is what
/// Start runs. A process-compose config is shown as the **files** that will be
/// loaded, and deliberately not as a command, because the string
/// `DevCommandResolver` builds for that source is
/// `process-compose up -U -f <files>` — no `-n`, so running it runs *every*
/// namespace including `bootstrap` and `dispose`, past `PhasePolicy` and past
/// `ScriptTrust`. `RunCommandPlan` makes it unreachable from Start; rendering it
/// here made it reachable by hand, in a monospaced font that invites exactly
/// that. The files are what `RunCommandPlan` meant the user to be able to see.
///
/// A free function, like its neighbours, so the property that matters — no
/// output of this is ever a runnable process-compose command — can be tested
/// without a view.
func devCommandDisplayText(devCommand: DevCommand?, loadedFiles: [String]) -> String? {
    guard let devCommand else { return nil }
    switch devCommand.source {
    case .override:
        return devCommand.command
    case .processCompose:
        guard !loadedFiles.isEmpty else { return devCommand.sourceDescription }
        return loadedFiles.map(\.abbreviatedPath).joined(separator: "  ")
    }
}

/// Whether the "Processes to start" list should render.
///
/// Visible before a run and hidden during one, and both halves are defects
/// that have already shipped, in opposite directions.
///
/// The list first lived inside `ProcessTableView`, which renders only once a
/// run exists, so the control for choosing what to start was unreachable until
/// after starting — the one moment it is no use. Fixing that by making
/// visibility independent of the run then left it editable *during* a run,
/// where it is equally useless: the selection is read when Start is pressed
/// (`TerminalContainerView`), so changing a checkbox mid-run silently affects
/// nothing until the next Stop and Start.
///
/// So the gate is two-sided, and both sides are pinned by tests. Neither
/// direction is the safe default to guess at.
func showsProcessSelection(
    runStarted: Bool,
    showsProcessTable: Bool,
    declaredProcesses: [String]
) -> Bool {
    !runStarted && showsProcessTable && !declaredProcesses.isEmpty
}

/// Wraps a command for a login shell, so it sees the PATH and shell functions
/// the user's own terminal would. Used when the `atelier-run` launcher is
/// unavailable and the command has to be run bare.
func scriptCommand(script: String, shell: String = CommandBuilder.userShell) -> String {
    "\(shell) -lic \(CommandBuilder.shellQuote(script, forShell: shell))"
}

struct EnvironmentTabView: View {
    let workstreamID: UUID
    let workingDirectory: String
    let useTmux: Bool
    let environmentVars: [String: String]
    /// Final assembled run command (atelier-run + tmux wrap), set once the session starts.
    let runCommand: String?
    /// The resolved dev command: the user's override, or the located
    /// process-compose config.
    let devCommand: DevCommand?
    @Binding var devCommandOverride: String?
    @Binding var runStarted: Bool
    @Binding var runGeneration: Int
    /// Live process state from process-compose. Only rendered when the run is a
    /// process-compose run; otherwise nothing is polling it.
    @ObservedObject var processTable: ProcessTableModel
    let showsProcessTable: Bool
    /// The worktree's port plan, so each row can show the port it owns.
    let portsByName: [String: String]
    /// Processes the config declares in `execute`, for the selection list.
    let declaredProcesses: [String]
    /// Whether Start may run anything. **Passed in, never re-derived here.**
    /// This is `RunCommandPlan.canRun` for the same plan `doStartRun` executes,
    /// so the button's enablement and the run's guard are one decision. They
    /// used to be two — enabled on `devCommand?.command != nil`, executed on the
    /// resolved command — and an unresolvable process-compose binary rendered an
    /// enabled Start that did nothing and explained nothing.
    let canStart: Bool
    /// Every file process-compose will load for this workstream, or empty when
    /// the run is not a process-compose run. Shown instead of a command string:
    /// see `devCommandDisplay`.
    let devCommandFiles: [String]
    /// Why Start can do nothing, when the copy below does not already say. The
    /// states that reach this were all silent: an integration switched off, a
    /// config that vanished, and a binary the search paths do not cover.
    let startUnavailableReason: String?
    /// The repository-provided process-compose files whose unattended phases the
    /// user has not approved, or empty when there is nothing to ask about.
    let unapprovedConfigFiles: [String]
    let onReviewConfig: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache
    @State private var isCustomizingDevCommand = false
    @State private var devCommandEditText = ""

    private var runID: UUID {
        derivedUUID(from: workstreamID, salt: "env-run-\(runGeneration)")
    }

    private var devCommandDisplay: String? {
        devCommandDisplayText(devCommand: devCommand, loadedFiles: devCommandFiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !unapprovedConfigFiles.isEmpty {
                configApprovalBanner(paths: unapprovedConfigFiles)
                Divider()
            }
            environmentContent
        }
    }

    private var environmentContent: some View {
        runPane()
    }

    @ViewBuilder
    private func runPane() -> some View {
        let title = NSLocalizedString("Run", comment: "")
        let shortcut = "⌘⇧⏎"
        VStack(spacing: 0) {
            // Only once something is running. Before that this bar carried a
            // play button, a Start button and the section title, above a pane
            // whose body is already one big Start button — three ways to do
            // the same thing, stacked. Stop and Rerun mean nothing until there
            // is a run, so the bar now arrives with them.
            if runStarted {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))

                    // Travels with the bar: it warns that the browser will not
                    // retarget on a detected port, which only matters once a
                    // server is actually up.
                    if canStart, RunLauncher.executableURL() == nil {
                        Text("No port detection")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("atelier-run helper not found. Run scripts will work but port detection is unavailable.")
                    }

                    Spacer()

                    if runControlsEnabled {
                        EnvActionButton(label: NSLocalizedString("Stop", comment: ""), icon: "stop.fill", shortcut: "", action: onStop)
                        EnvActionButton(label: NSLocalizedString("Rerun", comment: ""), icon: "arrow.counterclockwise", shortcut: shortcut, action: onRestart)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()
            }

            devCommandSection
            Divider()

            if runStarted, let runCommand {
                if showsProcessTable {
                    ProcessTableView(model: processTable, portsByName: portsByName)
                    Divider()
                }
                SingleTerminalView(
                    surfaceID: runID,
                    workingDirectory: workingDirectory,
                    command: runCommand,
                    isFocused: false,
                    environmentVars: environmentVars
                )
                .id(runID)
            } else if canStart {
                if showsProcessSelection(
                    runStarted: runStarted,
                    showsProcessTable: showsProcessTable,
                    declaredProcesses: declaredProcesses
                ) {
                    ProcessSelectionView(
                        workstreamID: workstreamID,
                        declaredProcesses: declaredProcesses
                    )
                    Divider()
                }
                VStack(spacing: 12) {
                    Button(action: onStart) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                            Text("Start")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                    if let display = devCommandDisplay {
                        Text(display)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(shortcut)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scriptInstructions(reason: startUnavailableReason)
            }
        }
    }

    /// Shows the effective dev command — the located process-compose config, or
    /// the user's per-workstream override — and lets the user change it.
    private var devCommandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dev command")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(isCustomizingDevCommand ? "Cancel" : "Customize") {
                    if isCustomizingDevCommand {
                        isCustomizingDevCommand = false
                    } else {
                        // Seeded only from an override — the user's own text.
                        // Seeding it from a `.processCompose` command handed the
                        // user the un-`-n`'d string in an editable field, and
                        // Save turns whatever is in that field into an
                        // `.override`, which `RunCommandPlan` runs literally.
                        // Three clicks, no typing, and `bootstrap` and `dispose`
                        // run with no approval.
                        devCommandEditText = devCommand?.source == .override
                            ? (devCommand?.command ?? "")
                            : ""
                        isCustomizingDevCommand = true
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            if let devCommand, let display = devCommandDisplay {
                HStack(spacing: 6) {
                    Text(display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    sourceTag(for: devCommand.source)
                }
            } else {
                Text("No dev command found. Add a process-compose.yaml, or set a command below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if isCustomizingDevCommand {
                HStack(spacing: 6) {
                    TextField("Command", text: $devCommandEditText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Save") {
                        let trimmed = devCommandEditText.trimmingCharacters(in: .whitespacesAndNewlines)
                        devCommandOverride = trimmed.isEmpty ? nil : trimmed
                        isCustomizingDevCommand = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if devCommand == nil, !isCustomizingDevCommand {
                Text("Open the command palette (\u{2318}\u{21E7}P) and run New Browser to start the dev server.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sourceTag(for source: DevCommand.Source) -> some View {
        let text: String
        switch source {
        case .override:
            text = NSLocalizedString("Custom", comment: "")
        case .processCompose:
            // The file name, since a repository can carry either spelling.
            text = devCommand?.sourceDescription ?? "process-compose.yaml"
        }
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .foregroundStyle(.tertiary)
    }

    /// A banner, not a gate. The unattended phases — bootstrap at creation,
    /// dispose at archive — are the ones that need approval, because nobody is
    /// there when they run. Start is attended: the user presses it deliberately,
    /// the stack's output lands in a terminal surface in front of them, and Stop
    /// is right there — so it stays available whether or not the file has been
    /// approved.
    ///
    /// That, and not "the pane shows the command Start runs", is the reason. The
    /// pane never showed it: what Start runs is the phase-scoped
    /// `prepare && execute`, assembled by `PhaseRunner`, while the string the
    /// pane used to render was a display-only one that must never execute. The
    /// decision to leave `execute` ungated stands; only the stated reason was
    /// false, and it was load-bearing in four places.
    private func configApprovalBanner(paths: [String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: NSLocalizedString("%@ came with this repository and has not been approved", comment: ""),
                    paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                ))
                .font(.system(size: 12, weight: .semibold))
                Text("Its bootstrap and dispose phases will not run until you review it. Start is unaffected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { onReviewConfig() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    /// Shown whenever Start cannot run. Two shapes, one surface: with no
    /// `reason` it names the two things that would make Start work — a
    /// process-compose.yaml in either home, or a per-workstream override —
    /// and with one it says what is actually in the way.
    ///
    /// Deliberately not a new pane. Every state that lands here was previously
    /// silent, and the review that found them was specific that they belong in
    /// the surface that already renders for "nothing to run".
    private func scriptInstructions(reason: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Nothing to start")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(reason ?? NSLocalizedString(
                "Add a process-compose.yaml to this worktree or the project directory, or set a command with Customize above.",
                comment: ""
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runControlsEnabled: Bool {
        canStart
    }
}

extension Notification.Name {
    static let rerunScript = Notification.Name("atelier.rerunScript")
}

private struct EnvActionButton: View {
    let label: String
    let icon: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
                Text(shortcut)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}
