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

        static var fileNames: [String] {
            configFile.fileNames
        }

        /// The file, described once. `Project.ConfigFile` owns the mechanics
        /// every project-directory config shares — first spelling present wins,
        /// nothing inside a work tree is read, a template is seeded only when
        /// neither spelling exists — and the trust argument behind them.
        ///
        /// **`load(from:)` below is the surface callers use, and it keeps
        /// throwing `LoadError`.** This declaration wraps the same parse rather
        /// than replacing it: `LoadError`'s three cases are switched on by
        /// callers and each names the offending entry, which a single
        /// `Project.ConfigLoad.invalid(reason:)` string cannot. So the shared
        /// mechanism supplies the *location* and the *seed*, and this file keeps
        /// its own error type.
        static let configFile = Project.ConfigFile<ProcessCompose.PortsConfig>(
            fileNames: ["ports.yaml", "ports.yml"],
            defaultContents: ProcessCompose.PortsConfig.defaultContents,
            parse: { text, _ in try ProcessCompose.PortsConfig.parse(text) }
        )

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

            /// Optional: a file that exists but declares nothing is a project with no
            /// ports, not a malformed file. Requiring the key made `ports:` with an
            /// empty body — and a file holding only comments — surface as `.malformed`.
            let ports: [String: Entry]?
        }

        /// Names Atelier owns. A declaration may not take one of these.
        ///
        /// `Workstream.Environment` merges declarations *over* the `ATELIER_*` set
        /// so a project can redefine `ATELIER_PORT`, which is deliberate and
        /// documented. The same merge let any other `ATELIER_*` name through: a
        /// declaration called `ATELIER_WORKTREE_DIR` replaced a filesystem path
        /// with a port number in all five namespaces, and because the `FF_*`
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
            guard let path = configFile.locate(projectDirectory: directory) else { return nil }

            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw LoadError.malformed(error.localizedDescription)
            }
            return try parse(text)
        }

        /// The parse, separated from the file system so the schema can be tested
        /// without one — and so `configFile` can name it.
        static func parse(_ text: String) throws -> ProcessCompose.PortsConfig {
            // An empty or comment-only file has no YAML document for Yams to decode
            // at all, so it cannot be distinguished from a broken one further down.
            // Answer it here: nothing declared is a valid way to declare nothing.
            let hasDocument = text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            guard hasDocument else { return ProcessCompose.PortsConfig(entries: []) }

            let file: File
            do {
                file = try YAMLDecoder().decode(File.self, from: text)
            } catch {
                throw LoadError.malformed(error.localizedDescription)
            }

            var entries: [ProcessCompose.PortEntry] = []
            // Sorting the pairs, rather than the keys and then subscripting, is what
            // removes the force-unwrap; it also puts the sort invariant in one place.
            for (name, entry) in (file.ports ?? [:]).sorted(by: { $0.key < $1.key }) {
                let kind: ProcessCompose.PortEntry.Kind
                switch (entry.assigned, entry.fixed) {
                case (true, nil):
                    kind = .assigned
                case let (nil, .some(port)):
                    // A port is a 16-bit number and every consumer treats it as
                    // one: it is exported into five namespaces' environments and
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

extension ProcessCompose.PortsConfig {
    /// The file a newly created project starts with.
    ///
    /// Deliberately **not** localized, for the reason `Verification.Config`'s
    /// template is not: this is file content the user edits, not UI, and the
    /// keys are part of the schema.
    ///
    /// Every line is a comment, and here that is the safe shape rather than a
    /// dead end: an uncommented example would claim a real port and inject its
    /// variable into every terminal surface of every seeded project, and a
    /// comment-only file loads as "declares nothing" — the ordinary state for a
    /// project that does not use ports.
    static let defaultContents = """
    # Port variables Atelier supplies to this project.
    #
    # Each entry declares an environment variable. `assigned: true` means
    # Atelier picks a stable per-worktree port, so two worktrees can run the
    # same stack at once. `fixed: <number>` means that exact port everywhere,
    # for values registered outside the machine — an OAuth redirect URI, a CORS
    # allowlist. At most one entry may set `browser: true`; that port is the one
    # the embedded browser opens.
    #
    # Every declared name reaches every terminal, initialization step,
    # verification check and process-compose namespace.
    #
    #   ports:
    #     WEB_PORT: { assigned: true, browser: true }
    #     API_PORT: { assigned: true }
    #     OAUTH_PORT: { fixed: 4000 }
    #
    # Uncomment and replace with this project's real ports. A file declaring
    # nothing supplies nothing.

    """

    /// Seed a newly created project with `defaultContents`.
    ///
    /// Called only by the two paths that *create* the project directory — a new
    /// empty project and a fresh clone — and never by the paths that adopt a
    /// directory the user already had, which would drop an untracked file into a
    /// repository they merely registered.
    ///
    /// `Project.ConfigFile.writeDefault` is the whole of it: this delegates so
    /// callers and tests keep one name to reach for, and so the refusal rule —
    /// nothing is written when *either* spelling is present — has one
    /// implementation rather than four.
    @discardableResult
    static func writeDefault(projectDirectory: String) -> Bool {
        configFile.writeDefault(projectDirectory: projectDirectory)
    }
}
