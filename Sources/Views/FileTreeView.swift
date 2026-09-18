// ABOUTME: SwiftUI view that renders a nested file tree with togglable folders and selection support.
// ABOUTME: Shows file-type icons, git status colors, and reduced opacity for gitignored entries.

import SwiftUI

/// The editor's file navigator: a lazily-loaded tree of the worktree, with
/// Material Icon Theme file icons, git status colors and dimmed gitignored
/// entries. (It credited vscicons until #175 swapped the vendored theme out;
/// `Resources/material-icon-theme-LICENSE.txt` is the bundled licence.)
///
/// `List(selection:)` over `DisclosureGroup`, the shape `ChangesFileTreeSidebar`
/// already uses — its own comment names this tree as the one that had no keyboard
/// navigation, because a `ScrollView` of `Button`s has no selection for the arrow
/// keys to move. The indentation, the disclosure triangle and its gutter column all
/// come from `List` now, so the hand-rolled `depth * 16` padding and the clear
/// 10pt spacer that faked the triangle column in leaf rows are gone with it.
///
/// **Long names truncate rather than scrolling sideways.** The rows used to be
/// `.fixedSize(horizontal: true)` inside a `ScrollView([.horizontal, .vertical])`;
/// a `List` nested in a horizontal `ScrollView` loses its own vertical scrolling
/// and virtualization, so this trades the sideways scroll for
/// `.truncationMode(.middle)` — the same trade, and the same middle ellipsis, that
/// `ChangesFileTreeSidebar` makes.
struct FileTreeView: View {
    let nodes: [FileNode]
    let selectedPath: String?
    let gitStatus: Git.FileStatusProvider
    var onSelect: (String) -> Void
    var onExpandFolder: (String) -> Void

    @State private var expandedFolders: Set<String> = []
    /// Where the arrow keys have walked to, which is *not* the same thing as the
    /// open file. `List` tags every row it draws — `ForEach` over `Identifiable`
    /// supplies the tag, so directories are selectable whether or not they carry
    /// an explicit `.tag` — and a cursor that could not rest on a directory could
    /// not be walked past one either. nil means "wherever the open file is", which
    /// is what every change of `selectedPath` puts it back to.
    ///
    /// It **is** cleared when the owner refuses a file, by the `.onChange(of:
    /// cursor)` below — so the tree cannot show a selection the editor does not
    /// have. That clear rests on a coupling worth stating, because nothing at
    /// either site declares it: `EditorView.navigateToFile` sets
    /// `currentFilePath` **synchronously**, so by the time the change handler
    /// runs, an *accepted* selection has already moved `selectedPath` and the
    /// `newCursor != selectedPath` guard leaves it alone. A refusal
    /// (`handleFileSelection` putting up the save alert) moves nothing, so the
    /// guard passes and the cursor drops back to the open file. Make that
    /// assignment asynchronous — a `Task`, a debounce, an animation — and the
    /// clear starts firing on accepted selections too, which breaks the arrow
    /// walk it exists to protect: two rows on one press, none on the next.
    @State private var cursor: String?

