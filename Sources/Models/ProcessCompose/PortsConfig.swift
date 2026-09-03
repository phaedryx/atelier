// ABOUTME: Parses ports.yaml, which declares the port variables Atelier supplies.
// ABOUTME: Names come from the file; numbers come from ProcessCompose.PortPlan.

import Foundation
import Yams

extension ProcessCompose {
    /// One declared port variable.
    struct PortEntry: Equatable {
        enum Kind: Equatable {
            /// Atelier picks the number, per worktree.
            case assigned
            /// This exact number, always — for values registered outside the machine,
            /// such as an OAuth redirect URI that cannot vary per worktree.
            case fixed(Int)
        }

        let name: String
        let kind: Kind
        /// The port the embedded browser opens. At most one per file.
        let isBrowser: Bool
    }

    struct PortsConfig: Equatable {
        /// Sorted by name, so allocation order does not depend on YAML dictionary
        /// ordering — an assigned port must not move because a key was reordered.
        let entries: [ProcessCompose.PortEntry]

        static let fileNames = ["ports.yaml", "ports.yml"]

        enum LoadError: Error, LocalizedError, Equatable {
            case malformed(String)
            case invalidEntry(name: String, reason: String)
            case multipleBrowserPorts([String])

            var errorDescription: String? {
                switch self {
                case let .malformed(detail):
                    String(format: NSLocalizedString("ports.yaml could not be read: %@", comment: ""), detail)
                case let .invalidEntry(name, reason):
                    String(format: NSLocalizedString("ports.yaml: %@ %@", comment: ""), name, reason)
                case let .multipleBrowserPorts(names):
                    String(
                        format: NSLocalizedString("ports.yaml: only one port may set browser: true (%@)", comment: ""),
                        names.sorted().joined(separator: ", ")
                    )
                }
            }
        }

        /// The wire shape. Every field is optional so validation can produce a
        /// specific message rather than a decoding failure.
        private struct File: Decodable {
            struct Entry: Decodable {
                let assigned: Bool?
                let fixed: Int?
                let browser: Bool?
            }

            let ports: [String: Entry]
        }

        /// Names Atelier owns. A declaration may not take one of these.
        ///
        /// `Workstream.Environment` merges declarations *over* the `ATELIER_*` set
        /// so a project can redefine `ATELIER_PORT`, which is deliberate and
        /// documented. The same merge let any other `ATELIER_*` name through: a
        /// declaration called `ATELIER_WORKTREE_DIR` replaced a filesystem path
        /// with a port number in all four namespaces, and because the `FF_*`
        /// mirror runs last it propagated the corrupted value too. `ATELIER_PORT`
        /// stays allowed; the rest are refused here, where the file is read and a
        /// specific message is possible.
        private static let reservedNames: Set<String> = [
            "ATELIER_WORKSTREAM_ID", "ATELIER_PROJECT", "ATELIER_WORKSTREAM",
            "ATELIER_PROJECT_DIR", "ATELIER_WORKTREE_DIR", "ATELIER_DEFAULT_BRANCH",
        ]

        /// A declared name becomes an environment variable name, and reaches a
        /// shell as one.
        ///
        /// `TmuxSession.wrapCommand` builds `-e "KEY=value"` and hands the result
        /// to `sh -c`; it escapes the *value* and not the key. `ports.yaml` is read
        /// from the project directory with no approval gate, and in the ordinary
        /// clone layout that directory is the work tree — so it is repository
        /// content. A name containing a quote or `$(…)` was therefore an ungated
        /// path from a repository into a shell whenever tmux mode was on.
        ///
        /// Restricting names to what an environment variable may actually be
        /// closes that, and also rejects names no shell could export.
        private static func validateName(_ name: String) throws {
            let valid = !name.isEmpty
                && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                && !(name.first?.isNumber ?? true)
            if !valid {
                throw LoadError.invalidEntry(
                    name: name,
                    reason: NSLocalizedString("is not a usable variable name; use letters, digits and _, not starting with a digit", comment: "")
                )
            }
            if reservedNames.contains(name) {
                throw LoadError.invalidEntry(
                    name: name,
                    reason: NSLocalizedString("is a name Atelier sets; choose another", comment: "")
                )
            }
            // The FF_ mirror is derived from ATELIER_*, so an FF_ declaration is
            // either overwritten a moment later or shadows a mirrored path.
            if name.hasPrefix("FF_") {
                throw LoadError.invalidEntry(
                    name: name,
                    reason: NSLocalizedString("starts with FF_, which Atelier mirrors from ATELIER_*; declare the ATELIER_ name instead", comment: "")
                )
            }
        }

