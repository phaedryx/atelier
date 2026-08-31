// ABOUTME: Clones a remote into the README's .bare container layout.
// ABOUTME: Produces <container>/{.bare, .git, <default-branch>} so every branch is a peer worktree.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "git.clone")

/// Clones a repository into the layout the README prescribes:
///
/// ```
/// <container>/
/// ├── .bare/      the git database (a bare clone)
/// ├── .git        "gitdir: ./.bare"
/// └── <default>/  the default branch, checked out as a worktree
/// ```
///
/// HEAD is parked on a `root` branch so the default branch is free to be
/// checked out as a peer worktree alongside every other branch.
enum BareRepoClone {
    enum CloneResult {
        case success(containerPath: String)
        case failure(String)
        /// The caller cancelled; the container has already been cleaned up and
        /// there is nothing to report to the user.
        case cancelled
    }

    /// Lets a caller stop a clone in flight.
    ///
    /// A clone is a chain of git subprocesses that can each block for a long
    /// time on the network, so cancelling means terminating whichever one is
    /// running. That makes the step fail, which unwinds through the same
    /// cleanup path as any other failure and removes the half-built container.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Process?
        private var isCancelled = false

        init() {}

        var cancelled: Bool {
            lock.withLock { isCancelled }
        }

        func cancel() {
            let process: Process? = lock.withLock {
                isCancelled = true
                return running
            }
            process?.terminate()
        }

        /// Returns false when cancellation already happened, so the caller can
        /// stop before launching another subprocess.
        fileprivate func track(_ process: Process) -> Bool {
            lock.withLock {
                guard !isCancelled else { return false }
                running = process
                return true
            }
        }

