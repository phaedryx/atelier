// ABOUTME: SwiftUI sidebar showing projects as a collapsible tree with workstreams.
// ABOUTME: Supports adding projects via picker/drag-drop and workstreams inline.

import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "atelier", category: "sidebar")

/// The ids a sidebar `ForEach` should emit rows for, given a cached sort order and
/// the ids that actually exist right now.
///
/// The caches `rebuildSortOrder` fills are **always one frame behind**: `onChange` runs
/// after the body that already observed the mutated `projects`, so every add, remove
/// and purge renders once against a cache that disagrees with the model. That window
/// used to be invisible because the rows only *looked* the same — but rows were keyed
/// by a cached id and their content and `.tag` came from a positional lookup, so in
/// that frame a row could be keyed `X` and tagged `Y`, and two rows could carry the
/// same tag. `List(selection:)` does not survive a duplicate tag: it highlights both,
/// and clicking elsewhere hands the selection straight back to the stale twin.
///
/// So the cache supplies **order and nothing else**. Membership is reconciled against
/// the live ids every render: ids the cache still carries but the model has dropped go
/// away, and ids the model has that the cache has not seen yet are appended in model
/// order, which is what makes a freshly created workstream appear in the frame it is
/// created rather than the one after. The result is duplicate-free, so no two rows can
/// ever share a tag.
func sidebarRowOrder(cached: [UUID]?, actual: [UUID]) -> [UUID] {
    guard let cached else { return actual }
    var seen = Set<UUID>()
    let present = Set(actual)
    var order = cached.filter { present.contains($0) && seen.insert($0).inserted }
    order.append(contentsOf: actual.filter { !seen.contains($0) })
    return order
}

func expandedProjectIDs(
    afterSelecting selection: SidebarSelection?,
    current: Set<UUID>,
    projectIDByWorkstreamID: [UUID: UUID],
    projectIDByGroupID: [UUID: UUID]
) -> Set<UUID> {
    guard let selection else { return current }
    var expanded = current
    switch selection {
    case let .project(projectID):
        expanded.insert(projectID)
    case let .workstream(workstreamID):
        if let projectID = projectIDByWorkstreamID[workstreamID] {
            expanded.insert(projectID)
        }
    case let .group(groupID):
        if let projectID = projectIDByGroupID[groupID] {
            expanded.insert(projectID)
        }
    case .settings, .help:
        break
    }
    return expanded
}

/// The groups to open after a selection lands, so the selected row exists.
///
/// A workstream inside a collapsed group has no row: `scrollTo` lands on
/// nothing and the highlight is invisible. `expandedProjectIDs` opens the
/// project; this opens the group under it. A group selection needs nothing
/// here — the group row is its own disclosure's label, visible whenever its
/// project is open.
func expandedGroupIDs(
    afterSelecting selection: SidebarSelection?,
    current: Set<UUID>,
    groupIDByWorkstreamID: [UUID: UUID]
) -> Set<UUID> {
    guard case let .workstream(workstreamID) = selection,
          let groupID = groupIDByWorkstreamID[workstreamID]
    else { return current }
    return current.union([groupID])
}

/// The directory new projects and clones are created under, or nil if the
/// setting cannot name one.
///
/// `URL(fileURLWithPath:)` resolves a relative string — and an empty one — against
/// the *process's* working directory, which for a launched app is wherever it
/// happened to start. The base directory is `@AppStorage` with a `?? ""`
/// default, so "unset" is reachable without the user doing anything unusual, and
/// the two callers go straight on to `createDirectory` and `git init`. Refusing
/// here keeps that failure a visible error instead of a repository somewhere
/// nobody chose.
///
/// Surrounding whitespace is trimmed rather than refused: the value is
/// user-editable text and a trailing space is not a reason to reject an
/// otherwise good path.
func projectBaseDirectory(from setting: String) -> URL? {
    let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: trimmed)
}

extension Notification.Name {
    static let addProject = Notification.Name("atelier.addProject")
    static let addNew = Notification.Name("atelier.addNew")
}

struct ProjectSidebar: View {
    @Binding var projects: [Project]
    @Binding var selection: SidebarSelection?
    /// The app's one verification runner, handed down rather than taken from
    /// the environment: the purge confirmation's `ArchiveContext` needs the
    /// reference, and nothing here renders a run — an `@EnvironmentObject` would
    /// redraw the whole sidebar on every live poll of every workstream's suite.
    let verificationRunner: Verification.Runner
    let onProjectsChanged: () -> Void

    @State private var showingAddProjectChoice = false
    @State private var showingNewProjectName = false
    @State private var newProjectName = ""
    @State private var newProjectError = ""
    @State private var showingCloneRepo = false
    @State private var cloneRemote = ""
    @State private var cloneDirectoryName = ""
    @State private var cloneDirectoryNameEdited = false
    @State private var cloneError = ""
    @State private var isCloning = false
    @State private var cloneCancellation: BareRepoClone.Cancellation?
    @State private var isDropTargeted = false
    @State private var projectToDelete: UUID?
    @StateObject private var removeConfirmation = Workstream.RemoveConfirmation()
    /// The pending Purge, its warning and its alert copy — see
    /// `Workstream.PurgeConfirmation`. Remove above stays a plain `UUID?`: it
    /// has no warning and no button-title rule to share.
    @StateObject private var purgeConfirmation = Workstream.PurgeConfirmation()
    @State private var expandedProjects: Set<UUID> = SidebarState.loadExpanded()
    /// Expanded groups, persisted under `atelier.expandedGroups`. Like
    /// `expandedProjects`, the inner `DisclosureGroup` reads it through a
    /// computed binding and owns none of it.
    @State private var expandedGroups: Set<UUID> = SidebarState.loadExpandedGroups()
    @State private var cachedSortedIDs: [UUID] = []
    /// Project id → that project's group ids, in sidebar order. Order only.
    @State private var cachedSortedGroupIDs: [UUID: [UUID]] = [:]
    /// **Group** id → that group's workstream ids, in sidebar order. Order only.
    @State private var cachedSortedWorkstreamIDs: [UUID: [UUID]] = [:]
    @State private var showWorktreeError = false
    @State private var showNotGitRepoError = false
    @State private var showingNewWorkstreamName = false
    @State private var newWorkstreamName = ""
    @State private var newWorkstreamError = ""
    @State private var newWorkstreamPlaceholder = ""
    @State private var pendingWorkstreamProjectID: UUID?
    @State private var pendingWorkstreamBypass: Bool?
    /// The group the pending creation joins, set alongside `pendingWorkstreamProjectID`
    /// and cleared wherever it is.
    @State private var pendingWorkstreamGroupID: UUID?
    /// The project whose inline new-group field is showing; at most one at a time.
    @State private var pendingGroupProjectID: UUID?
    /// A refused group name, from creation or rename; drives the alert.
    @State private var groupNameRefusal: Workstream.Group.NameRefusal?
    /// ⌘N with a project row selected: a workstream needs a group to join.
    @State private var showGroupRequiredHint = false

    @AppStorage(Shortcut.Settings.buttonEnabledKey) private var shortcutButtonEnabled: Bool = true
    @AppStorage(Shortcut.Settings.branchTemplateKey) private var branchTemplate: String = ""
    /// Keychain presence is not observable, so this is seeded at init and refreshed
    /// whenever Settings posts `Shortcut.Settings.tokenChanged`. It can still go stale if
    /// the item is removed outside the app; that surfaces as a `.noToken` error in the
    /// dialog rather than a hidden button.
    @State private var hasShortcutToken = KeychainTokenStore().hasToken
    @State private var showingShortcutStory = false
    @State private var shortcutStoryInput = ""
    @State private var shortcutError = ""
    /// Set from the `Shortcut.Error` case, so the Settings link never depends on message wording.
    @State private var shortcutErrorNeedsToken = false
    @State private var shortcutFetching = false
    /// Held so Cancel can actually stop it. Without this the fetch completes after the
    /// sheet closes and creates a workstream the user thought they had cancelled.
    @State private var shortcutFetchTask: Task<Void, Never>?
    @State private var showingGitHubBranch = false
    @State private var gitHubBranchInput = ""
    @State private var gitHubBranchError = ""
    @State private var gitHubBranchChecking = false
    /// Held so Cancel can stop the lookup, for the same reason as `shortcutFetchTask`:
    /// a fetch that lands after the dialog closes would create a workstream nobody asked for.
    @State private var gitHubBranchTask: Task<Void, Never>?

    /// Workstream whose row is showing the inline rename field; at most one
    /// at a time. Held here (not per-row) so periodic project mutations
    /// don't drop the edit state when rows rebuild.
    @State private var renamingWorkstreamID: UUID?
    @State private var renamingProjectID: UUID?
    @State private var renamingGroupID: UUID?

    @AppStorage(Project.SortOrder.storageKey) private var workstreamSortOrder: Project.SortOrder = .recent

