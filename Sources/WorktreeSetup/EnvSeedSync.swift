// ABOUTME: rsyncs a project's seed directory into a new worktree.
// ABOUTME: Carries .env files in as real files; no seed directory means nothing is copied.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "vibe.envseed")

enum EnvSeedSync {
    /// Absolute path — a GUI app inherits a minimal PATH from launchd, so the
    /// binary is never looked up by name.
    private static let rsyncPath = "/usr/bin/rsync"

    /// Whether new worktrees get the project's seed directory rsync'd in.
    static let defaultsKey = "atelier.copyEnvFiles"

    /// rsync's "partial transfer" exit codes. One unreadable file or dangling
    /// symlink in a hand-maintained seed produces these while every other file
    /// still arrives, so they are not the same as a failed run.
    private static let partialTransferExitCodes: Set<Int32> = [23, 24]

    /// What a sync attempt did. `noSeedDirectory` and a failed run are
    /// deliberately distinct: both copy zero files, but only one is a problem.
    enum Outcome: Equatable {
        case noSeedDirectory
        case copied(Int)
        case partial(copied: Int, reason: String)
        case failed(reason: String)

        var copiedCount: Int {
            switch self {
            case .noSeedDirectory, .failed: return 0
            case let .copied(count): return count
            case let .partial(count, _): return count
            }
        }

        /// Non-nil when the caller should surface something to the user.
        var problemDescription: String? {
            switch self {
            case .noSeedDirectory, .copied: return nil
            case let .partial(count, reason):
                return "Some seed files were not copied (\(count) copied): \(reason)"
            case let .failed(reason):
                return "Failed to copy seed files: \(reason)"
            }
        }
    }

