// ABOUTME: The project's `verification.yaml` — the checks the Verification tab offers.
// ABOUTME: Project directory only, so it can never arrive with the repository.

import Foundation
import os
import Yams

private let logger = Logger(subsystem: "atelier", category: "verification.config")

extension Verification {
    /// A project's declared checks, in the order the file declares them.
    ///
    /// **This file lives in the project directory and nowhere else**, and that is a
    /// trust decision rather than a convenience. `Project.directory` is the
    /// repository's *home* — the `.bare` container in that layout — so a file there
    /// sits outside every work tree and cannot have arrived with the repository.
    /// CLAUDE.md's rule for process-compose configs applies unchanged: approval is
    /// gated by a config's location, not its content, and a config in the project
    /// directory "was placed there by hand, outside git, and is never asked about".
    /// So there is no `ScriptTrust` fingerprint here and no `PhasePolicy` gate, and
    /// adding one would be answering a question that cannot arise.
    ///
    /// Two consequences follow and both are wanted. One set of checks serves every
    /// worktree of the project, so a check is edited in one place. And an agent
    /// working in a worktree — confined there by the "Restrict to worktree" system
    /// prompt — cannot edit the file that decides whether its own work passes. A
    /// worktree-local override would hand it exactly that, which is why there is no
    /// tier-one worktree lookup mirroring `ProcessCompose.Config.locate`'s.
    ///
    /// **The known hole, stated rather than papered over:** for an ordinary clone
    /// `Project.directory` *is* the checkout (`Project.swift:70-79`), so the file
    /// sits inside the work tree and can be committed. That hole already exists for
    /// process-compose's project-directory tier and the rule is applied here
    /// unchanged rather than half-tightened. Sniffing whether the file is git-tracked
    /// would make the gate depend on a second fact the user cannot see.
    struct Config: Equatable {
        /// The file this was read from.
        let path: String
        /// Every declared check, in file order.
        let checks: [Check]

        /// One check: a name, a command, and the shell to run it in.
        struct Check: Equatable {
            let name: String
            /// The command, as written. Run by `shell`, not parsed here.
            let command: String
            /// The shell named for this check, or nil to use the user's `$SHELL`.
            ///
            /// Kept `Optional` rather than resolved at parse time so the resolution
            /// stays with the spawn: `$SHELL` is read from the environment the app
            /// launched with, and a parsed config outliving a settings change should
            /// not pin a shell the user has since replaced.
            let shell: String?
        }

        /// The names, in file order. What the tab draws a row per.
        var checkNames: [String] {
            checks.map(\.name)
        }

        func check(named name: String) -> Check? {
            checks.first { $0.name == name }
        }
    }
}

extension Verification.Config {
    /// What a load attempt found.
    ///
    /// Three cases, not two, for the reason `ProcessCompose.Config.declaredProcesses`
    /// returns nil rather than `[]` on a parse failure: a file Atelier cannot read
    /// must never render as "this project declares no checks", which is the same
    /// sentence a project with genuinely no checks gets and the only diagnostic
    /// either one has.
    enum Load: Equatable {
        /// No `verification.yaml` in the project directory.
        case missing
        /// A file is there and could not be read as one.
        case invalid(reason: String)
        /// Parsed. May legitimately declare zero checks.
        case loaded(Verification.Config)

        var config: Verification.Config? {
            if case let .loaded(config) = self {
                return config
            }
            return nil
        }

        /// The checks to draw a row for. Empty whenever `unavailableReason` is
        /// set, so the two cannot describe different states.
        var checkNames: [String] {
            config?.checkNames ?? []
        }

        /// Present-tense wording for why nothing can run yet, or nil when
        /// something can.
        ///
        /// **This is the availability decision, not a mirror of one.** The gate the
        /// process-compose phases have — `PhasePolicy.plan`, hand-mirrored by a
        /// second copy that nothing made agree with it — has no counterpart here:
        /// there is no binary to resolve and no approval to check, so "can a check
        /// run" is exactly "did this file parse and does it declare anything". The
        /// runner asks the same `load` and throws on the same three cases, which is
        /// what keeps the tab's empty state and `start`'s refusal in step.
        var unavailableReason: String? {
            switch self {
            case .missing:
                NSLocalizedString(
                    "Add a verification.yaml to this project's directory to declare checks.",
                    comment: "Verification tab: no config"
                )
            case let .invalid(reason):
                String(
                    format: NSLocalizedString(
                        "This project's verification.yaml could not be read: %@",
                        comment: "Verification tab: the config is present and broken"
                    ),
                    reason
                )
            case let .loaded(config):
                config.checks.isEmpty
                    ? NSLocalizedString(
                        "This project's verification.yaml declares no checks.",
                        comment: "Verification tab: the config parsed and is empty"
                    )
                    : nil
            }
        }
    }

    /// The names looked for, in order. The first that exists is the one read —
    /// a second is never merged, because two files whose precedence a reader has
    /// to hold in their head is the shape `ProcessCompose.Config` retired.
    static let fileNames = ["verification.yaml", "verification.yml"]