    private func recomputeSortedIDs() -> [UUID] {
        projects
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.id)
    }

    /// Recompute the per-project workstream sort order.
    ///
    /// This is a cache of *order only*. It used to also hold a `[workstreamID: (Int, Int)]`
    /// pair per workstream, which rows and `.terminalActivity` both indexed into — and a
    /// positional pair into a two-level array is stale for one frame after every mutation
    /// and points at a real, wrong workstream rather than at nothing. `sidebarRowOrder`
    /// makes the display side immune to a stale order; nothing resolves a workstream by
    /// position any more. Do not reintroduce the index.
    ///
    /// Two caches, both order only: project → groups, and group → workstreams.
    /// The second is keyed by **group** id, so a workstream's row order is
    /// resolved within the group it is drawn under.
    private func rebuildSortOrder() {
        var sortedGroups: [UUID: [UUID]] = [:]
        var sortedWS: [UUID: [UUID]] = [:]
        for project in projects {
            sortedGroups[project.id] = workstreamSortOrder.sorted(project.sortedGroups, in: project).map(\.id)
            for group in project.sortedGroups {
                sortedWS[group.id] = workstreamSortOrder.sorted(project.workstreams(in: group.id)).map(\.id)
            }
        }
        cachedSortedGroupIDs = sortedGroups
        cachedSortedWorkstreamIDs = sortedWS
    }

    private func totalWorkstreamCount() -> Int {
        projects.reduce(0) { $0 + $1.workstreams.count }
    }

    private func totalGroupCount() -> Int {
        projects.reduce(0) { $0 + ($1.groups?.count ?? 0) }
    }

    private func groupIDByWorkstreamIDSnapshot() -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for project in projects {
            for workstream in project.workstreams {
                if let groupID = workstream.groupID {
                    map[workstream.id] = groupID
                }
            }
        }
        return map
    }

    private func projectIDByWorkstreamIDSnapshot() -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for project in projects {
            for workstream in project.workstreams {
                map[workstream.id] = project.id
            }
        }
        return map
    }

    private func projectIDByGroupIDSnapshot() -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for project in projects {
            for group in project.groups ?? [] {
                map[group.id] = project.id
            }
        }
        return map
    }

    private func deferSelectionExpansion(
        _ selected: SidebarSelection,
        projectIDByWorkstreamID: [UUID: UUID],
        projectIDByGroupID: [UUID: UUID],
        groupIDByWorkstreamID: [UUID: UUID],
        scrollProxy: ScrollViewProxy
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard selection == selected else { return }
            expandedProjects = expandedProjectIDs(
                afterSelecting: selected,
                current: expandedProjects,
                projectIDByWorkstreamID: projectIDByWorkstreamID,
                projectIDByGroupID: projectIDByGroupID
            )
            expandedGroups = expandedGroupIDs(
                afterSelecting: selected,
                current: expandedGroups,
                groupIDByWorkstreamID: groupIDByWorkstreamID
            )
            withAnimation {
                scrollProxy.scrollTo(selected, anchor: .center)
            }
        }
    }

    /// Projects and their workstreams, as rows of the sidebar `List`.
    ///
    /// A project with workstreams is a `DisclosureGroup`; one without is the bare
    /// header row. Three things about that are load-bearing:
    ///
    /// 1. **The group owns the triangle, but not the state.** `isExpanded` is a
    ///    computed `Binding` over `expandedProjects`, so expansion still lands in the
    ///    same `Set` that `SidebarState.saveExpanded` persists and that
    ///    `deferSelectionExpansion` opens on selection. Nothing downstream can tell
    ///    the difference. `ProjectHeaderRow`'s own chevron was deleted when this
    ///    landed — two controls for one piece of state is the trap `Section` has
    ///    under `.listStyle(.sidebar)`, and it is just as available here.
    /// 2. **The header row is the group's *label*, not a `Section` header.** A
    ///    section header is not selectable in `List(selection:)`, and this row must
    ///    stay selectable — it carries `.tag(SidebarSelection.project(_:))`, and
    ///    selecting it is how the project overview opens. Tagging the label works;
    ///    verified against the real sidebar, along with the label's hover buttons
    ///    and context menu, which keep receiving clicks rather than toggling the
    ///    group.
    /// 3. **A childless project reserves no leading column.** The disclosure
    ///    triangle is drawn in `List`'s own gutter, *left* of where row content
    ///    starts, so a placeholder column in the header row compensates for nothing
    ///    — it is 22pt of pure extra indent that leaves an ungrouped project sitting
    ///    out at workstream depth with no triangle above it. Both branches go
    ///    through `projectHeaderRow` unchanged; the alignment falls out for free.
    ///
    /// `.listStyle(.sidebar)` over `DisclosureGroup` with tagged children is not new
    /// here — `ChangesFileTreeSidebar` shipped exactly that shape and only moved to
    /// `.plain` later, for the vibrancy reason its own comment gives.
    ///
    /// The project's children are its **groups**, and all three rules apply one
    /// level down unchanged: a group with members is an inner `DisclosureGroup`
    /// whose label is the group row, tagged `.group(id)`, with `isExpanded` a
    /// computed binding over `expandedGroups`; a memberless group is the bare row.
    /// A project with no groups has no children at all — except the inline
    /// new-group field while it is pending, which is why `hasChildren` reads
    /// `pendingGroupProjectID` too: without it a group-less project has nowhere
    /// to draw the field its own plus asked for.
    private func projectRows() -> some View {
        let rowIDs = sidebarRowOrder(cached: cachedSortedIDs, actual: projects.map(\.id))
        return ForEach(rowIDs, id: \.self) { projectID in
            // An id the model cannot resolve emits no row. It used to resolve to a
            // synthesized `Project(name: "", directory: "")`, whose `id` was a fresh
            // UUID on every evaluation — a blank, untitled row whose selection tag
            // changed identity each render.
            if let project = projects.first(where: { $0.id == projectID }) {
                let hasChildren = !project.sortedGroups.isEmpty || pendingGroupProjectID == projectID
                let isFirst = projectID == rowIDs.first

                if hasChildren {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedProjects.contains(projectID) },
                            set: { on in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if on {
                                        expandedProjects.insert(projectID)
                                    } else {
                                        expandedProjects.remove(projectID)
                                    }
                                }
                            }
                        )
                    ) {
                        groupRows(project: project)
                    } label: {
                        projectHeaderRow(project: project, isFirst: isFirst)
                            .tag(SidebarSelection.project(project.id))
                    }
                } else {
                    projectHeaderRow(project: project, isFirst: isFirst)
                        .tag(SidebarSelection.project(project.id))
                }
            }
        }
    }

    /// Separation between one project's group and the next is this row's own top
    /// padding, never a `Divider()`. A separator emitted as a sibling of these rows
    /// becomes a phantom row inside `List(selection:)` — untagged, but highlightable
    /// and reachable with the arrow keys.
    private func projectHeaderRow(project: Project, isFirst: Bool) -> some View {
        ProjectHeaderRow(
            project: project,
            githubURL: appEnv.githubURL(for: project.directory),
            onAddGroup: { beginNewGroup(in: project.id) },
            isSelected: selection == .project(project.id),
            isRenaming: Binding(
                get: { renamingProjectID == project.id },
                set: { renamingProjectID = $0 ? project.id : nil }
            ),
            onRenameCommit: { commitProjectRename(projectID: project.id, input: $0) },
            onDelete: { projectToDelete = project.id }
        )
        .padding(.leading, Layout.projectTitleGap)
        .padding(.top, isFirst ? 0 : Layout.projectGroupGap)
    }

    /// Sizes for the sidebar's grouping. Collected rather than inlined because the
    /// three horizontal ones are a single decision: the trim pulls the group left,
    /// the spine sits at the edge that leaves, `spineGap` is measured from the spine,
    /// and `projectTitleGap` is what the spine is aligned against — moving one alone
    /// puts the hairline somewhere the rows are not. The two vertical ones,
    /// `projectGroupGap` and `spineOverhang`, are independent of all that.
    private enum Layout {
        /// Air above each project group but the first.
        static let projectGroupGap: CGFloat = 8
        /// Between `List`'s disclosure-triangle gutter and the project name.
        /// Applied to childless projects too, which have no triangle, so every
        /// project name still starts at one x.
        static let projectTitleGap: CGFloat = 4
        /// Pulls the workstream rows back toward the leading edge.
        /// `DisclosureGroup`'s own indent is generous for rows this dense.
        static let workstreamIndentTrim: CGFloat = -10
        /// Between the spine and the workstream row's content.
        static let spineGap: CGFloat = 8
        /// How far each row's spine segment overhangs its own bounds, so adjacent
        /// segments meet instead of leaving a dotted trail down the group. Half the
        /// inter-row spacing at each end.
        static let spineOverhang: CGFloat = 3
        /// The extra step a workstream row under a group takes past the group's
        /// own spine, so its second spine reads as one level deeper.
        static let groupIndent: CGFloat = 12
    }

    /// One spine segment down the leading edge of a row, the tree guide the
    /// group rows draw under their project and the workstream rows draw under
    /// their group. See `workstreamRows` for why each row draws its own.
    private func spined(_ row: some View, extraIndent: CGFloat = 0) -> some View {
        row
            .padding(.leading, Layout.spineGap)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.vertical, -Layout.spineOverhang)
            }
            .padding(.leading, Layout.workstreamIndentTrim + extraIndent)
    }

    /// The groups of one project, as the content of its `DisclosureGroup`, then the
    /// inline new-group field when this project's plus asked for one.
    ///
    /// Membership is reconciled by `sidebarRowOrder` exactly as projects and
    /// workstreams are, and each row resolves its group by id out of this
    /// project's own `groups` — never by a cached position.
    @ViewBuilder
    private func groupRows(project: Project) -> some View {
        let rowIDs = sidebarRowOrder(
            cached: cachedSortedGroupIDs[project.id],
            actual: project.sortedGroups.map(\.id)
        )
        ForEach(rowIDs, id: \.self) { groupID in
            if let group = project.group(with: groupID) {
                if project.workstreams.contains(where: { $0.groupID == groupID }) {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedGroups.contains(groupID) },
                            set: { on in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if on {
                                        expandedGroups.insert(groupID)
                                    } else {
                                        expandedGroups.remove(groupID)
                                    }
                                }
                            }
                        )
                    ) {
                        workstreamRows(project: project, group: group)
                    } label: {
                        groupRow(project: project, group: group)
                    }
                } else {
                    groupRow(project: project, group: group)
                }
            }
        }
        if pendingGroupProjectID == project.id {
            spined(
                InlineTextField(
                    initialText: "",
                    accessibilityID: "new-group-field",
                    onCommit: { value in
                        pendingGroupProjectID = nil
                        createGroup(in: project.id, input: value)
                    },
                    onCancel: { pendingGroupProjectID = nil }
                )
                .help(Text("New Group"))
                .padding(.vertical, 2)
            )
            // An untagged sibling inside `List(selection:)` is otherwise a phantom
            // row — highlightable and arrow-key reachable. This one is transient,
            // but it must not take the selection while it is up.
            .selectionDisabled(true)
        }
    }

    private func groupRow(project: Project, group: Workstream.Group) -> some View {
        let members = project.workstreams(in: group.id)
        let runs = agentStateTracker.runs(for: group.id)
        let mainRun = runs.first(where: \.isMain)
        let isGitRepo = appEnv.isGitRepo(project.directory)
        return spined(
            GroupRow(
                name: group.name,
                memberCount: members.count,
                isSelected: selection == .group(group.id),
                agentState: agentStateTracker.state(for: group.id),
                hasLiveSession: agentStateTracker.hasLiveSession(for: group.id),
                channelDown: channelProbe.state.isDown,
                mainActivity: mainRun?.activity,
                mainContextUsage: agentStateTracker.mainContextUsage(for: group.id),
                startedAt: mainRun?.startedAt,
                showShortcutButton: Shortcut.Settings.shouldShowButton(
                    isGitRepo: isGitRepo,
                    toggleEnabled: shortcutButtonEnabled,
                    hasToken: hasShortcutToken
                ),
                // Both halves are already cached in AppEnvironment and refreshed on its own
                // schedule — asking git or gh from a row body would spawn a subprocess per render.
                // `hasGitHubRemote` is the half that genuinely is: the path-validity sweep
                // probes every project's own directory every 15s. `githubURL`, which used to
                // stand here, is not — see `shouldShowBranchButton`.
                showGitHubButton: GitHub.Operations.shouldShowBranchButton(
                    isGitRepo: isGitRepo,
                    hasGitHubRemote: appEnv.hasGitHubRemote(project.directory)
                ),
                onAdd: { addWorkstream(for: project.id, groupID: group.id) },
                onAddWithPermissions: { addWorkstream(for: project.id, groupID: group.id, bypassPermissions: true) },
                onAddWithoutPermissions: { addWorkstream(for: project.id, groupID: group.id, bypassPermissions: false) },
                onAddFromShortcut: { addWorkstreamFromShortcut(for: project.id, groupID: group.id) },
                onAddFromGitHub: { addWorkstreamFromGitHub(for: project.id, groupID: group.id) },
                isRenaming: Binding(
                    get: { renamingGroupID == group.id },
                    set: { renamingGroupID = $0 ? group.id : nil }
                ),
                onRenameCommit: { commitGroupRename(projectID: project.id, groupID: group.id, input: $0) },
                bypassPermissions: group.bypassPermissions,
                onToggleBypass: { toggleGroupBypass(projectID: project.id, groupID: group.id) },
                onRemove: { removeGroup(projectID: project.id, groupID: group.id) },
                removeDisabledReason: members.isEmpty
                    ? nil
                    : NSLocalizedString("Remove or purge its workstreams first", comment: "Why Remove Group is disabled")
            )
        )
        .tag(SidebarSelection.group(group.id))
    }

    /// The workstreams of one group, as the content of its `DisclosureGroup`.
    ///
    /// Each row draws its own segment of the tree-guide spine. That is not a
    /// stylistic choice: these rows are siblings of the `List`, so there is no
    /// container to stroke down the side of — wrapping them in one would collapse
    /// them into a single row and take per-workstream selection with it. The
    /// segments are given a negative vertical padding so they overlap into their
    /// neighbours and read as one continuous line.
    private func workstreamRows(project: Project, group: Workstream.Group) -> some View {
        let members = project.workstreams(in: group.id)
        let rowIDs = sidebarRowOrder(
            cached: cachedSortedWorkstreamIDs[group.id],
            actual: members.map(\.id)
        )
        return ForEach(rowIDs, id: \.self) { workstreamID in
            // Resolved by id, from this group's own members — never by a cached
            // `(project, workstream)` index pair. A positional pair is global, so a stale
            // one could make one project's group render another's rows while that project
            // rendered them too, and tag both copies alike.
            if let workstream = members.first(where: { $0.id == workstreamID }) {
                let facts = appEnv.facts(for: workstream.worktreePath)
                let pr = appEnv.pullRequest(forWorktree: workstream.worktreePath, in: project.directory)
                let wsRuns = agentStateTracker.runs(for: workstream.id)
                let mainRun = wsRuns.first(where: \.isMain)
                let subRuns = wsRuns.filter { !$0.isMain }

                spined(VStack(alignment: .leading, spacing: 2) {
                    WorkstreamRow(
                        name: workstream.label,
                        branchName: facts?.branch,
                        worktreePath: workstream.worktreePath,
                        isPathValid: facts?.isPathValid ?? true,
                        isSelected: selection == .workstream(workstream.id),
                        agentState: agentStateTracker.state(for: workstream.id),
                        hasLiveSession: agentStateTracker.hasLiveSession(for: workstream.id),
                        channelDown: channelProbe.state.isDown,
                        mainActivity: mainRun?.activity,
                        // Passed regardless of whether the main run
                        // is still rostered: the tracker keeps the
                        // last reading after a turn ends so the bar
                        // persists (dimmed) at Done/Idle.
                        mainContextUsage: agentStateTracker.mainContextUsage(for: workstream.id),
                        startedAt: mainRun?.startedAt,
                        githubURL: appEnv.githubURL(for: project.directory),
                        taskDescription: facts?.taskDescription,
                        prTitle: pr?.title,
                        prNumber: pr?.number,
                        prStatus: pr?.status,
                        isRenaming: Binding(
                            get: { renamingWorkstreamID == workstream.id },
                            set: { renamingWorkstreamID = $0 ? workstream.id : nil }
                        ),
                        onRemove: { removeConfirmation.confirm(workstreamID: workstream.id) },
                        onPurge: { confirmPurge(workstream) },
                        onRenameCommit: { commitRename(workstreamID: workstream.id, input: $0) }
                    )

                    if !subRuns.isEmpty {
                        WorkstreamAgentRosterView(runs: subRuns, channelDown: channelProbe.state.isDown) {
                            selectAndFocusAgent(workstreamID: workstream.id)
                        }
                        .padding(.leading, 6)
                    }
                }, extraIndent: Layout.groupIndent)
                    .tag(SidebarSelection.workstream(workstream.id))
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            // Gated on the probe's verdict and *nothing else*, which is the
            // whole reason it exists rather than leaving the row words to carry
            // this. A channel broken before any event ever arrived leaves every
            // workstream with `hasLiveSession == false`, so no row draws a
            // status line at all — the one case the feature is for would
            // otherwise be exactly as invisible as before it existed.
            if channelProbe.state.isDown {
                HookChannelBanner()
            }

            UsageMeterView()

            HStack {
                SidebarBottomButton(icon: "plus") {
                    showingAddProjectChoice = true
                }
                .accessibilityLabel("Add project")
                Spacer()
                SidebarBottomButton(icon: "questionmark.circle") {
                    AppCommandChannel.shared.send(.openHelp)
                }
                .accessibilityLabel("Help")
                SidebarBottomButton(icon: "gear") {
                    AppCommandChannel.shared.send(.openSettings(pane: nil))
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    var body: some View {
        sidebar
            .alert(
                "Remove Project",
                isPresented: Binding(
                    get: { projectToDelete != nil },
                    set: {
                        if !$0 {
                            projectToDelete = nil
                        }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) { projectToDelete = nil }
                Button("Remove", role: .destructive) {
                    if let id = projectToDelete {
                        deleteProject(id: id)
                    }
                }
            } message: {
                if let id = projectToDelete, let project = projects.first(where: { $0.id == id }) {
                    Text(String(format: NSLocalizedString("Remove \"%@\" from the list? Files in %@ will not be deleted.", comment: ""), project.name, project.directory))
                }
            }
            .removeConfirmationAlert(
                removeConfirmation,
                archiving: Workstream.ArchiveContext(
                    projects: $projects,
                    surfaceCache: surfaceCache,
                    tmuxPath: appEnv.toolStatus.tmux.path,
                    verificationRunner: verificationRunner,
                    agentStateTracker: agentStateTracker
                ),
                selection: $selection
            ) { _ in
                rebuildSortOrder()
                onProjectsChanged()
            }
            .purgeConfirmationAlert(
                purgeConfirmation,
                archiving: Workstream.PurgeConfirmation.ArchiveContext(
                    projects: $projects,
                    surfaceCache: surfaceCache,
                    tmuxPath: appEnv.toolStatus.tmux.path,
                    verificationRunner: verificationRunner,
                    agentStateTracker: agentStateTracker
                )
            ) { completion in
                guard case let .workstream(wsID, projectID) = completion else { return }
                // Read before the rebuild: the model no longer holds the purged
                // workstream, and this cache is the one place its group is still named.
                let groupID = cachedSortedWorkstreamIDs.first(where: { $0.value.contains(wsID) })?.key
                rebuildSortOrder()
                if case let .workstream(id) = selection, id == wsID {
                    // The first row the user can see in the same group, which under
                    // `.recent` is not storage order; then the group itself.
                    selection = Workstream.RemoveConfirmation.fallbackSelection(
                        projectID: projectID,
                        groupID: groupID,
                        nextInGroup: groupID.flatMap { cachedSortedWorkstreamIDs[$0]?.first },
                        groupExists: groupID.map { id in projects.contains(where: { $0.group(with: id) != nil }) } ?? false
                    )
                }
                onProjectsChanged()
            }
            .alert(
                "Worktree Creation Failed",
                isPresented: $showWorktreeError
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Could not create the git worktree. The branch may already exist, or there may be an ongoing merge or rebase.")
            }
            .alert(
                "Not a Git Repository",
                isPresented: $showNotGitRepoError
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Workstreams require a git repository. Initialize one with git init or select a different directory.")
            }
            .alert(
                "Select a group to add a workstream to.",
                isPresented: $showGroupRequiredHint
            ) {
                Button("OK", role: .cancel) {}
            }
            .alert(
                groupNameRefusalTitle,
                isPresented: Binding(
                    get: { groupNameRefusal != nil },
                    set: {
                        if !$0 {
                            groupNameRefusal = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) { groupNameRefusal = nil }
            }
    }

    /// The localized text for a refused group name. `validateName` is the only
    /// validation; this is only its wording.
    private var groupNameRefusalTitle: String {
        switch groupNameRefusal {
        case .empty:
            NSLocalizedString("Group name can't be empty.", comment: "Group name refusal")
        case .taken:
            NSLocalizedString("A group with this name already exists.", comment: "Group name refusal")
        case nil:
            ""
        }
    }

    private var sidebar: some View {
        sidebarList
            .sheet(isPresented: $showingAddProjectChoice) {
                AddProjectChoiceSheet(
                    onCloneRepo: {
                        showingAddProjectChoice = false
                        cloneRemote = ""
                        cloneDirectoryName = ""
                        cloneDirectoryNameEdited = false
                        cloneError = ""
                        isCloning = false
                        showingCloneRepo = true
                    },
                    onNewProject: {
                        showingAddProjectChoice = false
                        newProjectName = ""
                        newProjectError = ""
                        showingNewProjectName = true
                    },
                    onExistingDirectory: {
                        showingAddProjectChoice = false
                        openDirectoryPicker()
                    },
                    onCancel: { showingAddProjectChoice = false }
                )
            }
            .sheet(isPresented: $showingCloneRepo) {
                CloneRepoSheet(
                    remote: $cloneRemote,
                    directoryName: $cloneDirectoryName,
                    error: $cloneError,
                    isCloning: isCloning,
                    baseDirectory: baseDirectory,
                    onRemoteChanged: { updateSuggestedCloneDirectoryName(from: $0) },
                    onDirectoryNameEdited: { cloneDirectoryNameEdited = true },
                    onClone: { cloneRepository() },
                    onCancel: { cancelClone() }
                )
            }
            .sheet(isPresented: $showingNewProjectName) {
                NewProjectSheet(
                    name: $newProjectName,
                    error: $newProjectError,
                    baseDirectory: baseDirectory,
                    onAdd: { createNewProject() },
                    onCancel: { showingNewProjectName = false }
                )
            }
            .sheet(isPresented: $showingNewWorkstreamName) {
                NewWorkstreamSheet(
                    name: $newWorkstreamName,
                    error: $newWorkstreamError,
                    projectName: pendingWorkstreamProjectID.flatMap { id in projects.first(where: { $0.id == id })?.name } ?? "",
                    placeholder: newWorkstreamPlaceholder,
                    onAdd: { createWorkstream() },
                    onCancel: {
                        showingNewWorkstreamName = false
                        pendingWorkstreamProjectID = nil
                        pendingWorkstreamGroupID = nil
                        pendingWorkstreamBypass = nil
                    }
                )
            }
            .sheet(isPresented: $showingShortcutStory) {
                ShortcutStorySheet(
                    storyInput: $shortcutStoryInput,
                    error: $shortcutError,
                    showsSettingsLink: shortcutErrorNeedsToken,
                    isFetching: shortcutFetching,
                    projectName: pendingWorkstreamProjectID.flatMap { id in projects.first(where: { $0.id == id })?.name } ?? "",
                    onCreate: { createWorkstreamFromShortcut() },
                    onOpenSettings: {
                        showingShortcutStory = false
                        AppCommandChannel.shared.send(.openSettings(pane: .integrations))
                    },
                    onCancel: {
                        shortcutFetchTask?.cancel()
                        shortcutFetchTask = nil
                        shortcutFetching = false
                        showingShortcutStory = false
                        pendingWorkstreamProjectID = nil
                        pendingWorkstreamGroupID = nil
                    }
                )
            }
            .sheet(isPresented: $showingGitHubBranch) {
                GitHubBranchSheet(
                    branchInput: $gitHubBranchInput,
                    error: $gitHubBranchError,
                    isChecking: gitHubBranchChecking,
                    projectName: pendingWorkstreamProjectID.flatMap { id in projects.first(where: { $0.id == id })?.name } ?? "",
                    onCreate: { createWorkstreamFromGitHubBranch() },
                    onCancel: {
                        gitHubBranchTask?.cancel()
                        gitHubBranchTask = nil
                        gitHubBranchChecking = false
                        showingGitHubBranch = false
                        pendingWorkstreamProjectID = nil
                        pendingWorkstreamGroupID = nil
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: Shortcut.Settings.tokenChanged)) { _ in
                hasShortcutToken = KeychainTokenStore().hasToken
            }
            .onReceive(NotificationCenter.default.publisher(for: .addProject)) { _ in
                showingAddProjectChoice = true
            }
            // The object, when present, is the `bypassPermissions` choice the add
            // menu's two variants make; the palette posts it for those two rows.
            // Absent means "use the `atelier.bypassPermissions` default", which is
            // what every other producer of this notification wants.
            //
            // A workstream joins a group, so the target is the selected workstream's
            // group or the selected group. A selected *project* names no group — it
            // may have several, or none — so it says so rather than guessing one.
            .onReceive(NotificationCenter.default.publisher(for: .addNew)) { note in
                let bypass = note.object as? Bool
                switch selection {
                case let .workstream(wsID):
                    guard let project = projects.first(where: { $0.workstreams.contains(where: { $0.id == wsID }) }),
                          let groupID = project.workstreams.first(where: { $0.id == wsID })?.groupID
                    else { return }
                    addWorkstream(for: project.id, groupID: groupID, bypassPermissions: bypass)
                case let .group(groupID):
                    guard let project = projects.first(where: { $0.group(with: groupID) != nil }) else { return }
                    addWorkstream(for: project.id, groupID: groupID, bypassPermissions: bypass)
                case .project:
                    showGroupRequiredHint = true
                case .settings, .help, nil:
                    showingAddProjectChoice = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameWorkstream)) { _ in
                beginRenameOfSelectedWorkstream()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openDirectory)) { notification in
                guard let directory = notification.object as? String else { return }
                addProject(name: URL(fileURLWithPath: directory).lastPathComponent, directory: directory)
            }
    }

    private var sidebarList: some View {
        // **No `GeometryReader` around this.** One wrapped the whole sidebar
        // here until it was removed, with its proxy discarded — the last real
        // use, `.frame(height: max(80, geo.size.height * 0.2))`, went in #101
        // and left the container standing.
        //
        // It is not free. A `GeometryReader` reports the parent's proposal as
        // its own size and never propagates its content's size back up, and it
        // can only hand the closure a proxy once its own size has resolved — so
        // the children are laid out downstream of the previous pass rather than
        // in it. `List` under `.listStyle(.sidebar)` is an `NSTableView`, which
        // caches row rects and invalidates them on a bounds change, and across
        // that extra hop the bounds change and the SwiftUI row updates arrive in
        // no guaranteed order. Dragging the sidebar divider left rows painted at
        // their pre-resize frames: a selected row's highlight capsule stranded at
        // the old width, over rows it did not belong to, still taking content
        // updates but no longer taking geometry.
        //
        // If something here needs the container's size, read it from somewhere
        // that does not take part in layout — `.onGeometryChange(for:of:action:)`,
        // or a `GeometryReader` inside `.background` — or express the intent with
        // `.containerRelativeFrame(_:)`. Do not wrap the `List` again.
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                List(selection: $selection) {
                    projectRows()
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, sel in
                    guard let sel else { return }
                    deferSelectionExpansion(
                        sel,
                        projectIDByWorkstreamID: projectIDByWorkstreamIDSnapshot(),
                        projectIDByGroupID: projectIDByGroupIDSnapshot(),
                        groupIDByWorkstreamID: groupIDByWorkstreamIDSnapshot(),
                        scrollProxy: scrollProxy
                    )
                }
            } // ScrollViewReader

            // Bottom bar (always visible)
            bottomBar
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalActivity)) { notification in
            guard let wsID = notification.object as? UUID else { return }
            recordTerminalActivity(workstreamID: wsID)
        }
        .onAppear {
            cachedSortedIDs = recomputeSortedIDs()
            rebuildSortOrder()
        }
        .onChange(of: expandedProjects) { _, newValue in SidebarState.saveExpanded(newValue) }
        .onChange(of: expandedGroups) { _, newValue in SidebarState.saveExpandedGroups(newValue) }
        .onChange(of: workstreamSortOrder) { _, _ in rebuildSortOrder() }
        .onChange(of: projects.count) { _, _ in
            cachedSortedIDs = recomputeSortedIDs()
            rebuildSortOrder()
        }
        .onChange(of: totalWorkstreamCount()) { _, _ in
            rebuildSortOrder()
        }
        .onChange(of: totalGroupCount()) { _, _ in
            rebuildSortOrder()
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Stamps a workstream (and its project) as just used, from `.terminalActivity`,
    /// and re-sorts what that stamp can move.
    private func recordTerminalActivity(workstreamID wsID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.workstreams.contains(where: { $0.id == wsID }) }),
              let wi = projects[pi].workstreams.firstIndex(where: { $0.id == wsID })
        else { return }
        let now = Date()
        projects[pi].lastAccessedAt = now
        projects[pi].workstreams[wi].lastAccessedAt = now
        onProjectsChanged()
        // Only `.recent` can be reordered by a timestamp write, and this fires on
        // every burst of terminal output — so under `.alphabetical` the re-sort is
        // pure work for an order that cannot have changed. Projects themselves are
        // always A–Z and never re-sorted here.
        //
        // A member's timestamp is also its group's recency, so the group row can
        // move too.
        if workstreamSortOrder == .recent {
            let project = projects[pi]
            if let groupID = project.workstreams[wi].groupID {
                cachedSortedWorkstreamIDs[groupID] = workstreamSortOrder
                    .sorted(project.workstreams(in: groupID))
                    .map(\.id)
            }
            cachedSortedGroupIDs[project.id] = workstreamSortOrder
                .sorted(project.sortedGroups, in: project)
                .map(\.id)
        }
    }

    // MARK: - Workstream management

    @AppStorage("atelier.bypassPermissions") private var defaultBypass: Bool = false

    private func addWorkstream(for projectID: UUID, groupID: UUID, bypassPermissions: Bool? = nil) {
        logger.warning("[Atelier] addWorkstream called for projectID=\(projectID, privacy: .public)")
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            logger.warning("[Atelier] addWorkstream: project not found")
            return
        }
        let project = projects[index]
        logger.warning("[Atelier] addWorkstream: project=\(project.name, privacy: .public) dir=\(project.directory, privacy: .public)")

        guard Git.Operations.isGitRepo(at: project.checkout) else {
            logger.warning("[Atelier] addWorkstream: not a git repo")
            showNotGitRepoError = true
            return
        }
        logger.warning("[Atelier] addWorkstream: is git repo")

        let existingNames = Set(project.workstreams.map(\.name))
        newWorkstreamName = ""
        newWorkstreamError = ""
        newWorkstreamPlaceholder = NameGenerator.generate(avoiding: existingNames)
        pendingWorkstreamProjectID = projectID
        pendingWorkstreamGroupID = groupID
        pendingWorkstreamBypass = bypassPermissions
        showingNewWorkstreamName = true
    }

    private func addWorkstreamFromShortcut(for projectID: UUID, groupID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard Git.Operations.isGitRepo(at: projects[index].checkout) else {
            showNotGitRepoError = true
            return
        }
        shortcutStoryInput = ""
        shortcutError = ""
        shortcutFetching = false
        pendingWorkstreamProjectID = projectID
        pendingWorkstreamGroupID = groupID
        showingShortcutStory = true
    }

    /// Fetches the story, then creates a workstream named by Shortcut's own suggested
    /// branch name. Nothing is created if the fetch fails.
    private func createWorkstreamFromShortcut() {
        guard let projectID = pendingWorkstreamProjectID,
              let groupID = pendingWorkstreamGroupID,
              let index = projects.firstIndex(where: { $0.id == projectID })
        else { return }

        // Cleared up front so a stale auth failure from a previous attempt does not
        // leave the Settings link showing next to an unrelated validation message.
        shortcutErrorNeedsToken = false

        guard let storyID = Shortcut.StoryID.parse(shortcutStoryInput) else {
            shortcutError = NSLocalizedString(
                "Enter a story id.",
                comment: "Shortcut story input validation error"
            )
            return
        }

        let project = projects[index]
        let bypass = defaultBypass
        shortcutError = ""
        shortcutFetching = true

        shortcutFetchTask = Task {
            do {
                let story = try await Shortcut.Client().story(id: storyID)
                // The sheet may have been cancelled while the request was in flight; the
                // 15s timeout makes that window wide on a slow network. Creating a
                // workstream after the user dismissed the dialog is the worst outcome here.
                guard !Task.isCancelled, pendingWorkstreamProjectID == projectID else { return }
                shortcutFetching = false

                // The render and the two collisions are `Shortcut.WorkstreamName`'s,
                // shared with `create_shortcut_workstream` so the sheet and the tool
                // cannot drift. Only the *decision* is shared — the wording is one
                // per consumer, and this one takes `localizedMessage` because it is
                // user copy where the tool's is an instruction to an agent. The two
                // collisions are distinct and their order matters: checking only the
                // name let the same story through twice under a changed Branch Name
                // Pattern, and blamed the story when an unrelated workstream happened
                // to match the name.
                let name: String
                switch Shortcut.WorkstreamName.resolve(
                    template: branchTemplate,
                    story: story,
                    existing: project.workstreams
                ) {
                case let .success(resolved):
                    name = resolved
                case let .failure(refusal):
                    shortcutError = refusal.localizedMessage
                    return
                }

                showingShortcutStory = false
                pendingWorkstreamProjectID = nil
                pendingWorkstreamGroupID = nil
                // Keep the story we just fetched: it carries the description, and the
                // worktree path it will be cached under does not exist yet.
                appEnv.stageShortcutStory(story)
                startLaunch(
                    project: project,
                    projectID: projectID,
                    groupID: groupID,
                    name: name,
                    bypass: bypass,
                    shortcutStoryID: story.id
                )
            } catch let error as Shortcut.Error {
                guard !Task.isCancelled, pendingWorkstreamProjectID == projectID else { return }
                shortcutFetching = false
                shortcutError = error.message
                shortcutErrorNeedsToken = error.needsToken
            } catch {
                guard !Task.isCancelled, pendingWorkstreamProjectID == projectID else { return }
                shortcutFetching = false
                shortcutError = error.localizedDescription
                shortcutErrorNeedsToken = false
            }
        }
    }

    private func addWorkstreamFromGitHub(for projectID: UUID, groupID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard Git.Operations.isGitRepo(at: projects[index].checkout) else {
            showNotGitRepoError = true
            return
        }
        gitHubBranchInput = ""
        gitHubBranchError = ""
        gitHubBranchChecking = false
        pendingWorkstreamProjectID = projectID
        pendingWorkstreamGroupID = groupID
        showingGitHubBranch = true
    }

    /// What the pre-flight found, decided off the main actor.
    ///
    /// The whole point of asking before creating anything: git refuses to check one branch
    /// out twice and reports a missing branch as an ordinary failure, and both of those
    /// arrive too late to say anything useful — after the optimistic row is already drawn.
    private enum GitHubBranchPreflight {
        case ready
        case missingOnOrigin
        case checkedOutAt(String)
    }

    /// Confirms origin really has the branch, and that no worktree already holds it, before
    /// a workstream exists. Nothing is created if either check fails.
    private func createWorkstreamFromGitHubBranch() {
        guard let projectID = pendingWorkstreamProjectID,
              let groupID = pendingWorkstreamGroupID,
              let index = projects.firstIndex(where: { $0.id == projectID })
        else { return }

        let branch: String
        switch GitHub.BranchInput.branch(from: gitHubBranchInput) {
        case let .success(name):
            branch = name
        case let .failure(rejection):
            gitHubBranchError = rejection.message
            return
        }

        let project = projects[index]
        guard !project.workstreams.contains(where: { $0.name == branch }) else {
            gitHubBranchError = NSLocalizedString(
                "A workstream with this name already exists.",
                comment: "Error when the workstream name collides with an existing workstream"
            )
            return
        }

        let bypass = defaultBypass
        let projectPath = project.checkout
        gitHubBranchError = ""
        gitHubBranchChecking = true

        gitHubBranchTask = Task {
            // Detached because both checks are git subprocesses, and one of them fetches:
            // run on the main actor they would freeze the dialog they are drawing a spinner in.
            // The local lookup goes first so an already-checked-out branch never waits on a fetch.
            let preflight = await Task.detached { () -> GitHubBranchPreflight in
                if let holder = Git.Operations.worktreePath(forBranch: branch, at: projectPath) {
                    return .checkedOutAt(holder)
                }
                guard Git.Operations.remoteBranchTip(at: projectPath, branch: branch) != nil else {
                    return .missingOnOrigin
                }
                return .ready
            }.value

            // The dialog may have been cancelled while the fetch was in flight; on a slow
            // link that window is seconds wide.
            guard !Task.isCancelled, pendingWorkstreamProjectID == projectID else { return }
            gitHubBranchChecking = false

            switch preflight {
            case .missingOnOrigin:
                gitHubBranchError = String(
                    format: NSLocalizedString(
                        "origin has no branch named %@.",
                        comment: "Error when the typed branch does not exist on the GitHub remote"
                    ),
                    branch
                )
            case let .checkedOutAt(path):
                gitHubBranchError = String(
                    format: NSLocalizedString(
                        "That branch is already checked out at %@.",
                        comment: "Error when another worktree already holds the requested branch"
                    ),
                    path.abbreviatedPath
                )
            case .ready:
                showingGitHubBranch = false
                pendingWorkstreamProjectID = nil
                pendingWorkstreamGroupID = nil
                startLaunch(
                    project: project,
                    projectID: projectID,
                    groupID: groupID,
                    name: branch,
                    bypass: bypass,
                    existingBranch: branch
                )
            }
        }
    }

    private func createWorkstream() {
        guard let projectID = pendingWorkstreamProjectID,
              let groupID = pendingWorkstreamGroupID
        else { return }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            showingNewWorkstreamName = false
            return
        }
        let project = projects[index]
        let existingNames = Set(project.workstreams.map(\.name))

        let typedName = newWorkstreamName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedName.isEmpty {
            guard Git.Operations.isValidBranchName(typedName) else {
                newWorkstreamError = NSLocalizedString(
                    "That name isn't valid for a git branch.",
                    comment: "Error when the workstream name is not a valid git branch name"
                )
                return
            }
            guard !existingNames.contains(typedName) else {
                newWorkstreamError = NSLocalizedString(
                    "A workstream with this name already exists.",
                    comment: "Error when the workstream name collides with an existing workstream"
                )
                return
            }
        }

        let bypass = pendingWorkstreamBypass ?? defaultBypass
        let name = typedName.isEmpty ? NameGenerator.generate(avoiding: existingNames) : typedName
        logger.warning("[Atelier] createWorkstream: \(typedName.isEmpty ? "generated" : "user") name=\(name, privacy: .public)")

        showingNewWorkstreamName = false
        pendingWorkstreamProjectID = nil
        pendingWorkstreamGroupID = nil
        pendingWorkstreamBypass = nil
        startLaunch(project: project, projectID: projectID, groupID: groupID, name: name, bypass: bypass)
    }

    /// Hands the creation sequence to `Workstream.Launcher`, which owns it for
    /// every producer — these three entry points, `ProjectOverviewView`'s
    /// adoption, and `create_workstream` over IPC.
    ///
    /// This function used to *be* that sequence, on its own `DispatchQueue`,
    /// with its own rollback. What is left is what only a mounted view can do:
    /// expanding the project's row so the optimistic workstream is visible, and
    /// raising the alert when the launch refuses. Its group is expanded too, or the
    /// optimistic row would be drawn inside a collapsed group. `rebuildSortOrder()` is no
    /// longer called here and is not lost — the `.onChange(of:
    /// totalWorkstreamCount())` and `.onChange(of: projects.count)` handlers
    /// above fire in the same update cycle, and the explicit call was already
    /// redundant with them.
    ///
    /// `existingBranch` decides *which* git operation the launcher runs, and it
    /// is not cosmetic: `createWorktree` cuts a new branch from the base branch,
    /// so using it for a branch that lives on origin succeeds and produces a
    /// worktree holding the base branch's code under the name the user asked
    /// for. This view used to assemble that git call itself; it now names the
    /// choice — `Workstream.Launcher.WorktreeSource` — and the launcher runs it.
    /// The two operations stay distinct and neither is routed through the other:
    /// see CLAUDE.md, "Two ways to create a worktree, and they are not
    /// interchangeable".
    private func startLaunch(
        project: Project,
        projectID: UUID,
        groupID: UUID,
        name: String,
        bypass: Bool,
        shortcutStoryID: Int? = nil,
        existingBranch: String? = nil
    ) {
        expandedProjects.insert(projectID)
        expandedGroups.insert(groupID)

        Task {
            do {
                _ = try await Workstream.Launcher.shared.launch(
                    in: Workstream.Launcher.target(for: project),
                    groupID: groupID,
                    requestedName: name,
                    bypassPermissions: bypass,
                    select: true,
                    shortcutStoryID: shortcutStoryID,
                    source: existingBranch.map { .existingRemoteBranch($0) } ?? .newBranch
                )
            } catch {
                // Every refusal lands on one alert, deliberately. The launcher
                // also throws `.invalidName` and `.nameInUse`, which each of
                // these three entry points has already checked against the same
                // rules — so reaching them here means a race, by which point the
                // sheet that owns the field-level message is dismissed and there
                // is nowhere else to say it.
                logger.warning("[Atelier] startLaunch failed: \(error.localizedDescription, privacy: .public)")
                showWorktreeError = true
            }
        }
    }

    @EnvironmentObject private var surfaceCache: TerminalSurfaceCache
    @EnvironmentObject private var appEnv: AppEnvironment
    @EnvironmentObject private var agentStateTracker: Workstream.AgentStateTracker
    @EnvironmentObject private var channelProbe: HookChannelProbe

    private func confirmPurge(_ workstream: Workstream) {
        purgeConfirmation.confirm(workstream: workstream)
    }

    /// Selects a workstream and focuses its Coding Agent tab. When the
    /// workstream isn't already selected, focus is deferred briefly so the
    /// detail pane can swap to the new container first.
    private func selectAndFocusAgent(workstreamID: UUID) {
        if case let .workstream(selected) = selection, selected == workstreamID {
            NotificationCenter.default.post(name: .focusAgent, object: nil)
            return
        }
        selection = SidebarSelection.workstream(workstreamID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .focusAgent, object: nil)
        }
    }

    /// Commit a project rename from the sidebar.
    ///
    /// Writes `Project.name` directly rather than adding a `displayName` override
    /// the way `Workstream` does. A workstream's `name` tracks its git branch, so it
    /// needs something to fall back to; a project's does not track anything, and
    /// `ProjectOverviewView`'s title field has always written this same field — a
    /// second, overriding one would make the two editors disagree about what the
    /// project is called.
    ///
    /// An empty or whitespace-only input keeps the current name. `Workstream`'s
    /// equivalent reads empty as "clear the override and follow the branch again";
    /// here there is nothing to fall back to, so honouring it would leave a nameless
    /// row that could only be fixed from the overview pane.
    private func commitProjectRename(projectID: UUID, input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projects.firstIndex(where: { $0.id == projectID }),
              projects[index].name != trimmed
        else { return }
        projects[index].name = trimmed
        onProjectsChanged()
        // Projects are ordered A-Z, so a rename can move this row.
        cachedSortedIDs = recomputeSortedIDs()
        rebuildSortOrder()
    }

    private func commitRename(workstreamID: UUID, input: String) {
        guard let pi = projects.firstIndex(where: { $0.id == workstreamProjectID(for: workstreamID) }),
              let wi = projects[pi].workstreams.firstIndex(where: { $0.id == workstreamID }) else { return }
        projects[pi].workstreams[wi].applyRename(input)
        onProjectsChanged()
        // `.alphabetical` sorts on `label`, which this just changed.
        rebuildSortOrder()
    }

    /// Begin an inline rename of the selected workstream (⌘⇧R / palette),
    /// expanding its project so the row is visible.
    private func beginRenameOfSelectedWorkstream() {
        guard case let .workstream(wsID) = selection,
              let projectID = workstreamProjectID(for: wsID) else { return }
        expandedProjects.insert(projectID)
        if let groupID = groupIDByWorkstreamIDSnapshot()[wsID] {
            expandedGroups.insert(groupID)
        }
        renamingWorkstreamID = wsID
    }

    private func workstreamProjectID(for workstreamID: UUID) -> UUID? {
        for project in projects where project.workstreams.contains(where: { $0.id == workstreamID }) {
            return project.id
        }
        return nil
    }

    // MARK: - Group management

    /// Opens the inline new-group field as the last child of the project.
    private func beginNewGroup(in projectID: UUID) {
        expandedProjects.insert(projectID)
        pendingGroupProjectID = projectID
    }

    /// Creating a group does **not** select it: selecting a group row starts its
    /// coordinator, and making a group is not asking for one.
    private func createGroup(in projectID: UUID, input: String) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        switch Workstream.Group.validateName(input, siblings: projects[pi].groups ?? []) {
        case let .success(name):
            // The app's current permission default, as a new workstream takes it.
            let group = Workstream.Group(name: name, bypassPermissions: defaultBypass)
            projects[pi].groups = (projects[pi].groups ?? []) + [group]
            expandedGroups.insert(group.id)
            onProjectsChanged()
            rebuildSortOrder()
        case let .failure(refusal):
            groupNameRefusal = refusal
        }
    }

    private func commitGroupRename(projectID: UUID, groupID: UUID, input: String) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let gi = projects[pi].groups?.firstIndex(where: { $0.id == groupID })
        else { return }
        switch Workstream.Group.validateName(input, siblings: projects[pi].groups ?? [], excluding: groupID) {
        case let .success(name):
            guard projects[pi].groups?[gi].name != name else { return }
            projects[pi].groups?[gi].name = name
            onProjectsChanged()
            // `.alphabetical` sorts on the name, which this just changed.
            rebuildSortOrder()
        case let .failure(refusal):
            groupNameRefusal = refusal
        }
    }

    private func toggleGroupBypass(projectID: UUID, groupID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let gi = projects[pi].groups?.firstIndex(where: { $0.id == groupID })
        else { return }
        projects[pi].groups?[gi].bypassPermissions.toggle()
        onProjectsChanged()
    }

    /// The context menu already refuses a group with members, and
    /// `Archiver.removeGroup` refuses it again.
    private func removeGroup(projectID: UUID, groupID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              projects[pi].workstreams(in: groupID).isEmpty
        else { return }
        Workstream.Archiver.removeGroup(
            groupID,
            from: &projects[pi],
            surfaceCache: surfaceCache,
            agentStateTracker: agentStateTracker,
            tmuxPath: appEnv.toolStatus.tmux.path
        )
        expandedGroups.remove(groupID)
        if selection == .group(groupID) {
            selection = .project(projectID)
        }
        rebuildSortOrder()
        onProjectsChanged()
    }

    // MARK: - Project management

    private func deleteProject(id: UUID) {
        // Through `Archiver`, not a hand-rolled pair of cleanup calls: deleting
        // a project ends every workstream in it, and this used to do only two
        // of the ten things ending one involves. See `removeAllWorkstreams`.
        if let project = projects.first(where: { $0.id == id }) {
            Workstream.Archiver.removeAllWorkstreams(
                in: project,
                surfaceCache: surfaceCache,
                tmuxPath: appEnv.toolStatus.tmux.path,
                verificationRunner: verificationRunner,
                agentStateTracker: agentStateTracker
            )
        }
        projects.removeAll { $0.id == id }
        // Eagerly, not left to `onChange(of: projects.count)`, so the rows settle in
        // this frame rather than the next. Nothing indexes positionally any more, so a
        // late rebuild is now only a cosmetic ordering lag rather than a stale
        // `(project, workstream)` pair pointing at the wrong workstream.
        cachedSortedIDs = recomputeSortedIDs()
        rebuildSortOrder()
        if case let .project(pid) = selection, pid == id {
            selection = nil
        }
        if case let .workstream(wsID) = selection,
           !projects.contains(where: { $0.workstreams.contains(where: { $0.id == wsID }) })
        {
            selection = nil
        }
        if case let .group(groupID) = selection,
           !projects.contains(where: { $0.group(with: groupID) != nil })
        {
            selection = nil
        }
        projectToDelete = nil
        onProjectsChanged()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.hasDirectoryPath || FileManager.default.isDirectory(at: url) else { return }

                DispatchQueue.main.async {
                    addProject(name: url.lastPathComponent, directory: url.path)
                }
            }
        }
        return true
    }

    @AppStorage("atelier.baseDirectory") private var baseDirectory: String = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""

    /// Shown by both creation paths when the base directory names nowhere. The
    /// picker and the settings row are left alone: an unusable value there is a
    /// bad starting directory for a panel, not a directory anything writes to.
    private static let missingBaseDirectoryMessage = NSLocalizedString(
        "Choose a base directory in Settings first.", comment: ""
    )

    private func openDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: baseDirectory)
        panel.message = NSLocalizedString("Choose a project directory", comment: "")
        panel.prompt = NSLocalizedString("Select", comment: "")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            addProject(name: url.lastPathComponent, directory: url.path)
        }
    }

    private func createNewProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        guard let base = projectBaseDirectory(from: baseDirectory) else {
            newProjectError = Self.missingBaseDirectoryMessage
            return
        }

        let dirURL = base.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dirURL.path) {
            newProjectError = NSLocalizedString("A file or directory with this name already exists.", comment: "")
            return
        }

        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            newProjectError = error.localizedDescription
            return
        }

        // Initialize git repo in the new directory
        _ = Git.Operations.initRepo(at: dirURL.path)

        // A directory this path just created is a directory nobody had, so the
        // templates cannot land in a repository the user merely registered — the
        // reason the picker and the drop path do not do this.
        Project.seedDefaultConfigs(projectDirectory: dirURL.path)

        showingNewProjectName = false
        addProject(name: name, directory: dirURL.path)
    }

    /// Keep the folder name in step with the URL until the user types their own.
    private func updateSuggestedCloneDirectoryName(from remote: String) {
        guard !cloneDirectoryNameEdited else { return }
        cloneDirectoryName = BareRepoClone.suggestedDirectoryName(for: remote) ?? ""
    }

    private func cloneRepository() {
        guard let remote = BareRepoClone.normalizeRemote(cloneRemote) else {
            cloneError = NSLocalizedString(
                "Enter a repository URL or an owner/repo name.", comment: ""
            )
            return
        }

        let directoryName = cloneDirectoryName.trimmingCharacters(in: .whitespaces)
        guard !directoryName.isEmpty else {
            cloneError = NSLocalizedString("Enter a folder name.", comment: "")
            return
        }
        guard !directoryName.contains("/"), directoryName != ".", directoryName != ".." else {
            cloneError = NSLocalizedString(
                "The folder name must be a single directory name.", comment: ""
            )
            return
        }

        guard let base = projectBaseDirectory(from: baseDirectory) else {
            cloneError = Self.missingBaseDirectoryMessage
            return
        }

        let container = base.appendingPathComponent(directoryName)
        let cancellation = BareRepoClone.Cancellation()
        cloneCancellation = cancellation
        cloneError = ""
        isCloning = true

        Task.detached {
            let result = BareRepoClone.clone(remote: remote, into: container, cancellation: cancellation)
            await MainActor.run {
                isCloning = false
                cloneCancellation = nil
                switch result {
                case let .success(containerPath):
                    showingCloneRepo = false
                    // The container is `Project.directory` for this layout — the
                    // `.bare` peer, outside every worktree — which is exactly
                    // where every config is looked for.
                    Project.seedDefaultConfigs(projectDirectory: containerPath)
                    addProject(
                        name: URL(fileURLWithPath: containerPath).lastPathComponent,
                        directory: containerPath
                    )
                case let .failure(message):
                    cloneError = message
                case .cancelled:
                    // The sheet is already dismissed and the container removed.
                    break
                }
            }
        }
    }

    /// Stops a clone in flight and closes the sheet. The clone unwinds on its
    /// own thread and cleans up the half-built container.
    private func cancelClone() {
        cloneCancellation?.cancel()
        cloneCancellation = nil
        showingCloneRepo = false
    }

    private func addProject(name: String, directory: String) {
        // Resolve worktree branches to their main repository, and a .bare
        // container to itself plus the checkout that represents it.
        let location = Git.Operations.projectLocation(for: directory)
        let resolvedDirectory = location.directory
        let resolvedName = location.name.isEmpty ? name : location.name

        if let existing = Project.existingRegistration(for: location, in: projects) {
            if let repaired = existing.repaired {
                projects[existing.index] = repaired
                // Saved by hand, because `Project` equates by id: the debounced
                // save on `projectList.items` cannot see a change that leaves
                // every id where it was. `.projectCreated` saves for the same
                // reason.
                ProjectStore.save(projects)
            }
            selection = .project(projects[existing.index].id)
            return
        }

        let projectName = resolvedName.isEmpty ? URL(fileURLWithPath: resolvedDirectory).lastPathComponent : resolvedName
        let project = Project(
            name: projectName,
            directory: resolvedDirectory,
            checkoutDirectory: location.checkoutDirectory
        )
        NotificationCenter.default.post(
            name: .projectCreated,
            object: nil,
            userInfo: ["project": project]
        )
    }
}

