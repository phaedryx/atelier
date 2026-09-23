// ABOUTME: Embedded code editor with a file tree sidebar for navigating the worktree.
// ABOUTME: Uses Monaco editor in a shared WKWebView via MonacoEditorBridge for syntax highlighting.

import SwiftUI
import WebKit

struct EditorView: View {
    let workingDirectory: String
    let fileTree: [FileNode]
    let gitStatus: Git.FileStatusProvider
    let initialFilePath: String?
    let bridge: MonacoEditorBridge
    let modelId: String
    /// The line this tab was asked to open at, consumed on first load.
    ///
    /// A closure rather than an `Int?` because taking the value mutates the
    /// model: the view is recreated on every navigation, and a plain value would
    /// be re-read and re-scrolled each time, dragging the user back to a line
    /// they had already scrolled away from. Defaults to "no line", so every
    /// existing call site is unaffected.
    var initialLine: () -> Int? = { nil }
    @Binding var isDirtyState: Bool
    /// Whether this tab's Monaco model already holds its file's contents.
    ///
    /// A binding onto `WorkspaceModel.editorFileLoaded`, not `@State`, and that
    /// is the whole of the fix for the edits this view used to discard. The
    /// editor is a `@ViewBuilder` branch of `TerminalContainerView`, which is
    /// `.id(workstreamID)`, so leaving the tab or the workstream destroys this
    /// view: a `@State` flag came back `false`, `onAppear` read that as "never
    /// loaded" and reloaded the file from disk over the model the user had been
    /// typing into. The flag has to outlive the view, so it lives where the run
    /// session's state lives — on the object the surface cache owns.
    @Binding var isFileLoaded: Bool
    var onFileChanged: ((String?) -> Void)?
    var onExpandFolder: ((String) -> Void)?
    /// Incremented by the workspace when the user presses Cmd+P while this
    /// editor tab is active; each change opens the file finder.
    var fileFinderRequest: Int = 0

    // Current file state
    @State private var currentFilePath: String?
    @State private var loadError: String?
    @State private var filePathCopied = false

    /// File tree visibility
    @State private var showFileTree = true

    // File finder (quick open)
    @State private var isFinderOpen = false
    @State private var finderQuery = ""
    /// One result row's height. Fixed because `List` has no ideal height of its
    /// own, so it is what the finder's height is counted in; the row is
    /// single-line.
    private static let finderRowHeight: CGFloat = 22

    /// The highlighted result's path. An id rather than an index: the results
    /// array is rebuilt on every keystroke, and an index into a stale array is
    /// what the two-identity-systems bug below was a symptom of.
    @State private var finderSelection: String?
    @State private var fileIndex: [FileFinder.Entry] = []
    @State private var finderResults: [String] = []
    @State private var isScanningFiles = false
    @State private var finderKeyMonitor: Any?
    @FocusState private var finderFieldFocused: Bool

    // Save confirmation for file switching
    @State private var pendingFilePath: String?
    @State private var showSaveAlert = false
    /// A write that failed, reported in an alert rather than through
    /// `loadError`. `loadError` draws an opaque overlay over the editor, which
    /// is right for a file that could not be read and wrong for one that could
    /// not be written: the unsaved text is still in the model, and covering it
    /// hides the very thing the user is trying to rescue.
    @State private var saveError: String?

    private var isDirty: Bool {
        isDirtyState
    }

