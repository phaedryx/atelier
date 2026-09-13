// ABOUTME: Where process-compose lives, and how the binary is found.
// ABOUTME: Detection only — there is no process-compose setting left to store.

import Foundation

extension ProcessCompose {
    enum Settings {
        /// Where process-compose usually lands. Not in homebrew-core, so a tap and a
        /// hand-installed release binary are both common.
        ///
        /// **This is now the whole of resolution.** There used to be an
        /// `atelier.processCompose.binaryPath` setting that took precedence and,
        /// when set, refused to fall back here — the reasoning being that
        /// silently running a different binary than the one named is worse than
        /// reporting the named one is gone. The setting is gone: process-compose
        /// is auto-detected, full stop. The trade is stated where it bites — an
        /// install by way of `go install`, nix, mise or asdf lands outside these
        /// three, and there is no longer an override to point at it.
        ///
        /// Do not widen this list to compensate. `CommandLineTools.path(for:)`
        /// would find those installs, and using it here is a real option — but it
        /// is a different change, and the Detected Tools row, the onboarding
        /// prerequisite and `PhasePolicy`'s binary precondition must all keep
        /// answering from *this* function, whatever it searches, or the row goes
        /// green over a Start button that refuses.
        static let searchPaths = [
            "/opt/homebrew/bin/process-compose",
            "/usr/local/bin/process-compose",
            "\(NSHomeDirectory())/.local/bin/process-compose",
        ]

        /// The binary to run, or nil if there isn't one. First match wins.
        ///
        /// - Parameter searchPaths: the directories to try, in order. Defaulted,
        ///   and injected only by tests. The earlier version of this file
        ///   declined such a seam — "pinning it would mean adding a search-paths
        ///   injection point to production for one test" — and that ruling was
        ///   right while the search was merely the *fallback* behind a
        ///   configured path the tests could set. It is now the only resolution
        ///   path there is, so without this parameter the whole of resolution is
        ///   unassertable on any host, and what the tests actually pinned
        ///   (trimming, the directory guard, configured-but-missing) described a
        ///   setting that no longer exists.
        static func resolveBinary(searchPaths: [String] = searchPaths) -> String? {
            searchPaths.first(where: isExecutableBinary)
        }

        /// `isExecutableFile` is true for a *searchable directory* as well as for
        /// a program, so a directory sitting where the binary should be passed the
        /// check and failed at spawn time.
        private static func isExecutableBinary(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        }
    }
}
