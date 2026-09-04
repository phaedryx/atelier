// ABOUTME: Sheet that shows uncommitted changes and unmerged commits for a git worktree.
// ABOUTME: Allows force-removing orphaned dirty worktrees or opening them in a terminal.

import SwiftUI

struct WorktreeDetailSheet: View {
    let worktree: Worktree.Info
    let projectDirectory: String
    let defaultTerminal: String
    let onForceRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detail: Worktree.Detail?
    @State private var isLoading = true
    @State private var showForceRemoveConfirm = false
    @State private var showDiscardConfirm = false
    @State private var showForceRemoveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(worktree.branch ?? "detached")
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                Text(worktree.path.abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if isLoading {
                Spacer()
                ProgressView()
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let detail {
                Form {
                    if !detail.changes.isEmpty {
                        Section {
                            ForEach(detail.changes) { change in
                                FileChangeButton(change: change, directory: worktree.path)
                            }
                        } header: {
                            HStack {
                                Text("Uncommitted Changes")
                                Spacer()
                                Text("\(detail.changes.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !detail.unmergedCommits.isEmpty {
                        Section {
                            ForEach(detail.unmergedCommits) { commit in
                                HStack(spacing: 8) {
                                    Text(commit.hash)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(commit.message)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        } header: {
                            HStack {
                                Text("Unmerged Commits")
                                Spacer()
                                Text("\(detail.unmergedCommits.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // A failed probe reports nothing, which is the same shape as a
                    // clean worktree. Saying "nothing found" for both told the user
                    // there was nothing to lose at the one moment the check had not
                    // run — with Force Remove sitting right below it.
                    if !detail.isFullyLoaded {
                        Section {
                            Label(Self.unavailableMessage(for: detail), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else if detail.changes.isEmpty, detail.unmergedCommits.isEmpty {
                        Section {
                            Text("No uncommitted changes or unmerged commits found.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()

            // Actions
            HStack {
                Button(action: { openInTerminal() }) {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .buttonStyle(.borderless)

                Spacer()

                if let detail, !detail.changes.isEmpty {
                    Button(role: .destructive, action: { showDiscardConfirm = true }) {
                        Label("Discard Changes", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                }

                Button(role: .destructive, action: { showForceRemoveConfirm = true }) {
                    Label("Force Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 400)
        .onAppear { loadDetail() }
        .alert("Force Remove Worktree", isPresented: $showForceRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                forceRemove()
            }
        } message: {
            Text(forceRemoveWarning)
        }
        .alert("Discard All Changes", isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { discardChanges() }
        } message: {
            Text("This will permanently discard all uncommitted changes, including staged files and untracked files.")
        }
        .alert("Could Not Remove Worktree", isPresented: $showForceRemoveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The worktree directory is still on disk. Close anything using it and try again.")
        }
    }

    /// The reassuring version of this sentence is only honest when both probes ran.
    ///
    /// Per-probe, not `isFullyLoaded`: collapsing the two flags with AND made this
    /// contradict the sheet behind it. With changes readable and commits not, the
    /// sheet listed twelve files by name while this said the contents "could not be
    /// read" — less informative than the sentence it replaced, and visibly wrong.
    ///
    /// One value rather than a branch inside the alert's `message:` builder: an alert
    /// message is the one place SwiftUI is picky about wrapped content, and a
    /// confirmation that renders *no* message is worse than the wrong one this
    /// replaces.
    private var forceRemoveWarning: LocalizedStringKey {
        Self.forceRemoveWarning(for: detail)
    }

    /// `static` and non-private so the mapping can be tested directly. The bug this
    /// replaced — one message for both probes — was a defect in exactly this table,
    /// and no test could reach it while it lived on the view as a private property.
    static func forceRemoveWarning(for detail: Worktree.Detail?) -> LocalizedStringKey {
        // No detail yet: the load has not answered, so nothing has been established.
        guard let detail else {
            return "This worktree has not been read yet, so what would be discarded is unknown. This permanently removes it either way."
        }
        return switch (detail.changesUnavailable, detail.unmergedCommitsUnavailable) {
        case (false, false):
            "This will permanently discard all uncommitted changes and unmerged commits in this worktree."
        case (true, true):
            "This worktree's contents could not be read, so what would be discarded is unknown. This permanently removes it either way."
        case (true, false):
            "Uncommitted changes could not be read, so what would be discarded is unknown. Anything listed above is removed too."
        case (false, true):
            "Unmerged commits could not be read, so what would be discarded is unknown. Anything listed above is removed too."
        }
    }

    /// Names which check didn't run, so the user knows what the sheet is silent about
    /// rather than only that something went wrong.
    ///
    /// `LocalizedStringKey`, not `String`: `Label` takes a plain `String` through its
    /// `StringProtocol` overload, which does not localize.
    static func unavailableMessage(for detail: Worktree.Detail) -> LocalizedStringKey {
        switch (detail.changesUnavailable, detail.unmergedCommitsUnavailable) {
        case (true, true):
            "This worktree's state could not be read. It may hold uncommitted changes or unmerged commits."
        case (true, false):
            "Uncommitted changes could not be read. This worktree may still hold some."
        // Deliberately does not name a cause: this flag is set both by an
        // unresolvable base branch and by `git log` itself failing or timing out,
        // and naming the wrong one sends the user to investigate the wrong thing.
        case (false, true):
            "Unmerged commits could not be read. This worktree may still hold some."
        case (false, false):
            ""
        }
    }

    private func loadDetail() {
        let path = worktree.path
        let mainRepo = projectDirectory
        Task.detached {
            let result = Git.Operations.worktreeDetail(at: path, mainRepoPath: mainRepo)
            await MainActor.run {
                detail = result
                isLoading = false
            }
        }
    }

    private func discardChanges() {
        let path = worktree.path
        let mainRepo = projectDirectory
        Task.detached {
            Git.Operations.discardAllChanges(at: path)
            let refreshed = Git.Operations.worktreeDetail(at: path, mainRepoPath: mainRepo)
            await MainActor.run {
                detail = refreshed
            }
        }
    }

    private func forceRemove() {
        let path = worktree.path
        let projectDir = projectDirectory
        Task.detached {
            Git.Operations.forceRemoveWorktreeByPath(worktreePath: path, projectPath: projectDir)
            // That call returns nothing and falls back to deleting the directory itself,
            // so whether the directory survived is the only honest signal there is.
            // Reporting success unconditionally made the parent drop a worktree from its
            // model while it was still on disk.
            let removed = !FileManager.default.fileExists(atPath: path)
            await MainActor.run {
                guard removed else {
                    showForceRemoveFailed = true
                    return
                }
                onForceRemove()
                dismiss()
            }
        }
    }

    private func openInTerminal() {
        let url = URL(fileURLWithPath: worktree.path)
        if !defaultTerminal.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultTerminal)
        {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: config)
        }
    }
}

private struct FileChangeButton: View {
    let change: Worktree.Detail.FileChange
    let directory: String

    @State private var isHovering = false

    var body: some View {
        Button(action: { openFile() }) {
            HStack(spacing: 8) {
                Image(systemName: change.status.icon)
                    .font(.caption)
                    .foregroundStyle(change.isStaged ? .green : .orange)
                    .frame(width: 14)
                Text(change.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if change.isStaged {
                    Text("staged")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.accentColor.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private func openFile() {
        let fullPath = URL(fileURLWithPath: directory)
            .appendingPathComponent(change.path).path

        if let nvimPath = CommandLineTools.path(for: "nvim") {
            let escaped = fullPath.replacingOccurrences(of: "'", with: "'\\''")
            let script = """
            tell application "Terminal"
                activate
                do script "\(nvimPath) '\(escaped)'"
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
        }
    }
}
