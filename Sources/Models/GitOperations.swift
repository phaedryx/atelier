// ABOUTME: Git operations for project and workstream management.
// ABOUTME: Handles repo detection, init, worktree create/remove, and repo info.

import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "git")

/// Git plumbing: running git, and the shapes it returns.
enum Git {}

/// A git worktree as this app models it: what it is, what changed in it,
/// and how its HEAD is watched.
///
/// Top-level rather than nested in `Git`: `Git.Worktree.Info` is three
/// levels at the call site, which costs more than the prefix it removes.
enum Worktree {}

extension Git {
    struct RepoInfo {
        let isRepo: Bool
        let branch: String?
        let remoteURL: String?
        let commitCount: Int?
        let isDirty: Bool

        /// `isDirty` is `false` because `git status` did not run, not because the
        /// tree is clean. Whatever renders a green "Clean" has to check this first.
        ///
        /// No default value on purpose, matching `Worktree.Info.cleanlinessUnknown`:
        /// a construction site must say whether it actually looked.
        let isDirtyUnknown: Bool
    }
}

extension Worktree {
    /// One row of `git worktree list --porcelain`: where it is, and the branch it
    /// holds. Deliberately **not** `Worktree.Info` — that carries cleanliness and
    /// ahead-of-base, which cost three git probes per row, and a caller that only
    /// needs to know what exists should not pay a fan-out for it.
    struct Registration: Equatable {
        let path: String
        /// Nil for a detached HEAD. The bare entry is never surfaced at all.
        let branch: String?
    }

    struct Info: Identifiable {
        let path: String
        let branch: String?
        let isDirty: Bool
        let isMain: Bool
        let hasUnpushedCommits: Bool
        let hasBranchCommits: Bool

        /// This worktree holds the repository's trunk — the checkout at the project
        /// directory, or the checkout of the default branch (`origin/HEAD`, `main`,
        /// `master`) whatever it is called here. Purge and Prune must skip it.
        ///
        /// `isMain` alone was the guard and it is only a path comparison, so it
        /// silently fails open: a project registered as its `.bare` *container*
        /// rather than as a checkout matches no worktree path at all, and then
        /// every row — the trunk included — reads as an ordinary purgeable
        /// worktree. Naming the branch as well means the guard does not depend on
        /// which path the project happens to be registered under.
        ///
        /// No default value on purpose, matching `cleanlinessUnknown` below: a
        /// `= false` here would let a future construction site declare a worktree
        /// unprotected without having asked the question.
        let isProtected: Bool

        /// `isDirty`, `hasUnpushedCommits` and/or `hasBranchCommits` are `false`
        /// because a probe did not run, not because the answer is no. Anything
        /// that acts on "this worktree is clean" — Prune, above all — has to
        /// treat it as not-clean.
        ///
        /// No default value on purpose: a `= false` here would let a future
        /// construction site claim both checks ran when it never asked.
        let cleanlinessUnknown: Bool

        var id: String {
            path
        }

        var standardizedPath: String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }
}

/// Where a project should be registered, what to call it, and which checkout
/// represents it.
///
/// All three differ in the `.bare` container layout. `directory` is the
/// repository's home — the container, which holds `.bare`, the default checkout
/// and every workstream worktree as peers — and `checkoutDirectory` is the
/// checkout that stands in for it wherever a work tree is required, because the
/// container has none of its own.
extension Project {
    struct Location: Equatable {
        let directory: String
        let name: String
        /// The checkout that represents this repository, when `directory` is a
        /// `.bare` container with no work tree of its own. Nil when `directory`
        /// *is* a work tree, and nil for a container whose checkout is gone —
        /// there is nothing better to offer than the container itself.
        ///
        /// Also what recognises a project saved under the *older* resolution,
        /// which stored this checkout as the project's `directory`. See
        /// `ProjectSidebar.addProject`.
        let checkoutDirectory: String?

        init(directory: String, name: String, checkoutDirectory: String? = nil) {
            self.directory = directory
            self.name = name
            self.checkoutDirectory = checkoutDirectory
        }
    }
}

extension Worktree {
    struct Detail {
        struct FileChange: Identifiable {
            enum Status: String {
                case modified = "M"
                case added = "A"
                case deleted = "D"
                case renamed = "R"
                case untracked = "??"

                var icon: String {
                    switch self {
                    case .modified: "pencil"
                    case .added: "plus"
                    case .deleted: "minus"
                    case .renamed: "arrow.right"
                    case .untracked: "questionmark"
                    }
                }
            }

            let status: Status
            let path: String
            let isStaged: Bool

            var id: String {
                "\(isStaged ? "S" : "U")\(path)"
            }
        }

        let changes: [FileChange]

        /// `git status` did not run — git is missing, timed out, or exited non-zero.
        /// `changes` is then empty for want of an answer, not because the tree is
        /// clean, and callers must not present it as the latter. `RepoChangesPopover`
        /// is the one that reads this; the flag was added for the worktree detail
        /// sheet (deleted in 2e6f2f8), which said "nothing to lose" directly above a
        /// Force Remove button.
        let changesUnavailable: Bool
    }
}

extension Git {
    /// A single file that differs in a diff listing for the Changes tab.
    ///
    /// Consumed by Phase 2's payload builder, which uses `isBinary` to emit a
    /// "binary file" placeholder and `changedLines`/`sizeHint` to apply the
    /// per-file large-file guard (defer rendering files over a threshold) before
    /// reading any content.
    struct DiffFile: Equatable {
        enum Status: String {
            case added = "A"
            case modified = "M"
            case deleted = "D"
            case renamed = "R"
        }

        /// Path relative to the worktree root. For renames, the new path.
        let relativePath: String
        let status: Status

        /// True when git reports the file as binary (numstat "-"/"-") or, for
        /// untracked files, when a NUL byte is found in the first chunk on disk.
        /// Binary files get a placeholder instead of a UTF-8 diff body (Hardening 2).
        var isBinary: Bool = false

        /// added + deleted line counts from `git diff --numstat`. For untracked
        /// files (absent from numstat) this is the file's own line count. Used by
        /// the large-file guard (Hardening 3).
        var changedLines: Int = 0

        /// Added lines from `git diff --numstat` (first column). For untracked
        /// files this is the file's own line count. 0 for binary files. Surfaced
        /// to the Changes sidebar as the GitHub-style `+a` count.
        var added: Int = 0

        /// Deleted lines from `git diff --numstat` (second column). For untracked
        /// files this is 0. 0 for binary files. Surfaced to the Changes sidebar as
        /// the GitHub-style `−d` count.
        var deleted: Int = 0

        /// Byte size of the modified-side file on disk (0 for deleted/missing).
        /// A second input to the large-file guard (Hardening 3).
        var sizeHint: Int = 0
    }
}

extension Git {
    /// Why an operation that changes something did not.
    ///
    /// The five mutators that used to return `Void` — `removeWorktree`,
    /// `deleteLocalBranch`, `discardAllChanges`, `addExcludeEntry`,
    /// `fetchDefaultBranch` — discarded git's exit status and its stderr at the
    /// spawn site, so a caller learned nothing and the log line was the only
    /// record. `Workstream.Archiver.purge` in particular found out that a
    /// `removeWorktree` had failed from a *later* `worktree list`, which reports
    /// that the worktree is still registered and not one word about why.
    ///
    /// `Result<Void, Failure>` rather than `throws`, because this file has no
    /// `throws` anywhere and already models every other failure as a value —
    /// `PullResult`, `Bool?`, `RepoInfo.isDirtyUnknown`. `try?` would also erase
    /// the error at the call site, which is exactly the silent discard being
    /// removed here; ignoring a `Result` at least costs a compiler warning.
    struct Failure: Error, Equatable {
        /// The command that failed, as it would be typed. For a refusal decided
        /// before anything was spawned, the command that was *not* run.
        let command: String

        /// git's exit status, or nil when no process ran: a refusal, a missing
        /// git binary, a deadline, or a step that is not a git spawn at all.
        let exitCode: Int32?

        /// The tail of stderr, bounded by `stderrTail`. Empty when there was none.
        let stderr: String

        /// One line fit to log or show. Never empty — a `Failure` whose only
        /// content was an exit code is the thing this type exists to replace.
        let reason: String

        /// stderr's last few lines, bounded.
        ///
        /// Whole stderr is unbounded and caller-controlled — a `git clean -fd`
        /// over a large tree, a hook printing a wall of text — and every consumer
        /// here is a log line or an alert. The tail rather than the head because
        /// git's own diagnosis is the last thing it says.
        static func stderrTail(_ text: String, lines maxLines: Int = 5, characters maxCharacters: Int = 500) -> String {
            let kept = text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(maxLines)
                .joined(separator: "; ")
            return kept.count > maxCharacters ? String(kept.suffix(maxCharacters)) : kept
        }

        /// Atelier declined before running anything — the path is the project
        /// directory, the trunk's checkout, the bare repository.
        static func refusing(_ command: String, _ reason: String) -> Failure {
            Failure(command: command, exitCode: nil, stderr: "", reason: reason)
        }

        /// A step that is not a git spawn: writing `info/exclude`, removing a
        /// directory git has already forgotten.
        static func system(_ command: String, _ reason: String) -> Failure {
            Failure(command: command, exitCode: nil, stderr: "", reason: reason)
        }

        /// What a log line or an alert shows: the reason, and the command that
        /// produced it so a user can run it themselves.
        var description: String {
            "\(reason) (\(command))"
        }
    }
}

extension Git {
    /// One parse of `git worktree list --porcelain`, and the only one.
    ///
    /// There were three — `worktreePath(forBranch:)`, `listWorktreesWithInfo` and
    /// `registeredWorktrees` — each walking the same lines with its own state
    /// machine, two of them defining their own `flush()`. They agreed on the two
    /// prefixes they happened to need and on nothing else: none of them noticed
    /// `detached` or `locked`, and the bare entry was skipped by two of the three
    /// with the third relying on a bare repository having no `branch` line.
    ///
    /// The three public functions are now filters over `worktreeList(at:)`, so a
    /// porcelain field learned here is learned by all of them at once.
    enum WorktreeListing {
        /// One `worktree` block of the porcelain listing.
        struct Entry: Equatable {
            /// The work tree's path, taken as the whole remainder of the line.
            ///
            /// **Never tokenized on whitespace**: `git worktree add "/tmp/my repo"`
            /// is legal and porcelain does not quote or escape it, so a
            /// `split(separator: " ")` truncates that path to `/tmp/my`.
            let path: String

            /// The full ref this worktree holds, e.g. `refs/heads/feat/thing`.
            /// Nil for a detached HEAD and for the bare entry, neither of which
            /// emits a `branch` line.
            ///
            /// The **full** ref, because `worktreePath(forBranch:)` matches on
            /// `refs/heads/<branch>` and only `branch` below wants it shortened.
            let ref: String?

            /// The commit the worktree is at, from the `HEAD` line. Absent on the
            /// bare entry.
            let head: String?

            /// The bare repository's own row. In the `.bare` container layout it is
            /// an entry in `worktree list` like any other, and it has no work tree,
            /// so nothing that surfaces worktrees to a user may include it.
            let isBare: Bool

            /// `detached` was reported: this worktree is on no branch.
            let isDetached: Bool

            /// `locked` was reported, with or without a reason. Nothing reads it
            /// yet; it is parsed because dropping a field the porcelain emits is
            /// how the three hand-rolled walkers ended up disagreeing.
            let isLocked: Bool

