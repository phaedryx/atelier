// ABOUTME: GitHub-style Changes view showing stacked inline diffs for all of a workstream's edits.
// ABOUTME: Renders git-derived diffs in Monaco diff editors inside one WKWebView via MonacoDiffBridge.

import AppKit
import SwiftUI

/// The diff scope shown by the Changes tab.
enum ChangesMode: String, CaseIterable {
    /// Everything that differs between merge-base(defaultBranch, HEAD) and the worktree.
    case branch
    /// Working-tree changes vs HEAD (plus untracked files).
    case uncommitted

    var label: String {
        switch self {
        case .branch: NSLocalizedString("Branch", comment: "Changes tab: branch diff mode")
        case .uncommitted: NSLocalizedString("Uncommitted", comment: "Changes tab: uncommitted diff mode")
        }
    }
}

/// The Changes tab. Lists every changed file as a stacked Monaco inline diff,
/// computed live from git. Supports Branch/Uncommitted modes, fingerprint-gated
/// refresh, and a per-file binary/large-file guard with click-to-load.
struct ChangesView: View {
    let workstreamID: UUID
    let workingDirectory: String
    let projectDirectory: String
    let bridge: MonacoDiffBridge
    @ObservedObject var annotations: ChangeAnnotationStore
    @EnvironmentObject private var surfaceCache: TerminalSurfaceCache

    @State private var isLoading = true
    /// Branch mode could not resolve a base branch, so an empty diff means
    /// "nothing to compare against" rather than "nothing changed".
    @State private var baseUnavailable = false
    @State private var isRefreshing = false
    /// Bumped by every load; a completion whose token no longer matches is a
    /// result for a mode or a refresh the user has already left behind.
    @State private var loadGeneration = 0
    @State private var fileCount = 0
    @State private var mode: ChangesMode = .branch
    @State private var submitBlocked: SubmitBlocker?
    @State private var confirmDiscard = false

    /// Why a submit was refused. Both cases keep the comments — the user gets
    /// them back to retry, rather than losing what they wrote.
    enum SubmitBlocker: String, Identifiable {
        /// No live Coding Agent surface to type into.
        case noAgent
        /// The agent is mid-turn, or sitting on a permission prompt where a
        /// synthetic Return would answer it.
        case busy

        var id: String {
            rawValue
        }

        var message: String {
            switch self {
            case .noAgent:
                NSLocalizedString(
                    "No Coding Agent terminal is running for this workstream.",
                    comment: "Changes tab: submit refused, no agent surface"
                )
            case .busy:
                NSLocalizedString(
                    "The Coding Agent is busy. Submit again once it finishes its turn.",
                    comment: "Changes tab: submit refused, agent mid-turn"
                )
            }
        }
    }

    /// The current changed-file set, surfaced for the sidebar tree. Captured
    /// from the same load that builds the diff payload (no extra git read).
    @State private var diffFiles: [Git.DiffFile] = []
    /// The leaf currently selected in the sidebar (its full relative path).
    @State private var selectedFilePath: String?

    /// Live width of the files-changed sidebar. Init from UserDefaults so it
    /// survives tab switches and relaunches; a divider DragGesture commits the
    /// final value on release.
    @State private var sidebarWidth: Double

    init(
        workstreamID: UUID,
        workingDirectory: String,
        projectDirectory: String,
        bridge: MonacoDiffBridge,
        annotations: ChangeAnnotationStore
    ) {
        self.workstreamID = workstreamID
        self.workingDirectory = workingDirectory
        self.projectDirectory = projectDirectory
        self.bridge = bridge
        self.annotations = annotations
        _sidebarWidth = State(initialValue: Self.loadSidebarWidth())
    }