extension FileManager {
    func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

func copyTextToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Opens a directory in the user's configured terminal, falling back to Apple Terminal.
func openDirectoryInTerminal(_ directory: String) {
    ExternalTerminal.open(directory: directory)
}

private struct ProjectHeaderRow: View {
    let project: Project
    var githubURL: URL?
    /// Opens the inline new-group field; the only way to add a group.
    let onAddGroup: () -> Void
    /// Whether this row is the sidebar's current selection. Gates the
    /// double-click-to-rename gesture — see `body`.
    let isSelected: Bool
    @Binding var isRenaming: Bool
    let onRenameCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isRenaming {
                        InlineTextField(
                            initialText: project.name,
                            accessibilityID: "project-rename-field",
                            fontSize: 13,
                            fontWeight: .medium,
                            onCommit: { value in
                                isRenaming = false
                                onRenameCommit(value)
                            },
                            onCancel: { isRenaming = false }
                        )
                    } else {
                        Text(project.name)
                            .font(.system(size: 13, weight: .medium))
                            // Same shape as `WorkstreamRow`'s, and for the same reason:
                            // a gesture attached here swallows mouse-down inside the
                            // label's bounds, so an unselected row would refuse to
                            // select when clicked on its name — the part of the row
                            // users aim at. `.none` leaves no recognizer to swallow
                            // anything. It matters more here than there: this row is a
                            // `DisclosureGroup` label, so a swallowed mouse-down would
                            // take the group's own toggle with it.
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { isRenaming = true },
                                including: isSelected ? .gesture : .none
                            )
                    }

