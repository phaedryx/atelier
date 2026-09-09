// ABOUTME: Info panel for a workstream showing metadata and docs.
// ABOUTME: First tab in the workspace, split into Local, GitHub, and Shortcut sections.

import SwiftUI

/// One row's worth of what background setup did.
///
/// Every state speaks, including the two that used to be silent. While this was
/// only a report, `.idle` and `.completed` returned nothing and the row did not
/// render — nothing had happened yet, or bootstrap did what the project asked
/// and the worktree was the evidence.
///
/// The row carries Rerun now, so silence is no longer free. `.completed` is the
/// state a manual re-run is most often wanted from — a clobbered
/// `node_modules`, a schema that needs reseeding — and a control that hides
/// there is no control at all. `.idle` is not an edge case either:
/// `AsyncSetupService.states` lives in memory, so after a relaunch every
/// existing workstream reports `.idle` and this is the default text on every
/// Info tab.
///
/// `.idle`'s copy is deliberately about the report and not about the run.
/// Nothing here knows whether a bootstrap ever happened for this worktree, only
/// that this session has not seen one, and "bootstrap never ran" would be a
/// claim the state cannot support.
///
/// A free function, so the copy for all five states can be pinned without a
/// view.
func bootstrapRow(for state: AsyncSetupState) -> (detail: String, icon: String, tint: Color) {
    switch state {
    case .idle:
        (NSLocalizedString("Nothing reported this session.", comment: ""), "questionmark.circle", .secondary)
    case let .inProgress(step, _):
        (step, "clock", .secondary)
    case .completed:
        (NSLocalizedString("Ran successfully.", comment: ""), "checkmark.circle", .green)
    case let .completedWithNote(note):
        (note, "info.circle", .secondary)
    case let .failed(detail):
        (detail, "exclamationmark.triangle", .orange)
    }
}

/// Whether Rerun may be pressed.
///
/// One state refuses, and it is the actor's own rule surfaced rather than a
/// second opinion about it: `AsyncSetupService` already ignores a second
/// bootstrap for a workstream that has one in flight, because both would share
/// `<id>-bootstrap.sock` and the second would strand the first's control
/// server. Disabling the button is how that refusal reads as unavailable
/// instead of as a press that did nothing.
///
/// Nothing else is checked. A missing binary, a config that came with the
/// repository and has not been approved, the integration switched off — those
/// are `PhasePolicy.plan`'s to decide, and it reports each one as a
/// `.completedWithNote` that lands in the row above. Refusing the press for
/// them would trade an explanation for silence.
func canRerunBootstrap(_ state: AsyncSetupState) -> Bool {
    if case .inProgress = state {
        return false
    }
    return true
}

struct WorkstreamInfoView: View {
    let workstreamID: UUID
    let workingDirectory: String
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
    /// Runs the project's `bootstrap` namespace against this worktree again.
    /// No default for the same reason as the two above, and one more: this row
    /// always renders, so a call site that forgot it would ship a Rerun button
    /// on every workstream that does nothing.
    let onRerunBootstrap: () -> Void

    @EnvironmentObject var appEnv: AppEnvironment
    @AppStorage("atelier.defaultTerminal") private var defaultTerminal: String = ""
    @State private var branchName: String?
    @State private var isDirty = false
    @State private var copiedBranch = false
    @State private var copiedPath = false
    @State private var docFiles: [DocFile] = []
    @State private var selectedDoc: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                localSection
                githubSection
                shortcutSection
                setupSection
                processConfigSection
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

    // MARK: - Local

