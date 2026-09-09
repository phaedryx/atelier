// ABOUTME: Git operations for project and workstream management.
// ABOUTME: Handles repo detection, init, worktree create/remove, and repo info.

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

        /// `isDirty` and/or `hasBranchCommits` are `false` because a probe did not
        /// run, not because the answer is no. Anything that acts on "this worktree
        /// is clean" — Prune, above all — has to treat it as not-clean.
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

        struct UnmergedCommit: Identifiable {
            let hash: String
            let message: String

            var id: String {
                hash
            }
        }

        let changes: [FileChange]
        let unmergedCommits: [UnmergedCommit]

        /// `git status` did not run — git is missing, timed out, or exited non-zero.
        /// `changes` is then empty for want of an answer, not because the tree is
        /// clean, and callers must not present it as the latter: the worktree detail
        /// sheet says "nothing to lose" directly above a Force Remove button.
        let changesUnavailable: Bool

        /// The unmerged-commit log did not run: either `git log` failed, or the base
        /// branch did not resolve, which turns the comparison into `HEAD..HEAD` — a
        /// valid empty range that exits 0 and reports every commit as merged.
        let unmergedCommitsUnavailable: Bool
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
        private static let gitPath: String? = CommandLineTools.path(for: "git")

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

        /// Detect the default branch. Prefers `development`, then falls back to auto-detection.
        static func defaultBranch(at path: String) -> String {
            // Prefer development branch if it exists (remote then local)
            for branch in ["origin/development", "development"] {
                if run(args: ["rev-parse", "--verify", branch], in: path) != nil {
                    return branch
                }
            }
            // Try remote HEAD
            if let ref = run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path) {
                return ref.trimmingCharacters(in: .whitespacesAndNewlines)
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
                args: ["diff", "--name-status", "--diff-filter=AMDR", "-M", base],
                in: worktreePath
            ) else {
                return []
            }
            var files = parseNameStatus(output)
            appendUntrackedFiles(into: &files, at: worktreePath)

            let stats = numstat(args: ["diff", "--numstat", "-M", base], in: worktreePath)
            annotate(&files, with: stats, at: worktreePath)
            return files.sorted { $0.relativePath < $1.relativePath }
        }

        /// List files that differ between HEAD and the working tree (Uncommitted
        /// mode), unioning untracked files in as `.added` (Hardening 1). Each file
        /// carries `isBinary`/`changedLines`/`sizeHint`. Empty on git failure.
        static func uncommittedDiffFiles(at path: String) -> [Git.DiffFile] {
            guard let output = run(
                args: ["diff", "--name-status", "--diff-filter=AMDR", "-M", "HEAD"],
                in: path
            ) else {
                return []
            }
            var files = parseNameStatus(output)
            appendUntrackedFiles(into: &files, at: path)

            let stats = numstat(args: ["diff", "--numstat", "-M", "HEAD"], in: path)
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
            // Same sentinel already guarded in `worktreeDetail` and
            // `hasBranchCommits`, and for the same reason this is not the
            // `BaseBranchSetting` migration those three sites share: which branch
            // is compared does not change here, only whether an unresolved one is
            // reported as a successful comparison.
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

            // Not cryptographic — just enough to detect changes between tab visits.
            return "\(head)|\(stat.count)|\(stat.hashValue)"
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

        /// Parse `git diff --name-status` output into DiffFiles.
        /// Each line is `<STATUS>\t<path>` or, for renames, `R###\t<old>\t<new>`.
        private static func parseNameStatus(_ output: String) -> [Git.DiffFile] {
            var files: [Git.DiffFile] = []
            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: true)
                guard let statusField = fields.first else { continue }
                let statusChar = statusField.prefix(1)
                switch statusChar {
                case "A":
                    if fields.count >= 2 {
                        files.append(Git.DiffFile(relativePath: String(fields[1]), status: .added))
                    }
                case "M":
                    if fields.count >= 2 {
                        files.append(Git.DiffFile(relativePath: String(fields[1]), status: .modified))
                    }
                case "D":
                    if fields.count >= 2 {
                        files.append(Git.DiffFile(relativePath: String(fields[1]), status: .deleted))
                    }
                case "R":
                    // Rename: use the new path (last field).
                    if fields.count >= 3 {
                        files.append(Git.DiffFile(relativePath: String(fields[2]), status: .renamed))
                    }
                default:
                    continue
                }
            }
            return files
        }

        /// Union untracked files (`git ls-files --others --exclude-standard`) into
        /// the list as `.added`, skipping any path already present (Hardening 1).
        private static func appendUntrackedFiles(into files: inout [Git.DiffFile], at path: String) {
            guard let output = run(args: ["ls-files", "--others", "--exclude-standard"], in: path) else {
                return
            }
            let existing = Set(files.map(\.relativePath))
            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let filePath = String(rawLine)
                guard !filePath.isEmpty, !existing.contains(filePath) else { continue }
                files.append(Git.DiffFile(relativePath: filePath, status: .added))
            }
        }

        /// Parse `git diff --numstat <ref>` into `[path: (added, deleted)]`.
        /// Binary files print `-\t-\t<path>`, mapped to `(nil, nil)`.
        private static func numstat(args: [String], in path: String) -> [String: (added: Int?, deleted: Int?)] {
            guard let output = run(args: args, in: path) else { return [:] }
            var result: [String: (added: Int?, deleted: Int?)] = [:]
            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 3 else { continue }
                let added = fields[0] == "-" ? nil : Int(fields[0])
                let deleted = fields[1] == "-" ? nil : Int(fields[1])
                // For renames numstat prints `<add>\t<del>\t<old>\t<new>` or a
                // brace-compacted path; the final field is the (new) path.
                let filePath = String(fields[fields.count - 1])
                result[filePath] = (added, deleted)
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
            // origin-HEAD guess instead would leave a worktree cut from a stale
            // local copy of the branch the user actually chose.
            let baseBranchSetting = BaseBranchSetting.current
            if baseBranchSetting == .repositoryDefault {
                fetchDefaultBranch(at: projectPath)
            }

            let baseBranch = BaseBranchSetting.resolve(for: projectPath)

            if baseBranchSetting != .repositoryDefault {
                fetchDefaultBranch(at: projectPath, branch: baseBranch)
            }

            // Create parent directories
            try? FileManager.default.createDirectory(
                at: worktreeDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Create worktree with new branch based off the default branch
            let result = runOnWholeTree(args: ["worktree", "add", "-b", branchName, worktreeDir.path, baseBranch], in: projectPath)

            if result == nil {
                // Branch might already exist, try without -b
                let fallback = runOnWholeTree(args: ["worktree", "add", worktreeDir.path, branchName], in: projectPath)
                guard fallback != nil else { return nil }
            }

            addExcludeEntry(at: projectPath, pattern: ".atelier-state/")

            return worktreeDir.path
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
            guard let output = run(args: ["worktree", "list", "--porcelain"], in: path) else { return nil }

            var current: String?
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("worktree ") {
                    current = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch "), let holder = current {
                    guard String(line.dropFirst("branch ".count)) == "refs/heads/\(branch)" else { continue }
                    return holder
                } else if line.isEmpty {
                    current = nil
                }
            }
            return nil
        }

        /// Append a pattern to the repo's info/exclude if not already present.
        static func addExcludeEntry(at repoPath: String, pattern: String) {
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
                return
            }

            let entry = existing.hasSuffix("\n") || existing.isEmpty ? pattern + "\n" : "\n" + pattern + "\n"
            if let data = entry.data(using: .utf8), let handle = try? FileHandle(forWritingTo: excludeURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? (existing + entry).write(to: excludeURL, atomically: true, encoding: .utf8)
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
        static func removeWorktree(projectPath: String, worktreePath: String) {
            let worktreeDir = URL(fileURLWithPath: worktreePath).standardizedFileURL
            let resolvedWorktree = worktreePath.canonicalPath
            let resolvedProject = projectPath.canonicalPath
            guard resolvedWorktree != resolvedProject else {
                logger.error(
                    "[Atelier] Refusing to remove \(resolvedProject, privacy: .public): that is the project directory, not a worktree of it"
                )
                return
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
                return
            }
            if isRoot(["rev-parse", "--path-format=absolute", "--git-dir"]), isBareRepository(at: worktreePath) {
                logger.error(
                    "[Atelier] Refusing to remove \(resolvedWorktree, privacy: .public): that is the bare repository, not a worktree"
                )
                return
            }

            _ = runOnWholeTree(args: ["worktree", "remove", "--force", worktreePath], in: projectPath)

            // Clean up empty directories
            try? FileManager.default.removeItem(at: worktreeDir)
            let parentDir = worktreeDir.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: parentDir)
            }
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

        /// Get detailed changes and unmerged commits for a worktree.
        /// The destination half of a `git status --porcelain` path field.
        ///
        /// Renames and copies are reported as `old -> new`; every other status reports a
        /// bare path. Callers want the path that exists on disk now, which is the
        /// destination. Shared so the two parsers of this output cannot drift apart.
        static func renamedDestination(in pathField: String) -> String {
            guard let arrow = pathField.range(of: " -> ") else { return pathField }
            return String(pathField[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        static func worktreeDetail(at worktreePath: String, mainRepoPath: String) -> Worktree.Detail {
            var changes: [Worktree.Detail.FileChange] = []

            let status = run(args: ["status", "--porcelain"], in: worktreePath)
            if let status {
                for line in status.components(separatedBy: "\n") where !line.isEmpty {
                    let trimmed = line
                    guard trimmed.count >= 3 else { continue }

                    let indexStatus = trimmed[trimmed.startIndex]
                    let workTreeStatus = trimmed[trimmed.index(after: trimmed.startIndex)]
                    // Renames and copies render as "R  old -> new". The destination is
                    // the path that exists on disk and the one `fileStatuses` records,
                    // so both parsers of this output agree on it.
                    let filePath = renamedDestination(in: String(trimmed.dropFirst(3)))

                    if indexStatus == "?" {
                        changes.append(.init(status: .untracked, path: filePath, isStaged: false))
                    } else {
                        if indexStatus != " " {
                            let status = parseStatus(indexStatus)
                            changes.append(.init(status: status, path: filePath, isStaged: true))
                        }
                        if workTreeStatus != " " {
                            let status = parseStatus(workTreeStatus)
                            changes.append(.init(status: status, path: filePath, isStaged: false))
                        }
                    }
                }
            }

            var commits: [Worktree.Detail.UnmergedCommit] = []
            let baseBranch = defaultBranch(at: mainRepoPath)
            // `defaultBranch` falls back to the literal "HEAD" when it resolves
            // nothing. `git log HEAD..HEAD` is a valid empty range that exits 0, so
            // that failure used to arrive as a confident "no unmerged commits". It is
            // an unrun check, not an empty result. Handled here rather than in
            // `defaultBranch`: `mergeBase` and `hasBranchCommits` share that fallback
            // and are out of scope.
            let log = baseBranch == "HEAD"
                ? nil
                : run(args: ["log", "\(baseBranch)..HEAD", "--oneline"], in: worktreePath)
            if let log {
                for line in log.components(separatedBy: "\n") where !line.isEmpty {
                    let parts = line.split(separator: " ", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    commits.append(.init(hash: String(parts[0]), message: String(parts[1])))
                }
            }

            return Worktree.Detail(
                changes: changes,
                unmergedCommits: commits,
                changesUnavailable: status == nil,
                unmergedCommitsUnavailable: log == nil
            )
        }

        /// Discard all uncommitted changes: reset staged, checkout unstaged, clean untracked.
        static func discardAllChanges(at path: String) {
            _ = run(args: ["reset", "HEAD"], in: path)
            _ = runOnWholeTree(args: ["checkout", "--", "."], in: path)
            _ = runOnWholeTree(args: ["clean", "-fd"], in: path)
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

        /// Check if the current branch has commits not yet pushed to its upstream.
        static func hasUnpushedCommits(at path: String) -> Bool {
            guard let output = run(args: ["log", "@{upstream}..HEAD", "--oneline"], in: path) else {
                // No upstream set means everything is unpushed (if there are commits)
                guard let commits = run(args: ["log", "--oneline", "-1"], in: path) else { return false }
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
        /// function, `mergeBase`, and `worktreeDetail`'s unmerged-commit log. That
        /// question is untouched here. (The commit log has had no reader since
        /// `WorktreeDetailSheet` was deleted in 2e6f2f8; it still counts toward the
        /// all-or-none rule until it is either wired up again or removed.)
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
            guard let output = run(args: ["worktree", "list", "--porcelain"], in: projectPath) else {
                return []
            }

            let mainPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
            // Resolved once per call, not once per worktree: this runs on every
            // refresh of the project overview, and the answer is a property of the
            // repository, not of the row.
            let protectedBranches = protectedBranchNames(at: projectPath)

            var results: [Worktree.Info] = []
            var currentPath: String?
            var currentBranch: String?
            var currentIsBare = false

            /// In the .bare container layout the bare repository is itself an entry
            /// in `worktree list`. It has no work tree and no branch, so it must not
            /// be surfaced as a workstream.
            func flush() {
                guard let path = currentPath, !currentIsBare else { return }
                let isMain = URL(fileURLWithPath: path).standardizedFileURL.path == mainPath
                let isProtected = isMain || currentBranch.map(protectedBranches.contains) == true
                let dirtyProbe = isMain ? false : hasUncommittedChanges(at: path)
                let unpushed = !isMain && hasUnpushedCommits(at: path)
                let branchCommitsProbe = isMain ? false : hasBranchCommits(at: path, projectPath: projectPath)
                results.append(Worktree.Info(
                    path: path,
                    branch: currentBranch,
                    isDirty: dirtyProbe ?? false,
                    isMain: isMain,
                    hasUnpushedCommits: unpushed,
                    hasBranchCommits: branchCommitsProbe ?? false,
                    isProtected: isProtected,
                    cleanlinessUnknown: dirtyProbe == nil || branchCommitsProbe == nil
                ))
            }

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("worktree ") {
                    flush()
                    currentPath = String(line.dropFirst("worktree ".count))
                    currentBranch = nil
                    currentIsBare = false
                } else if line.hasPrefix("branch refs/heads/") {
                    currentBranch = String(line.dropFirst("branch refs/heads/".count))
                } else if line == "bare" {
                    currentIsBare = true
                }
            }
            flush()

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
        /// peers, and the one place a `process-compose.yaml` or `ports.yml` can
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
            if let head = run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty
            {
                names.insert(head.hasPrefix("origin/") ? String(head.dropFirst("origin/".count)) : head)
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
            if let head = run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty
            {
                names.append(head.hasPrefix("origin/") ? String(head.dropFirst("origin/".count)) : head)
            }
            names.append(contentsOf: ["main", "master", "development"])
            return names
        }

        /// Worktree paths only, skipping the bare repository entry. Unlike
        /// `listWorktreesWithInfo` this runs a single git command — no per-worktree
        /// status probes — so it is cheap enough to call while resolving a project.
        private static func worktreePaths(at path: String) -> [String] {
            guard let output = run(args: ["worktree", "list", "--porcelain"], in: path) else { return [] }

            var paths: [String] = []
            var current: String?
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("worktree ") {
                    current = String(line.dropFirst("worktree ".count))
                } else if line == "bare" {
                    current = nil
                } else if line.isEmpty, let found = current {
                    paths.append(found)
                    current = nil
                }
            }
            if let current {
                paths.append(current)
            }
            return paths
        }

        /// Return the current branch name, or nil if detached or not a repo.
        static func currentBranch(at path: String) -> String? {
            guard let raw = run(args: ["rev-parse", "--abbrev-ref", "HEAD"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return raw == "HEAD" ? nil : raw
        }

        /// Delete a local branch by name.
        static func deleteLocalBranch(at path: String, branchName: String) {
            _ = run(args: ["branch", "-D", branchName], in: path)
        }

        /// Per-file git status for the file tree (modified, untracked, ignored).
        /// Returns an empty dictionary on failure so the tree degrades gracefully.
        static func fileStatuses(at path: String) -> [String: Git.FileStatus] {
            guard let output = runWithTimeout(
                args: ["status", "--porcelain", "--ignored", "--ignore-submodules=dirty"],
                in: path,
                timeout: 3
            ) else {
                return [:]
            }

            var result: [String: Git.FileStatus] = [:]
            for line in output.components(separatedBy: "\n") {
                guard line.count >= 4 else { continue }
                let xy = String(line.prefix(2))
                var filePath = String(line.dropFirst(3))

                if xy == "!!" {
                    // Ignored — strip trailing slash for directories
                    if filePath.hasSuffix("/") {
                        filePath = String(filePath.dropLast())
                    }
                    result[filePath] = .ignored
                } else if xy == "??" {
                    result[filePath] = .untracked
                } else {
                    result[renamedDestination(in: filePath)] = .modified
                }
            }
            return result
        }

        enum PullResult {
            case success(String)
            case failure(String)
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

        /// Fetch a branch from origin. Fails silently when there is no remote or
        /// the network is unreachable.
        ///
        /// With `branch` omitted, guesses at the origin's default branch (its
        /// symbolic HEAD, or "main") — used when the caller still needs to ask
        /// git what the default is. With `branch` given (e.g. a resolved
        /// `BaseBranchSetting`), fetches exactly that branch instead, stripping
        /// an `origin/` prefix if present since `git fetch origin <ref>` wants
        /// the bare name.
        static func fetchDefaultBranch(at path: String, branch: String? = nil) {
            // Check if origin remote exists first (fast, no network)
            guard run(args: ["remote", "get-url", "origin"], in: path) != nil else { return }

            // Determine which branch to fetch
            let branchToFetch: String = if let branch {
                branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch
            } else if let ref = run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path) {
                // e.g. "origin/main" -> "main"
                ref.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "origin/", with: "")
            } else {
                "main"
            }

            fetchBranch(at: path, branch: branchToFetch)
        }

        /// Fetch one named branch from origin. No-ops without a remote, and gives up rather
        /// than blocking a worktree creation that can proceed on stale refs.
        ///
        /// The 5s bound is much tighter than `ProcessRunner.Timeout.network`, and stays that
        /// way: every caller either has a stale ref to fall back on or a `rev-parse` that will
        /// report the miss, so waiting two minutes on a wedged link buys nothing.
        private static func fetchBranch(at path: String, branch: String) {
            guard run(args: ["remote", "get-url", "origin"], in: path) != nil else { return }
            let ref = branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch
            runWithTimeout(args: ["fetch", "origin", ref, "--no-tags"], in: path, timeout: 5)
        }

        /// Runs git and returns stdout, or nil if git is missing, exited non-zero,
        /// or outlived `timeout`.
        ///
        /// `ProcessRunner` owns the deadline and drains both pipes concurrently,
        /// which is what makes a large `git show`/`git status` safe: git blocks
        /// writing to a full pipe once its output passes the ~64 KB macOS buffer,
        /// so draining one stream while the other fills would wedge it.
        @discardableResult
        private static func runWithTimeout(args: [String], in directory: String, timeout: TimeInterval) -> String? {
            guard let gitPath else {
                logger.warning("[Atelier] git run: gitPath is nil")
                return nil
            }
            guard let output = ProcessRunner.capture(
                executable: gitPath,
                arguments: args,
                environment: gitEnvironment,
                currentDirectory: URL(fileURLWithPath: directory),
                timeout: timeout
            ) else { return nil }

            guard output.isSuccess else {
                logger.warning("[Atelier] git \(args.joined(separator: " "), privacy: .public) failed (exit \(output.status, privacy: .public)): \(output.stderrText, privacy: .public)")
                return nil
            }
            return String(data: output.stdout, encoding: .utf8)
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

        /// Git commands that write a whole working tree — `worktree add` checks one
        /// out, `worktree remove`, `reset --hard`, `checkout -- .` and `clean -fd`
        /// rewrite or delete one. How long they take is a property of the user's
        /// repository, so they get the loose tier; `run`'s minute would abort a
        /// legitimate checkout of a large repository partway through.
        private static func runOnWholeTree(args: [String], in directory: String) -> String? {
            runWithTimeout(args: args, in: directory, timeout: ProcessRunner.Timeout.userCommand)
        }
    }
}
