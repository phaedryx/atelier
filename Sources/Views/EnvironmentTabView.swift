// ABOUTME: View for the run script / dev server in the Environment tab.
// ABOUTME: Shows a terminal for the running server, or start instructions when not configured.

import SwiftUI

func shouldRestoreRunSession(useTmux: Bool, hasRunScript: Bool, hasExistingRunSession: Bool, wasStoppedManually: Bool) -> Bool {
    useTmux && hasRunScript && hasExistingRunSession && !wasStoppedManually
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
    /// Whether Start may run anything. **Passed in, never re-derived here.**
    /// This is `RunCommandPlan.canRun` for the same plan `doStartRun` executes,
    /// so the button's enablement and the run's guard are one decision. They
    /// used to be two — enabled on `devCommand?.command != nil`, executed on the
    /// resolved command — and an unresolvable process-compose binary rendered an
    /// enabled Start that did nothing and explained nothing.
    let canStart: Bool
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

    /// What the pane shows under "Dev command". For an override this is the
    /// command the user typed; for a process-compose config it is the files that
    /// will be loaded, which is deliberately *not* a runnable string — see
    /// `RunCommandPlan`.
    private var runCommandPreference: String? {
        devCommand?.command
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
            HStack {
                if runControlsEnabled, !runStarted {
                    Button(action: onStart) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Start", comment: ""))
                } else {
                    Image(systemName: "play")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                if canStart, RunLauncher.executableURL() == nil {
                    Text("No port detection")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("atelier-run helper not found. Run scripts will work but port detection is unavailable.")
                }

                Spacer()

                if runControlsEnabled {
                    if runStarted {
                        EnvActionButton(label: NSLocalizedString("Stop", comment: ""), icon: "stop.fill", shortcut: "", action: onStop)
                        EnvActionButton(label: NSLocalizedString("Rerun", comment: ""), icon: "arrow.counterclockwise", shortcut: shortcut, action: onRestart)
                    } else {
                        EnvActionButton(label: NSLocalizedString("Start", comment: ""), icon: "play.fill", shortcut: shortcut, action: onStart)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

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
                    if let command = runCommandPreference {
                        Text(command)
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
                        devCommandEditText = devCommand?.command ?? ""
                        isCustomizingDevCommand = true
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            if let devCommand {
                HStack(spacing: 6) {
                    Text(devCommand.command)
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
    /// dispose at archive — are the ones that need approval; Start runs a
    /// command this pane is already displaying, so it stays available whether or
    /// not the file has been approved.
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
