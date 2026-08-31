// ABOUTME: Git operations for project and workstream management.
// ABOUTME: Handles repo detection, init, worktree create/remove, and repo info.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "git")

struct GitRepoInfo {
    let isRepo: Bool
    let branch: String?
    let remoteURL: String?
    let commitCount: Int?
    let isDirty: Bool
}

struct WorktreeInfo: Identifiable {
    let path: String
    let branch: String?
    let isDirty: Bool
    let isMain: Bool
    let hasUnpushedCommits: Bool
    let hasBranchCommits: Bool

    var id: String {
        path
    }

    var standardizedPath: String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Where a project should be registered, and what to call it.
///
/// These differ in the `.bare` container layout, where the directory the user
/// points at (`<container>`) is a bare repository with no work tree: the project
/// lives in the default branch's checkout, but keeps the container's name.
struct ProjectLocation: Equatable {
    let directory: String
    let name: String
    /// The `.bare` container this checkout sits in, when the path resolved
    /// forward out of one. Projects saved before that resolution existed point
    /// at the container, so callers can match them without re-running git.
    let containerDirectory: String?

    init(directory: String, name: String, containerDirectory: String? = nil) {
        self.directory = directory
        self.name = name
        self.containerDirectory = containerDirectory
    }
}

struct WorktreeDetail {
    struct FileChange: Identifiable {
        enum Status: String {
            case modified = "M"
            case added = "A"
            case deleted = "D"
            case renamed = "R"
            case untracked = "??"

