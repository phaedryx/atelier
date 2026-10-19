// ABOUTME: Data models for projects and workstreams.
// ABOUTME: Each project has a directory and multiple workstreams, each with its own terminal.

import Foundation

struct Workstream: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var displayName: String?
    var worktreePath: String?
    var bypassPermissions: Bool
    var lastAccessedAt: Date
    /// The Shortcut story this workstream was created from, when it came from one.
    ///
    /// Must stay Optional. The synthesized `init(from:)` calls `decode` — not
    /// `decodeIfPresent` — for a non-Optional property and throws when the key is
    /// absent, so a blob written before this key existed would fail to decode.
    /// That now costs one workstream rather than every project the user has (see
    /// `Project.init(from:)` and `LossyStore`), but a workstream silently
    /// vanishing on upgrade is still not an acceptable price for a stored field.
    var shortcutStoryID: Int?
    /// The group this workstream belongs to. Optional for the same reason as
    /// `shortcutStoryID`; `Project.housingWorkstreams()` fills it on decode, so a
    /// loaded workstream always has one when its project has any.
    var groupID: UUID?

    init(name: String, displayName: String? = nil, worktreePath: String? = nil, bypassPermissions: Bool = false, id: UUID = UUID(), lastAccessedAt: Date = Date(), shortcutStoryID: Int? = nil, groupID: UUID? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.worktreePath = worktreePath
        self.bypassPermissions = bypassPermissions
        self.lastAccessedAt = lastAccessedAt
        self.shortcutStoryID = shortcutStoryID
        self.groupID = groupID
    }

    /// The user-facing label. Falls back to the branch-tracked `name` when no override is set.
    var label: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return name
    }

    /// Commit a rename from the user. An empty input or one matching the
    /// branch-tracked `name` clears the override so the label follows the
    /// branch again; anything else becomes the `displayName` override.
    mutating func applyRename(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (trimmed.isEmpty || trimmed == name) ? nil : trimmed
    }

    /// The working directory for this workstream's terminals.
    ///
    /// Uses the worktree path if available, otherwise falls back to the
    /// project's checkout — `Project.checkout`, never `Project.directory`. In
    /// the `.bare` container layout the latter has no work tree, so a shell
    /// opened there sees `.bare`, the peer worktrees and nothing to build.
    func workingDirectory(checkout: String) -> String {
        worktreePath ?? checkout
    }

    static func == (lhs: Workstream, rhs: Workstream) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    /// The repository's home: the `.bare` container in that layout, and the
    /// checkout itself for an ordinary clone. **Not** a work tree in the
    /// container layout — read `checkout` for that.
    ///
    /// This is the directory an `execution.process-compose.yaml`, a
    /// `verification.yaml` and a `ports.yml` sit beside `.bare` and the worktrees
    /// in — outside every work tree, which is what lets Atelier run those commands
    /// without asking.
    var directory: String
    /// The checkout that stands in for `directory` wherever a work tree is
    /// required. Nil when `directory` is itself one.
    ///
    /// Optional, and it has to stay that way: `init(from:)` below decodes with
    /// `decode` rather than `decodeIfPresent` for every non-Optional stored
    /// property, so adding one would fail the whole project on any blob written
    /// before it existed — and `LossyStore` only saves a project from a broken
    /// *workstream*, not from a broken project.
    var checkoutDirectory: String?
    var workstreams: [Workstream]
    var lastAccessedAt: Date
    /// The project's workstream groups. Optional for the same reason as
    /// `checkoutDirectory`; nil means the project has never had a workstream.
    var groups: [Workstream.Group]?

    init(
        name: String,
        directory: String,
        checkoutDirectory: String? = nil,
        id: UUID = UUID(),
        workstreams: [Workstream] = [],
        lastAccessedAt: Date = Date(),
        groups: [Workstream.Group]? = nil
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.checkoutDirectory = checkoutDirectory
        self.workstreams = workstreams
        self.lastAccessedAt = lastAccessedAt
        self.groups = groups
    }

    /// The directory to run work-tree operations in: `git status`, the branch
    /// display, the changed-file list, `git pull`, the docs scan, and the
    /// fallback working directory for a workstream that has no worktree yet.
    ///
    /// Falls back to `directory`, which is the right answer for an ordinary
    /// clone and the only one available for a container whose checkout is gone.
    var checkout: String {
        checkoutDirectory ?? directory
    }

    /// Hand-written for two reasons.
    ///
    /// The first: `workstreams` decodes element by element. A workstream the
    /// current shape cannot read used to fail the whole project, and
    /// `ProjectStore` then failed the whole list — so one stale record cost the
    /// user every project they had. `encode(to:)` is still synthesized, which is
    /// what keeps `CodingKeys` in step with the properties above.
    ///
    /// The second: `directory` changed meaning, and a blob written under the old
    /// meaning decodes *successfully* while pointing at the wrong thing — a
    /// checkout where the container belongs. That is worse than a decode
    /// failure, which at least surfaces, so it is repaired here. See
    /// `Project.hoistedLocation`.
    ///
    /// The third: a blob written before workstream groups carries neither
    /// `groups` nor any `groupID`. Both decode with `decodeIfPresent`, and
    /// `housingWorkstreams()` then runs on locals, since `self` is not usable
    /// until every stored property is set.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let storedDirectory = try container.decode(String.self, forKey: .directory)
        let storedCheckout = try container.decodeIfPresent(String.self, forKey: .checkoutDirectory)
        if let storedCheckout {
            directory = storedDirectory
            checkoutDirectory = storedCheckout
        } else {
            // Only when the key is absent. A blob that already carries the field
            // was written under the current meaning and needs no repair.
            let hoisted = Project.hoistedLocation(directory: storedDirectory)
            directory = hoisted.directory
            checkoutDirectory = hoisted.checkoutDirectory
        }
        lastAccessedAt = try container.decode(Date.self, forKey: .lastAccessedAt)
        let decodedWorkstreams = try container.decodeLossyArray(Workstream.self, forKey: .workstreams)
        let decodedGroups = try container.decodeIfPresent([Workstream.Group].self, forKey: .groups)

        var housing = Project(
            name: name,
            directory: directory,
            checkoutDirectory: checkoutDirectory,
            id: id,
            workstreams: decodedWorkstreams,
            lastAccessedAt: lastAccessedAt,
            groups: decodedGroups
        )
        housing = housing.housingWorkstreams()
        workstreams = housing.workstreams
        groups = housing.groups
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Project {
    /// Returns the project with every workstream housed in a group.
    ///
    /// A project with no workstreams is returned unchanged. Otherwise, when it
    /// has no groups, one is created named after the project; then any workstream
    /// whose `groupID` is nil or names no group lands in the first group.
    ///
    /// The backfilled group is deterministic: its id derives from the project's
    /// id and its dates are the project's `lastAccessedAt`, so two decodes of the
    /// same blob agree. A random id would differ on every launch until the first
    /// save, and anything keyed by it (a coordinator's tab, say) would be orphaned.
    func housingWorkstreams() -> Project {
        guard !workstreams.isEmpty else { return self }
        var housed = self
        let known: [Workstream.Group] = if let groups, !groups.isEmpty {
            groups
        } else {
            [Workstream.Group(
                name: name,
                id: derivedUUID(from: id, salt: "default-group"),
                createdAt: lastAccessedAt,
                lastAccessedAt: lastAccessedAt
            )]
        }
        housed.groups = known
        let ids = Set(known.map(\.id))
        for index in housed.workstreams.indices {
            if let current = housed.workstreams[index].groupID, ids.contains(current) {
                continue
            }
            housed.workstreams[index].groupID = known[0].id
        }
        return housed
    }

    func workstreams(in groupID: UUID) -> [Workstream] {
        workstreams.filter { $0.groupID == groupID }
    }

    /// Matches the trimmed name exactly, the same rule `Workstream.Group.validateName` enforces.
    func group(named name: String) -> Workstream.Group? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups?.first { $0.name == trimmed }
    }

    func group(with id: UUID) -> Workstream.Group? {
        groups?.first { $0.id == id }
    }

    /// Model order; the sidebar sorts separately.
    var sortedGroups: [Workstream.Group] {
        groups ?? []
    }
}

