// ABOUTME: One mechanism for "a config file read from the project directory".
// ABOUTME: Two spellings, first present wins, never a work tree — stated once, here.

import Foundation
import os
import Yams

private let logger = Logger(subsystem: "atelier", category: "project.config")

/// The erased face of `Project.ConfigFile`, so the declared files can be held in
/// one array despite each carrying a different `Contents`.
///
/// It exposes only what a caller with no interest in the contents needs — the
/// names, the template, and the seed — which is exactly what
/// `Project.seedDefaultConfigs` loops over. Anything that wants a parsed file
/// goes through the concrete `ConfigFile<Contents>` instead.
protocol ProjectConfigFile: Sendable {
    /// The names looked for, in order. The first that exists is the one read.
    var fileNames: [String] { get }
    /// The template a newly created project starts with.
    var defaultContents: String { get }
    @discardableResult
    func writeDefault(projectDirectory: String) -> Bool
}

extension Project {
    /// A file Atelier reads from the project directory, described once.
    ///
    /// **Four files answer to one rule** — `execution.process-compose.yaml`,
    /// `verification.yaml`, `initialization.yaml` and `ports.yaml` — and this is
    /// where the rule lives rather than in four copies of it:
    ///
    /// - **Two spellings, `.yaml` then `.yml`, and the first present wins.** A
    ///   second is never merged, because two files whose precedence a reader has
    ///   to hold in their head is the shape `ProcessCompose.Config` retired.
    /// - **The project directory and nowhere else.** `Project.directory` is the
    ///   repository's *home* — the `.bare` container in that layout — so a file
    ///   there sits outside every work tree and cannot have arrived with a clone.
    ///   That is the trust decision each of the four states in its own doc
    ///   comment, and it is why none of them has an approval gate: the location
    ///   *is* the gate. There is deliberately no work-tree tier here to add one
    ///   to. **The known hole, stated rather than papered over:** for an ordinary
    ///   clone `Project.directory` *is* the checkout, so the file can be
    ///   committed. Every one of the four accepts that hole unchanged rather
    ///   than half-tightening it.
    /// - **A template is seeded only when *neither* spelling is present.**
    ///   Seeding a `ports.yaml` beside an existing `ports.yml` would win the
    ///   lookup and hide the project's real declarations.
    ///
    /// What this type is deliberately *not* is a policy about the templates. It
    /// carries `defaultContents` as opaque text: whether a template's example is
    /// commented out is a per-file safety decision each config makes for itself,
    /// and CLAUDE.md's "Seeded config templates" explains each one. This is the
    /// mechanism, and the mechanism has no opinion.
    ///
    /// `projectDirectory` must be `Project.directory` and never
    /// `Project.checkout`. In the container layout those differ, and passing the
    /// checkout looks inside `main/` — a work tree, both the wrong place and the
    /// one location these lookups exist to avoid.
    struct ConfigFile<Contents: Sendable>: Sendable, ProjectConfigFile {
        let fileNames: [String]
        let defaultContents: String

        /// Turn the file's text into its contents, or throw to say why it could
        /// not be read as one.
        ///
        /// Throwing `Project.InvalidConfig` carries a user-facing reason through
        /// to `Load.invalid`; any other error is reported by its
        /// `localizedDescription`, which is what lets a config with its own error
        /// type — `ProcessCompose.PortsConfig.LoadError` — declare a parser here
        /// without flattening that type into a string at its own call sites.
        let parse: @Sendable (_ text: String, _ path: String) throws -> Contents

        /// The absolute path of the file that will be read, or nil when neither
        /// spelling is present.
        func locate(projectDirectory: String) -> String? {
            let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            let fileManager = FileManager.default
            return fileNames
                .map { directory.appendingPathComponent($0).path }
                .first { fileManager.fileExists(atPath: $0) }
        }

        /// Read and parse the project's file.
        func load(projectDirectory: String) -> Project.ConfigLoad<Contents> {
            guard let path = locate(projectDirectory: projectDirectory) else { return .missing }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .invalid(reason: NSLocalizedString(
                    "The file could not be read.",
                    comment: "A project config file: present but unreadable"
                ))
            }
            return load(text: text, path: path)
        }

        /// The parse, separated from the file system so a schema can be tested
        /// without one.
        func load(text: String, path: String) -> Project.ConfigLoad<Contents> {
            do {
                return try .loaded(parse(text, path))
            } catch let failure as Project.InvalidConfig {
                return .invalid(reason: failure.reason)
            } catch {
                return .invalid(reason: error.localizedDescription)
            }
        }