        /// Load `ports.yaml` from a directory. Returns nil when there is no such
        /// file — that is the normal state for a project that does not use ports.
        static func load(from directory: String) throws -> ProcessCompose.PortsConfig? {
            let url = URL(fileURLWithPath: directory)
            guard let path = fileNames
                .map({ url.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { return nil }

            let text: String
            do {
                text = try String(contentsOf: path, encoding: .utf8)
            } catch {
                throw LoadError.malformed(error.localizedDescription)
            }

            let file: File
            do {
                file = try YAMLDecoder().decode(File.self, from: text)
            } catch {
                throw LoadError.malformed(error.localizedDescription)
            }

            var entries: [ProcessCompose.PortEntry] = []
            for name in file.ports.keys.sorted() {
                // Force-unwrap is safe: the key came from this dictionary.
                let entry = file.ports[name]!
                let kind: ProcessCompose.PortEntry.Kind
                switch (entry.assigned, entry.fixed) {
                case (true, nil):
                    kind = .assigned
                case let (nil, .some(port)):
                    // A port is a 16-bit number and every consumer treats it as
                    // one: it is exported into four namespaces' environments and
                    // interpolated into the browser URL. `fixed: 70000` or
                    // `fixed: -1` parsed happily and failed later, somewhere else.
                    guard (1 ... 65535).contains(port) else {
                        throw LoadError.invalidEntry(
                            name: name,
                            reason: String(
                                format: NSLocalizedString("fixed: %d is not a port between 1 and 65535", comment: ""),
                                port
                            )
                        )
                    }
                    kind = .fixed(port)
                case (.some, .some):
                    throw LoadError.invalidEntry(
                        name: name,
                        reason: NSLocalizedString("sets both assigned and fixed", comment: "")
                    )
                case (false, _):
                    throw LoadError.invalidEntry(
                        name: name,
                        reason: NSLocalizedString("sets assigned: false, which means nothing; remove the entry instead", comment: "")
                    )
                case (nil, nil):
                    throw LoadError.invalidEntry(
                        name: name,
                        reason: NSLocalizedString("needs assigned: true or fixed: <port>", comment: "")
                    )
                }
                try validateName(name)
                entries.append(ProcessCompose.PortEntry(name: name, kind: kind, isBrowser: entry.browser == true))
            }

            // Two names pinned to one port cannot both bind. Every other
            // self-contradiction in this file is refused; this one used to parse
            // and fail later, at bind time, in whichever process lost the race.
            var seenFixed: [Int: String] = [:]
            for entry in entries {
                guard case let .fixed(port) = entry.kind else { continue }
                if let first = seenFixed[port] {
                    throw LoadError.invalidEntry(
                        name: entry.name,
                        reason: String(
                            format: NSLocalizedString("pins port %d, which %@ already pins", comment: ""),
                            port, first
                        )
                    )
                }
                seenFixed[port] = entry.name
            }

            let browsers = entries.filter(\.isBrowser).map(\.name)
            if browsers.count > 1 {
                throw LoadError.multipleBrowserPorts(browsers)
            }

            return ProcessCompose.PortsConfig(entries: entries)
        }
    }
}