                    if !isRenaming, !project.sortedGroups.isEmpty {
                        SidebarCountBadge(count: project.sortedGroups.count)
                            .accessibilityLabel("\(project.sortedGroups.count) groups")
                    }
                }

                Text(project.directory.abbreviatedPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Workstreams are added from their group's row; the project's one
            // button adds a group.
            SidebarIconButton(icon: "plus", action: onAddGroup)
                .accessibilityLabel("Add group to \(project.name)")
                .opacity(isHovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                openDirectoryInTerminal(project.directory)
            } label: {
                Label("Open in External Terminal", systemImage: "terminal")
            }
            if let githubURL {
                Button {
                    NSWorkspace.shared.open(githubURL)
                } label: {
                    Label("Open on GitHub", image: "github")
                }
            }
            Divider()
            Button {
                copyTextToPasteboard(project.directory)
            } label: {
                Label("Copy project path", systemImage: "doc.on.doc")
            }
            Divider()
            Button { isRenaming = true } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Remove Project", systemImage: "trash")
            }
        }
    }
}

/// The small capsule count beside a row's name.
private struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary)
            .clipShape(Capsule())
    }
}

/// "● Working · Editing AuthView.swift · 4m" — colored dot + localized status
/// word, current tool activity while active, and time since the run started.
/// Shared by the workstream row and the group row, whose coordinator is an
/// agent like any other.
private struct AgentStatusMeta: View {
    let word: LocalizedStringKey
    let color: Color
    let isAgentActive: Bool
    let activity: String?
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .padding(.trailing, 4)

