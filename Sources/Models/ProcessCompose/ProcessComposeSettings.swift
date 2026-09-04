// ABOUTME: Settings for the process-compose integration, and binary resolution.
// ABOUTME: Global rather than per-project: these are preferences about the tool.

import Foundation

extension ProcessCompose {
    enum Settings {
        static let enabledKey = "atelier.processCompose.enabled"
        static let binaryPathKey = "atelier.processCompose.binaryPath"

        /// Where process-compose usually lands. Not in homebrew-core, so a tap and a
        /// hand-installed release binary are both common.
        static let searchPaths = [
            "/opt/homebrew/bin/process-compose",
            "/usr/local/bin/process-compose",
            "\(NSHomeDirectory())/.local/bin/process-compose",
        ]

        static var isEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: enabledKey) }
            set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
        }

        static var binaryPath: String {
            get { UserDefaults.standard.string(forKey: binaryPathKey) ?? "" }
            set { UserDefaults.standard.set(newValue, forKey: binaryPathKey) }
        }

        /// The binary to run, or nil if there isn't one.
        ///
        /// A configured path is used or fails; it never falls back to a search,
        /// because silently running a different binary than the one named is worse
        /// than reporting that the named one is gone.
        static func resolveBinary() -> String? {
            // `.whitespacesAndNewlines`, because a path pasted out of a terminal
            // carries a trailing newline and `.whitespaces` leaves it on — which
            // resolved to nil with no diagnostic, the one thing the paragraph
            // above says this does not do.
            let configured = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty {
                return isExecutableBinary(configured) ? configured : nil
            }
            return searchPaths.first(where: isExecutableBinary)
        }

        /// `isExecutableFile` is true for a *searchable directory* as well as for
        /// a program, so pointing the setting at `/usr/local/bin` instead of the
        /// binary inside it passed the check and failed at spawn time.
        private static func isExecutableBinary(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        }
    }
}
