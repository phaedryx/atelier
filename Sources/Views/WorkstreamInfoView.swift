// ABOUTME: Info panel for a workstream showing metadata and docs.
// ABOUTME: First tab in the workspace, split into Local, GitHub, and Shortcut sections.

import SwiftUI

/// One row's worth of what initialization did.
///
/// Every state speaks, including the two that used to be silent. While this was
/// only a report, `.idle` and `.completed` returned nothing and the row did not
/// render — nothing had happened yet, or setup did what the project asked
/// and the worktree was the evidence.
///
/// The row carries Rerun now, so silence is no longer free. `.completed` is the
/// state a manual re-run is most often wanted from — a clobbered
/// `node_modules`, a schema that needs reseeding — and a control that hides
/// there is no control at all. `.idle` is not an edge case either:
/// `Initialization.Runner.states` lives in memory, so after a relaunch every
/// existing workstream reports `.idle` and this is the default text on every
/// Info tab.
///
/// `.idle`'s copy is deliberately about the report and not about the run.
/// Nothing here knows whether initialization ever happened for this worktree,
/// only that this session has not seen it, and "setup never ran" would be a
/// claim the state cannot support.
///
/// A free function, so the copy for all five states can be pinned without a
/// view.
///
/// The sentence is `Initialization.State.detail` and is not written again here.
/// It moved to the state when `get_initialization_state` became a second
/// consumer of it: an agent and the user reading this row have to be told the
/// same thing about the same run, which is the rule `Verification.Runner`
/// had to be corrected to. What stays is the part only a view can use.
func initializationRow(for state: Initialization.State) -> (detail: String, icon: String, tint: Color) {
    switch state {
    case .idle:
        (state.detail, "questionmark.circle", .secondary)
    case .inProgress:
        (state.detail, "clock", .secondary)
    case .completed:
        (state.detail, "checkmark.circle", .green)
    case .completedWithNote:
        (state.detail, "info.circle", .secondary)
    case .failed:
        (state.detail, "exclamationmark.triangle", .orange)
    }
}

/// Whether Rerun may be pressed.
///
/// One state refuses, and it is the actor's own rule surfaced rather than a
/// second opinion about it: `Initialization.Runner` already ignores a second
/// run for a workstream that has one in flight, because both would execute the
/// project's setup commands twice over one directory. Disabling the button is
/// how that refusal reads as unavailable instead of as a press that did nothing.
///
/// Nothing else is checked. A missing `initialization.yaml`, one that could not
/// be read, one declaring no steps — those are `Initialization.Config.Load`'s to
/// decide, and each is reported as a `.completedWithNote` that lands in the row
/// above. Refusing the press for them would trade an explanation for silence.
func canRerunInitialization(_ state: Initialization.State) -> Bool {
    if case .inProgress = state {
        return false
    }
    return true
}

struct WorkstreamInfoView: View {
    let workstreamID: UUID
    let workingDirectory: String
    let projectDirectory: String
    /// What background setup last reported for this workstream. Info is where
    /// it belongs: it is the permanent tab, and a `.completedWithNote` — "this
    /// project has no initialization.yaml, so no setup ran",
    /// "process-compose was not found" — is a fact about the workstream, not
    /// about the run pane. Nothing rendered it before, so those notes were
    /// written and thrown away.
    var setupState: Initialization.State = .idle
    /// Runs the project's initialization steps against this worktree again.
    /// No default: this row always renders, so a call site that forgot it would
    /// ship a Rerun button on every workstream that does nothing.
    let onRerunInitialization: () -> Void

    @EnvironmentObject var appEnv: AppEnvironment
    @AppStorage("atelier.defaultTerminal") private var defaultTerminal: String = ""
    @State private var copiedBranch = false
    @State private var copiedPath = false
    @State private var docFiles: [DocFile] = []
    @State private var selectedDoc: String?

    /// What the app already knows about this worktree.
    ///
    /// This tab used to run its own `Git.Operations.repoInfo` on every
    /// appearance for the branch and the dirtiness — the same probe the
    /// path-validity sweep makes for the same worktree, and `AppEnvironment`
    /// keeps the answer. Reading it here also stops the tab collapsing
    /// `isDirtyUnknown`: it rendered a green "Clean" for a `git status` that had
    /// not run, which is exactly what that flag exists to prevent.
    private var facts: Worktree.Facts? {
        appEnv.facts(for: workingDirectory)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                localSection
                githubSection
                shortcutSection
                setupSection
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
            if let branch = facts?.branch {
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
                switch facts?.cleanliness ?? .unknown {
                case .dirty:
                    Label("Uncommitted changes", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                case .clean:
                    Label("Clean", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .unknown:
                    // Three states, not two. `git status` failing, or not having
                    // run yet, is not the same as a clean tree, and saying so
                    // costs a word — the same call `WorktreeInfoRow` makes for
                    // `cleanlinessUnknown`.
                    Label("State unknown", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
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
        } else if let pr = appEnv.pullRequest(forWorktree: workingDirectory, in: projectDirectory) {
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
                        AppCommandChannel.shared.send(.purgeWorkstream(workstreamID))
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
        ExternalTerminal.open(directory: path, preferredBundleID: defaultTerminal)
    }

    private func loadInfo() {
        let workingDir = workingDirectory
        let gitHubProjectDir = projectDirectory
        // The same `repoInfo` this tab used to run itself, published into the
        // shared facts instead of into two `@State`s only this view could see.
        // It stays a probe made on appearance rather than a wait for the
        // fifteen-second sweep, because a tab the user has just opened should
        // not read "State unknown" for as long as fifteen seconds.
        Task {
            await appEnv.refreshGitFacts(for: workingDir)
            // The branch goes in as the optional `refreshGitHubInfo` already
            // takes, rather than gating the whole call on one. That call writes
            // `githubRepoCache` and the open-PR list regardless of any branch —
            // only the per-branch PR lookup needs one — so gating it meant a
            // worktree on a detached HEAD got no GitHub info on this tab at all.
            appEnv.refreshGitHubInfo(for: gitHubProjectDir, branch: appEnv.branchName(for: workingDir))
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
        let row = initializationRow(for: setupState)
        let canRerun = canRerunInitialization(setupState)
        return Section("Setup") {
            LabeledContent("Initialization") {
                HStack(spacing: 6) {
                    Image(systemName: row.icon)
                        .foregroundStyle(row.tint)
                    Text(row.detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Button("Rerun") { onRerunInitialization() }
                        .disabled(!canRerun)
                        .help(canRerun
                            ? NSLocalizedString("Run this project's initialization.yaml steps against this worktree again.", comment: "")
                            : NSLocalizedString("Initialization is already running.", comment: ""))
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
        ExternalTerminal.open(directory: path, preferredBundleID: defaultTerminal)
    }
}

private struct DirectoryActionButton: View {
    var icon: String = ""
    var assetIcon: String?
    var color: Color?
    /// `LocalizedStringKey`, not `String`: the `String` overloads of `.help` and
    /// `.accessibilityLabel` do not localize, so a plain parameter type would
    /// silently keep every call site's tooltip out of the strings file.
    let tooltip: LocalizedStringKey
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