            Text(word)
                .foregroundStyle(color)

            if isAgentActive, let activity {
                separator
                Text(activity)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let startedAt {
                separator
                ElapsedLabel(startedAt: startedAt, fontSize: 9)
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 3)
    }
}

/// A workstream group's row, which is also its coordinator's: selecting it opens
/// the coordinator pane, and its status line is the coordinator's agent state,
/// keyed by the group id.
///
/// The add buttons moved here from `ProjectHeaderRow` when workstreams began to
/// live in groups — a new workstream joins the group whose plus was pressed.
private struct GroupRow: View {
    let name: String
    let memberCount: Int
    /// Gates the double-click-to-rename gesture, as on `WorkstreamRow`.
    let isSelected: Bool
    let agentState: Workstream.AgentStateTracker.AgentRunState
    let hasLiveSession: Bool
    let channelDown: Bool
    let mainActivity: String?
    let mainContextUsage: Workstream.AgentStateTracker.ContextUsage?
    let startedAt: Date?
    let showShortcutButton: Bool
    let showGitHubButton: Bool
    let onAdd: () -> Void
    let onAddWithPermissions: () -> Void
    let onAddWithoutPermissions: () -> Void
    let onAddFromShortcut: () -> Void
    let onAddFromGitHub: () -> Void
    @Binding var isRenaming: Bool
    let onRenameCommit: (String) -> Void
    let bypassPermissions: Bool
    let onToggleBypass: () -> Void
    let onRemove: () -> Void
    /// Why Remove Group is unavailable, or nil when it is available.
    let removeDisabledReason: String?

