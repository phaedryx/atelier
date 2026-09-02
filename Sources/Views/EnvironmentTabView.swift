// ABOUTME: View for the run script / dev server in the Environment tab.
// ABOUTME: Shows a terminal for the running server, or start instructions when not configured.

import SwiftUI

func shouldRestoreRunSession(useTmux: Bool, hasRunScript: Bool, hasExistingRunSession: Bool, wasStoppedManually: Bool) -> Bool {
    useTmux && hasRunScript && hasExistingRunSession && !wasStoppedManually
}

func scriptCommand(script: String, role: String, shell: String = CommandBuilder.userShell) -> String {
    let inner: String
    if role == "setup" {
        inner = "\(script); printf '\\nSetup completed in this terminal.\\n'"
    } else {
        inner = script
    }
    return "\(shell) -lic \(CommandBuilder.shellQuote(inner, forShell: shell))"
}

struct EnvironmentTabView: View {
    let workstreamID: UUID
    let workingDirectory: String
    let projectDirectory: String
    let scriptConfig: ScriptConfig
    let useTmux: Bool
    let environmentVars: [String: String]
    /// Final assembled run command (atelier-run + tmux wrap), set once the session starts.
    let runCommand: String?
    /// The resolved dev command: the user's override, or a detected runner.
    let devCommand: DevCommand?
    /// Every runner detected in the worktree. A picker appears past one.
    let runnerCandidates: [DevCommand]
    let onSelectRunner: (DevCommand.Source) -> Void
    @Binding var envVarDefinitions: [EnvVarDefinition]
    /// What the definitions above evaluate to in this worktree.
    let resolvedEnvVars: [String: String]
    @Binding var devCommandOverride: String?
    @Binding var runStarted: Bool
    @Binding var runGeneration: Int
    /// Live process state from process-compose. Only rendered when the run is a
    /// process-compose run; otherwise nothing is polling it.
    @ObservedObject var processTable: ProcessTableModel
    let showsProcessTable: Bool
    /// The worktree's port plan, so each row can show the port it owns.
    let portsByName: [String: String]
    /// A repository-provided process-compose config whose unattended phases the
    /// user has not approved, or nil when there is nothing to ask about.
    let unapprovedConfigPath: String?
    let onReviewConfig: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache
    @State private var isCustomizingDevCommand = false
    @State private var devCommandEditText = ""
    @State private var isShowingEnvVars = false

    private var runID: UUID {
        derivedUUID(from: workstreamID, salt: "env-run-\(runGeneration)")
    }

    /// The short, human-readable command this pane would run.
    private var runCommandPreference: String? {
        devCommand?.command
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = scriptConfig.loadError {
                configErrorBanner(error: error)
                Divider()
            }
            if let source = scriptConfig.source, source != ".atelier.json" {
                configSourceBanner(source: source)
                Divider()
            }
            if let path = unapprovedConfigPath {
                configApprovalBanner(path: path)
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

                if runCommandPreference != nil, RunLauncher.executableURL() == nil {
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

            envVarSection
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
            } else if runCommandPreference != nil {
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
                scriptInstructions(title: title)
            }
        }
    }

    /// The environment variables this project injects, collapsed by default so
    /// the run pane keeps its space when nobody is editing them.
    ///
    /// Hand-rolled rather than a `DisclosureGroup`: that renders its own label
    /// and only its triangle reliably toggles, so the header read as clickable
    /// and mostly was not. A plain button with an explicit chevron makes the
    /// whole header the target. `Add` sits beside it rather than inside the
    /// editor, so the section carries one title instead of two.
    private var envVarSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    isShowingEnvVars.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isShowingEnvVars ? 90 : 0))
                        Text("Environment Variables")
                            .font(.system(size: 12, weight: .semibold))
                        if !envVarDefinitions.isEmpty {
                            Text("\(envVarDefinitions.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    // Without this the gaps between the label's pieces are not
                    // part of the button, so the header toggles only where there
                    // happens to be a glyph.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isShowingEnvVars {
                    Button("Add") { envVarDefinitions.append(EnvVarDefinition(name: "")) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if isShowingEnvVars {
                EnvVarsEditor(definitions: $envVarDefinitions, resolved: resolvedEnvVars)
            }
        }
    }

    /// Lets the user pick which detected runner starts the stack. Only shown
    /// when the worktree offers a real choice — a lone candidate is not a
    /// decision, and a config `run` script or a custom command has already
    /// settled the question.
    /// The candidate the picker should read as selected, or nil when the picker
    /// has nothing coherent to show: a custom command outranks both runners, so
    /// the picker would be inert *and* have no matching tag to highlight.
    private var pickedRunner: DevCommand.Source? {
        guard runnerCandidates.count > 1, let source = devCommand?.source,
              runnerCandidates.contains(where: { $0.source == source })
        else { return nil }
        return source
    }

    @ViewBuilder
    private var runnerPicker: some View {
        if let picked = pickedRunner {
            Picker("", selection: Binding(
                get: { picked },
                set: { onSelectRunner($0) }
            )) {
                ForEach(runnerCandidates, id: \.source) { candidate in
                    Text(runnerLabel(for: candidate)).tag(candidate.source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func runnerLabel(for candidate: DevCommand) -> String {
        switch candidate.source {
        case .processCompose: return NSLocalizedString("process-compose", comment: "")
        case .packageJSON, .override: return candidate.command
        }
    }

    /// Shows the effective dev command (detected runner or the user's
    /// per-workstream override) and lets the user customize it.
    private var devCommandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dev command")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                runnerPicker
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
                Text("No dev command found. Add a dev script to package.json or set one below.")
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
        case .packageJSON:
            text = NSLocalizedString("From package.json", comment: "")
        }
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .foregroundStyle(.tertiary)
    }

    private func configErrorBanner(error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Failed to load .atelier.json")
                    .font(.system(size: 12, weight: .semibold))
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08))
    }

    /// A banner, not a gate. The unattended phases — bootstrap at creation,
    /// dispose at archive — are the ones that need approval; Start runs a
    /// command this pane is already displaying, so it stays available whether or
    /// not the file has been approved.
    private func configApprovalBanner(path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: NSLocalizedString("%@ came with this repository and has not been approved", comment: ""),
                    (path as NSString).lastPathComponent
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

    private func configSourceBanner(source: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text(String(format: NSLocalizedString("Using scripts from %@", comment: ""), source))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color.blue.opacity(0.05))
    }

    /// Shown when nothing was detected and no command has been set. Names the
    /// two things that would make Start work rather than a config key, because
    /// detection is now the only path in.
    private func scriptInstructions(title _: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No dev command found")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Add a process-compose.yaml to this worktree or the project directory, or a dev script to package.json. Or set a command with Customize above.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runControlsEnabled: Bool {
        runCommandPreference != nil
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