extension Project {
    /// The already-registered project a newly resolved location names, and the
    /// repair it needs — or nil when nothing is registered for it yet.
    ///
    /// Matching on the checkout as well as the directory is what stops a second
    /// row being added for a repository saved while `projectLocation` resolved a
    /// container forward. Two rows for one repo would collide in
    /// `~/.atelier/worktrees`, since worktree paths are built from the project
    /// name.
    ///
    /// `repaired` is non-nil for the stored shapes `Project.hoistedLocation`
    /// cannot settle on the launch path, because settling them needs git:
    ///
    /// - registered before 0.2.0, so `directory` is already the container and no
    ///   checkout was ever recorded — every work-tree read then runs against a
    ///   directory that has no work tree
    /// - registered while the resolution ran forward, so `directory` is the
    ///   checkout, and the hoist had no `.bare` beside it to prove the layout
    ///
    /// Both are answered by writing the pair `location` already carries. This is
    /// the one path where that is free: the user just pointed at the repository,
    /// so it has been resolved once already, with no git subprocess and nothing
    /// on the launch path. Without it the only recovery is Remove and re-add.
    ///
    /// Compared against what was already resolved rather than by re-resolving
    /// every registered project, which would fan out to git subprocesses on the
    /// main thread for each one.
    static func existingRegistration(
        for location: Location,
        in projects: [Project]
    ) -> (index: Int, repaired: Project?)? {
        guard let index = projects.firstIndex(where: {
            $0.directory == location.directory || $0.directory == location.checkoutDirectory
        }) else { return nil }

        // Nothing to write when the location has no checkout to offer: a plain
        // clone, or a container whose checkout is gone. Overwriting a recorded
        // checkout with nil would be a downgrade, not a repair.
        guard let checkout = location.checkoutDirectory else { return (index, nil) }
        let stored = projects[index]
        guard stored.directory != location.directory || stored.checkoutDirectory != checkout else {
            return (index, nil)
        }

        var repaired = stored
        repaired.directory = location.directory
        repaired.checkoutDirectory = checkout
        return (index, repaired)
    }
}