    @State private var isHovering = false

    private var isAgentActive: Bool {
        switch agentState {
        case .working, .stalled: true
        case .idle, .needsAttention: false
        }
    }

    private var statusLabel: AgentStatusLabel? {
        AgentStatusLabel.resolve(
            agentState: agentState,
            hasLiveSession: hasLiveSession,
            channelDown: channelDown
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if isRenaming {
                        InlineTextField(
                            initialText: name,
                            accessibilityID: "group-rename-field",
                            fontWeight: .medium,
                            onCommit: { value in
                                isRenaming = false
                                onRenameCommit(value)
                            },
                            onCancel: { isRenaming = false }
                        )
                    } else {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            // As on `WorkstreamRow`: armed only on the selected row, and
                            // simultaneous, so a first click still selects. This row is a
                            // `DisclosureGroup` label too, like the project header.
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { isRenaming = true },
                                including: isSelected ? .gesture : .none
                            )
                    }

                    if !isRenaming, memberCount > 0 {
                        SidebarCountBadge(count: memberCount)
                            .accessibilityLabel("\(memberCount) workstreams")
                    }
                }

                if let statusLabel {
                    AgentStatusMeta(
                        word: statusLabel.text,
                        color: statusLabel.color,
                        isAgentActive: isAgentActive,
                        activity: mainActivity,
                        startedAt: startedAt
                    )
                }

