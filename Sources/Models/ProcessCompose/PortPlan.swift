// ABOUTME: Turns declared port names into the numbers one worktree receives.
// ABOUTME: Fixed ports are reserved first so an assigned port can never take one.

import Foundation

extension ProcessCompose {
    struct PortPlan: Equatable {
        /// Variable name to port number, ready to export.
        let values: [String: String]
        /// The port the embedded browser should open, if one was declared.
        let browserPort: Int?
        /// Whether `browserPort` came from a `fixed:` entry rather than
        /// `assigned:`. A fixed port exists for values registered off the
        /// machine and can never appear in `Port.Detector.detectedPorts`, which
        /// only ever reflects `atelier-run`'s scan of the launched command's own
        /// child-process tree — see `Port.isWaitingForServer`.
        let browserPortIsFixed: Bool

        init(values: [String: String], browserPort: Int?, browserPortIsFixed: Bool = false) {
            self.values = values
            self.browserPort = browserPort
            self.browserPortIsFixed = browserPortIsFixed
        }

        static let empty = ProcessCompose.PortPlan(values: [:], browserPort: nil)

        /// Resolve a declaration into numbers for one worktree.
        ///
        /// Fixed ports are claimed before anything is assigned, so a hash landing on
        /// a pinned number moves rather than colliding. Assigned ports start from
        /// the salted hash — stable per worktree and per name, which is what keeps a
        /// bookmark or an OAuth redirect valid between runs — and walk forward past
        /// anything already claimed or already bound.
        ///
        /// The bound check is a snapshot: it cannot reserve the port, so it avoids
        /// the common collision rather than every race.
        static func resolve(
            _ config: ProcessCompose.PortsConfig,
            workingDirectory: String,
            isFree: (Int) -> Bool = Port.Allocator.isPortFree
        ) -> ProcessCompose.PortPlan {
            var values: [String: String] = [:]
            var claimed: Set<Int> = []
            var browserPort: Int?
            var browserPortIsFixed = false

            for entry in config.entries {
                guard case let .fixed(port) = entry.kind else { continue }
                claimed.insert(port)
                values[entry.name] = "\(port)"
                if entry.isBrowser {
                    browserPort = port
                    browserPortIsFixed = true
                }
            }

            for entry in config.entries {
                guard entry.kind == .assigned else { continue }
                let port = Port.Allocator.availablePort(
                    for: workingDirectory,
                    salt: entry.name,
                    claimed: claimed,
                    isFree: isFree
                )
                claimed.insert(port)
                values[entry.name] = "\(port)"
                if entry.isBrowser {
                    browserPort = port
                }
            }

            return ProcessCompose.PortPlan(values: values, browserPort: browserPort, browserPortIsFixed: browserPortIsFixed)
        }
    }
}
