// ABOUTME: Application settings displayed in the detail area as tabbed panes.
// ABOUTME: Environment, general, coding agent, and advanced panes behind a pane strip.

import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsPane.storageKey) private var selectedPaneRaw: String = SettingsPane.general.rawValue
    @AppStorage("atelier.defaultTerminal") private var defaultTerminal: String = ""

    @EnvironmentObject private var appEnv: AppEnvironment

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneStrip(selection: Binding(
                get: { selectedPane },
                set: { selectedPaneRaw = $0.rawValue }
            ))
            .padding(.vertical, 8)

            Divider()

            switch selectedPane {
            case .environment: EnvironmentSettingsPane()
            case .general: GeneralSettingsPane()
            case .codingAgent: CodingAgentSettingsPane()
            case .prompts: PromptsSettingsPane()
            case .advanced: AdvancedSettingsPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Seeds the External Terminal default on any Settings visit, not just
        // a visit to the pane holding the picker. Panes are built by a switch,
        // so an .onAppear inside one only ever runs if the user selects it —
        // and the picker's pane is not the default one.
        .onAppear {
            if defaultTerminal.isEmpty, let first = appEnv.installedTerminals.first {
                defaultTerminal = first.bundleID
            }
        }
    }
}

// MARK: - Pane Strip

