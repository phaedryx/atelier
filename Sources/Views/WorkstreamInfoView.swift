// ABOUTME: Info panel for a workstream showing metadata and docs.
// ABOUTME: First tab in the workspace, combining project info with the docs viewer.

import SwiftUI

struct WorkstreamInfoView: View {
    let workstreamID: UUID
    let workstreamName: String
    let workingDirectory: String
    let projectName: String
    let projectDirectory: String
    /// Every repository-provided process-compose file this worktree would load.
    /// Info is the permanent tab, so this is the approval route that survives the
    /// user closing Environment.
    var repositoryConfigFiles: [String] = []
    var configApproved: Bool = false
    /// What background setup last reported for this workstream. Info is where
    /// it belongs: it is the permanent tab, and a `.completedWithNote` — "the
    /// integration is off, so no bootstrap ran", "process-compose was not
    /// found" — is a fact about the workstream, not about the run pane. Nothing
    /// rendered it before, so those notes were written and thrown away.
    var setupState: AsyncSetupState = .idle
    /// No defaults: a call site that passes `repositoryConfigFiles` but forgets
    /// these would render a Review button that silently does nothing, which is
    /// the whole failure this gate exists to avoid.
    let onReviewConfig: () -> Void
    let onRevokeConfig: () -> Void