        /// Seed a newly created project with `defaultContents`.
        ///
        /// Called only by the two paths that *create* the project directory — a
        /// new empty project and a fresh clone — and never by the paths that
        /// adopt a directory the user already had, which would drop an untracked
        /// file into a repository they merely registered. `Project.seedDefaultConfigs`
        /// is the one entry point.
        ///
        /// Does nothing when either name in `fileNames` is already present, and
        /// reports rather than throws: a convenience template must not fail
        /// project creation, but a write that silently did not happen is worse
        /// than one that says so.
        @discardableResult
        func writeDefault(projectDirectory: String) -> Bool {
            guard locate(projectDirectory: projectDirectory) == nil else { return false }

            let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            let path = directory.appendingPathComponent(fileNames[0])
            do {
                try defaultContents.write(to: path, atomically: true, encoding: .utf8)
                return true
            } catch {
                logger.warning(
                    "[Atelier] could not write default \(fileNames[0], privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }
    }

    /// A file that is present and could not be read as what it claims to be.
    ///
    /// `reason` is the user-facing sentence, already formatted and localized by
    /// the parser that threw it — which is where it belongs, because the wording
    /// names the file and is pinned by that file's own tests.
    struct InvalidConfig: Error {
        let reason: String
    }

    /// What a load attempt found.
    ///
    /// **Three cases, not two**, for the reason `ProcessCompose.Config.declaredProcesses`
    /// returns nil rather than `[]` on a parse failure: a file Atelier cannot
    /// read must never render as "this project declares nothing", which is the
    /// same sentence a project with genuinely nothing gets and, for some of these
    /// files, the only diagnostic either one has. The per-file `unavailableReason`
    /// extensions are what turn that distinction into wording.
    enum ConfigLoad<Contents> {
        /// Neither spelling is in the project directory.
        case missing
        /// A file is there and could not be read as one.
        case invalid(reason: String)
        /// Parsed. May legitimately declare nothing.
        case loaded(Contents)

        var config: Contents? {
            if case let .loaded(config) = self {
                return config
            }
            return nil
        }
    }
}

extension Project.ConfigLoad: Equatable where Contents: Equatable {}

// MARK: - The named-command schema

extension Project {
    /// One entry of a config file shaped "name → a command and the shell to run
    /// it in". `verification.yaml` and `initialization.yaml` are both that file;
    /// they differ in what a run *means*, not in what a parse has to do.
    struct CommandEntry: Equatable {
        let name: String
        /// The command, as written. Run by `shell`, not parsed here.
        let command: String
        /// The shell named for this entry, or nil to use the user's `$SHELL`.
        ///
        /// Kept `Optional` rather than resolved at parse time so the resolution
        /// stays with the spawn: `$SHELL` is read from the environment the app
        /// launched with, and a parsed config outliving a settings change should
        /// not pin a shell the user has since replaced.
        let shell: String?
    }

    /// The wording one command-entry file uses to describe its own shape.
    ///
    /// The schema is shared; the sentences are not. Each file names itself and
    /// its own noun — a check, a step — and those strings are rendered to the
    /// user and pinned by that file's tests, so they stay `NSLocalizedString`
    /// literals at the declaring call site and travel here already localized.
    /// Four of the six are `String(format:)` templates taking one argument.
    struct CommandEntryMessages: Sendable {
        /// Takes the Yams error's description.
        let notValidYAML: String
        let topLevelIsNotAMapping: String
        let entryHasNoName: String
        /// Each takes the entry's name.
        let entryIsNotAMapping: String
        let entryHasNoCommand: String
        let entryHasAnUnusableShell: String
    }

    /// Parse a command-entry file into its entries, **in file order**.
    ///
    /// **Ordered, which is why this walks `Yams.compose`'s nodes rather than
    /// decoding a `[String: Entry]`.** A Swift dictionary has no order, so a
    /// decoded config would present its entries in an arbitrary sequence that
    /// changed between launches — cosmetic for verification's rows and not at all
    /// cosmetic for initialization's, where file order *is* run order.
    ///
    /// **No duplicate-name guard: Yams refuses a duplicated key itself**, as a
    /// parse error, so such a file is rejected above and never reaches the loop.
    /// Measured — a guard written here first never fired. Two entries of one name
    /// would be indistinguishable in every report there is, so the refusal
    /// matters; it just is not this function's to make.
    static func parseCommandEntries(
        _ text: String,
        messages: CommandEntryMessages
    ) throws -> [CommandEntry] {
        let document: Yams.Node?
        do {
            document = try Yams.compose(yaml: text)
        } catch {
            throw InvalidConfig(reason: String(
                format: messages.notValidYAML, error.localizedDescription
            ))
        }

        // An empty file, or one holding nothing but comments, composes to nil.
        // That is a file declaring nothing rather than a broken one — the same
        // distinction `ProcessCompose.Config.declaredProcesses` draws for a
        // config with no `processes:` key.
        guard let document else { return [] }
        guard let mapping = document.mapping else {
            throw InvalidConfig(reason: messages.topLevelIsNotAMapping)
        }

        var entries: [CommandEntry] = []
        for (keyNode, valueNode) in mapping {
            guard let name = keyNode.string, !name.isEmpty else {
                throw InvalidConfig(reason: messages.entryHasNoName)
            }
            guard let entry = valueNode.mapping else {
                throw InvalidConfig(reason: String(format: messages.entryIsNotAMapping, name))
            }
            guard let command = entry["command"]?.string,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw InvalidConfig(reason: String(format: messages.entryHasNoCommand, name))
            }
            let shellNode = entry["shell"]
            if shellNode != nil, shellNode?.string == nil {
                throw InvalidConfig(reason: String(format: messages.entryHasAnUnusableShell, name))
            }
            let shell = shellNode?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(CommandEntry(
                name: name,
                command: command,
                shell: (shell?.isEmpty ?? true) ? nil : shell
            ))
        }
        return entries
    }
}