private struct SettingsPaneStrip: View {
    @Binding var selection: SettingsPane

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selection = pane
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 15))
                            .frame(height: 18)
                        Text(pane.title)
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == pane ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection == pane ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .accessibilityAddTraits(selection == pane ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Environment

private struct EnvironmentSettingsPane: View {
    @EnvironmentObject private var appEnv: AppEnvironment
    #if DEBUG
        private static let cliName = "atl-debug"
    #else
        private static let cliName = "atl"
    #endif
    @State private var cliInstalled = Self.isCliCorrectlyInstalled()

    var body: some View {
        Form {
            Section {
                ToolRow(
                    name: "claude",
                    status: appEnv.toolStatus.claude,
                    version: appEnv.toolStatus.claudeVersion
                )
                ToolRow(
                    name: "gh",
                    status: appEnv.toolStatus.gh,
                    version: appEnv.toolStatus.ghVersion,
                    detail: appEnv.toolStatus.ghAuthDetail
                )
                ToolRow(
                    name: "git",
                    status: appEnv.toolStatus.git,
                    version: appEnv.toolStatus.gitVersion
                )
                ToolRow(
                    name: "tmux",
                    status: appEnv.toolStatus.tmux,
                    version: appEnv.toolStatus.tmuxVersion
                )
            } header: {
                HStack {
                    Text("Detected Tools")
                    Spacer()
                    Button(action: { appEnv.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .rotationEffect(.degrees(appEnv.isDetecting ? 360 : 0))
                            .animation(appEnv.isDetecting ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: appEnv.isDetecting)
                    }
                    .buttonStyle(.plain)
                    .disabled(appEnv.isDetecting)
                }

                LabeledContent(String(format: NSLocalizedString("Install '%@' command", comment: ""), Self.cliName)) {
                    Button(cliInstalled ? "Installed" : "Install...", action: installCLI)
                        .disabled(cliInstalled)
                }
                Text(cliInstalled
                    ? String(format: NSLocalizedString("The '%@' command is installed and ready to use.", comment: ""), Self.cliName)
                    : String(format: NSLocalizedString("Install the '%@' command to open directories in %@ from any terminal.", comment: ""), Self.cliName, AppConstants.appName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func installCLI() {
        let script = """
        #!/bin/bash
        DIR="${1:-.}"
        RESOLVED=$(cd "$DIR" 2>/dev/null && pwd)
        [ -z "$RESOLVED" ] && echo "Error: directory '$DIR' not found" >&2 && exit 1
        open "\(AppConstants.urlScheme)://$RESOLVED"
        """
        let tempPath = NSTemporaryDirectory() + Self.cliName
        try? script.write(toFile: tempPath, atomically: true, encoding: .utf8)
        chmod(tempPath, 0o755)
        installWithPrivileges(source: tempPath)
    }

    private func installWithPrivileges(source: String) {
        let destination = "/usr/local/bin/\(Self.cliName)"
        let quotedSource = source.replacingOccurrences(of: "'", with: "'\\''")
        let quotedDest = destination.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"install -m 755 '\(quotedSource)' '\(quotedDest)'\" with administrator privileges"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                cliInstalled = true
            }
        }
    }

    private func chmod(_ path: String, _ mode: mode_t) {
        Darwin.chmod(path, mode)
    }

    /// Check if the CLI is installed and points to a valid script that opens this app.
    private static func isCliCorrectlyInstalled() -> Bool {
        let path = "/usr/local/bin/\(cliName)"
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              fm.isExecutableFile(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return false
        }
        return contents.contains(AppConstants.urlScheme)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @AppStorage("atelier.appearance") private var appearance: String = "system"
    @AppStorage("atelier.symlinkEnv") private var symlinkEnv: Bool = true
    @AppStorage("atelier.confirmQuit") private var confirmQuit: Bool = true
    @AppStorage("atelier.baseDirectory") private var baseDirectory: String = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""

    /// Read in `.task` rather than as the `@State` initial value: that
    /// expression runs on every construction of this pane, and
    /// `LaunchAtLogin.isEnabled` is a cross-process SMAppService query.
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Base directory")
                        Text("Default location when adding new projects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(baseDirectory.abbreviatedPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Change...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: baseDirectory)
                        panel.message = NSLocalizedString("Choose base directory for projects", comment: "")
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                baseDirectory = url.path
                            }
                        }
                    }
                }

                SettingToggle(
                    "Symlink .env files",
                    isOn: $symlinkEnv,
                    description: "Symlink .env and .env.local from the main repository into new worktrees."
                )

                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, newValue in
                    applyAppearance(newValue)
                }

                SettingToggle(
                    "Confirm before quitting",
                    isOn: $confirmQuit,
                    description: "Show a confirmation dialog when quitting with active workstreams."
                )

                SettingToggle(
                    "Launch at login",
                    isOn: $launchAtLogin,
                    description: "Automatically open Atelier when you log in."
                )
                // Skipped when the toggle already matches the system, so
                // seeding the real value in .task doesn't re-register.
                .onChange(of: launchAtLogin) { _, newValue in
                    guard newValue != LaunchAtLogin.isEnabled else { return }
                    LaunchAtLogin.setEnabled(newValue)
                }
            }
        }
        .formStyle(.grouped)
        .task { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - Coding Agent

private struct CodingAgentSettingsPane: View {
    @AppStorage("atelier.tmuxMode") private var tmuxMode: Bool = false
    @AppStorage("atelier.bypassPermissions") private var bypassPermissions: Bool = false
    @AppStorage("atelier.allowOutsideWorktree") private var allowOutsideWorktree: Bool = false
    @AppStorage("atelier.autoRenameBranch") private var autoRenameBranch: Bool = false
    @AppStorage(AgentIPCSettings.enabledKey) private var agentIPC: Bool = false
    @AppStorage(AgentIPCSettings.nudgeKey) private var agentIPCNudge: Bool = false
    @AppStorage("atelier.defaultTerminal") private var defaultTerminal: String = ""
    @AppStorage("atelier.defaultBrowser") private var defaultBrowser: String = ""

    @EnvironmentObject private var appEnv: AppEnvironment

    var body: some View {
        Form {
            Section {
                SettingToggle(
                    "Bypass permission prompts",
                    isOn: $bypassPermissions,
                    description: "When enabled, the coding agent will not ask for confirmation before making changes. Use with caution: the agent will be able to edit files, run commands, and make git commits without asking.",
                    descriptionStyle: bypassPermissions ? .warning : .secondary
                )

                SettingToggle(
                    "Allow writes outside worktree",
                    isOn: $allowOutsideWorktree,
                    description: "When enabled, the coding agent can modify files anywhere on disk. When disabled, writes are restricted to the worktree directory.",
                    descriptionStyle: allowOutsideWorktree ? .warning : .secondary
                )

                SettingToggle(
                    "Auto-rename branch",
                    isOn: $autoRenameBranch,
                    description: "On the first request, the agent renames the branch to match the task and writes a short description visible in the sidebar."
                )

                SettingToggle(
                    "Agent messaging",
                    isOn: $agentIPC,
                    description: NSLocalizedString(
                        "The master switch for agent-to-agent messaging in this project: agents can find each other and send messages, which the recipient sees only when it checks its inbox. Nothing is typed into any terminal unless you also turn on Nudge idle agents below. Takes effect the next time a Coding Agent starts. Only applies to Claude Code.",
                        comment: "Agent IPC setting description"
                    )
                )
                .onChange(of: agentIPC) { _, _ in
                    AgentIPCSettings.apply()
                }

                SettingToggle(
                    "Nudge idle agents",
                    isOn: $agentIPCNudge,
                    description: NSLocalizedString(
                        "Requires Agent messaging. When a message arrives for an agent that has finished its turn, Atelier types a notice into its terminal. That is typed input: an agent running without permission prompts will act on it.",
                        comment: "Agent IPC nudge setting description"
                    ),
                    descriptionStyle: agentIPCNudge ? .warning : .secondary
                )
                .disabled(!agentIPC)

                SettingToggle(
                    "Tmux Mode",
                    isOn: $tmuxMode,
                    description: "Coding Agent sessions persist across app restarts. The Terminal tab is not affected. Sessions are lost on system restart."
                )
                .disabled(!appEnv.toolStatus.tmux.isInstalled)

                if !appEnv.toolStatus.tmux.isInstalled {
                    Text("Requires tmux to be installed.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("External Terminal", selection: $defaultTerminal) {
                    ForEach(appEnv.installedTerminals) { app in
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .tag(app.bundleID)
                    }
                }

                Picker("External Browser", selection: $defaultBrowser) {
                    Text("System Default").tag("")
                    ForEach(appEnv.installedBrowsers) { app in
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .tag(app.bundleID)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Prompts

private struct PromptsSettingsPane: View {
    @ObservedObject private var store = StoredPromptStore.shared
    @State private var editingPrompt: StoredPrompt?
    @State private var addingPrompt = false

    var body: some View {
        Form {
            Section {
                if store.prompts.isEmpty {
                    Text("No stored prompts yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.prompts) { prompt in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.label)
                            Text(prompt.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editingPrompt = prompt }
                        Button {
                            store.remove(id: prompt.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Delete")
                    }
                }
                Button("Add Prompt...") { addingPrompt = true }
            } footer: {
                Text("Stored prompts appear in the command palette. Running one switches to the Coding Agent tab and types the prompt for you. They stay hidden while the agent is mid-turn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingPrompt) { prompt in
            PromptEditorSheet(prompt: prompt, onSave: { store.update($0) })
        }
        .sheet(isPresented: $addingPrompt) {
            PromptEditorSheet(prompt: StoredPrompt(label: "", text: ""), onSave: { store.add($0) })
        }
    }
}

private struct PromptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var prompt: StoredPrompt
    let onSave: (StoredPrompt) -> Void

    private var isSaveDisabled: Bool {
        prompt.label.trimmingCharacters(in: .whitespaces).isEmpty
            || prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Label", text: $prompt.label)

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $prompt.text)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @AppStorage("atelier.detailedLogging") private var detailedLogging: Bool = false
    @AppStorage("atelier.quickActionDebug") private var quickActionDebug: Bool = false

    @State private var showingClearConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $detailedLogging) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detailed logging")
                        if detailedLogging {
                            HStack(spacing: 0) {
                                Text("Log setup, run, and teardown script output to files for debugging. ")
                                    .foregroundStyle(.secondary)
                                Button("Open Logs Directory") {
                                    let url = LaunchLogger.logsDirectoryURL
                                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                            .font(.caption)
                        } else {
                            Text("Log setup, run, and teardown script output to files for debugging.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingToggle(
                    "Quick action debug",
                    isOn: $quickActionDebug,
                    description: "Show a debug panel with command output from quick actions (Create PR, Commit & Push)."
                )

                LabeledContent("Clear project list") {
                    Button("Clear All...", role: .destructive, action: { showingClearConfirm = true })
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                Text("Removes all projects and workstreams from the sidebar. No files or directories on disk will be deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Clear project list?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                NotificationCenter.default.post(name: .clearProjects, object: nil)
            }
        } message: {
            Text("This will remove all projects and workstreams from the sidebar. No files on disk will be deleted. This cannot be undone.")
        }
    }
}

// MARK: - Setting Toggle

private enum SettingDescriptionStyle {
    case secondary
    case warning
}

private struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool
    let description: String
    var descriptionStyle: SettingDescriptionStyle

    init(_ title: String, isOn: Binding<Bool>, description: String, descriptionStyle: SettingDescriptionStyle = .secondary) {
        self.title = title
        _isOn = isOn
        self.description = description
        self.descriptionStyle = descriptionStyle
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(descriptionStyle == .warning ? .orange : .secondary)
            }
        }
    }
}

// MARK: - Tool Detection

enum BinaryStatus {
    case notFound
    case found(String)

    var isInstalled: Bool {
        if case .found = self { return true }
        return false
    }

    var path: String? {
        if case let .found(p) = self { return p }
        return nil
    }
}

struct ToolStatus {
    var tmux: BinaryStatus = .notFound
    var tmuxVersion: String?
    var claude: BinaryStatus = .notFound
    var claudeVersion: String?
    var claudeSupportsSessionName: Bool = false
    var gh: BinaryStatus = .notFound
    var ghVersion: String?
    var ghAuthDetail: String?
    var git: BinaryStatus = .notFound
    var gitVersion: String?

    static func detect() -> ToolStatus {
        var status = ToolStatus()

        status.tmux = findBinary("tmux")
        if let path = status.tmux.path {
            status.tmuxVersion = runForVersion(path, args: ["-V"])
        }

        status.claude = findBinary("claude")
        if let path = status.claude.path {
            status.claudeVersion = runForVersion(path, args: ["--version"])
            status.claudeSupportsSessionName = helpContainsFlag(path, flag: "--name")
        }

        status.gh = findBinary("gh")
        if let path = status.gh.path {
            status.ghVersion = runForVersion(path, args: ["--version"])
            status.ghAuthDetail = checkGhAuth(path)
        }

        status.git = findBinary("git")
        if let path = status.git.path {
            status.gitVersion = runForVersion(path, args: ["--version"])
        }

        return status
    }

    private static func findBinary(_ name: String) -> BinaryStatus {
        guard let path = CommandLineTools.path(for: name) else { return .notFound }
        return .found(path)
    }

    private static func runForVersion(_ path: String, args: [String]) -> String? {
        guard let output = runCommand(path, args: args) else { return nil }
        let trimmed = output
            .replacingOccurrences(of: "tmux ", with: "")
            .replacingOccurrences(of: "gh version ", with: "")
        return trimmed.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
    }

    private static func helpContainsFlag(_ path: String, flag: String) -> Bool {
        guard let output = runCommand(path, args: ["--help"], includeStderr: true) else { return false }
        return output.contains(flag)
    }

    private static func checkGhAuth(_ ghPath: String) -> String? {
        guard let output = runCommand(ghPath, args: ["auth", "status"], includeStderr: true) else {
            return "Not authenticated"
        }
        if let range = output.range(of: "account ") {
            let afterAccount = output[range.upperBound...]
            let username = afterAccount.prefix(while: { !$0.isWhitespace && $0 != "(" })
            if !username.isEmpty {
                return String(username)
            }
        }
        if output.contains("Logged in") {
            return "Authenticated"
        }
        return "Not authenticated"
    }

    private static func runCommand(_ path: String, args: [String], includeStderr: Bool = false) -> String? {
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = includeStderr ? pipe : errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 || includeStderr else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

private struct ToolRow: View {
    let name: String
    let status: BinaryStatus
    var version: String?
    var detail: String?

    var body: some View {
        HStack {
            Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(status.isInstalled ? .green : .secondary)
                .accessibilityLabel(status.isInstalled ? "Installed" : "Not found")

            Text(name)
                .font(.system(.body, design: .monospaced))

            if let version {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status.isInstalled {
                if let detail {
                    let isAuth = detail != "Not authenticated"
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isAuth ? .green : .orange)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(isAuth ? "Authenticated" : "Not authenticated")
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App Detection

struct AppInfo: Identifiable, @unchecked Sendable {
    let name: String
    let bundleID: String
    var id: String {
        bundleID
    }

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func isAppInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func detectTerminals() -> [AppInfo] {
        let candidates: [(String, String)] = [
            ("Ghostty", "com.mitchellh.ghostty"),
            ("iTerm2", "com.googlecode.iterm2"),
            ("Terminal", "com.apple.Terminal"),
            ("Warp", "dev.warp.Warp-Stable"),
            ("Alacritty", "org.alacritty"),
            ("kitty", "net.kovidgoyal.kitty"),
        ]
        return candidates.compactMap { name, id in
            isAppInstalled(id) ? AppInfo(name: name, bundleID: id) : nil
        }
    }

    static func detectBrowsers() -> [AppInfo] {
        let candidates: [(String, String)] = [
            ("Safari", "com.apple.Safari"),
            ("Google Chrome", "com.google.Chrome"),
            ("Firefox", "org.mozilla.firefox"),
            ("Arc", "company.thebrowser.Browser"),
            ("Brave", "com.brave.Browser"),
            ("Microsoft Edge", "com.microsoft.edgemac"),
            ("Opera", "com.operasoftware.Opera"),
        ]
        return candidates.compactMap { name, id in
            isAppInstalled(id) ? AppInfo(name: name, bundleID: id) : nil
        }
    }
}