    @EnvironmentObject var appEnv: AppEnvironment
    @AppStorage("atelier.defaultTerminal") private var defaultTerminal: String = ""
    @State private var branchName: String?
    @State private var copiedBranch = false
    @State private var copiedPath = false
    @State private var docFiles: [DocFile] = []
    @State private var selectedDoc: String?
    @State private var projectIcon: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // Hero header
                Section {
                    VStack(spacing: 4) {
                        if let icon = projectIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        Text(projectName)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        if let desc = appEnv.taskDescription(for: workingDirectory), !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 22, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(workstreamName)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(workstreamName)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    if let branch = branchName {
                        LabeledContent {
                            HStack(spacing: 4) {
                                Text(branch)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                DirectoryActionButton(
                                    icon: copiedBranch ? "checkmark" : "doc.on.doc",
                                    color: copiedBranch ? .green : nil,
                                    tooltip: "Copy branch name"
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(branch, forType: .string)
                                    copiedBranch = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedBranch = false }
                                }
                            }
                        } label: {
                            Text("Branch")
                        }
                    }

                    LabeledContent {
                        HStack(spacing: 4) {
                            Text(workingDirectory.abbreviatedPath)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            DirectoryActionButton(
                                icon: copiedPath ? "checkmark" : "doc.on.doc",
                                color: copiedPath ? .green : nil,
                                tooltip: "Copy path"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(workingDirectory, forType: .string)
                                copiedPath = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedPath = false }
                            }
                            DirectoryActionButton(
                                icon: "terminal",
                                tooltip: "Open in external terminal"
                            ) {
                                openInTerminal(path: workingDirectory)
                            }
                            if let githubURL = appEnv.githubURL(for: projectDirectory) {
                                DirectoryActionButton(
                                    assetIcon: "github",
                                    tooltip: "Open on GitHub"
                                ) {
                                    NSWorkspace.shared.open(githubURL)
                                }
                            }
                        }
                    } label: {
                        Text("Directory")
                    }
                }

                if appEnv.ghAvailable, let branch = branchName,
                   let pr = appEnv.githubPR(for: projectDirectory, branch: branch)
                {
                    Section("Pull Request") {
                        let prColor: Color = pr.state == "MERGED" ? .purple : pr.state == "OPEN" ? .green : .secondary
                        LabeledContent {
                            HStack(spacing: 6) {
                                Image(systemName: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull")
                                    .foregroundStyle(prColor)
                                Text(verbatim: "#\(pr.number)")
                                    .font(.system(.body, design: .monospaced))
                                Text(pr.title)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } label: {
                            Text(pr.state.capitalized)
                                .foregroundStyle(prColor)
                        }

                        if pr.state == "MERGED" {
                            HStack {
                                Text("This branch has been merged.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Purge") {
                                    NotificationCenter.default.post(name: .purgeWorkstream, object: workstreamID)
                                }
                                .foregroundStyle(.purple)
                            }
                        }
                    }
                }

                if let story = appEnv.shortcutStory(for: workingDirectory) {
                    Section("Shortcut") {
                        LabeledContent {
                            Text(story.name)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text(verbatim: "sc-\(story.id)")
                                .font(.system(.body, design: .monospaced))
                        }

                        if let state = appEnv.shortcutStateName(for: workingDirectory) {
                            LabeledContent("State") {
                                Text(state)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let url = URL(string: story.appURL) {
                            HStack {
                                Spacer()
                                Button("Open in Shortcut") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }

                if let setup = setupSummary {
                    Section("Setup") {
                        LabeledContent(setup.label) {
                            HStack(spacing: 6) {
                                Image(systemName: setup.icon)
                                    .foregroundStyle(setup.tint)
                                Text(setup.detail)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }

                if !repositoryConfigFiles.isEmpty {
                    Section {
                        // Only the unattended phases are gated. Start runs a
                        // command the Environment pane already displays, so it
                        // is never held behind this.
                        Text("Bootstrap runs when a workstream is created and dispose when one is archived, both without asking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("Approval") {
                            HStack(spacing: 10) {
                                if configApproved {
                                    Label("Approved", systemImage: "checkmark.shield")
                                        .foregroundStyle(.green)
                                    Button("Revoke") { onRevokeConfig() }
                                } else {
                                    Label("Not approved", systemImage: "exclamationmark.shield")
                                        .foregroundStyle(.orange)
                                    Button("Review") { onReviewConfig() }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Process Config")
                            Spacer()
                            Text(repositoryConfigFiles
                                .map { ($0 as NSString).lastPathComponent }
                                .joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            // Markdown content fills remaining space when a doc is selected
            if let selected = selectedDoc,
               let doc = displayedDocs.first(where: { $0.name == selected })
            {
                Divider()
                MarkdownContentView(markdown: doc.content)
                    .id(selected)
            }

            // Doc tabs pinned to bottom
            if !displayedDocs.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(displayedDocs) { doc in
                        DocTabButton(
                            name: doc.name,
                            isActive: selectedDoc == doc.name,
                            action: { selectedDoc = selectedDoc == doc.name ? nil : doc.name }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadInfo() }
    } // body

    private func openInTerminal(path: String) {
        if !defaultTerminal.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultTerminal)
        {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)
        } else if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminalURL, configuration: config)
        }
    }

    private nonisolated static let iconPaths = [
        "icon.svg", "icon.png",
        ".github/icon.svg", ".github/icon.png",
        "logo.svg", "logo.png",
    ]

    private nonisolated static func findProjectIcon(in directory: String) -> NSImage? {
        let base = URL(fileURLWithPath: directory)
        for relative in iconPaths {
            let path = base.appendingPathComponent(relative).path
            if let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }

    private nonisolated static func findProjectIconPath(in directory: String) -> String? {
        let base = URL(fileURLWithPath: directory)
        for relative in iconPaths {
            let path = base.appendingPathComponent(relative).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func loadInfo() {
        let workingDir = workingDirectory
        let gitHubProjectDir = projectDirectory
        Task.detached {
            let branch = GitOperations.repoInfo(at: workingDir).branch
            await updateBranchInfo(branch, projectDirectory: gitHubProjectDir)
        }

        let projDir = projectDirectory
        Task.detached {
            let iconPath = Self.findProjectIconPath(in: projDir)
            await updateProjectIcon(iconPath: iconPath)
        }

        let dir = workingDirectory
        Task.detached {
            let found = DocFile.loadFrom(directory: dir)
            await updateDocFiles(found)
        }

        // Re-read the story on every visit so an edit in Shortcut shows up. The cache
        // publishes only when the story actually changed, so a revisit redraws nothing.
        Task { await appEnv.refreshShortcutStory(for: workingDir) }
    }

    @MainActor
    private func updateBranchInfo(_ branch: String?, projectDirectory: String) {
        branchName = branch
        appEnv.refreshGitHubInfo(for: projectDirectory, branch: branch)
    }

    @MainActor
    private func updateProjectIcon(iconPath: String?) {
        if let iconPath {
            projectIcon = NSImage(contentsOfFile: iconPath)
        } else {
            projectIcon = nil
        }
    }

    @MainActor
    private func updateDocFiles(_ docFiles: [DocFile]) {
        self.docFiles = docFiles
    }

    /// Files found on disk, plus the Shortcut story description when there is one.
    ///
    /// The story is appended here rather than pushed into `docFiles` so it tracks the
    /// `AppEnvironment` cache: the description arrives after the disk scan and can change
    /// on a later refresh. Note this widens what a `DocFile` is — no longer strictly a
    /// file on disk, but any Markdown panel the tab row can show.
    /// One row's worth of what background setup did, or nil when there is
    /// nothing worth a row.
    ///
    /// `.idle` and `.completed` are both silent on purpose: nothing has happened
    /// yet, or bootstrap did exactly what the project asked and the worktree is
    /// the evidence. The two that must speak are `.completedWithNote`, whose
    /// entire content is the reason nothing ran, and `.failed`.
    private var setupSummary: (label: String, detail: String, icon: String, tint: Color)? {
        switch setupState {
        case .idle, .completed:
            return nil
        case let .inProgress(step, _):
            return (NSLocalizedString("Bootstrap", comment: ""), step, "clock", .secondary)
        case let .completedWithNote(note):
            return (NSLocalizedString("Bootstrap", comment: ""), note, "info.circle", .secondary)
        case let .failed(detail):
            return (NSLocalizedString("Bootstrap", comment: ""), detail, "exclamationmark.triangle", .orange)
        }
    }

    private var displayedDocs: [DocFile] {
        guard let story = appEnv.shortcutStory(for: workingDirectory),
              let description = story.description,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return docFiles }
        return docFiles + [DocFile(name: "Story", content: description)]
    }
}

// MARK: - Directory row with copy and open-in-terminal actions

struct DirectoryRow: View {
    let path: String
    var defaultTerminal: String = ""
    var githubURL: URL?

    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(path.abbreviatedPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            DirectoryActionButton(
                icon: copied ? "checkmark" : "doc.on.doc",
                color: copied ? .green : nil,
                tooltip: "Copy path"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }

            DirectoryActionButton(
                icon: "terminal",
                tooltip: "Open in external terminal"
            ) {
                openInTerminal()
            }

            if let githubURL {
                DirectoryActionButton(
                    assetIcon: "github",
                    tooltip: "Open on GitHub"
                ) {
                    NSWorkspace.shared.open(githubURL)
                }
            }
        }
    }

    private func openInTerminal() {
        if !defaultTerminal.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultTerminal)
        {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)
        } else if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminalURL, configuration: config)
        }
    }
}

private struct DirectoryActionButton: View {
    var icon: String = ""
    var assetIcon: String?
    var color: Color? = nil
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            (assetIcon.map { Image($0) } ?? Image(systemName: icon))
                .font(.system(size: 12))
                .foregroundStyle(color ?? (isHovering ? Color.primary : Color.secondary))
                .frame(width: 22, height: 22)
                .background(isHovering ? Color.primary.opacity(0.1) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}

struct DocFile: Identifiable {
    let name: String
    let content: String
    var id: String {
        name
    }

    static let standardNames = ["README.md", "CLAUDE.md", "AGENTS.md"]

    static func loadFrom(directory: String) -> [DocFile] {
        let fm = FileManager.default
        var found: [DocFile] = []
        for name in standardNames {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular
            else { continue }
            if let data = fm.contents(atPath: path),
               data.count >= 20,
               let content = String(data: data, encoding: .utf8)
            {
                found.append(DocFile(name: name, content: content))
            }
        }
        return found
    }
}

struct DocTabButton: View {
    let name: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 10, weight: isActive ? .medium : .regular, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.primary.opacity(0.08) : (isHovering ? Color.primary.opacity(0.04) : .clear))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
    }
}