    var body: some View {
        VStack(spacing: 0) {
            changesToolbar
            if fileCount == 0 {
                // Empty state: no sidebar skeleton — just the "No changes" webview.
                ZStack {
                    MonacoDiffView(bridge: bridge)
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ChangesFileTreeSidebar(
                        files: diffFiles,
                        selectedFilePath: $selectedFilePath,
                        onSelect: { path in
                            bridge.scrollToFile(path)
                        }
                    )
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)

                    sidebarDivider

                    ZStack {
                        MonacoDiffView(bridge: bridge)
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Make sure the bridge can resolve content for click-to-load before
            // any deferred-file click can happen.
            configureLoadHandler()
            configureCommentHandler()

            if bridge.hasContent, bridge.lastMode == mode.rawValue {
                // Cached content exists for this mode — show it, refresh in background.
                isLoading = false
                fileCount = bridge.lastFileCount
                diffFiles = bridge.lastDiffFiles
                backgroundRefreshIfNeeded()
                pushComments()
            } else {
                fullLoad()
            }
        }
        .onChange(of: mode) {
            // Mode changed — always do a full load.
            bridge.lastFingerprint = nil
            configureLoadHandler()
            configureCommentHandler()
            fullLoad()
        }
        .onReceive(NotificationCenter.default.publisher(for: .submitChangeReview)) { _ in
            submitReview()
        }
    }

    // MARK: - Toolbar

    private var changesToolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(ChangesMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 170)
            .opacity(0.85)
            .labelsHidden()

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else if fileCount == 0, baseUnavailable {
                // An empty Branch diff with no base branch is not a clean branch.
                // The green check said "you are up to date" for a branch whose
                // commits had simply never been looked for.
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("No base branch to compare against")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if fileCount == 0 {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("No changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(
                    format: NSLocalizedString("%d file(s) changed", comment: "Changes tab: changed-file count"),
                    fileCount
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            if !annotations.comments(mode: mode).isEmpty {
                let count = annotations.comments(mode: mode).count
                Divider().frame(height: 14)
                Text(String(
                    format: NSLocalizedString("%d comment(s)", comment: "Changes tab: pending review comment count"),
                    count
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Button("Submit Review") { submitReview() }
                    .controlSize(.small)
                    .disabled(isLoading || isRefreshing)

                Button("Discard") { confirmDiscard = true }
                    .controlSize(.small)
            }

            Spacer()

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Text("Refresh changes"))
            .accessibilityLabel(Text("Refresh changes"))
            .disabled(isLoading || isRefreshing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .confirmationDialog(
            Text("Discard all review comments?"),
            isPresented: $confirmDiscard
        ) {
            Button("Discard", role: .destructive) {
                annotations.clear(mode: mode)
                pushComments()
            }
        }
        .alert(item: $submitBlocked) { blocker in
            Alert(title: Text(blocker.message), dismissButton: .cancel(Text("OK")))
        }
    }

    // MARK: - Refresh

    /// Manual refresh: invalidate the cached fingerprint and force a full reload.
    private func refresh() {
        bridge.lastFingerprint = nil
        configureLoadHandler()
        configureCommentHandler()
        fullLoad()
    }

    // MARK: - Full load (first visit, mode switch, or explicit refresh)

    private func fullLoad() {
        isLoading = true
        loadGeneration += 1
        let token = loadGeneration
        let workDir = workingDirectory
        let projDir = projectDirectory
        let currentMode = mode

        DispatchQueue.global(qos: .userInitiated).async {
            let fingerprint = Git.Operations.diffFingerprint(
                worktreePath: workDir,
                projectPath: projDir,
                mode: currentMode.rawValue
            )
            let contents = Self.buildContents(
                workDir: workDir,
                projDir: projDir,
                mode: currentMode
            )

            DispatchQueue.main.async {
                // A mode switch (or a second refresh) during the git hop starts
                // its own load. Without this the older completion lands second
                // and paints the mode the user already left over the one they
                // are on — files, counts, cached fingerprint and all.
                guard token == loadGeneration else { return }
                diffFiles = contents.files
                selectedFilePath = nil
                fileCount = contents.payload.count
                baseUnavailable = contents.baseUnavailable
                bridge.lastFileCount = contents.payload.count
                bridge.lastDiffFiles = contents.files
                bridge.lastFingerprint = fingerprint
                bridge.lastMode = currentMode.rawValue
                bridge.onContentReady = {
                    isLoading = false
                }
                annotations.reanchor(
                    mode: currentMode,
                    texts: Self.reanchorTexts(from: contents.payload),
                    presentPaths: Set(contents.files.map(\.relativePath))
                )
                bridge.setFiles(contents.payload)
                pushComments()
            }
        }
    }

    // MARK: - Background refresh (revisit with cached content already shown)

    private func backgroundRefreshIfNeeded() {
        loadGeneration += 1
        let token = loadGeneration
        let workDir = workingDirectory
        let projDir = projectDirectory
        let currentMode = mode
        let cachedFingerprint = bridge.lastFingerprint

        DispatchQueue.global(qos: .userInitiated).async {
            let fingerprint = Git.Operations.diffFingerprint(
                worktreePath: workDir,
                projectPath: projDir,
                mode: currentMode.rawValue
            )

            // Nothing changed — keep the cached content, no reload, no flicker.
            if fingerprint == cachedFingerprint {
                return
            }

            let contents = Self.buildContents(
                workDir: workDir,
                projDir: projDir,
                mode: currentMode
            )

            DispatchQueue.main.async {
                // See `fullLoad`: a completion for a mode the user has left must
                // not overwrite the current one.
                guard token == loadGeneration else { return }
                diffFiles = contents.files
                selectedFilePath = nil
                fileCount = contents.payload.count
                baseUnavailable = contents.baseUnavailable
                bridge.lastFileCount = contents.payload.count
                bridge.lastDiffFiles = contents.files
                bridge.lastFingerprint = fingerprint
                bridge.lastMode = currentMode.rawValue
                isRefreshing = true
                bridge.onContentReady = {
                    isRefreshing = false
                }
                annotations.reanchor(
                    mode: currentMode,
                    texts: Self.reanchorTexts(from: contents.payload),
                    presentPaths: Set(contents.files.map(\.relativePath))
                )
                bridge.setFiles(contents.payload)
                pushComments()
            }
        }
    }

    // MARK: - Click-to-load wiring

    /// Give the bridge enough context (workDir + mode) to resolve a single
    /// deferred file's content when its placeholder is clicked. The git base ref
    /// is resolved lazily inside the resolver, which the bridge runs off the main
    /// thread, so no git command blocks the main thread here.
    private func configureLoadHandler() {
        let workDir = workingDirectory
        let projDir = projectDirectory
        let currentMode = mode
        bridge.onLoadFile = { filePath in
            // Runs off the main thread; resolves base ref + content for one file.
            // No base branch resolved: there is no "original" side to read, so
            // show the file as it stands rather than diffing it against itself.
            let baseRef = Self.baseRef(workDir: workDir, projDir: projDir, mode: currentMode)
            let (original, modified) = Self.fileTexts(
                workDir: workDir,
                baseRef: baseRef ?? "HEAD",
                filePath: filePath
            )
            let languageId = MonacoLanguage.id(for: (filePath as NSString).lastPathComponent)
            return (original, modified, languageId)
        }
    }

    // MARK: - Review comments

    /// Route comment mutations from diff.js into the store, then push the
    /// authoritative set back down. The webview never owns comment state.
    private func configureCommentHandler() {
        let currentMode = mode
        bridge.onCommentEvent = { event in
            switch event {
            case let .added(filePath, side, line, endLine, lineText, text):
                annotations.add(
                    filePath: filePath, mode: currentMode, side: side,
                    line: line, endLine: endLine, lineText: lineText, text: text
                )
            case let .edited(id, text):
                annotations.updateText(id: id, text: text)
            case let .deleted(id):
                annotations.delete(id: id)
            }
            pushComments()
        }
    }

    /// Push the active mode's comments to diff.js for rendering.
    private func pushComments() {
        let payload = annotations.comments(mode: mode).map { c -> [String: Any] in
            var entry: [String: Any] = [
                "id": c.id.uuidString,
                "filePath": c.filePath,
                "side": c.side.rawValue,
                "line": c.line,
                "lineText": c.lineText,
                "text": c.text,
                "isOrphaned": c.isOrphaned,
            ]
            if let endLine = c.endLine {
                entry["endLine"] = endLine
            }
            return entry
        }
        bridge.setComments(payload)
    }

    /// Format the active mode's comments and paste them into the workstream's
    /// Coding Agent surface. Liveness and turn state are re-checked at send
    /// time, after the background git hop, and only the comments actually sent
    /// are removed — a comment added mid-flight, or a surface that died or
    /// started a turn in the meantime, all survive with their comments intact.
    ///
    /// The turn check matters more here than anywhere else the app types into a
    /// pane: the user is looking at the Changes tab, not at the agent, so they
    /// cannot see that the pane is sitting on a permission prompt where the
    /// synthetic Return would answer it. Same nil-permissive rule as
    /// `PromptInjector` — refuse only on evidence of a live turn.
    private func submitReview() {
        // The toolbar button is disabled mid-refresh; the palette command and
        // the notification reach here directly, so the guard lives here too.
        // Submitting now would send anchors the running re-anchor is rewriting.
        guard !isLoading, !isRefreshing else { return }

        let toSend = annotations.comments(mode: mode)
        guard !toSend.isEmpty else { return }
        guard let blocker = submitBlocker(for: workstreamID, cache: surfaceCache) else {
            submitBlocked = nil
            return proceedWithSubmit(toSend)
        }
        submitBlocked = blocker
    }

    /// Why `surfaceID` cannot be typed into right now, or nil when it can be.
    private func submitBlocker(for surfaceID: UUID, cache: TerminalSurfaceCache) -> SubmitBlocker? {
        guard cache.hasLiveSurface(surfaceID) else { return .noAgent }
        let state = Workstream.AgentStateTracker.shared.state(forSurface: surfaceID)
        return PromptInjector.canInject(state: state) ? nil : .busy
    }

    private func proceedWithSubmit(_ toSend: [ReviewComment]) {
        let workDir = workingDirectory
        let projDir = projectDirectory
        let currentMode = mode
        let cache = surfaceCache
        let target = workstreamID

        // repoInfo shells out to git — resolve the labels off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let branch = Git.Operations.repoInfo(at: workDir).branch
            let base = Git.Operations.repoInfo(at: projDir).branch
            let payload = ChangeReviewFormatter.payload(
                comments: toSend, mode: currentMode, branch: branch, baseBranch: base
            )
            DispatchQueue.main.async {
                // The surface can die — or the agent can start a turn — during
                // the git hop above, so both are re-checked here rather than
                // silently no-oping or interrupting a turn that just began.
                if let blocker = submitBlocker(for: target, cache: cache) {
                    submitBlocked = blocker
                    return
                }
                // Between the paste and either Return, liveness alone gates:
                // refusing a Return once the payload is already in the pane
                // would strand it there unsubmitted, with the comments gone.
                cache.typeAndSubmit(payload, into: target) {
                    cache.hasLiveSurface(target)
                }
                // Delete exactly what was sent, not the whole mode — a
                // comment added during the git hop above must survive.
                for comment in toSend {
                    annotations.delete(id: comment.id)
                }
                pushComments()
            }
        }
    }

    /// Pull (original, modified) texts out of the setFiles payload for
    /// re-anchoring. Binary and deferred entries carry empty texts and are
    /// excluded — reanchor() must leave their comments untouched.
    nonisolated static func reanchorTexts(
        from payload: [[String: Any]]
    ) -> [String: (original: String, modified: String)] {
        var texts: [String: (original: String, modified: String)] = [:]
        for entry in payload {
            guard entry["binary"] == nil, entry["deferred"] == nil,
                  let path = entry["filePath"] as? String,
                  let original = entry["originalText"] as? String,
                  let modified = entry["modifiedText"] as? String
            else { continue }
            texts[path] = (original: original, modified: modified)
        }
        return texts
    }

    // MARK: - Sidebar width persistence

    /// Clamp bounds for the files-changed sidebar width.
    private static let changesSidebarMinWidth: Double = 180
    private static let changesSidebarMaxWidth: Double = 480
    /// Default width matching the pre-persistence behavior.
    private static let changesSidebarDefault: Double = 240
    private static let changesSidebarWidthKey = "atelier.changesSidebarWidth"

    static func loadSidebarWidth() -> Double {
        let stored = UserDefaults.standard.double(forKey: changesSidebarWidthKey)
        return stored == 0 ? changesSidebarDefault : clampWidth(stored)
    }

    static func clampWidth(_ width: Double) -> Double {
        min(changesSidebarMaxWidth, max(changesSidebarMinWidth, width))
    }

    /// The resizable divider between the sidebar and the diff review. Drags
    /// resize the sidebar live; the final width is committed to UserDefaults
    /// on release so it survives tab switches and relaunches.
    private var sidebarDivider: some View {
        Color.clear
            .frame(width: 9)
            .overlay(
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        sidebarWidth = Self.clampWidth(
                            Self.loadSidebarWidth() + Double(value.translation.width)
                        )
                    }
                    .onEnded { value in
                        sidebarWidth = Self.clampWidth(
                            Self.loadSidebarWidth() + Double(value.translation.width)
                        )
                        UserDefaults.standard.set(sidebarWidth, forKey: Self.changesSidebarWidthKey)
                    }
            )
    }

    // MARK: - Large-file guard thresholds

    /// A file with more than this many changed lines is deferred (Hardening 3).
    static let largeFileLineThreshold = 1500
    /// A file larger than this many bytes on disk is deferred (Hardening 3).
    static let largeFileByteThreshold = 500 * 1024

    /// How a file's diff body should be produced.
    enum PayloadClass: Equatable {
        /// Binary — never rendered as a UTF-8 diff (Hardening 2).
        case binary
        /// Oversize — collapsed to a click-to-load placeholder (Hardening 3).
        case deferred
        /// Rendered immediately as a Monaco inline diff.
        case normal
    }

    /// Pure classification of a file's diff body. Decides BEFORE any content is
    /// read so git-show / disk reads are skipped for binary and deferred files.
    nonisolated static func classify(isBinary: Bool, changedLines: Int, sizeHint: Int) -> PayloadClass {
        if isBinary {
            return .binary
        }
        if changedLines > largeFileLineThreshold || sizeHint > largeFileByteThreshold {
            return .deferred
        }
        return .normal
    }

    // MARK: - Payload builder

    /// Build the `setFiles` payload for ALL changed files in the given mode.
    /// Runs on a background queue (nonisolated, captures no @State). Decides each
    /// file's class (binary / deferred / normal) before reading content so that
    /// git show and disk reads are skipped for binary and deferred files.
    nonisolated static func buildPayload(
        workDir: String,
        projDir: String,
        mode: ChangesMode
    ) -> [[String: Any]] {
        buildContents(workDir: workDir, projDir: projDir, mode: mode).payload
    }

    /// Build both the JS `setFiles` payload AND the structured, tree-ordered
    /// list of changed files in one pass. The sidebar tree is built from `files`
    /// while the diff webview renders `payload` in that same tree order; sharing
    /// one git read keeps the two in sync and avoids re-running git for the
    /// sidebar.
    nonisolated static func buildContents(
        workDir: String,
        projDir: String,
        mode: ChangesMode
    ) -> (payload: [[String: Any]], files: [Git.DiffFile], baseUnavailable: Bool) {
        let diffFiles: [Git.DiffFile] = switch mode {
        case .branch:
            Git.Operations.branchDiffFiles(worktreePath: workDir, projectPath: projDir)
        case .uncommitted:
            Git.Operations.uncommittedDiffFiles(at: workDir)
        }

        // An empty list because no base branch resolved is not an empty list
        // because nothing changed, and the tab must not render them the same way.
        let resolvedBase = baseRef(workDir: workDir, projDir: projDir, mode: mode)
        let baseUnavailable = resolvedBase == nil
        let baseRef = resolvedBase ?? "HEAD"

        // Order diffs exactly as the sidebar tree displays them (directories
        // before files, alphabetical at every level), so the code review scrolls
        // in lockstep with the "Files changed" sidebar.
        let orderedFiles = Self.flattenedTreeOrder(diffFiles)

        var payload: [[String: Any]] = []
        payload.reserveCapacity(orderedFiles.count)

        for file in orderedFiles {
            var entry: [String: Any] = [
                "filePath": file.relativePath,
                "status": file.status.rawValue,
                "languageId": MonacoLanguage.id(for: (file.relativePath as NSString).lastPathComponent),
                "changedLines": file.changedLines,
            ]

            switch classify(isBinary: file.isBinary, changedLines: file.changedLines, sizeHint: file.sizeHint) {
            case .binary:
                // No content read; diff.js renders a "Binary file (not shown)" badge.
                entry["binary"] = true
                entry["originalText"] = ""
                entry["modifiedText"] = ""
            case .deferred:
                // No content read yet; diff.js renders a click-to-load placeholder.
                entry["deferred"] = true
                entry["originalText"] = ""
                entry["modifiedText"] = ""
            case .normal:
                let (original, modified) = fileTexts(
                    workDir: workDir,
                    baseRef: baseRef,
                    filePath: file.relativePath,
                    status: file.status
                )
                entry["originalText"] = original
                entry["modifiedText"] = modified
            }

            payload.append(entry)
        }

        return (payload, orderedFiles, baseUnavailable)
    }

    /// Depth-first flattening of the sidebar tree. Directories come before
    /// sibling files and every level is alphabetical (case-insensitive) —
    /// identical to how `ChangesFileTreeSidebar` renders its rows, so the diff
    /// order always matches what the user sees in the sidebar.
    nonisolated static func flattenedTreeOrder(_ files: [Git.DiffFile]) -> [Git.DiffFile] {
        var ordered: [Git.DiffFile] = []
        func visit(_ node: FileTreeNode) {
            if let file = node.diffFile {
                ordered.append(file)
            } else if let children = node.children {
                for child in children {
                    visit(child)
                }
            }
        }
        if let topLevel = FileTreeNode.build(from: files).children {
            for node in topLevel {
                visit(node)
            }
        }
        return ordered
    }

    // MARK: - Content resolution helpers

    /// The diff base ref for a mode: merge-base for branch, HEAD for uncommitted.
    /// `nil` only in branch mode, when no base branch resolves.
    ///
    /// It used to fall back to HEAD there, which is not a weaker answer but a
    /// different question: comparing the branch against itself hides every commit
    /// on it, and the tab reported that as "No changes".
    nonisolated static func baseRef(workDir: String, projDir: String, mode: ChangesMode) -> String? {
        switch mode {
        case .branch:
            Git.Operations.mergeBase(worktreePath: workDir, projectPath: projDir)
        case .uncommitted:
            "HEAD"
        }
    }

    /// Read (original, modified) text for a file. The original side comes from the
    /// base ref via `git show`; the modified side from disk. `status` lets us skip
    /// reads that would always be empty (added has no base, deleted has no disk).
    nonisolated static func fileTexts(
        workDir: String,
        baseRef: String,
        filePath: String,
        status: Git.DiffFile.Status? = nil
    ) -> (original: String, modified: String) {
        let original: String = if status == .added {
            ""
        } else {
            Git.Operations.fileContent(at: workDir, ref: baseRef, filePath: filePath) ?? ""
        }

        let modified: String
        if status == .deleted {
            modified = ""
        } else {
            let fullPath = (workDir as NSString).appendingPathComponent(filePath)
            modified = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
        }

        return (original, modified)
    }
}