                if hasLiveSession, let usage = mainContextUsage {
                    ContextMeter(usage: usage, isActive: isAgentActive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 4pt, not 8, so the buttons fit without crowding the group name.
            // Below 4 the buttons' hover backgrounds touch.
            //
            // Ordered least-permanent first, farthest from the edge: this row is
            // right-anchored, so a Shortcut button that disappears when the token goes
            // would otherwise shift the buttons beside it out from under the cursor.
            HStack(spacing: 4) {
                if showShortcutButton {
                    SidebarIconButton(image: "shortcut", action: onAddFromShortcut)
                        .accessibilityLabel("New workstream from Shortcut story in \(name)")
                }
                if showGitHubButton {
                    SidebarIconButton(image: "github", action: onAddFromGitHub)
                        .accessibilityLabel("New workstream from GitHub branch in \(name)")
                }
                SidebarIconButton(icon: "plus", action: onAdd)
                    .accessibilityLabel("Add workstream to \(name)")
                    .contextMenu {
                        Button(action: onAddWithPermissions) {
                            Label("New workstream (full permissions)", systemImage: "lock.open")
                        }
                        Button(action: onAddWithoutPermissions) {
                            Label("New workstream (with prompts)", systemImage: "lock.shield")
                        }
                    }
            }
            .opacity(isHovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button { isRenaming = true } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Toggle("Full Permissions", isOn: Binding(
                get: { bypassPermissions },
                set: { _ in onToggleBypass() }
            ))
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Remove Group", systemImage: "trash")
            }
            .disabled(removeDisabledReason != nil)
            .help(removeDisabledReason ?? "")
        }
    }
}

private struct WorkstreamRow: View {
    let name: String
    var branchName: String?
    var worktreePath: String?
    let isPathValid: Bool
    /// Whether this row is the sidebar's current selection. Gates the
    /// double-click-to-rename gesture — see `body`.
    var isSelected: Bool = false
    var agentState: Workstream.AgentStateTracker.AgentRunState = .idle
    var hasLiveSession: Bool = false
    /// Whether the hook channel has stopped delivering events. App-wide rather
    /// than per-row, but it lands here because it decides what this row is
    /// entitled to claim about its agent.
    var channelDown: Bool = false
    var mainActivity: String?
    var mainContextUsage: Workstream.AgentStateTracker.ContextUsage?
    /// When this workstream's main run was first seen this launch; drives
    /// the status line's ticking elapsed time.
    var startedAt: Date?
    var githubURL: URL?
    var taskDescription: String?
    var prTitle: String?
    var prNumber: Int?
    /// The PR's decoded status, never its raw `state` string.
    ///
    /// `GitHub.PR.status` is what folds `isDraft` in, and it is the only thing
    /// that can: `state` is "OPEN" for a draft exactly as it is for a ready PR.
    /// Carrying the status rather than the string is what keeps the string from
    /// reaching the badge at all.
    var prStatus: GitHub.PR.Status?
    /// True while the row shows the inline rename field. Owned by the
    /// sidebar so the edit survives row rebuilds and stays exclusive.
    @Binding var isRenaming: Bool
    let onRemove: () -> Void
    let onPurge: () -> Void
    let onRenameCommit: (String) -> Void

