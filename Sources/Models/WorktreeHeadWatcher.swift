// ABOUTME: Watches each worktree's git directory so a branch rename shows up immediately.
// ABOUTME: Fires a debounced callback per worktree path; the 15s poll stays as the backstop.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "head-watcher")

/// Watches the git directory of every registered worktree and reports the ones
/// whose contents changed, so the app can re-read the branch immediately instead
/// of waiting out the 15s refresh.
///
/// **Why the directory and not HEAD itself.** `git branch -m` and `git checkout`
/// replace HEAD through a lockfile — write `HEAD.lock`, rename it over `HEAD` —
/// which swaps the inode out from under any descriptor opened on the old file.
/// A watch on the directory survives that, and costs one descriptor per worktree
/// instead of two (compare `PortDetector`, which watches a single fixed file and
/// therefore has to reattach when it is replaced).
///
/// **The callback is a hint, not a diff.** That directory is noisy: ordinary git
/// activity in the worktree rewrites `index` and friends, so this fires during
/// routine agent work with HEAD unchanged. Debouncing keeps a burst to one
/// callback; the receiver is responsible for doing something cheap and for
/// no-oping when the branch did not actually change.
final class WorktreeHeadWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "atelier.worktree-head-watcher")
    private let onChange: @Sendable (String) -> Void
    private let debounce: DispatchTimeInterval

    /// worktree path -> its active watch (mutated only on `queue`)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    /// worktree path -> pending debounced callback (mutated only on `queue`)
    private var pending: [String: DispatchWorkItem] = [:]

    init(debounce: DispatchTimeInterval = .milliseconds(200), onChange: @escaping @Sendable (String) -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        for source in sources.values {
            source.cancel()
        }
        for work in pending.values {
            work.cancel()
        }
    }

    /// The git directory holding HEAD for the worktree at `path`, or nil when
    /// there is no resolvable one.
    ///
    /// In a plain clone `.git` is a directory. In a linked worktree — which is
    /// what Atelier creates — it is a file containing `gitdir: <path>`, and HEAD
    /// lives at that target, not in the worktree. A relative pointer resolves
    /// against the worktree directory.
    static func gitDirectory(forWorktreeAt path: String) -> String? {
        let dotGit = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return dotGit.path
        }

        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") {
            return target
        }
        return URL(fileURLWithPath: path).appendingPathComponent(target).standardizedFileURL.path
    }

    /// Reconcile the watched set to exactly `paths`: attach watches for new
    /// worktrees, cancel those no longer present. Safe to call repeatedly; an
    /// already-watched path keeps its existing watch untouched.
    func sync(paths: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            for path in sources.keys where !paths.contains(path) {
                self.sources.removeValue(forKey: path)?.cancel()
                self.pending.removeValue(forKey: path)?.cancel()
            }
            for path in paths where sources[path] == nil {
                self.attach(to: path)
            }
        }
    }

    /// Watched worktree paths. Test seam: `sync` lands on `queue`, so this
    /// blocks until the pending reconcile has run.
    var watchedPathsForTesting: Set<String> {
        queue.sync { Set(sources.keys) }
    }

    // MARK: - Private

    /// Must run on `queue`.
    private func attach(to worktreePath: String) {
        guard let gitDirectory = Self.gitDirectory(forWorktreeAt: worktreePath) else { return }
        let descriptor = open(gitDirectory, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.detailed("Could not open \(gitDirectory) to watch HEAD")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleNotify(for: worktreePath)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources[worktreePath] = source
        source.resume()
    }

    /// Must run on `queue`. Collapses a burst of filesystem events into one
    /// callback per worktree.
    private func scheduleNotify(for worktreePath: String) {
        pending.removeValue(forKey: worktreePath)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending.removeValue(forKey: worktreePath)
            // Re-check membership: the path may have been unwatched while this
            // was waiting out the debounce.
            guard sources[worktreePath] != nil else { return }
            onChange(worktreePath)
        }
        pending[worktreePath] = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