    var body: some View {
        // A computed binding rather than state synced to `selectedPath`: the owner
        // may *refuse* a selection — `EditorView.handleFileSelection` puts up the
        // save alert for a dirty file and leaves `currentFilePath` alone, and
        // Cancel then changes nothing at all, so there would be no change event to
        // resync on. Reading the answer back each render is what makes a refusal
        // correct by construction.
        List(selection: Binding(
            get: { cursor ?? selectedPath },
            set: { newValue in
                cursor = newValue
                // Only files are opened. A directory is a place the cursor may
                // rest, never something to hand to the editor: `onSelect` reaches
                // `navigateToFile`, which would report a directory as a file that
                // could not be read.
                //
                // This fires for *every* way the selection moves, the arrow keys
                // included — so walking the list opens each file it passes over,
                // rather than only the one the user settles on. That is what a
                // `List(selection:)` gives, and it is stated here rather than
                // worked around: opening is cheap (a read plus a Monaco model
                // swap), and the alternative — a commit gesture, so the arrows
                // move a cursor that Return then opens — is a different
                // interaction than the one this tree shipped with. A dirty file
                // is the case that bites, and it is already handled: the owner
                // refuses, the save alert goes up, and the cursor drops back.
                if let newValue, !isDirectory(newValue) {
                    onSelect(newValue)
                }
            }
        )) {
            ForEach(nodes) { node in
                FileTreeNodeRow(
                    node: node,
                    selectedPath: selectedPath,
                    cursor: cursor,
                    gitStatus: gitStatus,
                    expandedFolders: $expandedFolders,
                    onExpandFolder: onExpandFolder
                )
            }
        }
        .listStyle(.plain)
        // `.plain` plus a hidden scroll background lets the window colour through,
        // so this tree and the Changes tab's sit on one flat surface — the pairing
        // `ChangesFileTreeSidebar` documents at its own `.listStyle`.
        .scrollContentBackground(.hidden)
        .onAppear {
            expandAncestors(of: selectedPath)
        }
        .onChange(of: selectedPath) { _, newPath in
            // The open file moved — by the file finder, by Save As, by the initial
            // file. The cursor follows it rather than staying where it was.
            cursor = nil
            expandAncestors(of: newPath)
        }
        .onChange(of: cursor) { _, newCursor in
            // A file the owner declined to open: the save alert is up and
            // `selectedPath` never moved. Dropping the cursor puts it back on the
            // file that is actually open, so the tree cannot show a selection the
            // editor does not have. An *accepted* selection has already updated
            // `selectedPath` by the time this runs, so it is left alone — which
            // holds only because `navigateToFile` writes it synchronously. See
            // `cursor`'s own comment; verified by clicking a file with the owner
            // refusing and then accepting.
            guard let newCursor, newCursor != selectedPath, !isDirectory(newCursor) else { return }
            cursor = nil
        }
    }

    /// The node at `path`, or nil if the tree has not loaded that far. Descends by
    /// path component rather than scanning, so it costs depth × siblings and not
    /// the whole tree.
    private func node(at path: String) -> FileNode? {
        var level = nodes
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            guard let found = level.first(where: { $0.id == prefix }) else { return nil }
            if prefix == path {
                return found
            }
            level = found.children ?? []
        }
        return nil
    }

    /// An unknown path answers false, which routes it to `onSelect` exactly as a
    /// file would be — the honest default when the tree cannot say otherwise.
    private func isDirectory(_ path: String) -> Bool {
        node(at: path)?.isDirectory == true
    }

    /// Expand all ancestor folders so a selected file is visible in the tree.
    /// Also triggers lazy loading for any unloaded ancestor directory.
    ///
    /// **Only an unloaded one.** This asked for every ancestor unconditionally,
    /// which was survivable while the selection moved on a click and is not now
    /// that the arrow keys move it: each call re-reads the directory and
    /// republishes the whole `nodes` tree, and doing that on every keystroke
    /// disrupts the very walk that republish is reacting to — measured, as an
    /// arrow walk that advanced two rows on one press and none on the next. The
    /// loading behaviour is unchanged; what is gone is reloading what is already
    /// loaded. A path the tree does not know yet answers nil, so it still loads.
    private func expandAncestors(of path: String?) {
        guard let path, !path.isEmpty else { return }
        let components = path.split(separator: "/").map(String.init)
        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? component : current + "/" + component
            if node(at: current)?.isLoaded != true {
                onExpandFolder(current)
            }
            expandedFolders.insert(current)
        }
    }
}

// MARK: - Git status colors (VSCode conventions)

private let modifiedColor = Color(red: 0.886, green: 0.753, blue: 0.553) // #E2C08D
private let untrackedColor = Color(red: 0.451, green: 0.788, blue: 0.569) // #73C991