            var icon: String {
                switch self {
                case .modified: return "pencil"
                case .added: return "plus"
                case .deleted: return "minus"
                case .renamed: return "arrow.right"
                case .untracked: return "questionmark"
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
}

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

enum GitOperations {
    private static var gitPath: String? {
        CommandLineTools.path(for: "git")
    }

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
    static func repoInfo(at path: String) -> GitRepoInfo {
        guard isGitRepo(at: path) else {
            return GitRepoInfo(isRepo: false, branch: nil, remoteURL: nil, commitCount: nil, isDirty: false)
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
        let isDirty = status.map { !$0.isEmpty } ?? false

        return GitRepoInfo(
            isRepo: true,
            branch: branch,
            remoteURL: remote,
            commitCount: commitCount,
            isDirty: isDirty
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
    static func branchDiffFiles(worktreePath: String, projectPath: String) -> [DiffFile] {
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
    static func uncommittedDiffFiles(at path: String) -> [DiffFile] {
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
        guard let sha = run(args: ["merge-base", base, "HEAD"], in: worktreePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !sha.isEmpty
        else {
            return nil
        }
        return sha
    }

    // MARK: - Diff fingerprint (cache invalidation)

    /// Fast (~10ms) cache key for the Changes view: HEAD SHA plus a hash of
    /// `git diff --stat` and the untracked-file list (both modes). Reads no file
    /// contents. Tolerates an unborn/empty HEAD and non-repo paths by returning a
    /// stable (non-empty) string rather than crashing.
    ///
    /// Both modes fold in `ls-files --others --exclude-standard` so that adding
    /// or removing an untracked file moves the fingerprint — matching the diff
    /// listing, which unions untracked files in for both modes (Hardening 1).
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
        let stat = tracked + untracked

        // Not cryptographic — just enough to detect changes between tab visits.
        return "\(head)|\(stat.count)|\(stat.hashValue)"
    }

    // MARK: - Diff listing helpers

    /// Parse `git diff --name-status` output into DiffFiles.
    /// Each line is `<STATUS>\t<path>` or, for renames, `R###\t<old>\t<new>`.
    private static func parseNameStatus(_ output: String) -> [DiffFile] {
        var files: [DiffFile] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: true)
            guard let statusField = fields.first else { continue }
            let statusChar = statusField.prefix(1)
            switch statusChar {
            case "A":
                if fields.count >= 2 { files.append(DiffFile(relativePath: String(fields[1]), status: .added)) }
            case "M":
                if fields.count >= 2 { files.append(DiffFile(relativePath: String(fields[1]), status: .modified)) }
            case "D":
                if fields.count >= 2 { files.append(DiffFile(relativePath: String(fields[1]), status: .deleted)) }
            case "R":
                // Rename: use the new path (last field).
                if fields.count >= 3 { files.append(DiffFile(relativePath: String(fields[2]), status: .renamed)) }
            default:
                continue
            }
        }
        return files
    }

    /// Union untracked files (`git ls-files --others --exclude-standard`) into
    /// the list as `.added`, skipping any path already present (Hardening 1).
    private static func appendUntrackedFiles(into files: inout [DiffFile], at path: String) {
        guard let output = run(args: ["ls-files", "--others", "--exclude-standard"], in: path) else {
            return
        }
        let existing = Set(files.map { $0.relativePath })
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let filePath = String(rawLine)
            guard !filePath.isEmpty, !existing.contains(filePath) else { continue }
            files.append(DiffFile(relativePath: filePath, status: .added))
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
        _ files: inout [DiffFile],
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
        if content.isEmpty { return 0 }
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

    /// Create a git worktree for a workstream, branching off the default branch.
    /// Returns the worktree path on success, nil on failure.
    static func createWorktree(projectPath: String, projectName: String, workstreamName: String) -> String? {
        let worktreeDir = worktreeDestination(
            projectPath: projectPath,
            projectName: projectName,
            workstreamName: workstreamName
        )

        let branchName = workstreamName

        // Fetch the default branch so worktrees start from the latest remote ref
        fetchDefaultBranch(at: projectPath)

        let baseBranch = defaultBranch(at: projectPath)

        // Create parent directories
        try? FileManager.default.createDirectory(
            at: worktreeDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Create worktree with new branch based off the default branch
        let result = run(args: ["worktree", "add", "-b", branchName, worktreeDir.path, baseBranch], in: projectPath)

        if result == nil {
            // Branch might already exist, try without -b
            let fallback = run(args: ["worktree", "add", worktreeDir.path, branchName], in: projectPath)
            guard fallback != nil else { return nil }
        }

        addExcludeEntry(at: projectPath, pattern: ".atelier-state/")
        // The seed directory holds .env files at the repo root; without this it
        // shows up untracked in every `git status`, one `git add -A` from being committed.
        addExcludeEntry(at: projectPath, pattern: WorktreeSetupConfig.defaultSeedDirectory + "/")

        return worktreeDir.path
    }

    /// Exclude a project's configured seed directory from git, so a custom
    /// `"seed"` path is hidden the same way the default one is. A seed outside
    /// the project directory needs no exclude and is skipped.
    static func excludeSeedDirectory(_ seedDirectory: String, inProject projectPath: String) {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let seed = URL(fileURLWithPath: seedDirectory).standardizedFileURL.path
        guard seed.hasPrefix(project + "/") else { return }
        let relative = String(seed.dropFirst(project.count + 1))
        guard !relative.isEmpty else { return }
        addExcludeEntry(at: projectPath, pattern: relative + "/")
    }

    /// Append a pattern to the repo's info/exclude if not already present.
    static func addExcludeEntry(at repoPath: String, pattern: String) {
        // Ask git where the file lives rather than assuming `.git` is a
        // directory — in a worktree, and in the .bare container layout, it is a
        // file pointing elsewhere, and the hardcoded path silently goes nowhere.
        let excludeURL: URL
        if let gitPath = run(args: ["rev-parse", "--git-path", "info/exclude"], in: repoPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !gitPath.isEmpty
        {
            excludeURL = gitPath.hasPrefix("/")
                ? URL(fileURLWithPath: gitPath)
                : URL(fileURLWithPath: repoPath).appendingPathComponent(gitPath).standardized
        } else {
            excludeURL = URL(fileURLWithPath: repoPath).appendingPathComponent(".git/info/exclude")
        }
        let fm = FileManager.default

        // Ensure the info directory exists
        let infoDir = excludeURL.deletingLastPathComponent()
        try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let lines = existing.components(separatedBy: .newlines)
        if lines.contains(pattern) { return }

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
    static func removeWorktree(projectPath: String, worktreePath: String) {
        let worktreeDir = URL(fileURLWithPath: worktreePath)

        _ = run(args: ["worktree", "remove", "--force", worktreePath], in: projectPath)

        // Clean up empty directories
        try? FileManager.default.removeItem(at: worktreeDir)
        let parentDir = worktreeDir.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: parentDir)
        }
    }

    /// Check if a worktree has uncommitted changes (staged, unstaged, or untracked files).
    static func hasUncommittedChanges(at path: String) -> Bool {
        guard let status = run(args: ["status", "--porcelain", "--ignore-submodules=dirty"], in: path) else { return false }
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get detailed changes and unmerged commits for a worktree.
    static func worktreeDetail(at worktreePath: String, mainRepoPath: String) -> WorktreeDetail {
        var changes: [WorktreeDetail.FileChange] = []

        if let status = run(args: ["status", "--porcelain"], in: worktreePath) {
            for line in status.components(separatedBy: "\n") where !line.isEmpty {
                let trimmed = line
                guard trimmed.count >= 3 else { continue }

                let indexStatus = trimmed[trimmed.startIndex]
                let workTreeStatus = trimmed[trimmed.index(after: trimmed.startIndex)]
                let filePath = String(trimmed.dropFirst(3))

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

        var commits: [WorktreeDetail.UnmergedCommit] = []
        let baseBranch = defaultBranch(at: mainRepoPath)
        if let log = run(args: ["log", "\(baseBranch)..HEAD", "--oneline"], in: worktreePath) {
            for line in log.components(separatedBy: "\n") where !line.isEmpty {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                commits.append(.init(hash: String(parts[0]), message: String(parts[1])))
            }
        }

        return WorktreeDetail(changes: changes, unmergedCommits: commits)
    }

    /// Force-remove a git worktree by path, discarding uncommitted changes.
    static func forceRemoveWorktreeByPath(worktreePath: String, projectPath: String) {
        _ = run(args: ["worktree", "remove", "--force", worktreePath], in: projectPath)

        let fm = FileManager.default
        if fm.fileExists(atPath: worktreePath) {
            try? fm.removeItem(atPath: worktreePath)
            _ = run(args: ["worktree", "prune"], in: projectPath)
        }
    }

    /// Discard all uncommitted changes: reset staged, checkout unstaged, clean untracked.
    static func discardAllChanges(at path: String) {
        _ = run(args: ["reset", "HEAD"], in: path)
        _ = run(args: ["checkout", "--", "."], in: path)
        _ = run(args: ["clean", "-fd"], in: path)
    }

    private static func parseStatus(_ char: Character) -> WorktreeDetail.FileChange.Status {
        switch char {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        default: return .modified
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

    /// Check if the current branch has commits ahead of the default branch.
    static func hasBranchCommits(at path: String, projectPath: String) -> Bool {
        let base = defaultBranch(at: projectPath)
        guard let output = run(args: ["log", "\(base)..HEAD", "--oneline"], in: path) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Check if a remote exists for this repository.
    static func hasRemote(at path: String) -> Bool {
        guard let output = run(args: ["remote"], in: path) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Push the current branch to origin, setting upstream if needed.
    static func pushCurrentBranch(at path: String) -> (success: Bool, output: String) {
        guard let gitPath else { return (false, "git not found") }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", path, "push", "-u", "origin", "HEAD"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// List existing worktrees for a project with branch and dirty status.
    static func listWorktreesWithInfo(at projectPath: String) -> [WorktreeInfo] {
        guard let output = run(args: ["worktree", "list", "--porcelain"], in: projectPath) else {
            return []
        }

        let mainPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path

        var results: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var currentIsBare = false

        /// In the .bare container layout the bare repository is itself an entry
        /// in `worktree list`. It has no work tree and no branch, so it must not
        /// be surfaced as a workstream.
        func flush() {
            guard let path = currentPath, !currentIsBare else { return }
            let isMain = URL(fileURLWithPath: path).standardizedFileURL.path == mainPath
            let dirty = !isMain && hasUncommittedChanges(at: path)
            let unpushed = !isMain && hasUnpushedCommits(at: path)
            let branchCommits = !isMain && hasBranchCommits(at: path, projectPath: projectPath)
            results.append(WorktreeInfo(path: path, branch: currentBranch, isDirty: dirty, isMain: isMain, hasUnpushedCommits: unpushed, hasBranchCommits: branchCommits))
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
    @discardableResult
    static func pruneCleanWorktrees(at projectPath: String, onlyPaths: Set<String>? = nil) -> Int {
        let worktrees = listWorktreesWithInfo(at: projectPath)
        let allowedPaths = onlyPaths.map { paths in
            Set(paths.map { path in
                URL(fileURLWithPath: path).standardizedFileURL.path
            })
        }
        var pruned = 0
        for wt in worktrees where !wt.isMain && !wt.isDirty && !wt.hasBranchCommits {
            let standardizedPath = URL(fileURLWithPath: wt.path).standardizedFileURL.path
            if let allowedPaths, !allowedPaths.contains(standardizedPath) {
                continue
            }
            let result = run(args: ["worktree", "remove", wt.path], in: projectPath)
            if result != nil {
                pruned += 1
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

        let commonURL: URL
        if commonDir.hasPrefix("/") {
            commonURL = URL(fileURLWithPath: commonDir)
        } else {
            commonURL = URL(fileURLWithPath: path).appendingPathComponent(commonDir).standardized
        }

        return commonURL.deletingLastPathComponent().standardizedFileURL.path
    }

    /// Resolve any path the user points at — a repo, a worktree, or a `.bare`
    /// container — to the directory the project should be registered under.
    ///
    /// Worktrees resolve to their main repository, as before. A `.bare`
    /// container has no work tree of its own (`git status` there fails outright
    /// and HEAD reads as the parked `root` branch), so it resolves *forward* to
    /// its default checkout instead, while keeping the container's name.
    static func projectLocation(for path: String) -> ProjectLocation {
        let container = mainRepositoryPath(for: path) ?? path

        guard isBareRepository(at: container) else {
            return ProjectLocation(directory: container, name: URL(fileURLWithPath: container).lastPathComponent)
        }

        let name = URL(fileURLWithPath: container).lastPathComponent
        guard let checkout = defaultCheckoutPath(in: container) else {
            return ProjectLocation(directory: container, name: name)
        }
        return ProjectLocation(directory: checkout, name: name, containerDirectory: container)
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
        if let current { paths.append(current) }
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

    /// Fetch the default branch from origin, fast-forward the local ref to match,
    /// and reset the working tree if it is clean. Fails silently when there is no
    /// remote, the network is unreachable, or the working tree has local changes.
    static func updateDefaultBranch(at path: String) {
        guard run(args: ["remote", "get-url", "origin"], in: path) != nil else { return }

        let branch: String
        if let ref = run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path) {
            branch = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "origin/", with: "")
        } else if run(args: ["rev-parse", "--verify", "refs/heads/main"], in: path) != nil {
            branch = "main"
        } else if run(args: ["rev-parse", "--verify", "refs/heads/master"], in: path) != nil {
            branch = "master"
        } else {
            return
        }

        // Fetch with timeout so we don't block the UI
        guard runWithTimeout(args: ["fetch", "origin", branch, "--no-tags"], in: path, timeout: 5) != nil else {
            return
        }

        // Move the local ref to match origin
        guard run(args: ["update-ref", "refs/heads/\(branch)", "refs/remotes/origin/\(branch)"], in: path) != nil else {
            return
        }

        // Reset the working tree only if it is clean
        if !hasUncommittedChanges(at: path) {
            _ = run(args: ["reset", "--hard", "--quiet"], in: path)
            logger.info("[Atelier] Updated \(branch, privacy: .public) to latest")
        } else {
            logger.info("[Atelier] Updated \(branch, privacy: .public) ref but working tree has local changes, skipping reset")
        }
    }

    /// Per-file git status for the file tree (modified, untracked, ignored).
    /// Returns an empty dictionary on failure so the tree degrades gracefully.
    static func fileStatuses(at path: String) -> [String: FileGitStatus] {
        guard let output = runWithTimeout(
            args: ["status", "--porcelain", "--ignored", "--ignore-submodules=dirty"],
            in: path,
            timeout: 3
        ) else {
            return [:]
        }

        var result: [String: FileGitStatus] = [:]
        for line in output.components(separatedBy: "\n") {
            guard line.count >= 4 else { continue }
            let xy = String(line.prefix(2))
            var filePath = String(line.dropFirst(3))

            if xy == "!!" {
                // Ignored — strip trailing slash for directories
                if filePath.hasSuffix("/") { filePath = String(filePath.dropLast()) }
                result[filePath] = .ignored
            } else if xy == "??" {
                result[filePath] = .untracked
            } else {
                // Handle renames/copies: "R  old -> new" or "C  old -> new"
                if let arrowRange = filePath.range(of: " -> ") {
                    let newPath = String(filePath[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    result[newPath] = .modified
                } else {
                    result[filePath] = .modified
                }
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
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["pull", "--ff-only"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                let msg = out.isEmpty ? err : out
                return .success(msg)
            }
            let reason = err.isEmpty ? "git pull failed (exit \(process.terminationStatus))" : err
            return .failure(reason)
        } catch {
            return .failure("\(error)")
        }
    }

    // MARK: - Private

    /// Fetch the default branch from origin. Fails silently when there is no
    /// remote or the network is unreachable.
    static func fetchDefaultBranch(at path: String) {
        // Check if origin remote exists first (fast, no network)
        guard run(args: ["remote", "get-url", "origin"], in: path) != nil else { return }

        // Determine which branch to fetch
        let branch: String
        if let ref = run(args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], in: path) {
            // e.g. "origin/main" -> "main"
            branch = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "origin/", with: "")
        } else {
            branch = "main"
        }

        // Fetch with timeout — don't block worktree creation
        runWithTimeout(args: ["fetch", "origin", branch, "--no-tags"], in: path, timeout: 5)
    }

    @discardableResult
    private static func runWithTimeout(args: [String], in directory: String, timeout: TimeInterval) -> String? {
        guard let gitPath else { return nil }
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            logger.info("[Atelier] git \(args.joined(separator: " "), privacy: .public) timed out after \(timeout, privacy: .public)s")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Validates a candidate workstream name for use as a git branch name.
    /// Follows git check-ref-format rules; empty names are invalid (callers
    /// treat empty as "generate a random name instead").
    static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let forbiddenCharacters = CharacterSet(charactersIn: " ~^:?*[\\")
        if name.rangeOfCharacter(from: forbiddenCharacters) != nil { return false }
        if name.contains("..") || name.contains("@{") || name.contains("//") { return false }
        if name.hasPrefix("-") { return false }
        if name.hasSuffix(".") || name.hasSuffix("/") || name.hasSuffix(".lock") { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 }) { return false }
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

    private static func run(args: [String], in directory: String) -> String? {
        guard let gitPath else {
            logger.warning("[Atelier] git run: gitPath is nil")
            return nil
        }
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            // Drain stdout AND stderr to end BEFORE waitUntilExit() to avoid a
            // deadlock when git output exceeds the ~64 KB macOS pipe buffer
            // (e.g. `git show`/`git diff` on large files): the child blocks on a
            // full pipe while we'd be blocked waiting for it to exit. The reads
            // block only until the child closes each fd, which it does on exit.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                logger.warning("[Atelier] git \(args.joined(separator: " "), privacy: .public) failed (exit \(process.terminationStatus, privacy: .public)): \(errStr, privacy: .public)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            logger.warning("[Atelier] git \(args.joined(separator: " "), privacy: .public) threw: \(error, privacy: .public)")
            return nil
        }
    }
}