        fileprivate func clearTracking() {
            lock.withLock { running = nil }
        }
    }

    /// The `owner/repo` shorthand expands to this form, matching the README.
    private static let shorthandTemplate = "git@github.com:%@.git"

    // MARK: - Input handling

    /// Turns user input into something `git clone` accepts, or nil if it is not
    /// recognizable as a repository. URLs, scp-style SSH remotes, and local
    /// paths pass through untouched; `owner/repo` expands to a GitHub SSH URL.
    static func normalizeRemote(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // https://…, ssh://…, git://…, file://…
        if trimmed.contains("://") { return trimmed }

        // Local paths, including ~-relative ones.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix(".") { return trimmed }
        if trimmed.hasPrefix("~") { return (trimmed as NSString).expandingTildeInPath }

        // scp-style: git@host:owner/repo.git — the colon must come before any slash.
        if let colon = trimmed.firstIndex(of: ":"),
           trimmed.contains("@"),
           trimmed.firstIndex(of: "/").map({ colon < $0 }) ?? true
        {
            return trimmed
        }

        // owner/repo shorthand.
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        var repo = String(parts[1])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard isShorthandComponent(owner), isShorthandComponent(repo) else { return nil }
        return String(format: shorthandTemplate, "\(owner)/\(repo)")
    }

    private static func isShorthandComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The directory name a remote suggests: the last path component with any
    /// `.git` suffix removed. Nil when that yields nothing usable.
    static func suggestedDirectoryName(for remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }

        // Split on whichever separator comes last — scp-style remotes without a
        // path (git@host:repo.git) are delimited by the colon.
        if let separator = value.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            value = String(value[value.index(after: separator)...])
        }
        if value.hasSuffix(".git") { value.removeLast(4) }

        guard !value.isEmpty, value != ".", value != ".." else { return nil }
        return value
    }

    // MARK: - Clone

    /// Runs the README recipe into `container`, which must not already exist.
    ///
    /// On any failure the container is removed, so a half-built clone never
    /// lands in the base directory. An empty remote (no commits) stops after the
    /// bare clone: there is no branch to park HEAD on and nothing to check out.
    static func clone(remote: String, into container: URL, cancellation: Cancellation? = nil) -> CloneResult {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: container.path) else {
            return .failure(String(
                format: NSLocalizedString("A file or directory named “%@” already exists.", comment: ""),
                container.lastPathComponent
            ))
        }

        do {
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            return .failure(error.localizedDescription)
        }

        let path = container.path
        func abort(_ message: String) -> CloneResult {
            try? fm.removeItem(at: container)
            if cancellation?.cancelled == true { return .cancelled }
            logger.warning("[Atelier] bare clone failed: \(message, privacy: .public)")
            return .failure(message)
        }

        // 1. The git database itself.
        let cloned = run(["clone", "--bare", remote, ".bare"], in: path, cancellation: cancellation)
        guard cloned.ok else { return abort(cloned.message) }

        // 2. Point the container at it, so git commands work from the container
        //    and from every worktree beneath it.
        do {
            try "gitdir: ./.bare\n".write(to: container.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        } catch {
            return abort(error.localizedDescription)
        }

        // 3. A bare clone has no fetch refspec, so remote-tracking refs would
        //    never be populated — and defaultBranch() looks for origin/*.
        let configured = run(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: path, cancellation: cancellation)
        guard configured.ok else { return abort(configured.message) }

        let fetched = run(["fetch", "--all", "--prune"], in: path, cancellation: cancellation)
        guard fetched.ok else { return abort(fetched.message) }

        // 4. An empty remote has no commits: stop with the container usable.
        //    A terminated probe looks the same as an empty repo, so rule that
        //    out before calling this a success.
        guard run(["rev-parse", "--verify", "HEAD"], in: path, cancellation: cancellation).ok else {
            if cancellation?.cancelled == true { return abort("cancelled") }
            return .success(containerPath: path)
        }

        let head = run(["symbolic-ref", "--short", "HEAD"], in: path, cancellation: cancellation)
        guard head.ok else { return abort(head.message) }
        let defaultBranch = head.output
        guard !defaultBranch.isEmpty else {
            return abort(NSLocalizedString("Could not determine the repository's default branch.", comment: ""))
        }

        // 5. Park HEAD on `root` so the default branch is free to be checked out
        //    as a worktree like any other branch.
        let recorded = run(["config", "wt.default", defaultBranch], in: path, cancellation: cancellation)
        guard recorded.ok else { return abort(recorded.message) }

        if !run(["rev-parse", "--verify", "refs/heads/root"], in: path, cancellation: cancellation).ok {
            let branched = run(["branch", "root", defaultBranch], in: path, cancellation: cancellation)
            guard branched.ok else { return abort(branched.message) }
        }

        let parked = run(["symbolic-ref", "HEAD", "refs/heads/root"], in: path, cancellation: cancellation)
        guard parked.ok else { return abort(parked.message) }

        // 6. The default branch becomes the first peer worktree.
        // Name the branch explicitly: `worktree add <path>` alone infers the
        // branch from the path's last component, so a slashed default branch
        // like release/1.0 would create a stray `1.0` off the parked HEAD.
        let added = run(["worktree", "add", defaultBranch, defaultBranch], in: path, cancellation: cancellation)
        guard added.ok else { return abort(added.message) }

        return .success(containerPath: path)
    }

    // MARK: - Private

    /// Holds a pipe's contents across the thread that drains it.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs git, keeping stderr so failures can be shown to the user rather
    /// than only logged — a clone fails for reasons they need to read.
    private static func run(
        _ args: [String],
        in directory: String,
        cancellation: Cancellation? = nil
    ) -> (ok: Bool, output: String, message: String) {
        guard let gitPath = CommandLineTools.path(for: "git") else {
            return (false, "", NSLocalizedString("git was not found on your PATH.", comment: ""))
        }

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Never prompt for credentials: a GUI app has no terminal to answer on,
        // so an auth failure must come back as an error instead of hanging.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        process.environment = environment

        guard cancellation?.track(process) ?? true else {
            return (false, "", "cancelled")
        }
        defer { cancellation?.clearTracking() }

        do {
            try process.run()
        } catch {
            return (false, "", error.localizedDescription)
        }

        // Drain the two pipes CONCURRENTLY. Reading one to EOF — which only
        // happens when git exits — while the other fills is a deadlock: git
        // blocks writing to a full pipe, we block reading the empty one.
        //
        // This is not hypothetical. `git fetch --all --prune` below runs right
        // after a bare clone gains its refspec, so every branch is new and git
        // prints a " * [new branch]" line per branch to *stderr*: 228 KB for a
        // 4,000-branch repo, against a 16-64 KB pipe buffer. Draining stdout
        // first wedges the clone with no timeout and no way to cancel.
        let errBox = DataBox()
        let errDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDrained.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDrained.wait()
        let errData = errBox.data
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let reason = err.isEmpty
                ? String(
                    format: NSLocalizedString("git %@ failed (exit %d)", comment: ""),
                    args.joined(separator: " "),
                    process.terminationStatus
                )
                : err
            return (false, out, reason)
        }
        return (true, out, err)
    }
}
