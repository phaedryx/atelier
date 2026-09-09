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

    init(name: String, displayName: String? = nil, worktreePath: String? = nil, bypassPermissions: Bool = false, id: UUID = UUID(), lastAccessedAt: Date = Date(), shortcutStoryID: Int? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.worktreePath = worktreePath
        self.bypassPermissions = bypassPermissions
        self.lastAccessedAt = lastAccessedAt
        self.shortcutStoryID = shortcutStoryID
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
    /// This is the directory a `process-compose.yaml` and a `ports.yml` sit
    /// beside `.bare` and the worktrees in, and the key `ScriptTrust` records
    /// config approvals under.
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

    init(
        name: String,
        directory: String,
        checkoutDirectory: String? = nil,
        id: UUID = UUID(),
        workstreams: [Workstream] = [],
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.checkoutDirectory = checkoutDirectory
        self.workstreams = workstreams
        self.lastAccessedAt = lastAccessedAt
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
        workstreams = try container.decodeLossyArray(Workstream.self, forKey: .workstreams)
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
        // Symlinks resolved on both sides before comparing, the same way
        // `Workstream.Archiver.destroyableWorktreePath` compares paths. `git
        // worktree add` records the pointer through whatever spelling it was
        // given, so a container reached through a symlinked parent — `/tmp` for
        // `/private/tmp`, a home directory linked in from elsewhere — writes an
        // absolute gitdir that shares no textual prefix with `bareURL`.
        //
        // `resolvingSymlinksInPath()` is a no-op on a path that does not exist,
        // so this resolves only for a gitdir git actually created — which is the
        // only kind worth hoisting. Anything else is compared by its literal
        // spelling and, at worst, declines to hoist.
        //
        // The paths returned below are the unresolved ones, because those are
        // what the user registered and how every other stored path is spelled.
        let bare = bareURL.resolvingSymlinksInPath().path
        guard resolvedGitDir.resolvingSymlinksInPath().path.hasPrefix(bare + "/") else {
            return unchanged
        }

        return (directory: containerURL.path, checkoutDirectory: checkoutURL.path)
    }
}

extension Project {
    enum SortOrder: String, CaseIterable {
        case recent = "Recent"
        case alphabetical = "A-Z"
    }
}