    private var localSection: some View {
        Section("Local") {
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
                            copy(branch, flag: $copiedBranch)
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
                        copy(workingDirectory, flag: $copiedPath)
                    }
                    DirectoryActionButton(
                        icon: "terminal",
                        tooltip: "Open in external terminal"
                    ) {
                        openInTerminal(path: workingDirectory)
                    }
                }
            } label: {
                Text("Directory")
            }

            LabeledContent("Working tree") {
                Label(
                    isDirty ? "Uncommitted changes" : "Clean",
                    systemImage: isDirty ? "circle.fill" : "checkmark.circle"
                )
                .foregroundStyle(isDirty ? .orange : .secondary)
                .font(isDirty ? .system(size: 11) : .body)
            }
        }
    }

    // MARK: - GitHub

    @ViewBuilder
    private var githubSection: some View {
        if let githubURL = appEnv.githubURL(for: projectDirectory) {
            Section("GitHub") {
                LabeledContent {
                    HStack(spacing: 4) {
                        Text(repositoryLabel)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        DirectoryActionButton(assetIcon: "github", tooltip: "Open on GitHub") {
                            NSWorkspace.shared.open(githubURL)
                        }
                    }
                } label: {
                    Text("Repository")
                }

                pullRequestRows
            }
        }
    }

    /// The PR rows, or the reason there are none.
    ///
    /// An absent PR used to hide the whole section, which read the same as a repo with no
    /// GitHub remote at all. Saying so explicitly costs one row and removes the ambiguity.
    @ViewBuilder
    private var pullRequestRows: some View {
        if !appEnv.ghAvailable {
            LabeledContent("Pull Request") {
                Text("gh not installed or not authenticated")
                    .foregroundStyle(.secondary)
            }
        } else if let branch = branchName,
                  let pr = appEnv.githubPR(for: projectDirectory, branch: branch)
        {
            LabeledContent {
                HStack(spacing: 6) {
                    Image(systemName: pr.status.symbolName)
                        .foregroundStyle(pr.status.color)
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(.body, design: .monospaced))
                    Text(pr.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let url = URL(string: pr.url) {
                        DirectoryActionButton(assetIcon: "github", tooltip: "Open pull request") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } label: {
                Text(pr.status.label)
                    .foregroundStyle(pr.status.color)
            }

            LabeledContent("Checks") {
                Label {
                    Text(pr.checks.label)
                } icon: {
                    Image(systemName: pr.checks.symbolName)
                }
                .foregroundStyle(pr.checks.color)
            }

            if let decision = pr.reviewDecision {
                LabeledContent("Review") {
                    Label {
                        Text(GitHubReviewDecision.label(decision))
                    } icon: {
                        Image(systemName: GitHubReviewDecision.symbolName(decision))
                    }
                    .foregroundStyle(GitHubReviewDecision.color(decision))
                }
            }

            if pr.status == .merged {
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
        } else {
            LabeledContent("Pull Request") {
                Text("None for this branch")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var repositoryLabel: String {
        if let name = appEnv.githubRepo(for: projectDirectory)?.name, !name.isEmpty {
            return name
        }
        guard let url = appEnv.githubURL(for: projectDirectory) else { return "" }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Shortcut

    @ViewBuilder
    private var shortcutSection: some View {
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

                if let type = story.storyType, !type.isEmpty {
                    LabeledContent("Type") {
                        Text(type.capitalized)
                            .foregroundStyle(.secondary)
                    }
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

                if let description = story.description,
                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    SelfSizingMarkdownView(markdown: description)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
        }
    }

    // MARK: - Actions

    private func copy(_ value: String, flag: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { flag.wrappedValue = false }
    }

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

    private func loadInfo() {
        let workingDir = workingDirectory
        let gitHubProjectDir = projectDirectory
        Task.detached {
            let info = Git.Operations.repoInfo(at: workingDir)
            await updateRepoInfo(branch: info.branch, isDirty: info.isDirty, projectDirectory: gitHubProjectDir)
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
    private func updateRepoInfo(branch: String?, isDirty: Bool, projectDirectory: String) {
        branchName = branch
        self.isDirty = isDirty
        appEnv.refreshGitHubInfo(for: projectDirectory, branch: branch)
    }

    @MainActor
    private func updateDocFiles(_ docFiles: [DocFile]) {
        self.docFiles = docFiles
    }

    /// What background setup did, and the button that runs it again.
    ///
    /// Always rendered. It used to appear only when there was something worth
    /// saying, which was right for a report and wrong for a control: the states
    /// it stayed quiet for — `.completed`, and `.idle` after any relaunch — are
    /// the ordinary ones, so the section would have been missing in exactly the
    /// case someone came looking for Rerun.
    private var setupSection: some View {
        let row = bootstrapRow(for: setupState)
        let canRerun = canRerunBootstrap(setupState)
        return Section("Setup") {
            LabeledContent("Bootstrap") {
                HStack(spacing: 6) {
                    Image(systemName: row.icon)
                        .foregroundStyle(row.tint)
                    Text(row.detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Button("Rerun") { onRerunBootstrap() }
                        .disabled(!canRerun)
                        .help(canRerun
                            ? NSLocalizedString("Run this project's bootstrap namespace against this worktree again.", comment: "")
                            : NSLocalizedString("Bootstrap is already running.", comment: ""))
                }
            }
        }
    }

    /// Approval for the repository's own process-compose files. Replaces the
    /// `.atelier.json` scripts section: the gated phases are now `bootstrap`
    /// and `dispose`, and approval is keyed on the config files themselves.
    @ViewBuilder
    private var processConfigSection: some View {
        if !repositoryConfigFiles.isEmpty {
            Section {
                // Only the unattended phases are gated. Start is
                // attended — a deliberate press, with the output in
                // front of the user and Stop to hand — so it is never
                // held behind this. Not because the pane shows the
                // command Start runs; it does not.
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

    /// Files found on disk, plus the Shortcut story description when there is one.
    ///
    /// The story is appended here rather than pushed into `docFiles` so it tracks the
    /// `AppEnvironment` cache: the description arrives after the disk scan and can change
    /// on a later refresh. Note this widens what a `DocFile` is — no longer strictly a
    /// file on disk, but any Markdown panel the tab row can show.
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
    var color: Color?
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