    @State private var isHovering = false

    private var headline: String {
        if let prTitle {
            return prTitle
        }
        if let taskDescription {
            return taskDescription
        }
        return name
    }

    private var hasRichHeadline: Bool {
        prTitle != nil || taskDescription != nil
    }

    private var subtitle: String? {
        guard isPathValid else { return nil }
        if hasRichHeadline {
            return branchName ?? name
        }
        if let branchName, branchName != name {
            return branchName
        }
        return nil
    }

    /// The main session's context bar stays visible once usage is known so a
    /// finished turn's consumption remains readable; `ContextMeter` dims its
    /// track — and only its track — while the agent isn't actively spending
    /// context.
    private var showsMainContextMeter: Bool {
        mainContextUsage != nil && isPathValid && hasLiveSession
    }

    /// True while the agent is actively spending context this turn.
    private var isAgentActive: Bool {
        switch agentState {
        case .working, .stalled: true
        case .idle, .needsAttention: false
        }
    }

    /// Word and colour for the status meta line, or nil when dormant, which
    /// hides the line. `AgentStatusLabel` owns the mapping — including whether
    /// a hook channel that has stopped delivering overrides it.
    private var statusLabel: AgentStatusLabel? {
        AgentStatusLabel.resolve(
            agentState: agentState,
            hasLiveSession: hasLiveSession,
            channelDown: channelDown
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // No status dot here: the meta line below the name already
            // carries one, with the state word beside it. A missing worktree
            // has no such line, so it keeps a marker.
            if !isPathValid {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    // Edits the workstream label (not the PR/task headline),
                    // so it is prefilled with `name` rather than `headline`.
                    InlineTextField(
                        initialText: name,
                        accessibilityID: "workstream-rename-field",
                        onCommit: { value in
                            isRenaming = false
                            onRenameCommit(value)
                        },
                        onCancel: { isRenaming = false }
                    )
                } else {
                    Text(headline)
                        .font(.system(size: 11))
                        .strikethrough(!isPathValid)
                        .foregroundStyle(isPathValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        // Rename is armed only on the selected row, and even then
                        // recognizes simultaneously rather than exclusively. Both
                        // halves are about the *first* click: a gesture attached here
                        // swallows mouse-down inside the label's own bounds, so the
                        // enclosing List never sees it and the row will not select
                        // when clicked on its name — the one part of the row users
                        // aim at. `.none` leaves no recognizer to swallow anything,
                        // so an unselected row selects on a plain click; once it is
                        // selected there is no selection left to lose.
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded { isRenaming = true },
                            including: isSelected ? .gesture : .none
                        )
                }

                if let subtitle {
                    HStack(spacing: 3) {
                        // Colour and glyph from `GitHubPRStatusStyle`, which
                        // `PRStatusBadge` and the Info tab already share — its
                        // own words are "so the two PR badges and the Info tab
                        // cannot drift apart". Deliberately *not* its `label`:
                        // the subtitle here is a short "#123" and a word beside
                        // it would change every row's density.
                        if let prStatus {
                            Image(systemName: prStatus.symbolName)
                                .font(.system(size: 8))
                                .foregroundStyle(prStatus.color)
                        }
                        Text(subtitle)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(prStatus.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.tertiary))
                }

                if let statusLabel {
                    // Rendered only for workstreams with a live session.
                    AgentStatusMeta(
                        word: statusLabel.text,
                        color: statusLabel.color,
                        isAgentActive: isAgentActive,
                        activity: mainActivity,
                        startedAt: startedAt
                    )
                }

                if showsMainContextMeter, let usage = mainContextUsage {
                    ContextMeter(usage: usage, isActive: isAgentActive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            SidebarIconButton(icon: "xmark", action: onRemove)
                .accessibilityLabel("Remove workstream")
                .opacity(isHovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .help(taskDescription ?? "")
        .onHover { isHovering = $0 }
        .contextMenu {
            if let worktreePath {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktreePath)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    openDirectoryInTerminal(worktreePath)
                } label: {
                    Label("Open in External Terminal", systemImage: "terminal")
                }
            }
            if let githubURL {
                Button {
                    NSWorkspace.shared.open(githubURL)
                } label: {
                    Label("Open on GitHub", image: "github")
                }
            }
            if worktreePath != nil || githubURL != nil {
                Divider()
            }
            if let branchName {
                Button {
                    copyTextToPasteboard(branchName)
                } label: {
                    Label("Copy branch name", systemImage: "arrow.triangle.branch")
                }
            }
            if let worktreePath {
                Button {
                    copyTextToPasteboard(worktreePath)
                } label: {
                    Label("Copy worktree path", systemImage: "doc.on.doc")
                }
            }
            Divider()
            Button { isRenaming = true } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(action: onRemove) {
                Label("Remove", systemImage: "xmark")
            }
            Button(role: .destructive, action: onPurge) {
                Label("Purge", systemImage: "trash")
            }
        }
    }
}

private struct SidebarIconButton: View {
    /// An SF Symbol name, or an asset-catalog image name. Asset images are declared with
    /// `template-rendering-intent`, so both kinds tint from `foregroundStyle` and pick up
    /// the hover transition identically.
    private enum Source {
        case symbol(String)
        case asset(String)
    }

    private let source: Source
    let action: () -> Void

    init(icon: String, action: @escaping () -> Void) {
        source = .symbol(icon)
        self.action = action
    }

    init(image: String, action: @escaping () -> Void) {
        source = .asset(image)
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            image
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(isHovering ? Color.primary.opacity(0.1) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var image: some View {
        switch source {
        case let .symbol(name):
            Image(systemName: name)
        case let .asset(name):
            // Asset images carry their own intrinsic size, so unlike an SF Symbol they
            // need explicit resizing to match the 11pt symbol metric.
            Image(name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
        }
    }
}

private struct SidebarBottomButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct AddProjectChoiceSheet: View {
    let onCloneRepo: () -> Void
    let onNewProject: () -> Void
    let onExistingDirectory: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Project")
                .font(.headline)

            VStack(spacing: 12) {
                AddProjectChoiceRow(
                    icon: "arrow.down.circle",
                    title: "Clone from GitHub repo",
                    detail: "Clone a repository into the base directory",
                    action: onCloneRepo
                )

                AddProjectChoiceRow(
                    icon: "plus.rectangle.on.folder",
                    title: "New Project",
                    detail: "Create a new directory in the base directory",
                    isDefault: true,
                    action: onNewProject
                )

                AddProjectChoiceRow(
                    icon: "folder",
                    title: "Existing Directory",
                    detail: "Select an existing directory from disk",
                    action: onExistingDirectory
                )
            }

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct AddProjectChoiceRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    /// Applied to the Button itself rather than to this wrapper, so Return
    /// reaches it regardless of how SwiftUI treats shortcuts on custom views.
    var isDefault: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, weight: .medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(isDefault ? KeyboardShortcut.defaultAction : nil)
    }
}

private struct CloneRepoSheet: View {
    @Binding var remote: String
    @Binding var directoryName: String
    @Binding var error: String
    let isCloning: Bool
    let baseDirectory: String
    let onRemoteChanged: (String) -> Void
    let onDirectoryNameEdited: () -> Void
    let onClone: () -> Void
    let onCancel: () -> Void

    private enum Field: Hashable {
        case remote
        case directoryName
    }

    @FocusState private var focusedField: Field?

    private var canClone: Bool {
        !remote.trimmingCharacters(in: .whitespaces).isEmpty
            && !directoryName.trimmingCharacters(in: .whitespaces).isEmpty
            && !isCloning
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Clone from GitHub repo")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Base directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(baseDirectory.abbreviatedPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("(change in Settings)")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Repository URL or owner/repo", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .remote)
                    .disabled(isCloning)
                    .onChange(of: remote) { _, value in onRemoteChanged(value) }
                    .onSubmit {
                        if canClone {
                            onClone()
                        }
                    }

                TextField("Folder name", text: $directoryName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .directoryName)
                    .disabled(isCloning)
                    .onChange(of: directoryName) { _, _ in
                        // Only a change the user typed themselves stops the
                        // field tracking the URL.
                        if focusedField == .directoryName {
                            onDirectoryNameEdited()
                        }
                    }
                    .onSubmit {
                        if canClone {
                            onClone()
                        }
                    }

                Text("Cloned as a .bare repository with the default branch checked out beside it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }

            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isCloning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cloning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Clone", action: onClone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focusedField = .remote }
    }
}

private struct NewWorkstreamSheet: View {
    @Binding var name: String
    @Binding var error: String
    let projectName: String
    let placeholder: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Text("New Workstream")
                .font(.headline)

            Divider()
                .opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                Text("Project")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Workstream name")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(Text("Leave blank for a random name. This becomes the branch and worktree name."))
                        .accessibilityLabel(Text("More info"))
                }
                TextField("", text: $name, prompt: Text(placeholder).font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary))
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { onAdd() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }
}

private struct ShortcutStorySheet: View {
    @Binding var storyInput: String
    @Binding var error: String
    /// Whether the failure is one Settings can fix (a missing or rejected token).
    let showsSettingsLink: Bool
    let isFetching: Bool
    let projectName: String
    let onCreate: () -> Void
    let onOpenSettings: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                Image("shortcut")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text("New Workstream from Shortcut")
                    .font(.headline)
            }

            Divider()
                .opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                Text("Project")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Story")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(Text("The branch and worktree are named using the Branch Name Pattern in Settings."))
                        .accessibilityLabel(Text("More info"))
                }
                // The `sc-` sits outside the field, so the field is plainly asking for an
                // id and nothing else.
                HStack(spacing: 2) {
                    Text(verbatim: "sc-")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("", text: $storyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                        .focused($isFocused)
                        .disabled(isFetching)
                        .onSubmit { onCreate() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !error.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    // Driven by the error case, never by the message text: the message is
                    // localized, so matching on its wording would break on translation.
                    if showsSettingsLink {
                        Button("Open Settings", action: onOpenSettings)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isFetching {
                    ProgressView().controlSize(.small)
                }
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isFetching || storyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    @Binding var error: String
    let baseDirectory: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Project")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Base directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(baseDirectory.abbreviatedPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("(change in Settings)")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Project Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        onAdd()
                    }
                }

            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
