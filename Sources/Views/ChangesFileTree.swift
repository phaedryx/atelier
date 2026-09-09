// ABOUTME: Pure file-tree model + builder for the Changes tab "Files changed" sidebar.
// ABOUTME: Turns a flat [Git.DiffFile] into a sorted, fully-nested directory tree (dirs before files).

import SwiftUI

/// A node in the Changes "Files changed" tree. Directories carry `children`;
/// leaves carry the associated `Git.DiffFile`. `id` is the full slash-joined path so
/// it is stable across rebuilds and unique within the tree.
struct FileTreeNode: Identifiable, Equatable {
    /// Full path from the tree root (e.g. "Sources/Models/Git.swift"). For the
    /// synthetic root node this is the empty string.
    let id: String
    /// Last path component (the display name). Empty for the synthetic root.
    let name: String
    let isDirectory: Bool
    /// Child nodes for directories; nil for leaves.
    let children: [FileTreeNode]?
    /// The changed file for leaves; nil for directories and the root.
    let diffFile: Git.DiffFile?

    /// Build a sorted, fully-nested tree from a flat list of changed files.
    ///
    /// Sort order at every level: directories before files, each alphabetical
    /// (case-insensitive). The returned node is a synthetic root whose
    /// `children` are the top-level entries.
    static func build(from files: [Git.DiffFile]) -> FileTreeNode {
        // Mutable builder mirror of the immutable node, assembled bottom-up.
        final class Builder {
            let name: String
            let path: String
            var children: [String: Builder] = [:]
            var diffFile: Git.DiffFile?

            init(name: String, path: String) {
                self.name = name
                self.path = path
            }

            var isDirectory: Bool {
                diffFile == nil
            }
        }

        let root = Builder(name: "", path: "")

        for file in files {
            let components = file.relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }

            var node = root
            var prefix = ""
            for (index, component) in components.enumerated() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if let existing = node.children[component] {
                    node = existing
                } else {
                    let child = Builder(name: component, path: prefix)
                    node.children[component] = child
                    node = child
                }
                // The final component is the leaf — attach the file.
                if index == components.count - 1 {
                    node.diffFile = file
                }
            }
        }

        func freeze(_ builder: Builder) -> FileTreeNode {
            if builder.isDirectory {
                let sorted = builder.children.values
                    .map(freeze)
                    .sorted(by: order)
                return FileTreeNode(
                    id: builder.path,
                    name: builder.name,
                    isDirectory: true,
                    children: sorted,
                    diffFile: nil
                )
            }
            return FileTreeNode(
                id: builder.path,
                name: builder.name,
                isDirectory: false,
                children: nil,
                diffFile: builder.diffFile
            )
        }

        return freeze(root)
    }

    /// Sort comparator: directories before files, then alphabetical case-insensitive.
    private static func order(_ lhs: FileTreeNode, _ rhs: FileTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Sidebar view

/// GitHub-PR-style "Files changed" navigator for the Changes tab. Renders the
/// tree built from `files` as a collapsible outline; selecting a leaf invokes
/// `onSelect` with its relative path (the diff webview scrolls to that block).
///
/// Styled to match the editor's `FileTreeView`: the same vscicons file icons,
/// the same 12pt rows, and a flat background rather than the sidebar material.
/// `List` stays (rather than the editor's `ScrollView` of buttons) because its
/// `selection` binding is what gives the tree keyboard navigation.
struct ChangesFileTreeSidebar: View {
    let files: [Git.DiffFile]
    @Binding var selectedFilePath: String?
    let onSelect: (String) -> Void

    /// Built when `files` changes, not from `body`. `FileTreeNode.build` walks
    /// every changed path and sorts every level; as a computed property it ran
    /// again on each re-render — and selection alone re-renders this view, so a
    /// keyboard walk down a large diff rebuilt the whole tree per keypress.
    @State private var rootChildren: [FileTreeNode] = []

    var body: some View {
        List(selection: $selectedFilePath) {
            ForEach(rootChildren) { node in
                ChangesFileTreeRow(node: node, selectedFilePath: selectedFilePath)
            }
        }
        .listStyle(.plain)
        // `.sidebar` painted the tree on vibrancy material — darker than the
        // editor's tree and with its own light selection fill. `.plain` plus a
        // hidden scroll background lets the window colour through, so both
        // trees sit on one flat surface. The header row went with it: the
        // toolbar above already reports the changed-file count.
        .scrollContentBackground(.hidden)
        .accessibilityLabel(Text("Files changed"))
        .onAppear { rebuild() }
        .onChange(of: files) { rebuild() }
        // Selection drives the scroll — works for both mouse clicks and keyboard
        // navigation. Skipped when selection is cleared (mode switch / reload).
        .onChange(of: selectedFilePath) { _, newValue in
            if let newValue {
                onSelect(newValue)
            }
        }
    }

    private func rebuild() {
        rootChildren = FileTreeNode.build(from: files).children ?? []
    }
}

/// One row in the file tree. Directories render a `DisclosureGroup` over their
/// children; leaves render a selectable file row with a file icon and counts.
private struct ChangesFileTreeRow: View {
    let node: FileTreeNode
    let selectedFilePath: String?
    /// Directories start expanded so the tree shows files all the way down on
    /// load (no clicking through each level). Users can still collapse manually.
    @State private var isExpanded = true

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children ?? []) { child in
                    ChangesFileTreeRow(node: child, selectedFilePath: selectedFilePath)
                }
            } label: {
                HStack(spacing: 4) {
                    FileIconImage(icon: FileTypeIcon.folderIcon(for: node.name, isExpanded: isExpanded))
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            ChangesFileLeafRow(node: node)
                .tag(node.id)
                // Overrides the row fill so `List` cannot paint its own
                // selection colour — the tree uses the editor's tinted,
                // rounded selection instead.
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(node.id == selectedFilePath ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
    }
}

/// A single changed-file leaf: file icon, name, then a right-aligned trailing
/// slot holding `+a −d` counts (or a "Bin" indicator for binary files) and the
/// status letter last — `+1 −1 M`, `+2 A`, `−13 D`. The letter used to lead the
/// row, which pushed every filename right by a column the eye had to skip.
private struct ChangesFileLeafRow: View {
    let node: FileTreeNode

    @State private var isHovering = false
    /// Brief checkmark confirmation after a copy, cleared by a delayed reset.
    @State private var copied = false

    private var file: Git.DiffFile? {
        node.diffFile
    }

    var body: some View {
        HStack(spacing: 4) {
            FileIconImage(icon: FileTypeIcon.icon(for: node.name))
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            copyButton
            Spacer(minLength: 4)
            counts
            statusBadge
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    /// GitHub-PR-style copy control: reveals on hover, copies the file's full
    /// relative path, and flashes a checkmark as confirmation.
    private var copyButton: some View {
        Group {
            if copied {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .help(Text("File path copied"))
                    .accessibilityLabel(Text("File path copied"))
            } else {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.id, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Copy File Path"))
                .accessibilityLabel(Text("Copy File Path"))
            }
        }
        .opacity(isHovering || copied ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: copied)
    }

    /// The status letter, last in the row and in a fixed-width frame so the
    /// letters line up down the tree however wide the counts beside them are.
    /// No tooltip: the letter is the label, and a hover popup that only
    /// spelled it out was noise on every row.
    @ViewBuilder
    private var statusBadge: some View {
        if let status = file?.status {
            Text(status.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.badgeColor(for: status))
                // Wide enough for a 10pt bold monospaced cap with its bearing;
                // a tighter frame center-overflows rather than truncating, so it
                // looks fine until a different system font size shifts it.
                .frame(width: 12)
                .accessibilityLabel(Text(Self.accessibilityLabel(for: status)))
        }
    }

    @ViewBuilder
    private var counts: some View {
        if let file, file.isBinary {
            Text("Bin")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(Text("Binary file"))
                .accessibilityLabel(Text("Binary file"))
        } else if let file, file.added > 0 || file.deleted > 0 {
            HStack(spacing: 4) {
                if file.added > 0 {
                    Text("+\(file.added)")
                        .foregroundStyle(Color(red: 0.25, green: 0.72, blue: 0.31))
                }
                if file.deleted > 0 {
                    (Text("−") + Text("\(file.deleted)"))
                        .foregroundStyle(Color(red: 0.97, green: 0.32, blue: 0.29))
                }
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    /// Status letter color, matching the diff webview conventions (GitHub palette).
    static func badgeColor(for status: Git.DiffFile.Status) -> Color {
        switch status {
        case .added: Color(red: 0.25, green: 0.72, blue: 0.31)
        case .modified: Color(red: 0.82, green: 0.60, blue: 0.13)
        case .deleted: Color(red: 0.97, green: 0.32, blue: 0.29)
        case .renamed: Color(red: 0.35, green: 0.65, blue: 1.0)
        }
    }

    /// Localized VoiceOver label for a status; the visible letters stay A/M/D/R.
    static func accessibilityLabel(for status: Git.DiffFile.Status) -> String {
        switch status {
        case .added: NSLocalizedString("Added", comment: "Changes sidebar: file status")
        case .modified: NSLocalizedString("Modified", comment: "Changes sidebar: file status")
        case .deleted: NSLocalizedString("Deleted", comment: "Changes sidebar: file status")
        case .renamed: NSLocalizedString("Renamed", comment: "Changes sidebar: file status")
        }
    }
}