extension Project {
    /// Repairs a `directory` saved under the older meaning, where a `.bare`
    /// container was registered as its default checkout.
    ///
    /// Returns the container as the directory and the stored path as the checkout,
    /// or the input unchanged when it is not that shape.
    ///
    /// **Filesystem only, never git.** This runs inside `Project.init(from:)`, and a
    /// decoder that spawns subprocesses would fan out one `git` per stored project
    /// on the launch path — before there is a window to show for it.
    ///
    /// The evidence required is the same as `Git.Operations.worktreeDestination`
    /// demands, minus its git probe, plus one thing that probe covered for free:
    ///
    /// - `<directory>/.git` is a **file**, so `directory` is a linked worktree
    /// - `<parent>/.bare` is a **directory** and `<parent>/.git` is a **file** —
    ///   the `gitdir: ./.bare` pointer the README's recipe writes. An ordinary
    ///   parent repository has `.git` as a directory and is excluded by this alone.
    /// - the worktree's own `gitdir:` line resolves inside `<parent>/.bare`, so this
    ///   worktree really belongs to *that* container rather than merely sitting next
    ///   to one. Without it the three checks above establish "this looks like the
    ///   layout" and not "these two files are related".
    ///
    /// A project saved before the resolution existed at all stores the container
    /// already, has no `.git` file of the required kind, and is left alone — its
    /// `checkout` falls back to the container, exactly as it does today. Filling
    /// it in from here would need git and a writable project list on the launch
    /// path, which is what this must not do. `ProjectSidebar.addProject` repairs
    /// that cohort instead, and the one this cannot prove, the next time the user
    /// points at the repository: both halves are already resolved there.
    static func hoistedLocation(
        directory: String,
        fileManager: FileManager = .default
    ) -> (directory: String, checkoutDirectory: String?) {
        let unchanged = (directory: directory, checkoutDirectory: String?.none)

        func isFile(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }

        func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        let checkoutURL = URL(fileURLWithPath: directory).standardizedFileURL
        let gitFile = checkoutURL.appendingPathComponent(".git")
        guard isFile(gitFile) else { return unchanged }

        let containerURL = checkoutURL.deletingLastPathComponent()
        let bareURL = containerURL.appendingPathComponent(".bare")
        guard isDirectory(bareURL), isFile(containerURL.appendingPathComponent(".git")) else {
            return unchanged
        }

        guard let pointer = try? String(contentsOf: gitFile, encoding: .utf8) else { return unchanged }
        let gitDir = pointer
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("gitdir:") else { return nil }
                return line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            }
            .first
        guard let gitDir else { return unchanged }

