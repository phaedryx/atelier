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

    /// The pre-rsync name of the same toggle, when it symlinked `.env` and
    /// `.env.local` instead of copying a seed directory. Read once by
    /// `migrateDefaults` so an explicit opt-out survives the rename.
    private static let legacyDefaultsKey = "atelier.symlinkEnv"

    /// Adopt the value of the old `atelier.symlinkEnv` toggle if the current one
    /// has never been set. Idempotent; call once at launch.
    static func migrateDefaults(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: defaultsKey) == nil,
              let legacy = defaults.object(forKey: legacyDefaultsKey) as? Bool
        else { return }
        defaults.set(legacy, forKey: defaultsKey)
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
    ///
    /// - Returns: the number of files copied. Zero when the project has no seed
    ///   directory, which is the normal case for a project that never made one.
    @discardableResult
    static func sync(seedDirectory: String, to worktreeDir: String) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: seedDirectory, isDirectory: &isDir), isDir.boolValue else {
            logger.info("No seed directory at \(seedDirectory, privacy: .public); nothing to copy")
            return 0
        }

        removeSymlinkedDestinations(seedBase: seedDirectory, currentDir: seedDirectory, worktreeBase: worktreeDir)

        // The trailing slash on the source is load-bearing: it copies the seed's
        // *contents* into the worktree rather than nesting the seed directory itself.
        let arguments = [
            "-a",
            "--copy-links",
            "--ignore-existing",
            "--out-format=%n",
            seedDirectory.hasSuffix("/") ? seedDirectory : seedDirectory + "/",
            worktreeDir.hasSuffix("/") ? worktreeDir : worktreeDir + "/",
        ]

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: rsyncPath)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            // Read before waiting: a seed large enough to fill the pipe buffer
            // would otherwise deadlock rsync against a full stdout.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                logger.warning("rsync from \(seedDirectory, privacy: .public) failed: \(errStr, privacy: .public)")
                return 0
            }

            let copied = copiedFileCount(rsyncOutput: String(data: outData, encoding: .utf8) ?? "")
            logger.info("Copied \(copied) seed file(s) from \(seedDirectory, privacy: .public) to \(worktreeDir, privacy: .public)")
            return copied
        } catch {
            logger.warning("Failed to run rsync: \(error, privacy: .public)")
            return 0
        }
    }

    /// Count the files in an `--out-format=%n` listing. rsync names directories
    /// with a trailing slash, and they are not files that were copied.
    static func copiedFileCount(rsyncOutput: String) -> Int {
        rsyncOutput
            .split(separator: "\n")
            .filter { !$0.isEmpty && !$0.hasSuffix("/") }
            .count
    }

    /// Delete worktree entries that are symlinks where the seed has a real file.
    /// `--ignore-existing` treats a symlink as existing content and would leave
    /// it in place, so worktrees created by older builds would keep pointing at
    /// the main repo's `.env`.
    private static func removeSymlinkedDestinations(seedBase: String, currentDir: String, worktreeBase: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: currentDir) else { return }

        for name in names {
            let source = (currentDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                removeSymlinkedDestinations(seedBase: seedBase, currentDir: source, worktreeBase: worktreeBase)
                continue
            }

            let relative = String(source.dropFirst(seedBase.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destination = (worktreeBase as NSString).appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: destination),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink
            else { continue }

            try? fm.removeItem(atPath: destination)
            logger.info("Replaced symlinked \(relative, privacy: .public) with a copy")
        }
    }
}
