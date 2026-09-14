// ABOUTME: How one verification check is turned into a terminal surface's command.
// ABOUTME: Owns the wrapper that reports the check's pid and its exit code.

import CryptoKit
import Foundation

extension Verification {
    /// Everything needed to run one check in its own terminal surface.
    ///
    /// A value rather than a method on the runner so the command string — the
    /// part with the quoting and the two shells in it — can be asserted without
    /// a surface, a Ghostty app, or a main actor.
    struct Spawn: Equatable {
        /// The surface this check owns. Deterministic; see `surfaceID(for:check:)`.
        let surfaceID: UUID
        /// The string handed to Ghostty as the surface's command.
        let command: String
        /// Where the wrapper writes the running check's pid.
        let pidPath: String
        /// Where the wrapper writes the command's exit status.
        let statusPath: String
    }
}

extension Verification.Spawn {
    /// Where the pid and status files live: one directory, beside the other
    /// disposable per-run state under Caches.
    static var stateDirectory: URL {
        AppConstants.cacheDirectory.appendingPathComponent("verify")
    }

    /// The surface a check owns, derived rather than allocated.
    ///
    /// **Deterministic, and it has to be.** `TerminalSurfaceCache` is keyed by
    /// `UUID`, the rows are rebuilt on every publish, and a surface that could not
    /// be found again would be a second terminal for a check already running in
    /// one. Derived from the workstream id *and* the check's name so it cannot
    /// collide with the workstream's own id — which is the Coding Agent's surface,
    /// and would mean a check's output replacing the user's agent.
    ///
    /// The bits are laid out as a v5 UUID (name-based, SHA-1 by the letter of the
    /// spec; SHA-256 truncated here, since nothing reads the digest back and
    /// matching the RFC's hash buys nothing). Version and variant are stamped so
    /// the value is a well-formed UUID rather than sixteen arbitrary bytes.
    static func surfaceID(for workstreamID: UUID, check: String) -> UUID {
        let seed = "atelier.verify:\(workstreamID.uuidString.lowercased()):\(check)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// A stable per-check file stem for the pid and status files.
    ///
    /// Hashed rather than spelled: a check's name is the user's and may hold `/`,
    /// spaces, or more bytes than a path component takes.
    static func fileStem(for workstreamID: UUID, check: String) -> String {
        let short = workstreamID.uuidString.prefix(8).lowercased()
        let digest = SHA256.hash(data: Data(check.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(short)-\(digest)"
    }

    /// Build the spawn for one check.
    ///
    /// **The command is read by bash before any shell of ours sees it.** Ghostty
    /// runs a surface command on macOS as `/usr/bin/login -flp <user> /bin/bash
    /// --noprofile --norc -c "exec -l <command>"` (`ghostty/src/termio/Exec.zig`),
    /// which is why the outermost token is POSIX-quoted and never fish-quoted —
    /// the same rule `CommandBuilder.inLoginShell` states at its own quoting.
    ///
    /// Three layers, each doing one job:
    ///
    /// 1. **`sh -c` on the outside**, because the wrapper needs `$$`, `$?` and
    ///    redirection, and the user's shell may be fish, where none of those are
    ///    spelled that way. `$?` in particular is `$status` in fish, which is the
    ///    whole reason the outer shell is Atelier's rather than theirs.
    /// 2. **The wrapper records its process *group* id before anything runs.**
    ///    Ghostty exposes no pid for a surface's child, so this is the only handle
    ///    on a running check, and the group is what `stop` signals — the same group
    ///    kill `ProcessRunner` already documents and has measured.
    ///
    ///    **`ps -o pgid=`, not `$$`, and the difference is not theoretical.**
    ///    `$$` is the shell's *pid*, and a pid is only the group id when that
    ///    process happens to be the group leader. Measured on this machine: a
    ///    backgrounded `sh -c` reported `$$` as 56980 while its real pgid was
    ///    56974, and `kill(-56980, 0)` answered ESRCH. Under `$$` both halves of
    ///    the runner fail together and both fail *silently* — `stop` signals a
    ///    group that does not exist, so nothing dies, and `isAlive` reads the same
    ///    ESRCH as "the check is gone", so every check is recorded as finished the
    ///    moment the completion pass first looks at it. Production is the case
    ///    where they most likely coincide, since Ghostty's child calls `setsid` and
    ///    every exec in the chain keeps the pid — which is exactly what would make
    ///    this pass in testing and break wherever it did not.
    /// 3. **The user's shell with `-lic`**, so the command sees the PATH their
    ///    profile builds. `-l` alone is not enough for the common case: zsh users
    ///    put PATH in `.zshrc`, which only an interactive shell reads. This is the
    ///    same flag set `CommandBuilder.inLoginShell` uses, deliberately, because a
    ///    check that cannot find `bundle` fails for a reason nothing on the row
    ///    could explain.
    ///
    /// The exit code goes to a file rather than coming from Ghostty's
    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED`, which does fire but whose code cannot be
    /// trusted here: Ghostty's own source says so at the point it builds the
    /// message — "On macOS, our exit code detection doesn't work, possibly because
    /// of our `login` wrapper" (`ghostty/src/Surface.zig:1208`).
    ///
    /// A stopped check never writes the status file, and that is correct rather
    /// than a gap: killing the group takes the wrapper with it, and the state a
    /// stopped check gets is `.stopped`, which Atelier knows because it did the
    /// stopping.
    static func build(
        check: Verification.Config.Check,
        workstreamID: UUID,
        defaultShell: String = CommandBuilder.userShell
    ) -> Verification.Spawn {
        let stem = fileStem(for: workstreamID, check: check.name)
        let pidPath = stateDirectory.appendingPathComponent("\(stem).pid").path
        let statusPath = stateDirectory.appendingPathComponent("\(stem).status").path
        let shell = check.shell.map(resolveShell) ?? defaultShell

        let script = [
            "ps -o pgid= -p $$ | tr -d ' ' > \(CommandBuilder.shellQuote(pidPath))",
            "\(CommandBuilder.shellQuote(shell)) -lic \(CommandBuilder.shellQuote(check.command))",
            "echo $? > \(CommandBuilder.shellQuote(statusPath))",
        ].joined(separator: "; ")

        return Verification.Spawn(
            surfaceID: surfaceID(for: workstreamID, check: check.name),
            command: "sh -c \(CommandBuilder.shellQuote(script))",
            pidPath: pidPath,
            statusPath: statusPath
        )
    }

    /// A bare `shell: fish` names a shell on PATH; a path names one outright.
    ///
    /// Left to PATH resolution rather than searched for here: the wrapper's `sh`
    /// inherits the app's environment, which is a GUI app's minimal PATH — so a
    /// bare name is resolved against `/usr/bin:/bin:/usr/sbin:/sbin` and a
    /// Homebrew fish would not be found. Naming the common prefixes is what makes
    /// `shell: fish` mean what the user expects.
    private static func resolveShell(_ named: String) -> String {
        guard !named.contains("/") else { return named }
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { "\($0)/\(named)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? named
    }

    /// Create the directory the pid and status files live in.
    static func ensureStateDirectory() {
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true
        )
    }

    /// Remove any leftovers from an earlier run of this check.
    ///
    /// Before every spawn, because the status file is the completion signal: a
    /// stale one from the previous run would be read as this run finishing the
    /// instant it started.
    func clearState() {
        try? FileManager.default.removeItem(atPath: pidPath)
        try? FileManager.default.removeItem(atPath: statusPath)
    }

    /// The exit code the wrapper recorded, or nil while the check is still running.
    var recordedStatus: Int? {
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The running check's process **group** id, or nil before the wrapper has
    /// written it. Signalled as `kill(-pgid)`; see `build` for why this is not `$$`.
    var recordedPID: pid_t? {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 1
        else { return nil }
        return value
    }
}