            /// The branch name without its `refs/heads/` prefix — what the sidebar
            /// and every stored record spell.
            ///
            /// Nil for anything that is not a local branch, which is what the
            /// walkers this replaced did by only ever matching the literal
            /// `branch refs/heads/` prefix. Strips exactly that prefix and nothing
            /// else: a branch legitimately named `feat/thing` must come back whole,
            /// so no path-component or last-separator trick may stand here.
            var branch: String? {
                guard let ref, ref.hasPrefix("refs/heads/") else { return nil }
                return String(ref.dropFirst("refs/heads/".count))
            }
        }

        /// Parse porcelain output. Pure — no git, no filesystem — so the fixture
        /// cases live in `Tests/GitWorktreeListingTests.swift` and cost nothing.
        ///
        /// A `worktree ` line opens a block and everything up to the next one
        /// belongs to it; the blank line between blocks is not relied on, because
        /// the last block does not always have one after it.
        static func parse(porcelain: String) -> [Entry] {
            var entries: [Entry] = []

            var path: String?
            var ref: String?
            var head: String?
            var isBare = false
            var isDetached = false
            var isLocked = false

            func flush() {
                guard let path else { return }
                entries.append(Entry(
                    path: path,
                    ref: ref,
                    head: head,
                    isBare: isBare,
                    isDetached: isDetached,
                    isLocked: isLocked
                ))
            }

            func value(_ line: String, after key: String) -> String? {
                guard line.hasPrefix(key + " ") else { return nil }
                return String(line.dropFirst(key.count + 1))
            }

            for rawLine in porcelain.components(separatedBy: "\n") {
                // Porcelain is newline-terminated; a \r would end up inside a path
                // or a ref if the output ever arrived with CRLF endings.
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

                if let next = value(line, after: "worktree") {
                    flush()
                    path = next
                    ref = nil
                    head = nil
                    isBare = false
                    isDetached = false
                    isLocked = false
                } else if let next = value(line, after: "branch") {
                    ref = next
                } else if let next = value(line, after: "HEAD") {
                    head = next
                } else if line == "bare" {
                    isBare = true
                } else if line == "detached" {
                    isDetached = true
                } else if line == "locked" || line.hasPrefix("locked ") {
                    // `locked` stands alone when no reason was given and carries the
                    // reason otherwise, so neither form may be the only one matched.
                    isLocked = true
                }
            }
            flush()

            return entries
        }
    }
}

extension Git {
    enum Operations {
        /// Resolved once per process. `CommandLineTools.path(for:)` stats each PATH
        /// entry until it hits, and `listWorktreesWithInfo` spawns three git
        /// processes per worktree — a 12-worktree project paid that lookup ~37
        /// times per render. A `static let` is lazy and thread-safe, and matches
        /// `CommandLineTools`' own once-per-process shell PATH cache: git moving
        /// mid-session is not a case either of them tries to follow — nor is git
        /// appearing after a launch that could not find it, which is the direction
        /// this actually changes: the computed property re-checked every call, so a
        /// nil could recover. Installing git while the app runs is the only way to
        /// reach that, and a stale answer either way is worth the ~37 lookups a
        /// render this removes.
        ///
        /// Not private, because `GitHub.Operations` ran git too and carried a verbatim
        /// copy of this — its own `static let`, its own cache, and this comment with it,
        /// citing a `listWorktreesWithInfo` that lives here and not there. One lookup,
        /// one answer.
        static let gitPath: String? = CommandLineTools.path(for: "git")

        /// Check if a directory is a git repository.
        static func isGitRepo(at path: String) -> Bool {
            let gitDir = URL(fileURLWithPath: path).appendingPathComponent(".git")
            return FileManager.default.fileExists(atPath: gitDir.path)
        }

        /// Initialize a git repo at the given path with an empty initial commit.
        static func initRepo(at path: String) -> Bool {
            guard run(args: ["init"], in: path) != nil else { return false }
            // Create an empty commit so the repo has a HEAD ref, which is
            // required for worktree creation.
            return run(args: ["commit", "--allow-empty", "-m", "Initial commit"], in: path) != nil
        }