        // Relative for a hand-written pointer; absolute for anything `git worktree
        // add` wrote. Both have to land inside this container's `.bare`.
        let resolvedGitDir = gitDir.hasPrefix("/")
            ? URL(fileURLWithPath: gitDir)
            : checkoutURL.appendingPathComponent(gitDir)
        // Compared canonically, the same way
        // `Workstream.Archiver.destroyableWorktreePath` compares paths. `git
        // worktree add` records the pointer through whatever spelling it was
        // given, so a container reached through a symlinked parent — `/tmp` for
        // `/private/tmp`, a home directory linked in from elsewhere — writes an
        // absolute gitdir that shares no textual prefix with `bareURL`.
        //
        // `String.canonicalPath` and not `resolvingSymlinksInPath()`, which is a
        // no-op on a path that is not on disk: `git worktree prune` leaves a
        // checkout's pointer aimed at a `worktrees/<name>` that is gone, and
        // that spelling still names this container. The gitdir is the *inside*
        // of the pair, so this asks containment rather than a prefix, which is
        // also what keeps a sibling `.bare-backup` out.
        //
        // The paths returned below are the unresolved ones, because those are
        // what the user registered and how every other stored path is spelled.
        guard resolvedGitDir.path.isCanonicallyInside(bareURL.path) else {
            return unchanged
        }

        return (directory: containerURL.path, checkoutDirectory: checkoutURL.path)
    }
}

extension Project {
    /// How a project's workstreams are ordered, wherever they are listed.
    ///
    /// Four surfaces order the same list — the sidebar's rows, the sidebar's
    /// re-sort when a terminal produces output, the project overview's list, and
    /// the workstream the ⌘[ / ⌘] cycle lands on. They all read this one setting
    /// and go through `sorted(_:)`, because a keyboard walk that visits rows in a
    /// different order than the sidebar draws them is indistinguishable from a bug.
    /// If you add a fifth, route it here rather than inlining a fourth comparison.
    enum SortOrder: String, CaseIterable {
        case recent = "Recent"
        case alphabetical = "A-Z"

        static let storageKey = "atelier.workstreamSortOrder"

        /// Sorts by `label`, not `name`, so a renamed workstream sits where the
        /// sidebar says it does rather than under the branch name behind it.
        func sorted(_ workstreams: [Workstream]) -> [Workstream] {
            switch self {
            case .recent:
                workstreams.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
            case .alphabetical:
                workstreams.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            }
        }

        /// Orders a project's groups the way the sidebar draws them.
        ///
        /// `.recent` ranks a group by the newest of its own `lastAccessedAt` and
        /// its members', so a group whose workstream was just used rises with it
        /// even though nobody selected the group row itself. `.alphabetical` is
        /// case-insensitive on the name, matching the workstream rule.
        func sorted(_ groups: [Workstream.Group], in project: Project) -> [Workstream.Group] {
            switch self {
            case .recent:
                let newest = Dictionary(
                    project.workstreams.compactMap { ws in ws.groupID.map { ($0, ws.lastAccessedAt) } },
                    uniquingKeysWith: max
                )
                func recency(_ group: Workstream.Group) -> Date {
                    max(group.lastAccessedAt, newest[group.id] ?? .distantPast)
                }
                return groups.sorted { recency($0) > recency($1) }
            case .alphabetical:
                return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
    }
}
