// ABOUTME: Sheet that shows uncommitted changes and unmerged commits for a git worktree.
// ABOUTME: Allows force-removing orphaned dirty worktrees or opening them in a terminal.

import SwiftUI

struct WorktreeDetailSheet: View {
    let worktree: WorktreeInfo
    let projectDirectory: String
    let defaultTerminal: String
    let onForceRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detail: WorktreeDetail?
    @State private var isLoading = true
    @State private var showForceRemoveConfirm = false
    @State private var showDiscardConfirm = false

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

                    if detail.changes.isEmpty, detail.unmergedCommits.isEmpty {
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
            Text("This will permanently discard all uncommitted changes and unmerged commits in this worktree.")
        }
        .alert("Discard All Changes", isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { discardChanges() }
        } message: {
            Text("This will permanently discard all uncommitted changes, including staged files and untracked files.")
        }
    }

    private func loadDetail() {
        let path = worktree.path
        let mainRepo = projectDirectory
        Task.detached {
            let result = GitOperations.worktreeDetail(at: path, mainRepoPath: mainRepo)
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
            GitOperations.discardAllChanges(at: path)
            let refreshed = GitOperations.worktreeDetail(at: path, mainRepoPath: mainRepo)
            await MainActor.run {
                detail = refreshed
            }
        }
    }

    private func forceRemove() {
        let path = worktree.path
        let projectDir = projectDirectory
        Task.detached {
            GitOperations.forceRemoveWorktreeByPath(worktreePath: path, projectPath: projectDir)
            await MainActor.run {
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
    let change: WorktreeDetail.FileChange
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