        /// Get repo information for display.
        static func repoInfo(at path: String) -> Git.RepoInfo {
            guard isGitRepo(at: path) else {
                // Not a repository at all: there is no tree whose cleanliness could
                // be in question, so this is an answer rather than a failure to look.
                return Git.RepoInfo(isRepo: false, branch: nil, remoteURL: nil, commitCount: nil, isDirty: false, isDirtyUnknown: false)
            }

            let rawBranch = run(args: ["rev-parse", "--abbrev-ref", "HEAD"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // rev-parse returns literal "HEAD" when in detached state
            let branch = (rawBranch == "HEAD") ? nil : rawBranch

            let remote = run(args: ["remote", "get-url", "origin"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let countStr = run(args: ["rev-list", "--count", "HEAD"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let commitCount = countStr.flatMap(Int.init)

            let status = run(args: ["status", "--porcelain", "--ignore-submodules=dirty"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `?? false` alone reported a failed probe as a clean tree, and the
            // surfaces above render that as a green "Clean".
            let isDirty = status.map { !$0.isEmpty } ?? false
            let isDirtyUnknown = status == nil

            return Git.RepoInfo(
                isRepo: true,
                branch: branch,
                remoteURL: remote,
                commitCount: commitCount,
                isDirty: isDirty,
                isDirtyUnknown: isDirtyUnknown
            )
        }

        /// This repository's default branch, resolved once per directory.
        ///
        /// What git reports as `origin/HEAD`, falling back to a `development` branch
        /// and then to the usual names — see `resolveDefaultBranch`, which is where
        /// that order lives and why it is in that order.
        ///
        /// **Cached, because the cost is a fan-out and the answer is a property of
        /// the repository.** Resolving costs up to six sequential git probes, and
        /// the two comparison sites — `mergeBase` and `hasBranchCommits` — are each
        /// called *per worktree*: `refreshPathValidity` runs `hasBranchCommits` for
        /// every worktree on a 15-second timer, and `listWorktreesWithInfo` does the
        /// same on every project-overview refresh. Twelve workstreams in two projects
        /// meant ~72 subprocesses every tick resolving two strings. (There was a
        /// third, `worktreeDetail`'s unmerged-commit log, until that dead field was
        /// deleted; it no longer resolves a base branch at all.)
        ///
        /// The cache lives **here** rather than in `AppEnvironment` — which is
        /// where it started — because half the callers structurally cannot reach a
        /// `@MainActor` cache: `diffFingerprint` is called from
        /// `Verification.Runner`, `IPC.VerificationRunnerBridge` and
        /// `VerificationTabView`, and `ChangesView.baseRef` is `nonisolated`.
        /// Threading a resolved branch down as a parameter instead would have had
        /// to stop at those call sites or point `Verification.Runner` at
        /// `AppEnvironment`, which is the wrong direction for that dependency.
        /// `AppEnvironment.defaultBranch(for:)` now delegates here, so there is one
        /// cache and one policy rather than two that can disagree.
        ///
        /// **The literal `"HEAD"` is never cached.** That is the sentinel for
        /// "resolved nothing", which for a freshly added project usually means
        /// `origin/HEAD` has not been fetched yet rather than that the repository
        /// has no default branch — and `AppEnvironment.fetchOrigin` is running
        /// concurrently to fix exactly that. Pinning the sentinel would make the
        /// repair unobservable for the rest of the session.
        ///
        /// Not invalidated otherwise, deliberately. A repository whose default
        /// branch genuinely renames mid-session serves the old answer until
        /// relaunch; a TTL would not help the case that actually happens (the
        /// unfetched repo above, which the sentinel rule already covers) and would
        /// put the fan-out back on a timer.
        static func defaultBranch(at path: String) -> String {
            if let cached = defaultBranchCache.value(for: path) {
                return cached
            }
            let resolved = resolveDefaultBranch(at: path)
            if resolved != "HEAD" {
                defaultBranchCache.store(resolved, for: path)
            }
            return resolved
        }

        private static let defaultBranchCache = BranchCache()

        /// Locked rather than actor-isolated: `defaultBranch` is synchronous and has
        /// ~50 transitive callers in synchronous contexts, so an actor would force
        /// the whole chain async for a dictionary read. Mirrors the locked-box
        /// pattern in `CommandLineTools`.
        ///
        /// No in-flight de-duplication, which `AppEnvironment.defaultBranchTasks`
        /// still provides for the callers that can await: a lock serialises
        /// concurrent misses but does not merge them, so N simultaneous first-time
        /// callers for one directory each resolve it. Bounded and once — every
        /// later call is a hit.
        private final class BranchCache: @unchecked Sendable {
            private let lock = NSLock()
            private var branches: [String: String] = [:]

            func value(for path: String) -> String? {
                lock.lock()
                defer { lock.unlock() }
                return branches[path]
            }

            func store(_ branch: String, for path: String) {
                lock.lock()
                defer { lock.unlock() }
                branches[path] = branch
            }
        }

        /// Detect the default branch: git's own `origin/HEAD` first, then a
        /// `development` branch, then the usual names.
        ///
        /// **`origin/HEAD` is asked first, and used to be asked third.** A
        /// `development` branch — remote or local — won outright, so a repository
        /// whose real default is `main` but which merely *carries* a long-lived
        /// `development` branch answered `development` to every caller. There is one
        /// reader, `defaultBranch(at:)`, and it is cached per directory, so that one
        /// answer was wrong everywhere for the session:
        ///
        /// - the "Repository default" base branch, so every new worktree was cut from
        ///   `origin/development` (`BaseBranchSetting.resolve`);
        /// - the Changes tab's diff base (`mergeBase`);
        /// - the ahead count (`hasBranchCommits`), and the "open a pull request" offer
        ///   that reads it;
        /// - **prune's clean decision**, which is the ahead count again and is the
        ///   consequence with teeth: a branch merged to `main` but not to
        ///   `development` reads as *having commits* and is withheld, and — the
        ///   dangerous direction — one merged to `development` but not to `main` reads
        ///   as clean and is offered for deletion while its work is not on the real
        ///   default branch (`pruneCleanWorktrees`, `ProjectOverviewView`);
        /// - the exported `ATELIER_DEFAULT_BRANCH`, seen by every project-supplied
        ///   command, initialization step and verification check.
        ///
        /// Two documented promises said otherwise — `BaseBranchSetting`'s
        /// `repositoryDefault` ("ask git what the repository's default branch is") and
        /// AGENTS.md on `ATELIER_DEFAULT_BRANCH` ("what git thinks this repository's
        /// default branch is") — and both are true again now without being reworded.
        ///
        /// **The `development` preference is kept, as a fallback, and that is not
        /// timidity.** It now answers only where git has said nothing:
        /// `refs/remotes/origin/HEAD` is present in the README's container layout —
        /// measured, on git 2.55.0, through exactly what `BareRepoClone.clone` runs
        /// (`clone --bare`, the refspec, `fetch --all --prune`), because git sets that
        /// ref on fetch when it is unset (2.45+). So on current git this rarely fires
        /// at all; deleting it outright would buy nothing and would drop a repository
        /// whose default really *is* `development`, and whose `origin/HEAD` was never
        /// fetched, to `origin/main` and then to the `"HEAD"` sentinel — which
        /// `mergeBase` and `hasBranchCommits` correctly refuse to compare against, so
        /// the Changes tab and the ahead count would go blank rather than wrong.
        ///
        /// **This is not the `BaseBranchSetting` migration AGENTS.md holds all-or-none
        /// across `mergeBase` and `hasBranchCommits`**, and a reviewer will
        /// pattern-match it to one — the caching change had to say so too. That rule
        /// governs whether those two sites consult the *setting* instead of
        /// `defaultBranch(at:)`. Both still ask `defaultBranch(at:)`, and still agree
        /// with each other; only what it resolves has changed.
        private static func resolveDefaultBranch(at path: String) -> String {
            // What git itself says the default is.
            if let ref = remoteHeadRef(at: path) {
                return ref
            }
            // Only where it has said nothing: a development branch, remote then local.
            for branch in ["origin/development", "development"] {
                if run(args: ["rev-parse", "--verify", branch], in: path) != nil {
                    return branch
                }
            }
            // Check if origin/main or origin/master exist
            for branch in ["origin/main", "origin/master"] {
                if run(args: ["rev-parse", "--verify", branch], in: path) != nil {
                    return branch
                }
            }
            // Fallback to local main/master
            for branch in ["main", "master"] {
                if run(args: ["rev-parse", "--verify", branch], in: path) != nil {
                    return branch
                }
            }
            return "HEAD"
        }

        // MARK: - Changes tab diff listing

        /// Largest prefix of a file we sniff for a NUL byte when deciding whether an
        /// untracked file is binary (numstat does not cover untracked files).
        private static let binarySniffBytes = 8 * 1024

        /// List files changed between `merge-base(defaultBranch, HEAD)` and the
        /// working tree (Branch mode), unioning untracked files in as `.added`
        /// (Hardening 1). Each file carries `isBinary`/`changedLines`/`sizeHint`.
        /// Returns an empty array on any git failure or non-repo path.
        static func branchDiffFiles(worktreePath: String, projectPath: String) -> [Git.DiffFile] {
            guard let base = mergeBase(worktreePath: worktreePath, projectPath: projectPath) else {
                return []
            }
            guard let output = run(
                args: ["diff", "--name-status", "--diff-filter=AMDR", "-M", "-z", base],
                in: worktreePath
            ) else {
                return []
            }
            var files = parseNameStatus(output)
            appendUntrackedFiles(into: &files, at: worktreePath)

            let stats = numstat(args: ["diff", "--numstat", "-M", "-z", base], in: worktreePath)
            annotate(&files, with: stats, at: worktreePath)
            return files.sorted { $0.relativePath < $1.relativePath }
        }

        /// List files that differ between HEAD and the working tree (Uncommitted
        /// mode), unioning untracked files in as `.added` (Hardening 1). Each file
        /// carries `isBinary`/`changedLines`/`sizeHint`. Empty on git failure.
        static func uncommittedDiffFiles(at path: String) -> [Git.DiffFile] {
            guard let output = run(
                args: ["diff", "--name-status", "--diff-filter=AMDR", "-M", "-z", "HEAD"],
                in: path
            ) else {
                return []
            }
            var files = parseNameStatus(output)
            appendUntrackedFiles(into: &files, at: path)

            let stats = numstat(args: ["diff", "--numstat", "-M", "-z", "HEAD"], in: path)
            annotate(&files, with: stats, at: path)
            return files.sorted { $0.relativePath < $1.relativePath }
        }

        /// Return the content of a file at a given git ref via `git show <ref>:<path>`.
        /// Returns nil if the file does not exist at that ref or git fails.
        /// `run()` drains stdout before waiting, so large files do not deadlock.
        static func fileContent(at path: String, ref: String, filePath: String) -> String? {
            run(args: ["show", "\(ref):\(filePath)"], in: path)
        }

        /// The merge-base commit of the default branch and HEAD, trimmed. nil when
        /// merge-base cannot be computed (e.g. non-repo, unborn HEAD, git failure).
        static func mergeBase(worktreePath: String, projectPath: String) -> String? {
            let base = defaultBranch(at: projectPath)
            // `defaultBranch` hands back the literal "HEAD" when it resolves
            // nothing, and `git merge-base HEAD HEAD` answers with HEAD's own SHA —
            // exit 0, non-empty, straight past the guard below. That base means
            // "compare this branch against itself", so Branch mode showed only
            // uncommitted work and dropped every commit on the branch. An
            // unresolvable base is no base at all.
            //
            // Same sentinel already guarded in `hasBranchCommits`, and for the same
            // reason this is not the `BaseBranchSetting` migration those two sites
            // share: which branch is compared does not change here, only whether an
            // unresolved one is reported as a successful comparison. (`worktreeDetail`
            // guarded it too, until its unmerged-commit log — dead since
            // `WorktreeDetailSheet` went in 2e6f2f8 — was deleted.)
            guard base != "HEAD" else { return nil }
            guard let sha = run(args: ["merge-base", base, "HEAD"], in: worktreePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !sha.isEmpty
            else {
                return nil
            }
            return sha
        }

        // MARK: - Diff fingerprint (cache invalidation)

        /// Cache key for the Changes view: HEAD SHA plus a hash of `git diff --stat`, the
        /// untracked-file list, and a content hash of every file whose working-tree copy
        /// the SHA does not already pin (both modes). Tolerates an unborn/empty HEAD and
        /// non-repo paths by returning a stable (non-empty) string rather than crashing.
        ///
        /// Both modes fold in `ls-files --others --exclude-standard` so that adding
        /// or removing an untracked file moves the fingerprint — matching the diff
        /// listing, which unions untracked files in for both modes (Hardening 1).
        ///
        /// **`--stat` alone is blind to any edit that leaves the line counts alone**, which
        /// is what `dirtyContentHashes` is here for. Renaming an identifier, rewriting a
        /// line, reordering two lines — none of it moves an insertion/deletion count, so
        /// the Changes tab went on rendering the pre-edit diff until the user pressed
        /// Refresh. A rename sweep is far too ordinary a shape to be outside what "just
        /// enough to detect changes between tab visits" has to cover.
        ///
        /// The content hashes are additive: everything the old fingerprint distinguished it
        /// still distinguishes. What they cost is reading the changed files — but only the
        /// ones git already names as changed, and `buildContents` (the work this cache
        /// exists to skip) reads all of them plus formats and parses the diff, so the check
        /// stays cheaper than the thing it guards.
        static func diffFingerprint(worktreePath: String, projectPath: String, mode: String) -> String {
            let head = run(args: ["rev-parse", "HEAD"], in: worktreePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let tracked: String
            if mode == "branch" {
                let base = mergeBase(worktreePath: worktreePath, projectPath: projectPath) ?? "HEAD"
                tracked = run(args: ["diff", "--stat", base], in: worktreePath) ?? ""
            } else {
                tracked = run(args: ["diff", "--stat", "HEAD"], in: worktreePath) ?? ""
            }
            let untracked = run(args: ["ls-files", "--others", "--exclude-standard"], in: worktreePath) ?? ""
            let stat = tracked + untracked + dirtyContentHashes(at: worktreePath)

            // Not cryptographic in purpose — but SHA-256 rather than `hashValue`,
            // because `String.hashValue` is seeded per process. The Verification tab
            // persists a run's stamp and compares it after a relaunch; a per-process
            // seed would mark every restored result stale. ChangesView only ever tests
            // two fingerprints for equality, so a stable digest is strictly better
            // there too.
            let digest = SHA256.hash(data: Data(stat.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "\(head)|\(stat.count)|\(digest)"
        }

        /// `git hash-object` over every path whose working-tree content is not already
        /// pinned by the HEAD SHA: tracked files modified in the index or the working tree,
        /// plus untracked files. Committed content needs no entry here — the SHA is an
        /// exact fingerprint of it, and of the base side of a branch-mode diff.
        ///
        /// Returns "" when there is nothing dirty, and also when the hashing fails, which
        /// degrades this to exactly the `--stat`-only fingerprint that came before rather
        /// than to a fingerprint that moves at random.
        ///
        /// Three details are load-bearing:
        ///
        /// - **`-z` on both listings.** Without it git quotes any path holding a space or a
        ///   non-ASCII byte, and a quoted path handed to `hash-object` as an argument names
        ///   a file that does not exist — failing the whole spawn over one oddly-named file.
        /// - **Deleted paths are filtered out.** `diff --name-only` lists a file staged or
        ///   removed for deletion, and `hash-object` exits non-zero on a path it cannot
        ///   open, taking every other hash in the batch with it. The deletion still moves
        ///   the fingerprint, through `--stat`.
        /// - **Batched.** Arguments and environment share a 1MB ceiling on macOS, and a
        ///   large enough uncommitted sweep would blow it. Batching keeps the result exact
        ///   instead of trading correctness for a single spawn.
        private static func dirtyContentHashes(at worktreePath: String) -> String {
            func nulSeparatedPaths(_ args: [String]) -> [String] {
                (run(args: args, in: worktreePath) ?? "")
                    .split(separator: "\0")
                    .map(String.init)
            }

            let modified = nulSeparatedPaths(["diff", "--name-only", "-z", "HEAD"])
            let untracked = nulSeparatedPaths(["ls-files", "--others", "--exclude-standard", "-z"])

            let fileManager = FileManager.default
            let paths = (modified + untracked).filter { path in
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: worktreePath + "/" + path, isDirectory: &isDirectory)
                return exists && !isDirectory.boolValue
            }
            guard !paths.isEmpty else { return "" }

            var hashes = ""
            for batch in stride(from: 0, to: paths.count, by: hashObjectBatchSize) {
                let slice = Array(paths[batch ..< min(batch + hashObjectBatchSize, paths.count)])
                guard let output = run(
                    args: ["hash-object", "--no-filters", "--"] + slice,
                    in: worktreePath
                ) else { return "" }
                hashes += output
            }
            return hashes
        }

        /// Paths per `hash-object` spawn. 256 paths of even a very long name stay two
        /// orders of magnitude inside the 1MB argument ceiling, and one batch covers any
        /// working tree a person is actually editing.
        private static let hashObjectBatchSize = 256

        // MARK: - Diff listing helpers

        /// Parse `git diff --name-status -z` output into DiffFiles.
        ///
        /// Under `-z` every field is its own NUL-terminated record — a status, then
        /// one path for `A`/`M`/`D` and two, old then new, for `R` — and git stops
        /// C-quoting unusual paths, so a path arrives as the bytes it is on disk.
        /// (`C`, a copy, would also carry two paths; widening `--diff-filter` past
        /// `AMDR` means teaching this loop about it.)
        ///
        /// The quoting is why this moves with `numstat`: these paths are the keys
        /// `annotate` looks the counts up by, and one side quoted while the other is
        /// raw misses every non-ASCII name.
        private static func parseNameStatus(_ output: String) -> [Git.DiffFile] {
            var files: [Git.DiffFile] = []
            let records = output.split(separator: "\0", omittingEmptySubsequences: true)
            var index = 0
            while index < records.count {
                let statusChar = records[index].prefix(1)
                index += 1
                let status: Git.DiffFile.Status?
                let pathCount: Int
                switch statusChar {
                case "A": (status, pathCount) = (.added, 1)
                case "M": (status, pathCount) = (.modified, 1)
                case "D": (status, pathCount) = (.deleted, 1)
                case "R": (status, pathCount) = (.renamed, 2)
                // Every other status git can print (`T`, `U`, `X`) carries a single
                // path, so skipping one record keeps the walk in step even though
                // `--diff-filter` means none of them should arrive.
                default: (status, pathCount) = (nil, 1)
                }
                guard index + pathCount <= records.count else { break }
                // For a rename the new path is the second of the two.
                let filePath = records[index + pathCount - 1]
                index += pathCount
                if let status, !filePath.isEmpty {
                    files.append(Git.DiffFile(relativePath: String(filePath), status: status))
                }
            }
            return files
        }

        /// Union untracked files (`git ls-files --others --exclude-standard -z`) into
        /// the list as `.added`, skipping any path already present (Hardening 1).
        /// `-z` for the same reason the two diff listings take it: it is what stops
        /// git C-quoting a non-ASCII name, so the paths compared here and the paths
        /// `numstat` is keyed by are spelled one way.
        private static func appendUntrackedFiles(into files: inout [Git.DiffFile], at path: String) {
            guard let output = run(args: ["ls-files", "--others", "--exclude-standard", "-z"], in: path) else {
                return
            }
            let existing = Set(files.map(\.relativePath))
            for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
                let filePath = String(record)
                guard !filePath.isEmpty, !existing.contains(filePath) else { continue }
                files.append(Git.DiffFile(relativePath: filePath, status: .added))
            }
        }

        /// Parse `git diff --numstat -z <ref>` into `[path: (added, deleted)]`.
        ///
        /// A record is `<add>\t<del>\t<path>`, with binary files printing `-\t-\t`
        /// for the counts — mapped to `(nil, nil)` — renamed or not. A **rename** is
        /// the exception: its third field is empty and the old and new paths follow
        /// as their own NUL-terminated records.
        ///
        /// That exception is the whole reason for `-z`. Without it a rename is one
        /// combined field naming both paths — `old.txt => new.txt`, or brace-compacted
        /// as `src/{old => new}/file.txt` — and the spelling is ambiguous rather than
        /// merely fiddly: a file genuinely called `a => b.txt` renamed to `c.txt`
        /// prints `a => b.txt => c.txt`, which no parser can split correctly. Keyed on
        /// that combined string a renamed file never matched, so `annotate` fell
        /// through to its untracked fallback and reported the file's *entire* line
        /// count as added — which then fed the Changes tab's large-file guard, which
        /// could refuse to render a 2,000-line file that had one line edited.
        private static func numstat(args: [String], in path: String) -> [String: (added: Int?, deleted: Int?)] {
            guard let output = run(args: args, in: path) else { return [:] }
            var result: [String: (added: Int?, deleted: Int?)] = [:]
            let records = output.split(separator: "\0", omittingEmptySubsequences: true)
            var index = 0
            while index < records.count {
                // `omittingEmptySubsequences: false` keeps the empty third field a
                // rename is recognised by; `maxSplits: 2` keeps a tab inside a file
                // name part of the path rather than a fourth field.
                let fields = records[index].split(
                    separator: "\t",
                    maxSplits: 2,
                    omittingEmptySubsequences: false
                )
                index += 1
                guard fields.count == 3 else { continue }
                let added = fields[0] == "-" ? nil : Int(fields[0])
                let deleted = fields[1] == "-" ? nil : Int(fields[1])
                if fields[2].isEmpty {
                    // Rename: old path, then new path. Key on the new one, which is
                    // what `parseNameStatus` lists the file under.
                    guard index + 2 <= records.count else { break }
                    result[String(records[index + 1])] = (added, deleted)
                    index += 2
                } else {
                    result[String(fields[2])] = (added, deleted)
                }
            }
            return result
        }

        /// Populate `isBinary`, `changedLines`, and `sizeHint` for each file using
        /// the numstat map. Tracked binaries come from numstat `-`/`-`; untracked
        /// files (absent from numstat) fall back to a NUL-byte sniff plus a line
        /// count. `sizeHint` is the on-disk byte size of the modified side.
        private static func annotate(
            _ files: inout [Git.DiffFile],
            with stats: [String: (added: Int?, deleted: Int?)],
            at path: String
        ) {
            for index in files.indices {
                let file = files[index]
                let fullPath = (path as NSString).appendingPathComponent(file.relativePath)

                // sizeHint: byte size of the modified side (0 for deleted/missing).
                if file.status != .deleted {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
                    files[index].sizeHint = (attrs?[.size] as? Int) ?? 0
                }

                if let entry = stats[file.relativePath] {
                    if entry.added == nil, entry.deleted == nil {
                        files[index].isBinary = true
                    } else {
                        let add = entry.added ?? 0
                        let del = entry.deleted ?? 0
                        files[index].added = add
                        files[index].deleted = del
                        files[index].changedLines = add + del
                    }
                } else {
                    // Not in numstat (typically an untracked file): sniff + count.
                    if file.status != .deleted {
                        files[index].isBinary = fileLooksBinary(atPath: fullPath)
                        if !files[index].isBinary {
                            let lines = lineCount(atPath: fullPath)
                            files[index].added = lines
                            files[index].deleted = 0
                            files[index].changedLines = lines
                        }
                    }
                }
            }
        }

        /// True if the first `binarySniffBytes` of the file contain a NUL byte.
        private static func fileLooksBinary(atPath path: String) -> Bool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? handle.close() }
            let chunk = handle.readData(ofLength: binarySniffBytes)
            return chunk.contains(0)
        }

        /// Number of newline-terminated lines in a file (best-effort, 0 on failure).
        private static func lineCount(atPath path: String) -> Int {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
            if content.isEmpty {
                return 0
            }
            return content.split(separator: "\n", omittingEmptySubsequences: false).count
                - (content.hasSuffix("\n") ? 1 : 0)
        }

        /// Where a new worktree for this project should live.
        ///
        /// The setup in the README is a bare clone in `.bare` with a `.git` file beside it and
        /// every worktree added as a sibling, so worktrees belong next to the repository they
        /// came from — not collected under `~/.atelier/worktrees`, on a different volume from
        /// the repo. Resolving through the git common directory means this holds whether the
        /// project was registered as the container or as one of the worktrees inside it.
        ///
        /// Anything that is not that layout keeps the central location: for an ordinary clone
        /// the equivalent directory *is* the working tree, and putting a worktree inside it
        /// would leave it sitting in the checkout as untracked clutter.
        static func worktreeDestination(projectPath: String, projectName: String, workstreamName: String) -> URL {
            let central = AppConstants.worktreesDirectory
                .appendingPathComponent(sanitize(projectName))
                .appendingPathComponent(sanitize(workstreamName))

            guard let commonDir = run(args: ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: projectPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !commonDir.isEmpty
            else { return central }

            let container = URL(fileURLWithPath: commonDir).deletingLastPathComponent()

            // Require positive evidence of the README's layout: a `.git` *file* beside the
            // repository, written by `echo "gitdir: ./.bare" > .git`.
            //
            // Inferring the layout from `--is-inside-work-tree` not being "true" is not enough,
            // because `run` returns nil on failure and a false-or-failed probe covers three very
            // different situations. A plain `git clone --bare foo.git` resolves its container to
            // whatever directory happens to hold the repo, and a submodule resolves it to
            // `<super>/.git/modules` — where `git worktree add` succeeds, silently planting a
            // checkout inside the superproject's git directory.
            var isDirectory: ObjCBool = false
            let gitFile = container.appendingPathComponent(".git")
            let hasGitFile = FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
            guard hasGitFile else { return central }

            let containerIsCheckout = run(args: ["rev-parse", "--is-inside-work-tree"], in: container.path)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            guard !containerIsCheckout else { return central }

            return container.appendingPathComponent(sanitize(workstreamName))
        }

        /// Create a git worktree for a workstream, branching off the base branch
        /// (`BaseBranchSetting`, an app-wide setting the user can override in
        /// General settings).
        /// Returns the worktree path on success, nil on failure.
        static func createWorktree(projectPath: String, projectName: String, workstreamName: String) -> String? {
            let worktreeDir = worktreeDestination(
                projectPath: projectPath,
                projectName: projectName,
                workstreamName: workstreamName
            )

            let branchName = workstreamName

            // `repositoryDefault` needs a fresh remote-tracking ref to resolve
            // against, so fetch the origin-HEAD guess first, the same way
            // `defaultBranch` looks for one. A named setting (main/master/trunk/
            // develop) already tells us exactly what to fetch — fetching the
            // origin-HEAD guess instead would fetch a branch the user did not pick.
            let baseBranchSetting = BaseBranchSetting.current
            if baseBranchSetting == .repositoryDefault {
                fetchDefaultBranch(at: projectPath)
            }

            let baseBranch = BaseBranchSetting.resolve(for: projectPath)

            if baseBranchSetting != .repositoryDefault {
                fetchDefaultBranch(at: projectPath, branch: baseBranch)
            }

            // The fetch alone does not make the start point current — see
            // `creationStartPoint`, which is what turns `main` into `origin/main`.
            let startPoint = creationStartPoint(forBase: baseBranch, at: projectPath)

            // Create parent directories
            try? FileManager.default.createDirectory(
                at: worktreeDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Create worktree with new branch based off the base branch.
            //
            // `--no-track` because `startPoint` is usually a remote-tracking ref, and
            // git's default `branch.autoSetupMerge` would then set the new branch's
            // upstream to `origin/<base>` — a different name from the branch itself.
            // That breaks a bare `git push` in the workstream's terminal under the
            // default `push.default=simple`, and quietly weakens the purge guard:
            // `hasUnpushedCommits` reads `@{upstream}..HEAD`, which is empty for a
            // workstream that has not committed yet. `pushCurrentBranch` passes `-u`,
            // so the app's own push sets the upstream when there is something to push.
            let result = runOnWholeTree(
                args: ["worktree", "add", "--no-track", "-b", branchName, worktreeDir.path, startPoint],
                in: projectPath
            )

            if result == nil {
                // Branch might already exist, try without -b
                let fallback = runOnWholeTree(args: ["worktree", "add", worktreeDir.path, branchName], in: projectPath)
                guard fallback != nil else { return nil }
            }

            addExcludeEntry(at: projectPath, pattern: ".atelier-state/")

            return worktreeDir.path
        }

        /// The ref a new workstream branch is actually cut from, given the base branch's name.
        ///
        /// `BaseBranchSetting` names a *branch* — `main`, `master`, `trunk`, `develop` — and git
        /// resolves that name to the local `refs/heads/main` long before it looks at
        /// `refs/remotes/origin/main`. In the README's container layout `refs/heads/main` is the
        /// trunk checkout's own branch, and it moves only when somebody pulls. So fetching
        /// `origin/main` and then cutting from `main` starts every workstream from whenever that
        /// last happened: the fetch updates a ref the `worktree add` never reads.
        ///
        /// Preferring the remote-tracking ref is what makes the fetch mean something. The fallback
        /// to the name as given covers a repository with no origin, a base branch that exists only
        /// locally, and `repositoryDefault` — `defaultBranch` already prefers `origin/*` refs, so
        /// re-prefixing its answer would ask for `origin/origin/main`.
        ///
        /// Deliberately *not* `adoptRemoteBranch`'s treatment. That advances the local branch, and
        /// here the local branch is the trunk checkout the user has open in another worktree;
        /// moving it under them is a larger promise than cutting one new worktree from origin's
        /// tip. This also leaves `createWorktree`'s `-b`-less fallback exactly as it was — a
        /// workstream name that collides with a branch the bare clone captured still checks that
        /// stale local branch out, which is a different bug from this one.
        private static func creationStartPoint(forBase base: String, at path: String) -> String {
            guard !base.hasPrefix("origin/") else { return base }
            guard let sha = run(
                args: ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(base)"],
                in: path
            )?.trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else { return base }
            return "origin/\(base)"
        }

        /// Create a git worktree for a branch that already exists on origin, checking that
        /// branch out rather than cutting a new one.
        /// Returns the worktree path on success, nil on failure.
        ///
        /// Deliberately a sibling of `createWorktree` rather than a `startPoint:` parameter on
        /// it. That function's whole job is branching off `BaseBranchSetting`, and its
        /// `-b`-less fallback exists to reuse a local branch of the same name — handed a
        /// branch that lives only on origin, the pair of them succeeds and produces a worktree
        /// holding the base branch's code under exactly the name the user asked for.
        static func createWorktreeTrackingRemote(
            projectPath: String,
            projectName: String,
            branch: String
        ) -> String? {
            let worktreeDir = worktreeDestination(
                projectPath: projectPath,
                projectName: projectName,
                workstreamName: branch
            )

            // Fetched here as well as in `remoteBranchTip`: this has to be correct when called
            // on its own, and re-fetching one branch that is already current is a no-op.
            fetchBranch(at: projectPath, branch: branch)

            try? FileManager.default.createDirectory(
                at: worktreeDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let tracked = runOnWholeTree(
                args: ["worktree", "add", "--track", "-b", branch, worktreeDir.path, "origin/\(branch)"],
                in: projectPath
            )

            if tracked == nil {
                // A local branch of this name already exists, so `-b` refuses. Nothing exists
                // to check out if this fails too.
                guard runOnWholeTree(args: ["worktree", "add", worktreeDir.path, branch], in: projectPath) != nil
                else { return nil }
                adoptRemoteBranch(inWorktree: worktreeDir.path, branch: branch)
            }

            addExcludeEntry(at: projectPath, pattern: ".atelier-state/")

            return worktreeDir.path
        }

        /// Point a local branch that already existed at its counterpart on origin.
        ///
        /// In the README's bare-repo layout this is the *ordinary* path, not the edge case:
        /// `git clone --bare` writes every branch into `refs/heads`, and the refspec
        /// `BareRepoClone` configures only ever updates `refs/remotes/origin/*` afterwards. So
        /// for every branch the clone captured, `refs/heads/<branch>` exists, carries no
        /// upstream, and is as old as the clone — and checking it out is how a worktree ends up
        /// named for a branch while holding code from whenever the project was added.
        ///
        /// `--ff-only` is what makes advancing it safe: a branch that is merely behind moves to
        /// origin's tip, and one carrying commits origin has never seen refuses to move and
        /// keeps them. The upstream is set either way, so the Changes tab and the ahead count
        /// have a remote to measure against.
        private static func adoptRemoteBranch(inWorktree worktree: String, branch: String) {
            _ = run(args: ["branch", "--set-upstream-to=origin/\(branch)", branch], in: worktree)
            _ = runOnWholeTree(args: ["merge", "--ff-only", "origin/\(branch)"], in: worktree)
        }

        /// The commit `origin/<branch>` points at, after fetching it — or nil when origin has
        /// no such branch.
        ///
        /// The pre-flight for `createWorktreeTrackingRemote`: a typo'd branch name is a message
        /// in the dialog the user is still looking at, rather than an optimistic sidebar row
        /// followed by a generic "could not create worktree" alert.
        ///
        /// Asks for the remote-tracking ref specifically. A local branch of the same name is
        /// not evidence origin has one, and `--verify <branch>` would resolve it.
        static func remoteBranchTip(at path: String, branch: String) -> String? {
            fetchBranch(at: path, branch: branch)
            guard let sha = run(
                args: ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"],
                in: path
            )?.trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else { return nil }
            return sha
        }

        /// The worktree that has `branch` checked out, or nil when none does.
        ///
        /// git refuses to check one branch out twice, and reports it as an ordinary failure —
        /// which arrives too late to say anything useful, after the optimistic row is already
        /// on screen. Like `worktreePaths` this is a single git command, so it is cheap enough
        /// to ask before starting.
        static func worktreePath(forBranch branch: String, at path: String) -> String? {
            // Matched on the full ref, not on `Entry.branch`: a worktree holding a
            // ref outside `refs/heads/` must not answer for a local branch of the
            // same tail.
            worktreeList(at: path)?.first { $0.ref == "refs/heads/\(branch)" }?.path
        }

        /// Every row of `git worktree list --porcelain`, parsed once.
        ///
        /// **Nil means the question could not be asked**, and it is the reason this
        /// is optional at all: `registeredWorktrees` is what stranded-workstream
        /// repair reads, and it has to tell "git says this worktree is gone" from
        /// "git did not answer" — collapsing the two lets a transient git failure
        /// look like proof a worktree no longer exists. Callers that genuinely do
        /// not need the distinction say `?? []` for themselves, where a reader can
        /// see them saying it.
        ///
        /// The bare entry is **not** filtered here. It is a real row and one caller
        /// — nothing today, but `worktreePath(forBranch:)` would match it if a bare
        /// repository ever reported a branch — should see the listing git gave.
        /// Each public function drops what it does not want, and says why.
        private static func worktreeList(at path: String) -> [Git.WorktreeListing.Entry]? {
            guard let output = run(args: ["worktree", "list", "--porcelain"], in: path) else { return nil }
            return Git.WorktreeListing.parse(porcelain: output)
        }

        /// Append a pattern to the repo's info/exclude if not already present.
        ///
        /// Failure is the *write* failing, never the `rev-parse --git-path` probe:
        /// that probe missing is an ordinary case with a documented fallback below,
        /// and reporting it would make a successful write look failed.
        @discardableResult
        static func addExcludeEntry(at repoPath: String, pattern: String) -> Result<Void, Git.Failure> {
            // Ask git where the file lives rather than assuming `.git` is a
            // directory — in a worktree, and in the .bare container layout, it is a
            // file pointing elsewhere, and the hardcoded path silently goes nowhere.
            // `excludePath`, not `gitPath`: the static `gitPath` above is the git
            // *binary*, and shadowing it here with the info/exclude path made two
            // unrelated things share one name in one file.
            let excludeURL: URL = if let excludePath = run(args: ["rev-parse", "--git-path", "info/exclude"], in: repoPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !excludePath.isEmpty
            {
                excludePath.hasPrefix("/")
                    ? URL(fileURLWithPath: excludePath)
                    : URL(fileURLWithPath: repoPath).appendingPathComponent(excludePath).standardized
            } else {
                URL(fileURLWithPath: repoPath).appendingPathComponent(".git/info/exclude")
            }
            let fm = FileManager.default

            // Ensure the info directory exists
            let infoDir = excludeURL.deletingLastPathComponent()
            try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

            let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
            let lines = existing.components(separatedBy: .newlines)
            if lines.contains(pattern) {
                return .success(())
            }

            let entry = existing.hasSuffix("\n") || existing.isEmpty ? pattern + "\n" : "\n" + pattern + "\n"
            if let data = entry.data(using: .utf8), let handle = try? FileHandle(forWritingTo: excludeURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
                return .success(())
            }
            do {
                try (existing + entry).write(to: excludeURL, atomically: true, encoding: .utf8)
                return .success(())
            } catch {
                return .failure(.system(
                    "write \(excludeURL.path)",
                    String(format: NSLocalizedString("Could not write the repository's exclude file: %@", comment: "info/exclude write failed"), error.localizedDescription)
                ))
            }
        }

        /// Remove a git worktree.
        ///
        /// The directory goes whether or not git agreed to drop it: an orphan —
        /// one git has already forgotten — is only ever cleaned up by that
        /// fallback, and `purgeOrphanWorktree` depends on it. So `worktreePath` is
        /// a destructive argument rather than a hint, and it is checked before
        /// anything runs. `Workstream.Archiver.purge` used to pass the project
        /// directory for a workstream that had no worktree path yet, and this
        /// deleted the user's checkout: git refuses to remove a main working tree,
        /// but the `removeItem` below never asked.
        ///
        /// Compared as `canonicalPath`, because the same directory reaches here
        /// under different spellings — a stored worktree path and a picked
        /// project directory need not agree on `/tmp` vs `/private/tmp`, and
        /// `removeItem` follows a symlinked parent to the real directory.
        /// `resolvingSymlinksInPath()` alone would settle that only while both
        /// paths were on disk.
        static func removeWorktree(projectPath: String, worktreePath: String) -> Result<Void, Git.Failure> {
            let worktreeDir = URL(fileURLWithPath: worktreePath).standardizedFileURL
            let resolvedWorktree = worktreePath.canonicalPath
            let resolvedProject = projectPath.canonicalPath
            let command = "git worktree remove --force \(worktreePath)"
            guard resolvedWorktree != resolvedProject else {
                logger.error(
                    "[Atelier] Refusing to remove \(resolvedProject, privacy: .public): that is the project directory, not a worktree of it"
                )
                return .failure(.refusing(command, String(
                    format: NSLocalizedString("Refusing to remove %@: that is the project directory, not a worktree of it.", comment: "removeWorktree refusal"),
                    resolvedProject
                )))
            }

            /// Whether the root `args` reports is `worktreePath` itself, rather than
            /// some enclosing directory. Every git probe below answers for the
            /// repository that *encloses* the path it runs in, so without this an
            /// orphan directory inside the main checkout reports the trunk's branch,
            /// and one inside a `.bare` container reports a bare repository — and the
            /// guards would then refuse the filesystem cleanup that
            /// `purgeOrphanWorktree` is built on.
            func isRoot(_ args: [String]) -> Bool {
                guard let root = run(args: args, in: worktreePath)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty
                else { return false }
                return root.canonicalPath == resolvedWorktree
            }

            // The last line of defence, below whichever caller got here: the trunk's
            // checkout, and the bare repository itself, are not things Atelier
            // removes. `git worktree remove --force` on the trunk takes the user's
            // working copy with it, and the callers deciding what is removable are
            // two layers of path comparison away from this one.
            if isRoot(["rev-parse", "--show-toplevel"]),
               let branch = currentBranch(at: worktreePath),
               protectedBranchNames(at: projectPath).contains(branch)
            {
                logger.error(
                    "[Atelier] Refusing to remove \(resolvedWorktree, privacy: .public): it is the checkout of protected branch \(branch, privacy: .public)"
                )
                return .failure(.refusing(command, String(
                    format: NSLocalizedString("Refusing to remove %1$@: it is the checkout of protected branch %2$@.", comment: "removeWorktree refusal"),
                    resolvedWorktree, branch
                )))
            }
            if isRoot(["rev-parse", "--path-format=absolute", "--git-dir"]), isBareRepository(at: worktreePath) {
                logger.error(
                    "[Atelier] Refusing to remove \(resolvedWorktree, privacy: .public): that is the bare repository, not a worktree"
                )
                return .failure(.refusing(command, String(
                    format: NSLocalizedString("Refusing to remove %@: that is the bare repository, not a worktree.", comment: "removeWorktree refusal"),
                    resolvedWorktree
                )))
            }

            let gitOutcome = runOnWholeTreeReporting(
                args: ["worktree", "remove", "--force", worktreePath],
                in: projectPath
            )

            // Clean up empty directories
            var removalError: Error?
            do {
                try FileManager.default.removeItem(at: worktreeDir)
            } catch {
                removalError = error
            }
            let parentDir = worktreeDir.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: parentDir)
            }

            // **The verdict is whether the directory is gone, not whether git
            // agreed.** An orphan — one git has already forgotten — makes
            // `worktree remove` fail every time, and the `removeItem` above is the
            // only thing that ever cleans it up; `purgeOrphanWorktree` is built on
            // exactly that. Reporting git's exit code as the verdict would make a
            // successful orphan purge report failure, which is the one thing a
            // caller must not be told here.
            //
            // git's stderr is still what a survivor's failure carries, because it
            // is the diagnosis: "is a main working tree", "contains modified files".
            guard FileManager.default.fileExists(atPath: worktreeDir.path) else { return .success(()) }
            if case let .failure(failure) = gitOutcome {
                return .failure(failure)
            }
            return .failure(.system(command, String(
                format: NSLocalizedString("The worktree directory is still at %1$@: %2$@", comment: "removeWorktree left the directory behind"),
                worktreeDir.path,
                removalError?.localizedDescription ?? NSLocalizedString("git reported success but the directory remains.", comment: "removeWorktree unexplained survivor")
            )))
        }

        /// Whether a worktree has uncommitted changes (staged, unstaged, or untracked
        /// files) — or `nil` when the probe did not run.
        ///
        /// This used to return `false` on failure, which every caller read as "clean".
        /// `purgeWarning` gates the only warning shown before a `--force` removal on
        /// it, so a failed probe hid the last thing standing between the user and
        /// losing work. A probe that could not look must not answer "no".
        static func hasUncommittedChanges(at path: String) -> Bool? {
            guard let status = run(args: ["status", "--porcelain", "--ignore-submodules=dirty"], in: path) else { return nil }
            return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// One entry of `git status --porcelain -z`: the two status columns and the path
        /// they describe.
        struct StatusEntry: Equatable {
            /// The index column and the work-tree column, always exactly two characters.
            let xy: String
            let path: String

            var indexStatus: Character {
                xy.first ?? " "
            }

            var workTreeStatus: Character {
                xy.last ?? " "
            }
        }

        /// Split `git status --porcelain -z` output into entries. Shared so the two
        /// parsers of this output cannot drift apart.
        ///
        /// **`-z`, for the reason the diff listings take it** (see `parseNameStatus`):
        /// without it git C-quotes any path holding a space-adjacent quote, a backslash
        /// or a non-ASCII byte, so `café.txt` arrives as `"caf\303\251.txt"` — a
        /// spelling that names no file on disk. `fileStatuses`' keys are looked up
        /// against paths the file tree read straight out of `contentsOfDirectory`, so
        /// every non-ASCII file silently lost its modified and untracked badge, and
        /// `worktreeDetail` rendered the quoted spelling in the changes popover.
        ///
        /// Under `-z` each entry is its own NUL-terminated record, spelled `XY <path>`.
        /// A rename or a copy spends **two**: git drops the `->` and reverses the order,
        /// so the destination comes first and the origin follows as its own record. The
        /// origin is consumed and dropped — callers want the path that exists on disk
        /// now, which is the destination. That consumption is why this is one parser and
        /// not two: an origin record left in the stream is read as an entry whose first
        /// two characters happened to look like a status.
        ///
        /// The pair is detected on the **index column alone**, which is the only column
        /// git puts an `R` or a `C` in — it does not detect renames in the work tree, so
        /// ` R` is not a status it emits. Accepting one in either column would consume a
        /// record git never paired and put every entry after it out of step, which is a
        /// worse failure than the quoting this fixes.
        static func parsePorcelainStatus(_ output: String) -> [StatusEntry] {
            var entries: [StatusEntry] = []
            let records = output.split(separator: "\0", omittingEmptySubsequences: true)
            var index = 0
            while index < records.count {
                let record = records[index]
                index += 1
                // "XY " plus at least one character of path.
                guard record.count >= 4 else { continue }
                let xy = String(record.prefix(2))
                entries.append(StatusEntry(xy: xy, path: String(record.dropFirst(3))))
                if xy.hasPrefix("R") || xy.hasPrefix("C") {
                    index += 1
                }
            }
            return entries
        }

        /// Get the uncommitted file changes in a worktree.
        static func worktreeDetail(at worktreePath: String) -> Worktree.Detail {
            var changes: [Worktree.Detail.FileChange] = []

            let status = run(args: ["status", "--porcelain", "-z"], in: worktreePath)
            if let status {
                for entry in parsePorcelainStatus(status) {
                    // A rename's path is the destination, which is the one that exists on
                    // disk and the one `fileStatuses` records, so both readers of this
                    // output agree on it.
                    let filePath = entry.path

                    if entry.indexStatus == "?" {
                        changes.append(.init(status: .untracked, path: filePath, isStaged: false))
                    } else {
                        if entry.indexStatus != " " {
                            let status = parseStatus(entry.indexStatus)
                            changes.append(.init(status: status, path: filePath, isStaged: true))
                        }
                        if entry.workTreeStatus != " " {
                            let status = parseStatus(entry.workTreeStatus)
                            changes.append(.init(status: status, path: filePath, isStaged: false))
                        }
                    }
                }
            }

            return Worktree.Detail(
                changes: changes,
                changesUnavailable: status == nil
            )
        }

        /// Discard all uncommitted changes: reset staged, checkout unstaged, clean untracked.
        ///
        /// **All three run whatever the earlier ones did**, unchanged from when this
        /// returned `Void`, and the first failure is what comes back. That is not an
        /// oversight to tidy into an early return: a `reset` that fails still leaves
        /// a tree the `checkout` and `clean` can strip, and stopping at the first
        /// error would leave the user staring at changes a Discard All said it had
        /// discarded.
        static func discardAllChanges(at path: String) -> Result<Void, Git.Failure> {
            let outcomes = [
                runReporting(args: ["reset", "HEAD"], in: path),
                runOnWholeTreeReporting(args: ["checkout", "--", "."], in: path),
                runOnWholeTreeReporting(args: ["clean", "-fd"], in: path),
            ]
            for outcome in outcomes {
                if case let .failure(failure) = outcome {
                    return .failure(failure)
                }
            }
            return .success(())
        }

        private static func parseStatus(_ char: Character) -> Worktree.Detail.FileChange.Status {
            switch char {
            case "M": .modified
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
        }

        /// Whether the current branch holds commits not yet pushed to its
        /// upstream — or `nil` when the probe could not run.
        ///
        /// Mirrors `hasUncommittedChanges` above: `purgeWarning` gates the same
        /// last-warning-before-`--force` on this, so a probe that could not look
        /// must not answer "no". A branch with no upstream configured is *not*
        /// a probe failure — `git log @{upstream}..HEAD` exits non-zero for
        /// exactly that reason on every branch that has never been pushed — so
        /// this only reports `nil` when the fallback, `git log --oneline -1`,
        /// also fails to answer. Git missing or the call timing out fails both
        /// probes identically, which is what makes that the honest signal; a
        /// truly empty repository (no commits at all) hits the same branch and
        /// is reported as unknown rather than "nothing to push", which is the
        /// same fail-closed trade the rest of this change makes.
        static func hasUnpushedCommits(at path: String) -> Bool? {
            guard let output = run(args: ["log", "@{upstream}..HEAD", "--oneline"], in: path) else {
                // No upstream set means everything is unpushed (if there are commits).
                guard let commits = run(args: ["log", "--oneline", "-1"], in: path) else { return nil }
                return !commits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Whether this branch holds commits the base branch does not — or `nil` when
        /// the comparison never happened.
        ///
        /// `defaultBranch` falls back to the literal "HEAD" when it resolves nothing,
        /// and `git log HEAD..HEAD` is a valid empty range that exits 0, so an
        /// unresolvable base used to report "no commits" with full confidence.
        ///
        /// This does not change *which* branch is compared against, so it is not the
        /// `BaseBranchSetting` migration AGENTS.md holds all-or-none across this
        /// function and `mergeBase`. That question is untouched here. (There was a
        /// third site, `worktreeDetail`'s unmerged-commit log. It had no reader after
        /// `WorktreeDetailSheet` was deleted in 2e6f2f8, so it was deleted rather than
        /// migrated — the rule now binds two sites, not three.)
        static func hasBranchCommits(at path: String, projectPath: String) -> Bool? {
            let base = defaultBranch(at: projectPath)
            guard base != "HEAD" else { return nil }
            guard let output = run(args: ["log", "\(base)..HEAD", "--oneline"], in: path) else { return nil }
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Check if a remote exists for this repository.
        static func hasRemote(at path: String) -> Bool {
            guard let output = run(args: ["remote"], in: path) else { return false }
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Push the current branch to origin, setting upstream if needed.
        ///
        /// Bounded: a push reaches the network, so it can stall indefinitely on a
        /// dead connection with nothing to cancel it.
        static func pushCurrentBranch(at path: String) -> (success: Bool, output: String) {
            guard let gitPath else { return (false, "git not found") }
            guard let result = ProcessRunner.capture(
                executable: gitPath,
                arguments: ["-C", path, "push", "-u", "origin", "HEAD"],
                environment: gitEnvironment,
                timeout: ProcessRunner.Timeout.network
            ) else {
                return (false, NSLocalizedString("git push did not finish in time.", comment: ""))
            }
            // git push reports progress on stderr and little else, so both streams
            // go back to the caller, which shows them verbatim.
            let combined = [result.stdoutText, result.stderrText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return (result.isSuccess, combined)
        }

        /// List existing worktrees for a project with branch and dirty status.
        static func listWorktreesWithInfo(at projectPath: String) -> [Worktree.Info] {
            // `?? []` on purpose, and unchanged: this feeds the project overview,
            // which redraws on a timer and has an empty state. `registeredWorktrees`
            // is the caller that may not flatten the distinction.
            guard let entries = worktreeList(at: projectPath), !entries.isEmpty else {
                return []
            }

            let mainPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
            // Resolved once per call, not once per worktree: this runs on every
            // refresh of the project overview, and the answer is a property of the
            // repository, not of the row.
            let protectedBranches = protectedBranchNames(at: projectPath)

            var results: [Worktree.Info] = []

            // In the .bare container layout the bare repository is itself an entry
            // in `worktree list`. It has no work tree and no branch, so it must not
            // be surfaced as a workstream.
            for entry in entries where !entry.isBare {
                let path = entry.path
                let currentBranch = entry.branch
                let isMain = URL(fileURLWithPath: path).standardizedFileURL.path == mainPath
                let isProtected = isMain || currentBranch.map(protectedBranches.contains) == true
                let dirtyProbe = isMain ? false : hasUncommittedChanges(at: path)
                let unpushedProbe: Bool? = isMain ? false : hasUnpushedCommits(at: path)
                let branchCommitsProbe = isMain ? false : hasBranchCommits(at: path, projectPath: projectPath)
                results.append(Worktree.Info(
                    path: path,
                    branch: currentBranch,
                    isDirty: dirtyProbe ?? false,
                    isMain: isMain,
                    // Defensible only because `cleanlinessUnknown` below now folds
                    // this probe in — a caller that wants to know whether this
                    // answer is trustworthy has somewhere to look.
                    hasUnpushedCommits: unpushedProbe ?? false,
                    hasBranchCommits: branchCommitsProbe ?? false,
                    isProtected: isProtected,
                    cleanlinessUnknown: dirtyProbe == nil || unpushedProbe == nil || branchCommitsProbe == nil
                ))
            }

            return results
        }

        /// Remove clean worktrees (no uncommitted changes and no unmerged branch commits).
        /// When `onlyPaths` is provided, only those worktree paths are considered.
        /// Removes the worktrees that are known to be clean, and returns the
        /// standardized paths of the ones git actually removed.
        ///
        /// The return used to be a count, which the caller could not map back to
        /// paths — so it dropped every *attempted* worktree from the project's
        /// workstream list, including ones git had refused to remove.
        @discardableResult
        static func pruneCleanWorktrees(at projectPath: String, onlyPaths: Set<String>? = nil) -> Set<String> {
            let worktrees = listWorktreesWithInfo(at: projectPath)
            let allowedPaths = onlyPaths.map { paths in
                Set(paths.map { path in
                    URL(fileURLWithPath: path).standardizedFileURL.path
                })
            }
            var pruned: Set<String> = []
            // `cleanlinessUnknown` fails closed: a worktree whose checks did not run
            // is not a clean worktree, whatever the caller asked for. `isProtected`
            // covers the trunk, which is clean by every one of these measures and so
            // was the first thing a bulk prune reached for.
            for wt in worktrees where !wt.isProtected && !wt.isDirty && !wt.hasBranchCommits && !wt.cleanlinessUnknown {
                let standardizedPath = URL(fileURLWithPath: wt.path).standardizedFileURL.path
                if let allowedPaths, !allowedPaths.contains(standardizedPath) {
                    continue
                }
                // No --force: git refuses to remove a worktree holding modified or
                // untracked files, which is the backstop behind the checks above.
                if runOnWholeTree(args: ["worktree", "remove", wt.path], in: projectPath) != nil {
                    pruned.insert(standardizedPath)
                }
            }
            // Clean up stale entries
            _ = run(args: ["worktree", "prune"], in: projectPath)
            return pruned
        }

        /// If the given path is a git worktree (not the main repository), return the main
        /// repository path. Returns nil for non-git directories or main repositories.
        static func mainRepositoryPath(for path: String) -> String? {
            let gitEntry = URL(fileURLWithPath: path).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDir) else {
                return nil
            }
            // .git is a directory in main repos, a file in worktrees
            guard !isDir.boolValue else {
                return nil
            }

            guard let commonDir = run(args: ["rev-parse", "--git-common-dir"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return nil
            }

            let commonURL = if commonDir.hasPrefix("/") {
                URL(fileURLWithPath: commonDir)
            } else {
                URL(fileURLWithPath: path).appendingPathComponent(commonDir).standardized
            }

            return commonURL.deletingLastPathComponent().standardizedFileURL.path
        }

        /// Resolve any path the user points at — a repo, a worktree, or a `.bare`
        /// container — to the repository's home, and to the checkout that
        /// represents it.
        ///
        /// Worktrees resolve to their main repository. A `.bare` container
        /// resolves to *itself*: it is the repository's home, the directory that
        /// holds `.bare`, the default checkout and every workstream worktree as
        /// peers, and the one place an `execution.process-compose.yaml` or `ports.yml` can
        /// sit and serve all of them while staying outside git.
        ///
        /// This used to resolve *forward*, registering the container's default
        /// checkout as the project, because a bare container has no work tree of
        /// its own — `git status` there fails outright and HEAD reads as the
        /// parked `root` branch — and every git-backed surface read
        /// `Project.directory` directly. That is still true of those surfaces,
        /// and they still need a checkout; what changed is that they ask
        /// `Project.checkout` for one. Resolving forward here meant
        /// "project directory" named the container in the README and the
        /// checkout in the code, and the process-compose lookups were written
        /// against the first while being handed the second.
        static func projectLocation(for path: String) -> Project.Location {
            let container = mainRepositoryPath(for: path) ?? path
            let name = URL(fileURLWithPath: container).lastPathComponent

            guard isBareRepository(at: container) else {
                return Project.Location(directory: container, name: name)
            }

            // Nil for a container whose checkout is gone. `Project.checkout`
            // then falls back to the container, which is wrong for a work tree
            // and is still the only answer there is.
            return Project.Location(
                directory: container,
                name: name,
                checkoutDirectory: defaultCheckoutPath(in: container)
            )
        }

        /// True when `path` resolves to a bare repository — the `.bare` container
        /// layout, where the git database has no work tree attached.
        static func isBareRepository(at path: String) -> Bool {
            run(args: ["rev-parse", "--is-bare-repository"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }

        /// The checkout a bare container should be represented by: the worktree for
        /// `wt.default` when it is present, otherwise the child worktree on the
        /// default branch. Nil when the container has no checkout at all.
        private static func defaultCheckoutPath(in container: String) -> String? {
            let containerURL = URL(fileURLWithPath: container).standardizedFileURL

            if let configured = run(args: ["config", "wt.default"], in: container)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty
            {
                let candidate = containerURL.appendingPathComponent(configured)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate.path
                }
            }

            // wt.default may be unset (a container made outside Atelier) or stale.
            let candidates = worktreePaths(at: container).filter { path in
                URL(fileURLWithPath: path).standardizedFileURL
                    .deletingLastPathComponent().path == containerURL.path
            }
            guard candidates.count > 1 else { return candidates.first }

            // Workstream worktrees are created beside the repository too, so the
            // container's children are the default checkout *and* every workstream.
            // Pick the checkout of the repository's own default branch rather than
            // whichever git lists first, which would register a workstream instead.
            let branches = candidates.map { (path: $0, branch: currentBranch(at: $0)) }
            for candidate in defaultBranchNames(at: container) {
                if let match = branches.first(where: { $0.branch == candidate }) {
                    return match.path
                }
            }
            return candidates.first
        }

        /// Branch names whose checkout must never be purged or pruned.
        ///
        /// Deliberately not `defaultBranchNames` below: that one is answering
        /// "which checkout represents this project" and includes `development`,
        /// which is an ordinary long-lived branch someone may well want to discard
        /// a worktree of. This set is the trunk only — whatever the remote calls
        /// its HEAD, plus the two conventional names for repositories with no
        /// `origin/HEAD` to ask.
        static func protectedBranchNames(at path: String) -> Set<String> {
            var names: Set = ["main", "master"]
            if let head = remoteHeadRef(at: path), !head.isEmpty {
                names.insert(stripOriginPrefix(head))
            }
            return names
        }

        /// Branch names that could be the repository's default, best guess first.
        ///
        /// Deliberately not `defaultBranch`: that one prefers `development` for
        /// worktree *branching*, which is a different question from which checkout
        /// represents the project. A repo with a `development` branch whose checkout
        /// is on `main` would match nothing and fall through to an arbitrary
        /// worktree.
        private static func defaultBranchNames(at path: String) -> [String] {
            var names: [String] = []
            if let head = remoteHeadRef(at: path), !head.isEmpty {
                names.append(stripOriginPrefix(head))
            }
            names.append(contentsOf: ["main", "master", "development"])
            return names
        }

        /// Every worktree git knows about, with the branch each holds. One
        /// `worktree list --porcelain` and nothing else — unlike
        /// `listWorktreesWithInfo`, which spawns three status probes *per row*.
        ///
        /// **Nil means the question could not be asked**, which is not the same
        /// answer as an empty array. A caller deciding whether a stored record is
        /// repairable has to tell "git says this worktree is gone" from "git did
        /// not answer"; collapsing the two would let a transient git failure look
        /// like proof that a worktree no longer exists.
        static func registeredWorktrees(at path: String) -> [Worktree.Registration]? {
            // The bare repository is itself an entry in the `.bare` container
            // layout. It has no work tree, so it is not a worktree anyone can be
            // pointed at. The optional is passed straight through — see
            // `worktreeList`, whose nil this is the reason for.
            worktreeList(at: path)?
                .filter { !$0.isBare }
                .map { Worktree.Registration(path: $0.path, branch: $0.branch) }
        }

        /// Worktree paths only, skipping the bare repository entry. Cheap enough
        /// to call while resolving a project — see `registeredWorktrees`, which
        /// this is a projection of.
        ///
        /// **Deliberately flattens "could not ask" to "nothing there"**, which
        /// `registeredWorktrees` refuses to do for its own callers. Safe only
        /// because of what the single caller does with it: `projectLocation` is
        /// looking for a checkout to prefer among candidates, and having no
        /// candidate is already an outcome it handles — it falls back to the
        /// directory it was given. A repair that *discards* a user's record on an
        /// empty answer is the case that needs the distinction, and it has it.
        private static func worktreePaths(at path: String) -> [String] {
            registeredWorktrees(at: path)?.map(\.path) ?? []
        }

        /// Return the current branch name, or nil if detached or not a repo.
        static func currentBranch(at path: String) -> String? {
            guard let raw = run(args: ["rev-parse", "--abbrev-ref", "HEAD"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return raw == "HEAD" ? nil : raw
        }

        /// Delete a local branch by name.
        static func deleteLocalBranch(at path: String, branchName: String) -> Result<Void, Git.Failure> {
            runReporting(args: ["branch", "-D", branchName], in: path).map { _ in () }
        }

        /// Per-file git status for the file tree (modified, untracked, ignored).
        /// Returns an empty dictionary on failure so the tree degrades gracefully.
        static func fileStatuses(at path: String) -> [String: Git.FileStatus] {
            guard let output = runWithTimeout(
                args: ["status", "--porcelain", "--ignored", "--ignore-submodules=dirty", "-z"],
                in: path,
                timeout: 3
            ) else {
                return [:]
            }

            var result: [String: Git.FileStatus] = [:]
            for entry in parsePorcelainStatus(output) {
                var filePath = entry.path

                if entry.xy == "!!" {
                    // Ignored — strip trailing slash for directories
                    if filePath.hasSuffix("/") {
                        filePath = String(filePath.dropLast())
                    }
                    result[filePath] = .ignored
                } else if entry.xy == "??" {
                    result[filePath] = .untracked
                } else {
                    // Already the destination half of a rename — see `parsePorcelainStatus`.
                    result[filePath] = .modified
                }
            }
            return result
        }

        enum PullResult {
            case success(String)
            case failure(String)
        }

        /// Cuts a git command's output down to something an alert can show.
        ///
        /// An alert's message is one unscrollable `Text` and the `_NSAlertPanel`
        /// behind it grows to fit whatever it is handed. `git pull` refusing over
        /// 150 locally-modified files names every one of them, and the panel then
        /// measures 2574pt on a 1084pt screen with its origin 1522pt below the
        /// bottom edge — the OK button is off-screen and the dialog cannot be
        /// dismissed at all. That is the bug this exists for; it is not tidying.
        ///
        /// Head *and* tail are kept because git puts the diagnosis first
        /// ("error: Your local changes to the following files would be overwritten
        /// by merge:") and the instruction last ("Please commit your changes or
        /// stash them before you merge. / Aborting"). Keeping either end alone
        /// drops half of what the user needs to act on. The elided middle is the
        /// file list, which is not what an alert is for — `git status` is.
        ///
        /// `characterLimit` is the backstop for output with no newlines to cut on:
        /// a single 8000-character line measured 2310pt on its own, so a line
        /// budget alone does not bound the panel.
        static func truncatedForAlert(
            _ text: String,
            headLines: Int = 6,
            tailLines: Int = 3,
            characterLimit: Int = 900
        ) -> String {
            let lines = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)

            var kept = lines
            // `+ 1`: eliding a single line to insert an elision line saves nothing.
            if lines.count > headLines + tailLines + 1 {
                let omitted = lines.count - headLines - tailLines
                let elision = String(
                    format: NSLocalizedString(
                        "… %d more lines …",
                        comment: "Marks the middle of a git error trimmed to fit an alert"
                    ),
                    omitted
                )
                kept = Array(lines.prefix(headLines)) + [elision] + Array(lines.suffix(tailLines))
            }

            let joined = kept.joined(separator: "\n")
            guard joined.count > characterLimit else { return joined }
            return String(joined.prefix(characterLimit - 1)) + "…"
        }

        /// Run `git pull --ff-only` on whatever branch is currently checked out at `path`.
        /// Returns stdout on success and stderr (or an explanatory message) on failure.
        static func pullCurrentBranch(at path: String) -> PullResult {
            guard let gitPath else { return .failure("git not found") }
            // Bounded: a pull reaches the network and the caller is a UI action.
            guard let result = ProcessRunner.capture(
                executable: gitPath,
                arguments: ["pull", "--ff-only"],
                environment: gitEnvironment,
                currentDirectory: URL(fileURLWithPath: path),
                timeout: ProcessRunner.Timeout.network
            ) else {
                return .failure(NSLocalizedString("git pull did not finish in time.", comment: ""))
            }

            let out = result.stdoutText
            let err = result.stderrText
            guard result.isSuccess else {
                return .failure(err.isEmpty ? "git pull failed (exit \(result.status))" : err)
            }
            return .success(out.isEmpty ? err : out)
        }

        // MARK: - Private

        /// Strips a leading `"origin/"` from `ref`, leaving any other occurrence of
        /// that substring untouched. `git fetch origin <ref>` wants the bare name,
        /// and a prefix check is required rather than a blanket substring removal
        /// because `"origin/"` can legally recur inside the ref itself — a branch
        /// literally named `feature/origin/thing` must come back unchanged, not as
        /// `feature/thing`.
        static func stripOriginPrefix(_ ref: String) -> String {
            ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
        }

        /// `origin/HEAD` as git reports it — `origin/main`, trimmed — or nil when
        /// the ref is absent, which is the ordinary case for a repository that has
        /// never been fetched.
        ///
        /// Four sites asked git this with four copies of the same two lines, and
        /// two of them then reimplemented `stripOriginPrefix` inline rather than
        /// calling it. That is the prefix check that must not become a substring
        /// removal — a branch named `feature/origin/thing` comes back unchanged —
        /// so having two hand-rolled copies of it was the part worth removing.
        ///
        /// Deliberately **not** cached and deliberately not routed through
        /// `defaultBranch(at:)`: three of the four callers are asking a different
        /// question from that one (which trunk must never be purged, which checkout
        /// represents the project, which branch to fetch), and `defaultBranch`'s
        /// cache and its `"HEAD"` sentinel belong to its own question.
        private static func remoteHeadRef(at path: String) -> String? {
            run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Fetch a branch from origin. Fails silently when there is no remote or
        /// the network is unreachable.
        ///
        /// With `branch` omitted, guesses at the origin's default branch (its
        /// symbolic HEAD, or "main") — used when the caller still needs to ask
        /// git what the default is. With `branch` given (e.g. a resolved
        /// `BaseBranchSetting`), fetches exactly that branch instead, stripping
        /// an `origin/` prefix if present since `git fetch origin <ref>` wants
        /// the bare name.
        @discardableResult
        static func fetchDefaultBranch(at path: String, branch: String? = nil) -> Result<Void, Git.Failure> {
            // Determine which branch to fetch. `fetchBranch` makes the no-remote check, so
            // there is no guard here — asking twice was one git spawn per call for nothing.
            let branchToFetch: String = if let branch {
                stripOriginPrefix(branch)
            } else if let ref = remoteHeadRef(at: path) {
                // e.g. "origin/main" -> "main"
                stripOriginPrefix(ref)
            } else {
                "main"
            }

            return fetchBranch(at: path, branch: branchToFetch)
        }

        /// Fetch one named branch from origin. No-ops without a remote, and gives up rather
        /// than blocking a worktree creation that can proceed on stale refs.
        ///
        /// The 5s bound is much tighter than `ProcessRunner.Timeout.network`, and stays that
        /// way: every caller either has a stale ref to fall back on or a `rev-parse` that will
        /// report the miss, so waiting two minutes on a wedged link buys nothing.
        ///
        /// **No remote is `.success`, not a failure.** A local-only repository is an
        /// ordinary state in which there is nothing to fetch, and `fetchOrigin`
        /// sweeps every project on a two-minute timer — reporting it would put a
        /// line in the log every two minutes for a repository that is working
        /// exactly as intended.
        /// `@discardableResult` for the reason the doc comment gives: both
        /// creation paths call this for refs they can proceed without, and a
        /// local-only repository reaches the `.success` above on every call.
        @discardableResult
        private static func fetchBranch(at path: String, branch: String) -> Result<Void, Git.Failure> {
            guard run(args: ["remote", "get-url", "origin"], in: path) != nil else { return .success(()) }
            // The 5s bound is deliberate and stays inline: it is tighter than every
            // `ProcessRunner.Timeout` tier on purpose (see the doc comment above),
            // and there is no tier for "give up fast because a stale ref will do".
            return capture(
                args: ["fetch", "origin", stripOriginPrefix(branch), "--no-tags"],
                in: path,
                timeout: 5
            ).map { _ in () }
        }

        /// Runs git and reports either stdout or why it did not run.
        ///
        /// **The spawn site for everything shaped like a read.** `runWithTimeout`,
        /// `run` and `runOnWholeTree` are all projections of this, so the deadline,
        /// `gitEnvironment`'s `GIT_TERMINAL_PROMPT=0`/`GIT_ASKPASS` pair and the
        /// concurrent pipe drain are decided once. Every mutator returning a
        /// `Git.Failure` gets its exit code and stderr from here rather than
        /// re-spawning to ask.
        ///
        /// It is not the *only* spawn site, and said it was for a while.
        /// `pushCurrentBranch` and `pullCurrentBranch` reach `ProcessRunner.capture`
        /// directly, because both hand the user git's own words and this returns
        /// stdout alone: git reports a push almost entirely on stderr, and a failed
        /// pull's diagnosis is the stderr `PullResult.failure` carries. They still
        /// take `gitEnvironment` and a `Timeout` tier, so what this decides once they
        /// agree with — but they are two more places to change, not zero.
        ///
        /// `pushCurrentBranch` is also the one caller that says where to run with
        /// `-C <path>` rather than `currentDirectory:`. Equivalent for the push
        /// itself, and left alone deliberately: it is a network path with no test,
        /// and a difference nothing can observe is not worth moving blind.
        ///
        /// `ProcessRunner` owns the deadline and drains both pipes concurrently,
        /// which is what makes a large `git show`/`git status` safe: git blocks
        /// writing to a full pipe once its output passes the ~64 KB macOS buffer,
        /// so draining one stream while the other fills would wedge it.
        private static func capture(
            args: [String],
            in directory: String,
            timeout: TimeInterval
        ) -> Result<String, Git.Failure> {
            let command = "git " + args.joined(separator: " ")

            guard let gitPath else {
                logger.warning("[Atelier] git run: gitPath is nil")
                return .failure(.system(command, NSLocalizedString("git was not found", comment: "git binary missing")))
            }
            guard let output = ProcessRunner.capture(
                executable: gitPath,
                arguments: args,
                environment: gitEnvironment,
                currentDirectory: URL(fileURLWithPath: directory),
                timeout: timeout
            ) else {
                return .failure(.system(
                    command,
                    String(format: NSLocalizedString("git did not finish within %ds", comment: "git deadline"), Int(timeout))
                ))
            }

            guard output.isSuccess else {
                logger.warning("[Atelier] git \(args.joined(separator: " "), privacy: .public) failed (exit \(output.status, privacy: .public)): \(output.stderrText, privacy: .public)")
                let tail = Git.Failure.stderrTail(output.stderrText)
                return .failure(Git.Failure(
                    command: command,
                    exitCode: output.status,
                    stderr: tail,
                    reason: tail.isEmpty
                        ? String(format: NSLocalizedString("git exited %d", comment: "git exit status"), output.status)
                        : tail
                ))
            }
            // Nil only for stdout that is not UTF-8, which none of these commands
            // produce. Kept as a failure rather than coerced to "" because every
            // caller above reads an empty listing as a real answer.
            guard let text = String(data: output.stdout, encoding: .utf8) else {
                return .failure(.system(command, NSLocalizedString("git output was not readable as text", comment: "git non-UTF8 output")))
            }
            return .success(text)
        }

        /// Runs git and returns stdout, or nil if git is missing, exited non-zero,
        /// or outlived `timeout`. The read-shaped projection of `capture`, for the
        /// three dozen probes whose only question is "what did git say".
        @discardableResult
        private static func runWithTimeout(args: [String], in directory: String, timeout: TimeInterval) -> String? {
            try? capture(args: args, in: directory, timeout: timeout).get()
        }

        /// Validates a candidate workstream name for use as a git branch name.
        /// Follows git check-ref-format rules; empty names are invalid (callers
        /// treat empty as "generate a random name instead").
        static func isValidBranchName(_ name: String) -> Bool {
            guard !name.isEmpty else { return false }
            let forbiddenCharacters = CharacterSet(charactersIn: " ~^:?*[\\")
            if name.rangeOfCharacter(from: forbiddenCharacters) != nil {
                return false
            }
            if name.contains("..") || name.contains("@{") || name.contains("//") {
                return false
            }
            if name.hasPrefix("-") {
                return false
            }
            if name.hasSuffix(".") || name.hasSuffix("/") || name.hasSuffix(".lock") {
                return false
            }
            if name.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                return false
            }
            return true
        }

        private static func sanitize(_ name: String) -> String {
            var result = name.replacingOccurrences(of: "/", with: "--")
                .replacingOccurrences(of: " ", with: "-")
            // Prevent names from being interpreted as git flags
            while result.hasPrefix("-") {
                result = String(result.dropFirst())
            }
            return result.isEmpty ? "unnamed" : result
        }

        /// Git's environment for every spawn here.
        ///
        /// `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS` are what keep an auth failure
        /// from becoming a hang: a GUI app has no terminal to answer a credential
        /// prompt on, so git must fail instead of waiting. `BareRepoClone.run` sets
        /// the same pair for the same reason.
        private static var gitEnvironment: [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_ASKPASS"] = "/usr/bin/true"
            return environment
        }

        /// Git commands that only read, or that touch a handful of refs. A minute is
        /// far past any of them; past it, git is wedged.
        private static func run(args: [String], in directory: String) -> String? {
            runWithTimeout(args: args, in: directory, timeout: ProcessRunner.Timeout.local)
        }

        /// `run`, for a mutator that has to report why git refused.
        private static func runReporting(args: [String], in directory: String) -> Result<String, Git.Failure> {
            capture(args: args, in: directory, timeout: ProcessRunner.Timeout.local)
        }

        /// Git commands that write a whole working tree — `worktree add` checks one
        /// out, `worktree remove`, `reset --hard`, `checkout -- .` and `clean -fd`
        /// rewrite or delete one. How long they take is a property of the user's
        /// repository, so they get the loose tier; `run`'s minute would abort a
        /// legitimate checkout of a large repository partway through.
        private static func runOnWholeTree(args: [String], in directory: String) -> String? {
            runWithTimeout(args: args, in: directory, timeout: ProcessRunner.Timeout.userCommand)
        }

        /// `runOnWholeTree`, for a mutator that has to report why git refused.
        private static func runOnWholeTreeReporting(args: [String], in directory: String) -> Result<String, Git.Failure> {
            capture(args: args, in: directory, timeout: ProcessRunner.Timeout.userCommand)
        }
    }
}
