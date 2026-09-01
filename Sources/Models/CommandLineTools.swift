// ABOUTME: Resolves full paths for command line tools the app launches directly.
// ABOUTME: Keeps tool detection and process execution consistent across app builds.

import Foundation

enum CommandLineTools {
    static func path(
        for name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        resolveFromPath: (String, [String: String]) -> String? = { name, environment in
            pathFromEnvironment(named: name, environment: environment)
        },
        resolveFromShellPath: (String) -> String? = { shell in
            loginShellPath(shell: shell)
        }
    ) -> String? {
        // Prefer the user's login shell PATH so we find the same binary
        // their terminal would. GUI apps inherit a minimal PATH from launchd,
        // so we resolve the full login shell PATH first.
        if let shell = environment["SHELL"], !shell.isEmpty,
           let shellPath = resolveFromShellPath(shell)
        {
            for directory in shellPath.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
                if isExecutable(candidate) {
                    return candidate
                }
            }
        }

        // Fall back to the process PATH (minimal launchd PATH for GUI apps)
        if let found = resolveFromPath(name, environment) {
            return found
        }

        // Last resort: check well-known locations
        let knownLocations = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/run/current-system/sw/bin/\(name)",
            "\(NSHomeDirectory())/.nix-profile/bin/\(name)",
        ]

        for location in knownLocations where isExecutable(location) {
            return location
        }

        return nil
    }

    /// Ceiling on the login-shell PATH lookup. Resolved once per process, so
    /// this is only ever paid once — but it must be paid, not waited on forever.
    static let loginShellPathTimeout: TimeInterval = 10

    private static let shellPathCache = ShellPathCache()

    static func loginShellPath(shell: String) -> String? {
        shellPathCache.resolve(shell: shell)
    }

    private final class ShellPathCache: Sendable {
        private let lock = NSLock()
        private let storage = MutableBox()

        /// Mutable state isolated behind NSLock
        private final class MutableBox: @unchecked Sendable {
            var resolved = false
            var path: String?
        }

        func resolve(shell: String, timeout: TimeInterval = CommandLineTools.loginShellPathTimeout) -> String? {
            lock.lock()
            defer { lock.unlock() }

            if storage.resolved {
                return storage.path
            }
            storage.resolved = true

            // Bounded: `-i` starts an *interactive* shell, and one without a
            // usable terminal can block indefinitely. This runs while holding
            // the lock, so a hang here stalls every caller — tool detection and
            // the usage probe included. On timeout `path(for:)` falls back to
            // the process PATH and the known locations.
            let data = ProcessRunner.run(
                executable: shell,
                arguments: ["-lic", "printenv PATH"],
                timeout: timeout
            )
            guard let data else { return nil }
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            storage.path = result
            return result
        }
    }

    private static func pathFromEnvironment(named name: String, environment: [String: String]) -> String? {
        guard let rawPath = environment["PATH"], !rawPath.isEmpty else { return nil }

        for directory in rawPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