private func gitTextColor(for status: Git.FileStatus?) -> Color {
    switch status {
    case .modified: modifiedColor
    case .untracked: untrackedColor
    case .ignored, .none: .primary
    }
}

// MARK: - Node View

/// One row. Directories render a `DisclosureGroup` over their children; files
/// render a leaf row. The explicit `.tag` on a leaf is belt and braces, matching
/// `ChangesFileTreeRow`: `ForEach` over `Identifiable` already tags every row it
/// draws with the element's `id`, which is why directories are selectable too.
private struct FileTreeNodeRow: View {
    let node: FileNode
    let selectedPath: String?
    let cursor: String?
    let gitStatus: Git.FileStatusProvider
    /// Expansion lives in `FileTreeView`, not in this row: `expandAncestors` has
    /// to reach it to open the path down to a file the editor was told to show.
    @Binding var expandedFolders: Set<String>
    var onExpandFolder: (String) -> Void

    private var isExpanded: Bool {
        expandedFolders.contains(node.id)
    }

    private var isIgnored: Bool {
        gitStatus.isIgnored(node.id)
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(node.children ?? []) { child in
                    FileTreeNodeRow(
                        node: child,
                        selectedPath: selectedPath,
                        cursor: cursor,
                        gitStatus: gitStatus,
                        expandedFolders: $expandedFolders,
                        onExpandFolder: onExpandFolder
                    )
                }
            } label: {
                // The whole row toggled in the ScrollView-of-Buttons this
                // replaced, and a `List` does not give that back: a tagged row —
                // and `ForEach` over `Identifiable` tags every one — takes a click
                // as *selection*, so without this only the ~16pt disclosure
                // triangle expanded a folder. Measured, not assumed.
                //
                // The frame has to come before `contentShape`, and it is the half
                // that is easy to leave out: a label is only as wide as its text,
                // so `contentShape` alone made a long name clickable and a short
                // one a ~40pt target with dead space beside it — which reads as
                // "clicking the name sometimes works".
                directoryLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { expansionBinding.wrappedValue.toggle() }
            }
            .listRowBackground(rowFill)
        } else {
            fileRow
                .tag(node.id)
                .listRowBackground(rowFill)
        }
    }

    /// Overrides the row fill so `List` cannot paint its own selection colour —
    /// both trees use the same tinted, rounded selection. Two rows can carry it at
    /// once, and deliberately: the open file keeps its tint while the arrow keys
    /// walk over a directory, so a keyboard walk never hides which file is open.
    private var rowFill: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(node.id == selectedPath || node.id == cursor ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    /// The false→true edge is what triggers lazy loading, and it has to be the
    /// *edge*: SwiftUI issues redundant `set(true)` calls, and `isLoaded` is still
    /// false between asking for the children and their arriving — so gating on
    /// `!node.isLoaded` alone would load the same directory repeatedly.
    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { isExpanded },
            set: { on in
                withAnimation(.easeInOut(duration: 0.15)) {
                    if on {
                        guard !expandedFolders.contains(node.id) else { return }
                        if !node.isLoaded {
                            onExpandFolder(node.id)
                        }
                        expandedFolders.insert(node.id)
                    } else {
                        expandedFolders.remove(node.id)
                    }
                }
            }
        )
    }

    private var directoryLabel: some View {
        HStack(spacing: 4) {
            FileIconImage(icon: FileTypeIcon.folderIcon(for: node.name, isExpanded: isExpanded))
            Text(node.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(gitTextColor(for: gitStatus.status(for: node.id, isDirectory: true)))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(isIgnored ? 0.5 : 1.0)
    }

    private var fileRow: some View {
        HStack(spacing: 4) {
            FileIconImage(icon: FileTypeIcon.icon(for: node.name))
            Text(node.name)
                .font(.system(size: 12))
                .foregroundStyle(gitTextColor(for: gitStatus.status(for: node.id, isDirectory: false)))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(isIgnored ? 0.5 : 1.0)
    }
}