    private var currentFileName: String {
        guard let path = currentFilePath else { return "file" }
        return (path as NSString).lastPathComponent
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if showFileTree {
                    fileTreePanel
                        .frame(width: 220)
                    Divider()
                }
                VStack(spacing: 0) {
                    editorToolbar
                    editorPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // On the panel rather than beside the switch-file alert
                        // below: that alert is dismissing at the moment an
                        // async save sets `saveError`, and two alert modifiers
                        // on one view are not reliable that close together. A
                        // refusal to navigate that says nothing is the failure
                        // this fix exists to remove, so the two sit on
                        // different views.
                        .alert(
                            Text("The file could not be saved."),
                            isPresented: Binding(
                                get: { saveError != nil },
                                set: {
                                    if !$0 {
                                        saveError = nil
                                    }
                                }
                            )
                        ) {
                            Button(NSLocalizedString("OK", comment: "")) { saveError = nil }
                        } message: {
                            Text(saveError ?? "")
                        }
                }
            }
            if isFinderOpen {
                finderOverlay
                    .padding(.top, 44)
            }
        }
        .onAppear {
            if isFileLoaded, let initialFilePath {
                // This tab has been here before: its Monaco model already holds
                // the file, unsaved edits and all. Attach to it rather than
                // reading the file again — `loadFile` pushes disk contents
                // through `openFile`, whose `setValue` replaces whatever the
                // user had typed and resets the model's clean version, taking
                // the dirty dot and the close prompt with it.
                //
                // `initialFilePath` is `editorFilePaths[id]`, which every
                // navigation and Save As keeps current, so it is the path the
                // model is holding. The `let` is load-bearing: Save As to a file
                // outside the worktree removes that entry and detaches the
                // editor, and there is nowhere durable to record an absolute
                // path, so that case deliberately falls through to the
                // do-nothing it has always had rather than attaching underneath
                // the opaque "Select a file to edit" placeholder.
                currentFilePath = initialFilePath
                bridge.switchModel(modelId: modelId)
            } else if let initialFilePath, currentFilePath == nil {
                navigateToFile(initialFilePath)
            }
        }
        .onDisappear {
            closeFileFinder()
        }
        .onChange(of: fileFinderRequest) { _, _ in
            openFileFinder()
        }
        .onChange(of: finderQuery) { _, _ in
            refreshFinderResults()
        }
        .alert(
            Text(String(
                format: NSLocalizedString("Do you want to save changes to \"%@\"?", comment: ""),
                currentFileName
            )),
            isPresented: $showSaveAlert
        ) {
            Button(NSLocalizedString("Save", comment: "")) {
                Task {
                    let outcome = await saveFile()
                    if Self.mayNavigate(after: outcome), let pending = pendingFilePath {
                        navigateToFile(pending)
                    }
                    pendingFilePath = nil
                }
            }
            Button(NSLocalizedString("Don't Save", comment: ""), role: .destructive) {
                if let pending = pendingFilePath {
                    navigateToFile(pending)
                }
                pendingFilePath = nil
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                pendingFilePath = nil
            }
        } message: {
            Text("Your changes will be lost if you don't save them.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveEditor)) { _ in
            Task { await saveFile() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveEditorAs)) { _ in
            Task { await saveFileAs() }
        }
    }

    // MARK: - Editor Toolbar

    private var editorToolbar: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showFileTree.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(showFileTree ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle file tree")

            Button {
                openFileFinder()
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(isFinderOpen ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Find File (\u{2318}P)", comment: ""))

            if let currentFilePath {
                HStack(spacing: 6) {
                    Text((currentFilePath as NSString).lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    copyFilePathButton
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// Copies the current file's relative path and flashes a checkmark as
    /// confirmation.
    private var copyFilePathButton: some View {
        Group {
            if filePathCopied {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .help(Text("File path copied"))
                    .accessibilityLabel(Text("File path copied"))
            } else {
                Button {
                    guard let path = currentFilePath else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    filePathCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        filePathCopied = false
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
        .animation(.easeInOut(duration: 0.12), value: filePathCopied)
    }

    // MARK: - File Tree Panel

    private var fileTreePanel: some View {
        FileTreeView(nodes: fileTree, selectedPath: currentFilePath, gitStatus: gitStatus) { selectedPath in
            handleFileSelection(selectedPath)
        } onExpandFolder: { path in
            onExpandFolder?(path)
        }
    }

    // MARK: - Editor Panel

    /// MonacoEditorView is ALWAYS in the tree so the WKWebView starts loading
    /// immediately when the editor tab opens (before the user picks a file).
    /// Placeholder and error states overlay on top with opaque backgrounds.
    private var editorPanel: some View {
        ZStack {
            MonacoEditorView(bridge: bridge)
            if currentFilePath == nil {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Select a file to edit")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(loadError)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }

    // MARK: - File Finder

    private var finderOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(
                    NSLocalizedString("Search files by name", comment: ""),
                    text: $finderQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($finderFieldFocused)
                if isScanningFiles {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if finderResults.isEmpty {
                if isScanningFiles {
                    Text(NSLocalizedString("Scanning files…", comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if !finderQuery.isEmpty {
                    Text(NSLocalizedString("No files found", comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            } else {
                // Paths are unique, so the path is the row's identity and the
                // selection's — one identity system rather than the two (a
                // `ForEach` id *and* an `.id()`) that used to desync rendering
                // in the lazy container this replaced.
                FilterResultList(
                    items: finderResults,
                    id: \.self,
                    selection: $finderSelection,
                    rowHeight: Self.finderRowHeight,
                    maxHeight: 260,
                    onActivate: selectFinderResult
                ) { path, isSelected in
                    finderRow(path: path, isSelected: isSelected)
                }
            }
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func finderRow(path: String, isSelected: Bool) -> some View {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let icon = FileTypeIcon.icon(for: name)

        return HStack(spacing: 6) {
            FileIconImage(icon: icon)
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
            if !dir.isEmpty {
                Text(dir)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func openFileFinder() {
        isFinderOpen = true
        finderQuery = ""
        finderResults = []
        finderSelection = nil
        installFinderKeyMonitor()
        DispatchQueue.main.async {
            finderFieldFocused = true
        }
        scanFinderFiles()
    }

    private func closeFileFinder() {
        isFinderOpen = false
        finderFieldFocused = false
        if let monitor = finderKeyMonitor {
            NSEvent.removeMonitor(monitor)
            finderKeyMonitor = nil
        }
    }

    /// The finder's query is driven entirely by this local key monitor, not by
    /// the TextField's first-responder editing. This makes the query a faithful
    /// replay of the exact keys pressed regardless of focus state, field editor
    /// quirks, or SwiftUI binding timing — the field is a pure display.
    /// arrow/return/escape keys are intercepted here (field editor would consume
    /// them before SwiftUI's focus system).
    private func installFinderKeyMonitor() {
        guard finderKeyMonitor == nil else { return }
        finderKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isFinderOpen else { return event }
            if let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "\u{1b}": // Escape
                    closeFileFinder()
                    return nil
                case "\r", "\n": // Return
                    openSelectedFinderResult()
                    return nil
                case "\u{F700}", "\u{F701}": // Up / Down arrow
                    moveFinderSelection(chars == "\u{F700}" ? -1 : 1)
                    return nil
                case "\u{7f}", "\u{08}": // Delete / Backspace
                    if !finderQuery.isEmpty {
                        finderQuery.removeLast()
                    }
                    return nil
                default:
                    let flags = event.modifierFlags
                    if flags.contains(.command), chars.lowercased() == "v" {
                        appendPasteboardText()
                        return nil
                    }
                    // Plain printable characters: append and never let them
                    // reach the field editor (which would double-insert).
                    if flags.intersection([.command, .option, .control]).isEmpty, !chars.isEmpty {
                        finderQuery.append(chars)
                        return nil
                    }
                    return event
                }
            }
            return event
        }
    }

    private func appendPasteboardText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        finderQuery.append(text.replacingOccurrences(of: "\n", with: " "))
    }

    private func scanFinderFiles() {
        isScanningFiles = true
        fileIndex = []
        finderResults = []
        let root = workingDirectory
        let ignored = gitStatus
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = FileFinder.scanFiles(at: root)
            let visible = scanned.filter { !ignored.isIgnored($0.path) }
            DispatchQueue.main.async {
                fileIndex = visible
                isScanningFiles = false
                refreshFinderResults()
            }
        }
    }

    /// Synchronously recompute the displayed results from the current query.
    /// Matching is allocation-free and fast enough (milliseconds) that this can
    /// run on every keystroke; the displayed list can never be stale.
    private func refreshFinderResults() {
        let results = FileFinder.results(matching: finderQuery, in: fileIndex)
        finderResults = results
        finderSelection = results.first
    }

    private func moveFinderSelection(_ delta: Int) {
        finderSelection = neighbouringSelection(from: finderSelection, in: finderResults, delta: delta)
    }

    private func openSelectedFinderResult() {
        // Results are always current (recomputed synchronously on every
        // keystroke); never re-compute here — refreshFinderResults() resets the
        // selection to the first row and would ignore one moved with the arrows.
        guard let path = finderSelection, finderResults.contains(path) else { return }
        selectFinderResult(path)
    }

    private func selectFinderResult(_ path: String) {
        closeFileFinder()
        handleFileSelection(path)
    }

    // MARK: - Navigation

    private func handleFileSelection(_ path: String) {
        guard path != currentFilePath else { return }

        if isDirty {
            pendingFilePath = path
            showSaveAlert = true
        } else {
            navigateToFile(path)
        }
    }

    private func navigateToFile(_ relativePath: String) {
        // Don't toggle isFileLoaded — MonacoEditorView must stay in the tree.
        // Just clear errors and update the path; loadFile() will push new content.
        loadError = nil
        isDirtyState = false

        currentFilePath = relativePath
        onFileChanged?(relativePath)

        loadFile()
    }

    // MARK: - File I/O

    private func loadFile() {
        guard let relativePath = currentFilePath else { return }
        let fullPath = (workingDirectory as NSString).appendingPathComponent(relativePath)
        let url = URL(fileURLWithPath: fullPath)

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let fileName = (relativePath as NSString).lastPathComponent
            let langId = MonacoLanguage.id(for: fileName)
            bridge.openFile(
                modelId: modelId,
                text: content,
                languageId: langId,
                filePath: fullPath,
                line: initialLine()
            )
            isDirtyState = false
            isFileLoaded = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// What a save did.
    ///
    /// Not `Void`, because the switch-file alert's Save button acts on the
    /// answer: it navigates, and navigating replaces the Monaco model with the
    /// next file's contents from disk. A save that failed is indistinguishable
    /// from one that succeeded unless it says so, and what a caller loses by
    /// confusing them is exactly the edits the user pressed Save to keep.
    enum SaveOutcome: Equatable {
        case saved
        /// Nothing was written because nothing had changed.
        case nothingToSave
        case failed(String)
    }

    /// Whether the file the user picked may now be opened over the current one.
    ///
    /// Exhaustive and deliberately without a `default:`, so a fourth outcome has
    /// to answer this question rather than inherit an answer — the inherited
    /// answer here throws away unsaved work.
    static func mayNavigate(after outcome: SaveOutcome) -> Bool {
        switch outcome {
        case .saved, .nothingToSave:
            true
        case .failed:
            false
        }
    }

    @discardableResult
    private func saveFile() async -> SaveOutcome {
        guard isDirty else { return .nothingToSave }
        guard let relativePath = currentFilePath, isFileLoaded else {
            // Dirty with nowhere to write. Save As detaches the editor when
            // it writes outside the working directory (`editedPath` returns
            // nil), so a nil path is reachable; `isDirtyState` is a binding the
            // parent owns, so this pairing cannot be ruled out from here. It is
            // a failure rather than "nothing to save" because the latter would
            // let the alert navigate over whatever the model is holding — the
            // same bug by a different route.
            return failedSave(NSLocalizedString(
                "This editor is not pointing at a file in the worktree. Use Save As to choose where to write it.",
                comment: ""
            ))
        }
        let fullPath = (workingDirectory as NSString).appendingPathComponent(relativePath)
        guard let content = await bridge.getContent(modelId: modelId) else {
            // The model is dirty, so it exists; nil is the bridge failing to
            // hand its text over rather than an absence of text.
            return failedSave(NSLocalizedString(
                "The editor could not read the file's contents.",
                comment: ""
            ))
        }
        do {
            try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
            bridge.markClean(modelId: modelId)
            isDirtyState = false
            return .saved
        } catch {
            return failedSave(error.localizedDescription)
        }
    }

    /// Reports a failed write and leaves the model dirty, so ⌘S can retry it.
    private func failedSave(_ message: String) -> SaveOutcome {
        saveError = message
        return .failed(message)
    }

    private func saveFileAs() async {
        guard isFileLoaded else { return }
        guard let content = await bridge.getContent(modelId: modelId) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = currentFileName
        if let currentFilePath {
            let fullPath = (workingDirectory as NSString).appendingPathComponent(currentFilePath)
            panel.directoryURL = URL(fileURLWithPath: fullPath).deletingLastPathComponent()
        }

        guard let window = NSApp.keyWindow else { return }
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            // The editor now edits the file it was just saved to. Without this,
            // `currentFilePath` still names the file Save As was invoked *from*,
            // and the next ⌘S writes this content back over it — the one file the
            // user was deliberately leaving alone.
            let saved = Self.editedPath(forFileSavedTo: url, workingDirectory: workingDirectory)
            currentFilePath = saved
            onFileChanged?(saved)
            if saved != nil {
                bridge.openFile(
                    modelId: modelId,
                    text: content,
                    languageId: MonacoLanguage.id(for: url.lastPathComponent),
                    filePath: url.path
                )
            }
            bridge.markClean(modelId: modelId)
            isDirtyState = false

        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The editor-relative path for a file Save As just wrote, or nil when it
    /// landed outside the working directory.
    ///
    /// `currentFilePath` is resolved against `workingDirectory` by everything
    /// that reads it, so a file outside has no representation here. Nil detaches
    /// the editor, which makes `saveFile` a no-op — the honest outcome, and far
    /// better than keeping a path that now names a different file. The comparison
    /// standardizes both sides and appends a separator so `…/project-backup` is
    /// not read as a child of `…/project`.
    static func editedPath(forFileSavedTo url: URL, workingDirectory: String) -> String? {
        let root = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        let saved = url.standardizedFileURL.path
        let boundary = root.hasSuffix("/") ? root : root + "/"
        guard saved.hasPrefix(boundary) else { return nil }
        let relative = String(saved.dropFirst(boundary.count))
        return relative.isEmpty ? nil : relative
    }
}