    /// Read the project's checks.
    ///
    /// `projectDirectory` must be `Project.directory` and never `Project.checkout`.
    /// In the container layout those differ, and passing the checkout would look
    /// inside `main/` — a work tree — which is both the wrong place and the one
    /// location this type exists to avoid.
    static func load(projectDirectory: String) -> Load {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        guard let path = fileNames
            .map({ directory.appendingPathComponent($0).path })
            .first(where: { fileManager.fileExists(atPath: $0) })
        else { return .missing }

        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .invalid(reason: NSLocalizedString(
                "The file could not be read.",
                comment: "verification.yaml: present but unreadable"
            ))
        }
        return parse(text, path: path)
    }

    /// The parse, separated from the file system so the schema can be tested
    /// without one.
    ///
    /// **Ordered, which is why this walks `Yams.compose`'s nodes rather than
    /// decoding a `[String: Check]`.** A Swift dictionary has no order, so a
    /// decoded config would draw rows in an arbitrary sequence that changed
    /// between launches. `Node.Mapping` preserves the file's.
    static func parse(_ text: String, path: String) -> Load {
        let document: Yams.Node?
        do {
            document = try Yams.compose(yaml: text)
        } catch {
            return .invalid(reason: String(
                format: NSLocalizedString(
                    "The file is not valid YAML: %@",
                    comment: "verification.yaml: Yams could not parse it"
                ),
                error.localizedDescription
            ))
        }

        // An empty file, or one holding nothing but comments, composes to nil.
        // That is a file declaring no checks rather than a broken one — the same
        // distinction `ProcessCompose.Config.declaredProcesses` draws for a config
        // with no `processes:` key.
        guard let document else {
            return .loaded(Verification.Config(path: path, checks: []))
        }
        guard let mapping = document.mapping else {
            return .invalid(reason: NSLocalizedString(
                "The file must be a mapping of check names to their commands.",
                comment: "verification.yaml: the top level is a list or a scalar"
            ))
        }

        // No duplicate-name guard here: **Yams refuses a duplicated key itself**,
        // as a parse error, so such a file lands in `.invalid` above and never
        // reaches this loop. Measured — a guard that was written here first never
        // fired. Two rows of one name would share a record, a surface id and a
        // status, so the refusal matters; it just is not this function's to make.
        var checks: [Verification.Config.Check] = []
        for (keyNode, valueNode) in mapping {
            guard let name = keyNode.string, !name.isEmpty else {
                return .invalid(reason: NSLocalizedString(
                    "Every check needs a name.",
                    comment: "verification.yaml: a key that is not a non-empty string"
                ))
            }
            guard let entry = valueNode.mapping else {
                return .invalid(reason: String(
                    format: NSLocalizedString(
                        "“%@” must be a mapping with a command:.",
                        comment: "verification.yaml: a check given as a bare string or a list"
                    ),
                    name
                ))
            }
            guard let command = entry["command"]?.string,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .invalid(reason: String(
                    format: NSLocalizedString(
                        "“%@” needs a command: to run.",
                        comment: "verification.yaml: a check with no command"
                    ),
                    name
                ))
            }
            let shellNode = entry["shell"]
            if shellNode != nil, shellNode?.string == nil {
                return .invalid(reason: String(
                    format: NSLocalizedString(
                        "“%@” has a shell: that is not a shell name.",
                        comment: "verification.yaml: shell given as a list or a mapping"
                    ),
                    name
                ))
            }
            let shell = shellNode?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            checks.append(Verification.Config.Check(
                name: name,
                command: command,
                shell: (shell?.isEmpty ?? true) ? nil : shell
            ))
        }
        return .loaded(Verification.Config(path: path, checks: checks))
    }
}

extension Verification.Config {
    /// The file a newly created project starts with.
    ///
    /// Deliberately **not** localized, for the reason `BareRepoClone` writes
    /// `"gitdir: ./.bare\n"` as a literal: this is file content the user edits,
    /// not UI, and the keys are part of the schema.
    ///
    /// The example check is left *uncommented* on purpose. A file of nothing but
    /// comments composes to nil, which `parse` reads as a config declaring no
    /// checks — so the Verification tab would swap the actionable "Add a
    /// verification.yaml…" for the dead-end "declares no checks", and writing the
    /// template would have made the empty state worse than not writing it.
    static let defaultContents = """
    # Verification checks for this project.
    #
    # Each entry is one check: its name, the command to run, and optionally the
    # shell to run it in (`$SHELL` by default). Commands run with the
    # workstream's worktree as the working directory, each in its own terminal
    # in the Verification tab.
    #
    #   rubocop:
    #     shell: fish
    #     command: bundle exec rubocop
    #
    #   rspec:
    #     command: bundle exec rspec
    #
    # Replace the example below with this project's real checks.

    example:
      command: echo "Edit verification.yaml to declare this project's checks."

    """

    /// Seed a newly created project with `defaultContents`.
    ///
    /// Called only by the two paths that *create* the project directory — a new
    /// empty project and a fresh clone — and never by the paths that adopt a
    /// directory the user already had, which would drop an untracked file into a
    /// repository they merely registered.
    ///
    /// Does nothing when either name in `fileNames` is already present, and
    /// reports rather than throws: a convenience template must not fail project
    /// creation, but a write that silently did not happen is worse than one that
    /// says so.
    @discardableResult
    static func writeDefault(projectDirectory: String) -> Bool {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        guard !fileNames.contains(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return false }

        let path = directory.appendingPathComponent(fileNames[0])
        do {
            try defaultContents.write(to: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.warning(
                "[Atelier] could not write default verification.yaml: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