    /// Whether the seed directory should be synced into new worktrees. On by default.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// rsync the contents of `seedDirectory` into `worktreeDir`.
    ///
    /// Files already in the worktree win — the seed fills gaps, it does not
    /// overwrite. Symlinks are dereferenced on the way in, so what lands in the
    /// worktree is always a real file, both for links inside the seed and for
    /// `.env` symlinks left behind by builds that predate this.
    static func sync(seedDirectory: String, to worktreeDir: String) -> Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: seedDirectory, isDirectory: &isDir), isDir.boolValue else {
            logger.info("No seed directory at \(seedDirectory, privacy: .public); nothing to copy")
            return .noSeedDirectory
        }

        let seedFiles = relativeFilePaths(under: seedDirectory)
        guard !seedFiles.isEmpty else { return .copied(0) }

        // Anything absent now and present afterwards was copied by this run.
        let absentBefore = seedFiles.filter { !exists(at: (worktreeDir as NSString).appendingPathComponent($0)) }
        // Symlinks left by older builds. `--ignore-existing` treats a symlink as
        // existing content and skips it, so they are swapped out afterwards —
        // afterwards, not before, so a failed rsync never leaves the worktree
        // with neither the symlink nor a real file.
        let staleSymlinks = seedFiles.filter { isSymlink(at: (worktreeDir as NSString).appendingPathComponent($0)) }
        // `-p` applies the seed's modes to directories that already exist in the
        // worktree, so a seed at 0700 would clamp the worktree root. rsync's
        // --chmod would fix this but openrsync rejects it, so restore by hand.
        let directoryModes = existingDirectoryModes(for: seedFiles, under: worktreeDir)

        let result = runRsync(from: seedDirectory, to: worktreeDir)

        if case let .failure(reason) = result {
            restore(directoryModes)
            logger.warning("rsync from \(seedDirectory, privacy: .public) failed: \(reason, privacy: .public)")
            return .failed(reason: reason)
        }

        var copied = absentBefore.filter { exists(at: (worktreeDir as NSString).appendingPathComponent($0)) }.count
        copied += replaceStaleSymlinks(staleSymlinks, seedDirectory: seedDirectory, worktreeDir: worktreeDir)
        restore(directoryModes)

        if case let .partial(reason) = result {
            logger.warning("rsync partially copied \(seedDirectory, privacy: .public): \(reason, privacy: .public)")
            return .partial(copied: copied, reason: reason)
        }

        logger.info("Copied \(copied) seed file(s) from \(seedDirectory, privacy: .public) to \(worktreeDir, privacy: .public)")
        return .copied(copied)
    }

    // MARK: - rsync

    private enum RsyncResult {
        case success
        case partial(String)
        case failure(String)
    }

    /// Every flag here is accepted by both the rsync 2.6.9 that ships with the
    /// minimum supported macOS and the openrsync that replaced it later. Notably
    /// `--out-format` (rsync 3.0+) and `--chmod` (absent from openrsync) are not,
    /// which is why the copied count comes from the filesystem instead.
    private static func runRsync(from seedDirectory: String, to worktreeDir: String) -> RsyncResult {
        // The trailing slash on the source is load-bearing: it copies the seed's
        // *contents* into the worktree rather than nesting the seed directory itself.
        let arguments = [
            "-rlpt",
            "--omit-dir-times",
            "--copy-links",
            "--ignore-existing",
            trailingSlash(seedDirectory),
            trailingSlash(worktreeDir),
        ]

        // Bounded at the user-command tier: the seed's size is the user's to
        // choose, so the deadline is generous and only catches a true wedge.
        // `ProcessRunner` drains stdout and stderr concurrently, which is what
        // keeps a chatty rsync from filling a pipe nobody is reading.
        guard let output = ProcessRunner.capture(
            executable: rsyncPath,
            arguments: arguments,
            timeout: ProcessRunner.Timeout.userCommand
        ) else {
            return .failure(NSLocalizedString("rsync did not finish in time.", comment: ""))
        }

        let status = output.status
        if status == 0 { return .success }
        let stderr = output.stderrText.isEmpty ? "rsync exit \(status)" : output.stderrText
        if partialTransferExitCodes.contains(status) {
            return .partial(stderr)
        }
        return .failure(stderr)
    }

    private static func trailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: - Stale symlinks

    /// Swap each symlink for a real copy of the seed's file, writing the copy
    /// first and replacing atomically so a failure leaves the symlink intact.
    private static func replaceStaleSymlinks(
        _ relativePaths: [String],
        seedDirectory: String,
        worktreeDir: String
    ) -> Int {
        let fm = FileManager.default
        var replaced = 0

        for relative in relativePaths {
            let source = (seedDirectory as NSString).appendingPathComponent(relative)
            let destination = (worktreeDir as NSString).appendingPathComponent(relative)
            // `contents(atPath:)` follows symlinks, so a link inside the seed
            // yields the file it points at rather than the link itself.
            guard let data = fm.contents(atPath: source) else { continue }

            let resolved = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
            let mode = (try? fm.attributesOfItem(atPath: resolved))?[.posixPermissions]
            let staging = URL(fileURLWithPath: destination + ".atelier-seed-staging")
            try? fm.removeItem(at: staging)

            guard fm.createFile(
                atPath: staging.path,
                contents: data,
                attributes: mode.map { [.posixPermissions: $0] }
            ) else { continue }

            // The replacement bytes are already on disk at this point, so the
            // symlink is only unlinked once there is something to put in its
            // place. `replaceItemAt` is not usable here: it resolves a symlink
            // original and would rewrite the file the link points at.
            do {
                try? fm.removeItem(atPath: destination)
                try fm.moveItem(atPath: staging.path, toPath: destination)
                replaced += 1
                logger.info("Replaced symlinked \(relative, privacy: .public) with a copy")
            } catch {
                try? fm.removeItem(at: staging)
                logger.warning("Failed to replace symlinked \(relative, privacy: .public): \(error, privacy: .public)")
            }
        }

        return replaced
    }

    // MARK: - Filesystem helpers

    /// Every regular file under `directory`, as paths relative to it.
    static func relativeFilePaths(under directory: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []

        func walk(_ current: String, prefix: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: current) else { return }
            for name in names.sorted() {
                let full = (current as NSString).appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : (prefix as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                // Follows symlinks, matching --copy-links: a linked directory in
                // the seed is walked as a directory.
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    walk(full, prefix: relative)
                } else {
                    results.append(relative)
                }
            }
        }

        walk(directory, prefix: "")
        return results
    }

    /// Modes of the worktree directories the sync will write into, for the ones
    /// that already exist. Directories rsync creates are left alone.
    private static func existingDirectoryModes(for relativePaths: [String], under worktreeDir: String) -> [String: NSNumber] {
        let fm = FileManager.default
        var directories: Set<String> = [worktreeDir]

        for relative in relativePaths {
            var parent = (relative as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                directories.insert((worktreeDir as NSString).appendingPathComponent(parent))
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        var modes: [String: NSNumber] = [:]
        for path in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
            else { continue }
            modes[path] = mode
        }
        return modes
    }

    private static func restore(_ directoryModes: [String: NSNumber]) {
        for (path, mode) in directoryModes {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }

    private static func exists(at path: String) -> Bool {
        // `fileExists` follows symlinks and so misses a broken one; check both.
        FileManager.default.fileExists(atPath: path) || isSymlink(at: path)
    }

    private static func isSymlink(at path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}
